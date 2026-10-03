import Foundation

// MARK: - データ

public struct RigPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
    public static let zero = RigPoint(0, 0)
}

public struct RigRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum DeformerKind: String, Codable, Sendable {
    /// 中心と角度
    case rotation
    /// 範囲を格子に分け、格子の点のずれで面を曲げる
    case warp
}

/// レイヤーかフォルダーに付けて形を変えるもの。フォルダーに付けると中のレイヤー全部に効く
public struct Deformer: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// 付けるレイヤー（フォルダー）の PSD レイヤー ID
    public var layer: UInt32
    public var kind: DeformerKind
    /// 回転の中心（ドキュメント座標、基本の形）
    public var pivot = RigPoint.zero
    /// ワープの範囲（ドキュメント座標、基本の形）
    public var rect = RigRect(x: 0, y: 0, width: 0, height: 0)
    /// ワープの格子のマス数
    public var cols = 4
    public var rows = 4

    public init(id: String, name: String, layer: UInt32, kind: DeformerKind) {
        self.id = id
        self.name = name
        self.layer = layer
        self.kind = kind
    }

    /// ワープの格子の点の数（左上から右へ、行ごと）
    public var pointCount: Int { kind == .warp ? (cols + 1) * (rows + 1) : 0 }

    /// 格子の点の基本の位置
    public func restPoint(_ i: Int) -> RigPoint {
        let c = i % (cols + 1), r = i / (cols + 1)
        return RigPoint(rect.x + rect.width * Double(c) / Double(cols), rect.y + rect.height * Double(r) / Double(rows))
    }
}

/// デフォーマの形（基本の形からのずれ）
public struct DeformerForm: Codable, Equatable, Sendable {
    /// 回転: 角度（度、時計回り）
    public var angle: Double = 0
    /// ワープ: 格子の点ごとのずれ（足りない分は 0）
    public var offsets: [RigPoint] = []

    public init(angle: Double = 0, offsets: [RigPoint] = []) {
        self.angle = angle
        self.offsets = offsets
    }

    public var isZero: Bool { angle == 0 && offsets.allSatisfy { $0 == .zero } }

    func offset(_ i: Int) -> RigPoint { i < offsets.count ? offsets[i] : .zero }

    static func lerp(_ a: DeformerForm, _ b: DeformerForm, _ t: Double) -> DeformerForm {
        let n = max(a.offsets.count, b.offsets.count)
        return DeformerForm(angle: a.angle + (b.angle - a.angle) * t,
                            offsets: (0..<n).map { i in
                                let p = a.offset(i), q = b.offset(i)
                                return RigPoint(p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t)
                            })
    }

    static func + (a: DeformerForm, b: DeformerForm) -> DeformerForm {
        let n = max(a.offsets.count, b.offsets.count)
        return DeformerForm(angle: a.angle + b.angle,
                            offsets: (0..<n).map { RigPoint(a.offset($0).x + b.offset($0).x, a.offset($0).y + b.offset($0).y) })
    }
}

/// 名前つきのつまみ。いくつかの値（キー）で、各デフォーマの形を記録する
public struct RigParameter: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var min: Double = 0
    public var max: Double = 1
    public var defaultValue: Double = 0
    /// 値の順に並べる
    public var keys: [RigParameterKey] = []

    public init(id: String, name: String, min: Double = 0, max: Double = 1, defaultValue: Double = 0) {
        self.id = id
        self.name = name
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
    }

    public func clamp(_ v: Double) -> Double { Swift.min(Swift.max(v, min), max) }

    /// value でのデフォーマの形（キーの間は直線で補間、外側は端のキー。キーにないデフォーマは 0）。
    /// 既定値にキーがなければ、ずれ 0 のキーがそこにあるものとする（既定値はいつも基本ポーズ）
    public func form(for deformer: String, at value: Double) -> DeformerForm? {
        guard !keys.isEmpty else { return nil }
        var keys = keys
        if !keys.contains(where: { abs($0.value - defaultValue) < 1e-9 }) {
            keys.append(RigParameterKey(value: defaultValue))
            keys.sort { $0.value < $1.value }
        }
        guard let first = keys.first, let last = keys.last else { return nil }
        func f(_ k: RigParameterKey) -> DeformerForm { k.forms[deformer] ?? DeformerForm() }
        if value <= first.value { return f(first) }
        if value >= last.value { return f(last) }
        for i in 1..<keys.count where value <= keys[i].value {
            let a = keys[i - 1], b = keys[i]
            return DeformerForm.lerp(f(a), f(b), (value - a.value) / Swift.max(b.value - a.value, 1e-9))
        }
        return f(last)
    }
}

public struct RigParameterKey: Codable, Equatable, Sendable {
    public var value: Double
    /// デフォーマ ID → 形
    public var forms: [String: DeformerForm] = [:]

    public init(value: Double, forms: [String: DeformerForm] = [:]) {
        self.value = value
        self.forms = forms
    }
}

/// デフォーマとパラメータの一式
public struct Rig: Codable, Equatable, Sendable {
    public var deformers: [Deformer] = []
    public var parameters: [RigParameter] = []

    public init() {}

    public var isEmpty: Bool { deformers.isEmpty && parameters.isEmpty }

    public func deformer(_ id: String) -> Deformer? { deformers.first { $0.id == id } }
    public func parameter(_ id: String) -> RigParameter? { parameters.first { $0.id == id } }

    /// パラメータの値（ないものは既定値）での各デフォーマの形（パラメータごとのずれを足し合わせる）
    public func forms(values: [String: Double]) -> [String: DeformerForm] {
        var out: [String: DeformerForm] = [:]
        for p in parameters {
            let v = p.clamp(values[p.id] ?? p.defaultValue)
            for d in deformers {
                guard let f = p.form(for: d.id, at: v), !f.isZero else { continue }
                out[d.id] = (out[d.id] ?? DeformerForm()) + f
            }
        }
        return out
    }

    /// 形が基本のまま（何も動いていない）か
    public func isRest(values: [String: Double]) -> Bool {
        forms(values: values).values.allSatisfy(\.isZero)
    }
}

// MARK: - 点を写す

extension Deformer {
    /// 基本の形の点 p を、form の形に写したときの位置
    public func map(_ p: RigPoint, _ form: DeformerForm) -> RigPoint {
        switch kind {
        case .rotation:
            guard form.angle != 0 else { return p }
            let a = form.angle * .pi / 180
            let dx = p.x - pivot.x, dy = p.y - pivot.y
            return RigPoint(pivot.x + dx * cos(a) - dy * sin(a), pivot.y + dx * sin(a) + dy * cos(a))
        case .warp:
            guard rect.width > 0, rect.height > 0, !form.offsets.isEmpty else { return p }
            // 範囲の外は端のずれをそのまま使う
            let u = Swift.min(Swift.max((p.x - rect.x) / rect.width, 0), 1) * Double(cols)
            let v = Swift.min(Swift.max((p.y - rect.y) / rect.height, 0), 1) * Double(rows)
            let c = Swift.min(Int(u), cols - 1), r = Swift.min(Int(v), rows - 1)
            let fu = u - Double(c), fv = v - Double(r)
            let w = cols + 1
            let o00 = form.offset(r * w + c), o10 = form.offset(r * w + c + 1)
            let o01 = form.offset((r + 1) * w + c), o11 = form.offset((r + 1) * w + c + 1)
            let ox = (o00.x * (1 - fu) + o10.x * fu) * (1 - fv) + (o01.x * (1 - fu) + o11.x * fu) * fv
            let oy = (o00.y * (1 - fu) + o10.y * fu) * (1 - fv) + (o01.y * (1 - fu) + o11.y * fu) * fv
            return RigPoint(p.x + ox, p.y + oy)
        }
    }
}

// MARK: - ポーズを当てる

extension DocumentState {
    /// パラメータの値でデフォーマをかけたドキュメント（動くレイヤーの画素を移したもの）
    public func posed(values: [String: Double]) -> DocumentState {
        let forms = rig.forms(values: values)
        guard !forms.isEmpty else { return self }
        // レイヤー（フォルダー）ごとに付いているデフォーマ
        var byLayer: [UInt32: [Deformer]] = [:]
        for d in rig.deformers where forms[d.id] != nil { byLayer[d.layer, default: []].append(d) }
        guard !byLayer.isEmpty else { return self }
        var out = self
        func walk(_ nodes: inout [LayerNode], outer: [Deformer]) {
            for i in nodes.indices {
                // 内側（自分）から外側（親）の順
                let chain = (byLayer[nodes[i].psdID] ?? []) + outer
                if nodes[i].isFolder {
                    walk(&nodes[i].children, outer: chain)
                } else if !chain.isEmpty {
                    nodes[i].tiles = Self.warp(nodes[i].tiles, chain: chain, forms: forms, width: width, height: height)
                }
            }
        }
        walk(&out.layers, outer: [])
        return out
    }

    /// レイヤーの画素を、細かい三角形の網で基本の形からポーズの形へ移す
    static func warp(_ tiles: TileMap, chain: [Deformer], forms: [String: DeformerForm], width w: Int, height h: Int) -> TileMap {
        guard let b0 = tiles.contentBounds() else { return tiles }
        let b = b0.insetBy(-1).intersection(IntRect(x: 0, y: 0, width: w, height: h))
        let cell = 24.0
        let nx = Swift.min(Swift.max(Int((Double(b.width) / cell).rounded(.up)), 1), 160)
        let ny = Swift.min(Swift.max(Int((Double(b.height) / cell).rounded(.up)), 1), 160)
        var src: [RigPoint] = []
        var dst: [RigPoint] = []
        for j in 0...ny {
            for i in 0...nx {
                let p = RigPoint(Double(b.minX) + Double(b.width) * Double(i) / Double(nx),
                                 Double(b.minY) + Double(b.height) * Double(j) / Double(ny))
                src.append(p)
                var q = p
                for d in chain { q = d.map(q, forms[d.id] ?? DeformerForm()) }
                dst.append(q)
            }
        }
        var tris: [(Int, Int, Int)] = []
        for j in 0..<ny {
            for i in 0..<nx {
                let a = j * (nx + 1) + i, bb = a + 1, c = a + nx + 1, d = c + 1
                tris.append((a, bb, d))
                tris.append((a, d, c))
            }
        }
        let srcBuf = tiles.toBuffer(width: w, height: h)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let band = 32
        srcBuf.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                let sp = s.baseAddress!, op = o.baseAddress!
                // 行の帯ごとに並列（帯どうしは書く場所が重ならない）
                DispatchQueue.concurrentPerform(iterations: (h + band - 1) / band) { bi in
                    let y0 = bi * band, y1 = Swift.min(y0 + band, h)
                    for (ia, ib, ic) in tris {
                        rasterize(dst[ia], dst[ib], dst[ic], src[ia], src[ib], src[ic], rows: y0..<y1, width: w, height: h, src: sp, out: op)
                    }
                }
            }
        }
        return out.withUnsafeBufferPointer { TileMap.from(buffer: $0.baseAddress!, width: w, height: h, gen: 0) }
    }

    /// 写した先の三角形 (a, b, c) を塗り、各画素は元の三角形 (sa, sb, sc) の同じ位置から双線形でとる
    private static func rasterize(_ a: RigPoint, _ b: RigPoint, _ c: RigPoint, _ sa: RigPoint, _ sb: RigPoint, _ sc: RigPoint,
                                  rows: Range<Int>, width w: Int, height h: Int,
                                  src: UnsafePointer<UInt8>, out: UnsafeMutablePointer<UInt8>) {
        let det = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
        guard abs(det) > 1e-9 else { return }
        let minY = Swift.max(Int(floor(Swift.min(a.y, b.y, c.y))), rows.lowerBound)
        let maxY = Swift.min(Int(ceil(Swift.max(a.y, b.y, c.y))), rows.upperBound - 1)
        let minX = Swift.max(Int(floor(Swift.min(a.x, b.x, c.x))), 0)
        let maxX = Swift.min(Int(ceil(Swift.max(a.x, b.x, c.x))), w - 1)
        guard minY <= maxY, minX <= maxX else { return }
        let eps = -1e-6
        for y in minY...maxY {
            let py = Double(y) + 0.5
            for x in minX...maxX {
                let px = Double(x) + 0.5
                let l1 = ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / det
                let l2 = ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / det
                let l3 = 1 - l1 - l2
                if l1 < eps || l2 < eps || l3 < eps { continue }
                let sx = l1 * sa.x + l2 * sb.x + l3 * sc.x - 0.5
                let sy = l1 * sa.y + l2 * sb.y + l3 * sc.y - 0.5
                let x0 = Int(floor(sx)), y0 = Int(floor(sy))
                let fx = sx - Double(x0), fy = sy - Double(y0)
                var acc = (0.0, 0.0, 0.0, 0.0)
                for (dx, dy, wgt) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
                    let xx = x0 + dx, yy = y0 + dy
                    guard wgt > 0, xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                    let o = (yy * w + xx) * 4
                    acc.0 += Double(src[o]) * wgt
                    acc.1 += Double(src[o + 1]) * wgt
                    acc.2 += Double(src[o + 2]) * wgt
                    acc.3 += Double(src[o + 3]) * wgt
                }
                let o = (y * w + x) * 4
                out[o] = UInt8(Swift.min(acc.0 + 0.5, 255))
                out[o + 1] = UInt8(Swift.min(acc.1 + 0.5, 255))
                out[o + 2] = UInt8(Swift.min(acc.2 + 0.5, 255))
                out[o + 3] = UInt8(Swift.min(acc.3 + 0.5, 255))
            }
        }
    }
}
