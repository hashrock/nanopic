import Foundation

public struct StrokeInput: Sendable {
    public var x: Double
    public var y: Double
    /// 0...1
    public var pressure: Double
    /// 秒
    public var time: Double

    public init(x: Double, y: Double, pressure: Double, time: Double) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.time = time
    }

    /// Apple Pencil の力を筆圧 (0...1) にする。普段の筆圧で 0.5 前後、軽く触れたときは十分小さくなる曲線
    public static func applePencilPressure(force: Double, maximum: Double) -> Double {
        guard maximum > 0 else { return 1 }
        return pow(min(1, force / maximum * 1.6), 1.15)
    }
}

/// One Euro Filter（速度に応じてカットオフを変える低域通過フィルタ）
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var dCutoff: Double = 8.0
    private var x: Double?
    private var dx: Double = 0

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1.0 / (2 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    mutating func filter(_ value: Double, dt: Double) -> Double {
        guard let prev = x else {
            x = value
            return value
        }
        let rawDx = (value - prev) / dt
        dx += (rawDx - dx) * Self.alpha(dCutoff, dt)
        let cutoff = minCutoff + beta * abs(dx)
        let v = prev + (value - prev) * Self.alpha(cutoff, dt)
        x = v
        return v
    }
}

/// 位置用の One Euro Filter。カットオフは 2 次元の速さで決め、X と Y に同じ強さでかける
/// （軸ごとに決めると、片方の軸の速度が 0 になる場所でそちらだけ強く補正され、円が角張る）
struct OneEuroFilter2D {
    var minCutoff: Double
    var beta: Double
    var dCutoff: Double = 8.0
    /// 1 段目と 2 段目の出力（2 段重ねて、手の揺れを強く落としつつ接線の折れをなくす）
    private var pos: (x: Double, y: Double)?
    private var out: (x: Double, y: Double)?
    private var dx: Double = 0
    private var dy: Double = 0

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1.0 / (2 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    mutating func filter(x: Double, y: Double, dt: Double) -> (x: Double, y: Double) {
        guard let prev = pos, let prevOut = out else {
            pos = (x, y)
            out = (x, y)
            return (x, y)
        }
        let da = Self.alpha(dCutoff, dt)
        dx += ((x - prev.x) / dt - dx) * da
        dy += ((y - prev.y) / dt - dy) * da
        let a = Self.alpha(minCutoff + beta * hypot(dx, dy), dt)
        let first = (x: prev.x + (x - prev.x) * a, y: prev.y + (y - prev.y) * a)
        let second = (x: prevOut.x + (first.x - prevOut.x) * a, y: prevOut.y + (first.y - prevOut.y) * a)
        pos = first
        out = second
        return second
    }
}

/// 入力サンプル列を滑らかな曲線に補間し、等間隔のダブを生成する。
///
/// 1. 位置を One Euro Filter で平滑化（手ブレ補正。速く動かすほど補正が弱まり遅延が減る）
/// 2. Centripetal Catmull-Rom スプラインで補間し、弧長に沿ってダブを配置
/// 3. 筆圧は時間でならしたうえで移動距離あたりの変化量を制限する（速いストロークほど長い距離でならされる）
/// 4. 最後の少しの区間は描くのを遅らせ、ペンを離したと分かったら、その区間で筆圧を 0 まで抜く
public final class StrokeEngine {
    struct Point {
        var x: Double
        var y: Double
        var p: Double
        var t: Double
    }

    public let brush: BrushSettings
    public let usePressure: Bool
    /// 表示倍率（手ブレ補正の強さを画面上の見た目基準にする）
    public let zoom: Double
    public var emit: (Dab) -> Void = { _ in }

    private var fpos: OneEuroFilter2D
    /// 筆圧をならす 2 段のフィルタの状態
    private var pressure1: Double = 0
    private var pressure2: Double = 0
    /// 描くのを遅らせている点（離したときに抜きをつけるため）
    private var held: [Point] = []
    /// ペンを離したあとの抜きを描いている
    private var tailing = false
    /// 抜きの始まりで、実効筆圧と目標がつながるようにする係数
    private var tailScale: Double = 1
    /// 筆圧をならす時定数（秒）。2 段なので目標の 90% に届くまでこの約 3.9 倍かかる
    private var pressureTimeConstant: Double { Double(clamp01(brush.pressureSmoothing)) * 0.04 }
    /// 描くのを遅らせる時間（秒）
    private var liftHoldback: Double { Double(clamp01(brush.liftTaper)) * 0.06 }
    private var pts: [Point] = []
    private var lastRaw: StrokeInput?
    private var lastTime: Double = 0
    private var segmentsDrawn = 0

    /// 制限後の実効筆圧
    private var effP: Double
    private var distSinceDab: Double = 0
    private var dabCount = 0
    private var lastDir: Double = 0
    private var jitterSeed: Int = 0
    /// サイズのランダムの乱数（0...1）。次に打つダブの分を先に決めておき、間隔をランダム後の太さで決める
    private var nextSizeRandom: Double = 0
    private var lastSizeRandom: Double = 0
    /// 設定すると、ペンが止まっていてもこの間隔（秒）でダブを出し続ける（ゆがみの膨張・回転用）
    public var continuousInterval: Double?
    private var currentTime: Double = 0
    private var lastDabTime: Double = -1
    private var lastDabPos: (Double, Double)?

    /// seed: サイズ・角度のランダムの種。同じ種・同じ入力なら必ず同じダブを出す
    public init(brush: BrushSettings, usePressure: Bool, zoom: Double = 1, seed: Int = 0) {
        self.brush = brush
        self.usePressure = usePressure
        self.zoom = max(zoom, 0.01)
        let s = Double(clamp01(brush.smoothing))
        // 手ブレ補正: 強いほど最小カットオフを下げる。速度係数 beta は画面座標基準。
        let minCutoff = 14.0 * pow(0.02, s)        // s=0: 14Hz, s=1: 0.28Hz
        let beta = 0.03 * pow(0.2, s) * self.zoom  // 速度 (canvas px/s) × zoom = 画面 px/s
        fpos = OneEuroFilter2D(minCutoff: minCutoff, beta: beta)
        effP = usePressure ? 0 : 1
        jitterSeed = seed
        nextSizeRandom = rollSizeRandom()
        lastSizeRandom = nextSizeRandom
    }

    /// サイズのランダムで半径をどれだけ小さくするかの上限（px）。小さいペンでは半径そのもの（今まで通り）、
    /// 大きいペンではこれで頭打ち（にじみの幅がペン先に比例して大きくなりすぎないように）
    static let sizeJitterLimit = 10.0

    static func jitteredRadius(_ r: Double, amount: Double, random u: Double) -> Double {
        guard amount > 0 else { return r }
        let scale = min(r, sizeJitterLimit)
        return max(r - amount * u * scale, r * 0.05)
    }

    private func rollSizeRandom() -> Double {
        guard brush.sizeJitter > 0 else { return 0 }
        jitterSeed &+= 1
        return Double(pixelHash(jitterSeed, 101))
    }

    /// 描き始めの入力から決める乱数の種（同じストロークは毎回同じ結果になる）
    public static func seed(for s: StrokeInput) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for v in [s.x, s.y, s.pressure] {
            h = (h ^ v.bitPattern) &* 0x100_0000_01b3
        }
        return Int(truncatingIfNeeded: h % 1_000_000)
    }

    private var maxRadius: Double { Double(max(brush.size, 1)) / 2 }

    private func curvedPressure(_ p: Double) -> Double {
        guard usePressure else { return 1 }
        let g = Double(max(brush.pressureGamma, 0.05))
        return pow(min(max(p, 0), 1), g)
    }

    // MARK: 入力

    public func begin(_ s: StrokeInput) {
        lastRaw = s
        lastTime = s.time
        let p = curvedPressure(s.pressure)
        _ = fpos.filter(x: s.x, y: s.y, dt: 1.0 / 240)
        pts = [Point(x: s.x, y: s.y, p: p, t: s.time)]
        if !usePressure {
            emitDab(x: s.x, y: s.y, dirX: 0, dirY: 0)
        }
    }

    public func add(_ s: StrokeInput) {
        guard let prev = lastRaw else {
            begin(s)
            return
        }
        // 離した瞬間の 0 は本当の筆圧ではない（抜きは end でつける）
        if usePressure && s.pressure <= 0 { return }
        var dt = s.time - prev.time
        if dt <= 0.0005 { dt = 1.0 / 240 }
        dt = min(dt, 0.1)
        lastRaw = s
        let x: Double, y: Double
        if brush.smoothing > 0.001 {
            (x, y) = fpos.filter(x: s.x, y: s.y, dt: dt)
        } else {
            x = s.x
            y = s.y
        }
        let q = Point(x: x, y: y, p: usePressure ? curvedPressure(s.pressure) : 1, t: s.time)
        guard holdsBackForLift else {
            pushPoint(q)
            return
        }
        held.append(q)
        var n = 0
        while n < held.count, q.t - held[n].t > liftHoldback {
            pushPoint(held[n])
            n += 1
        }
        if n > 0 { held.removeFirst(n) }
    }

    private var holdsBackForLift: Bool { usePressure && continuousInterval == nil && brush.liftTaper > 0.001 }

    /// 残りの区間の筆圧を、弧長に沿って 0 まで落とす
    private func applyLiftTaper(_ tail: inout [Point]) {
        guard tail.count >= 2 else { return }
        var total = 0.0
        for i in 1..<tail.count { total += hypot(tail[i].x - tail[i - 1].x, tail[i].y - tail[i - 1].y) }
        // ほとんど動いていない（タップなど）なら抜かない
        guard total >= 2 else { return }
        let start = pts.last?.p ?? tail[0].p
        var run = 0.0
        for i in 1..<tail.count {
            run += hypot(tail[i].x - tail[i - 1].x, tail[i].y - tail[i - 1].y)
            tail[i].p = start * max(0, 1 - run / total)
        }
        tail[0].p = start
        tailScale = start > 0.001 ? min(effP / start, 1.5) : 1
    }

    public func end() {
        // 手ブレ補正の遅れを取り戻す：最後の位置でフィルタを回し続けて滑らかに収束させる
        var tail = held
        held.removeAll()
        if let raw = lastRaw, brush.smoothing > 0.001, let lastP = tail.last?.p ?? pts.last?.p {
            var t = raw.time
            for _ in 0..<60 {
                t += 1.0 / 240
                let (x, y) = fpos.filter(x: raw.x, y: raw.y, dt: 1.0 / 240)
                tail.append(Point(x: x, y: y, p: lastP, t: t))
                if hypot(raw.x - x, raw.y - y) < 0.3 { break }
            }
        }
        if holdsBackForLift { applyLiftTaper(&tail) }
        tailing = holdsBackForLift && tail.count >= 2
        for q in tail { pushPoint(q) }
        if pts.count >= 2 {
            drawPendingSegment(final: true)
        } else if let only = pts.first, dabCount == 0 {
            // タップ（点）: 経過時間に応じて筆圧を成長させて 1 ダブ
            let dur = max(0, (lastRaw?.time ?? only.t) - only.t)
            advancePressure(target: only.p, ds: 0, dt: dur + 0.02)
            emitDab(x: only.x, y: only.y, dirX: 0, dirY: 0)
        }
        pts.removeAll()
    }

    private func pushPoint(_ q: Point) {
        currentTime = q.t
        guard let last = pts.last else {
            pts.append(q)
            return
        }
        let d = hypot(q.x - last.x, q.y - last.y)
        if d < 0.35 {
            // ほぼ静止: 最後の点の筆圧・時刻だけ更新（まだ描画していない点なので安全）
            pts[pts.count - 1].p = q.p
            let dt = q.t - pts[pts.count - 1].t
            pts[pts.count - 1].t = q.t
            if let iv = continuousInterval, q.t - lastDabTime >= iv {
                // 止まっていても効果をかけ続ける
                advancePressure(target: q.p, ds: 0, dt: max(dt, 0))
                let pos = lastDabPos ?? (last.x, last.y)
                emitDab(x: pos.0, y: pos.1, dirX: 0, dirY: 0)
                return
            }
            if pts.count == 1 && usePressure {
                // 描き始めで止まっている間も少しずつ太らせる
                let before = effP
                advancePressure(target: q.p, ds: 0, dt: max(dt, 0))
                if effP > before + 0.03 || (dabCount == 0 && effP > 0.05) {
                    emitDab(x: last.x, y: last.y, dirX: 0, dirY: 0)
                }
            }
            return
        }
        pts.append(q)
        drawPendingSegment(final: false)
    }

    /// pts の末尾 3〜4 点から、末尾の 1 つ手前までの区間を描画する
    private func drawPendingSegment(final: Bool) {
        let n = pts.count
        if final {
            // 最後の区間 pts[n-2] → pts[n-1]
            guard n >= 2 else { return }
            let p1 = pts[n - 2], p2 = pts[n - 1]
            let p0 = n >= 3 ? pts[n - 3] : reflect(p2, about: p1)
            let p3 = reflect(p1, about: p2)
            drawSegment(p0, p1, p2, p3)
            return
        }
        // 区間 pts[n-3] → pts[n-2]（次の点が来たので接線が決まる）
        guard n >= 3 else { return }
        let p1 = pts[n - 3], p2 = pts[n - 2], p3 = pts[n - 1]
        let p0 = n >= 4 ? pts[n - 4] : reflect(p2, about: p1)
        drawSegment(p0, p1, p2, p3)
        if pts.count > 8 { pts.removeFirst(pts.count - 8) }
    }

    private func reflect(_ a: Point, about b: Point) -> Point {
        Point(x: 2 * b.x - a.x, y: 2 * b.y - a.y, p: b.p, t: b.t)
    }

    // MARK: スプライン

    private func drawSegment(_ p0: Point, _ p1: Point, _ p2: Point, _ p3: Point) {
        segmentsDrawn += 1
        let chord = hypot(p2.x - p1.x, p2.y - p1.y)
        if chord < 1e-6 { return }
        // Centripetal Catmull-Rom (alpha = 0.5)
        func knot(_ a: Point, _ b: Point) -> Double { max(pow(hypot(b.x - a.x, b.y - a.y), 0.5), 1e-4) }
        let t0 = 0.0
        let t1 = t0 + knot(p0, p1)
        let t2 = t1 + knot(p1, p2)
        let t3 = t2 + knot(p2, p3)

        func eval(_ u: Double) -> (Double, Double) {
            let t = t1 + (t2 - t1) * u
            func lerp(_ a: (Double, Double), _ b: (Double, Double), _ ta: Double, _ tb: Double) -> (Double, Double) {
                let w = (t - ta) / (tb - ta)
                return (a.0 + (b.0 - a.0) * w, a.1 + (b.1 - a.1) * w)
            }
            let a1 = lerp((p0.x, p0.y), (p1.x, p1.y), t0, t1)
            let a2 = lerp((p1.x, p1.y), (p2.x, p2.y), t1, t2)
            let a3 = lerp((p2.x, p2.y), (p3.x, p3.y), t2, t3)
            let b1 = lerp(a1, a2, t0, t2)
            let b2 = lerp(a2, a3, t1, t3)
            return lerp(b1, b2, t1, t2)
        }
        // 筆圧: 一様 Catmull-Rom（区間内で連続・なめらか）
        func pressureAt(_ u: Double) -> Double {
            let u2 = u * u, u3 = u2 * u
            let v = 0.5 * ((2 * p1.p) + (-p0.p + p2.p) * u + (2 * p0.p - 5 * p1.p + 4 * p2.p - p3.p) * u2
                + (-p0.p + 3 * p1.p - 3 * p2.p + p3.p) * u3)
            // オーバーシュートを両端の範囲に抑える
            return min(max(v, min(p1.p, p2.p)), max(p1.p, p2.p))
        }

        let steps = max(2, min(4000, Int(ceil(chord / 0.4))))
        let segDt = max(0, p2.t - p1.t)
        var prev = (p1.x, p1.y)
        for i in 1...steps {
            let u = Double(i) / Double(steps)
            let cur = eval(u)
            let dx = cur.0 - prev.0, dy = cur.1 - prev.1
            let ds = hypot(dx, dy)
            if ds <= 0 { continue }
            advancePressure(target: pressureAt(u), ds: ds, dt: segDt / Double(steps))
            // 間隔は現在の半径で決める（細い入り抜きでは密に）。サイズのランダムがあれば、
            // 直前のダブと次のダブの小さいほうの太さにする（小さくなったダブの前後ですき間が空かないように）
            let r = currentRadius(), amount = Double(clamp01(brush.sizeJitter))
            let rr = min(Self.jitteredRadius(r, amount: amount, random: lastSizeRandom),
                         Self.jitteredRadius(r, amount: amount, random: nextSizeRandom))
            let spacing = max(Double(brush.spacing) * 2 * rr, 0.3)
            distSinceDab += ds
            if distSinceDab >= spacing || dabCount == 0 {
                // 超過分だけ戻った位置に置く
                let back = dabCount == 0 ? 0 : min(distSinceDab - spacing, ds)
                let w = back / ds
                emitDab(x: cur.0 - dx * w, y: cur.1 - dy * w, dirX: dx, dirY: dy)
                distSinceDab = back
            }
            prev = cur
        }
    }

    // MARK: 筆圧の変化制限

    private func advancePressure(target: Double, ds: Double, dt: Double) {
        guard usePressure else {
            effP = 1
            return
        }
        if tailing {
            effP = min(max(target * tailScale, 0), 1)
            return
        }
        let tau = pressureTimeConstant
        let k = tau < 0.0005 ? 1 : 1 - exp(-max(dt, 0) / tau)
        pressure1 += (target - pressure1) * k
        pressure2 += (pressure1 - pressure2) * k
        let slope = Double(max(brush.pressureSlope, 0.02))
        // サイズ変化の最大勾配（半径 px / 移動 px）→ 筆圧単位へ換算。
        // サイズが筆圧で変わらないブラシでも濃度の急変を抑えるため最大半径を基準にする。
        let perPx = slope / max(maxRadius, 1.0)
        // 静止中も変化できるよう時間成分も加える（0→1 に約 0.06 秒）
        let allowed = perPx * ds + dt / 0.06
        let diff = pressure2 - effP
        effP += min(max(diff, -allowed), allowed)
        effP = min(max(effP, 0), 1)
    }

    private func currentRadius() -> Double {
        let r = maxRadius
        if brush.sizePressure {
            let m = Double(brush.minSizeRatio)
            return r * (m + (1 - m) * effP)
        }
        return r
    }

    private func currentAlpha() -> Double {
        var a = Double(brush.opacity)
        if brush.opacityPressure {
            let m = Double(brush.minOpacityRatio)
            a *= m + (1 - m) * effP
        }
        // サイズ筆圧のみのブラシでも、ごく弱い筆圧では濃度も落として入り抜きを自然に
        if brush.sizePressure && usePressure && brush.minSizeRatio < 0.01 {
            a *= min(1, effP * 8)
        }
        return a
    }

    private func emitDab(x: Double, y: Double, dirX: Double, dirY: Double) {
        var angle = Double(brush.angle) * .pi / 180
        if brush.followDirection {
            if dirX != 0 || dirY != 0 { lastDir = atan2(dirY, dirX) }
            angle += lastDir
        }
        if brush.angleJitter > 0 {
            jitterSeed &+= 1
            angle += Double(pixelHash(jitterSeed, 17) - 0.5) * 2 * .pi * Double(brush.angleJitter)
        }
        // ダブごとにランダムに小さくする（筆圧の変化制限とは独立）。乱数は前もって決めてある
        let radius = Self.jitteredRadius(currentRadius(), amount: Double(clamp01(brush.sizeJitter)), random: nextSizeRandom)
        lastSizeRandom = nextSizeRandom
        nextSizeRandom = rollSizeRandom()
        let dab = Dab(x: Float(x), y: Float(y), radius: Float(radius), alpha: Float(currentAlpha()),
                      angle: Float(angle))
        dabCount += 1
        lastDabTime = currentTime
        lastDabPos = (x, y)
        emit(dab)
    }
}
