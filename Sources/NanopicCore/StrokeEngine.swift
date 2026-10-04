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

/// 入力サンプル列を滑らかな曲線に補間し、等間隔のダブを生成する。
///
/// 1. 位置を One Euro Filter で平滑化（手ブレ補正。速く動かすほど補正が弱まり遅延が減る）
/// 2. Centripetal Catmull-Rom スプラインで補間し、弧長に沿ってダブを配置
/// 3. 筆圧はスプライン上で連続に補間したうえで、移動距離あたりの変化量を制限
///    （入り抜きや筆圧の急変でブラシサイズが急に変わらないようにする）
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

    private var fx: OneEuroFilter
    private var fy: OneEuroFilter
    private var fp: OneEuroFilter
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
        let beta = 0.05 * pow(0.15, s) * self.zoom  // 速度 (canvas px/s) × zoom = 画面 px/s
        fx = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        fy = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        fp = OneEuroFilter(minCutoff: 12, beta: 0.5)
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
        _ = fx.filter(s.x, dt: 1.0 / 240)
        _ = fy.filter(s.y, dt: 1.0 / 240)
        _ = fp.filter(p, dt: 1.0 / 240)
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
        var dt = s.time - prev.time
        if dt <= 0.0005 { dt = 1.0 / 240 }
        dt = min(dt, 0.1)
        lastRaw = s
        let x: Double, y: Double
        if brush.smoothing > 0.001 {
            x = fx.filter(s.x, dt: dt)
            y = fy.filter(s.y, dt: dt)
        } else {
            x = s.x
            y = s.y
        }
        let p = usePressure ? fp.filter(curvedPressure(s.pressure), dt: dt) : 1
        pushPoint(Point(x: x, y: y, p: p, t: s.time))
    }

    public func end() {
        // 手ブレ補正の遅れを取り戻す：最後の位置でフィルタを回し続けて滑らかに収束させる
        if let raw = lastRaw, brush.smoothing > 0.001, let lastP = pts.last?.p {
            var t = raw.time
            for _ in 0..<60 {
                t += 1.0 / 240
                let x = fx.filter(raw.x, dt: 1.0 / 240)
                let y = fy.filter(raw.y, dt: 1.0 / 240)
                pushPoint(Point(x: x, y: y, p: lastP, t: t))
                if hypot(raw.x - x, raw.y - y) < 0.3 { break }
            }
        }
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
        let slope = Double(max(brush.pressureSlope, 0.02))
        // サイズ変化の最大勾配（半径 px / 移動 px）→ 筆圧単位へ換算。
        // サイズが筆圧で変わらないブラシでも濃度の急変を抑えるため最大半径を基準にする。
        let perPx = slope / max(maxRadius, 1.0)
        // 静止中もゆっくり変化できるよう時間成分も加える（0→1 に約 0.12 秒）
        let allowed = perPx * ds + dt / 0.12
        let diff = target - effP
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
