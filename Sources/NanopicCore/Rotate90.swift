import Foundation

/// キャンバスを 90 度回したときの座標の写し方（用紙の向きを直す）。
/// 時計回り: 元の (x, y) → (元の高さ - y, x)。反時計回り: 元の (x, y) → (y, 元の幅 - x)
public struct Rotate90: Sendable {
    public let clockwise: Bool
    /// 回す前のキャンバスの大きさ
    public let width: Int
    public let height: Int

    public init(clockwise: Bool, width: Int, height: Int) {
        self.clockwise = clockwise
        self.width = width
        self.height = height
    }

    public func point(_ p: RigPoint) -> RigPoint {
        clockwise ? RigPoint(Double(height) - p.y, p.x) : RigPoint(p.y, Double(width) - p.x)
    }

    /// 向きだけを回す（ずれ・移動量）
    public func vector(_ v: RigPoint) -> RigPoint {
        clockwise ? RigPoint(-v.y, v.x) : RigPoint(v.y, -v.x)
    }

    public func rect(_ r: RigRect) -> RigRect {
        clockwise
            ? RigRect(x: Double(height) - r.y - r.height, y: r.x, width: r.height, height: r.width)
            : RigRect(x: r.y, y: Double(width) - r.x - r.width, width: r.height, height: r.width)
    }

    public func rect(_ r: IntRect) -> IntRect {
        clockwise
            ? IntRect(x: height - r.y - r.height, y: r.x, width: r.height, height: r.width)
            : IntRect(x: r.y, y: width - r.x - r.width, width: r.height, height: r.width)
    }

    /// RGBA8 のバッファ（width × height）を回す。結果は height × width
    public func buffer(_ src: [UInt8]) -> [UInt8] {
        let w = width, h = height
        var dst = [UInt8](repeating: 0, count: w * h * 4)
        src.withUnsafeBytes { sp in
            dst.withUnsafeMutableBytes { dp in
                let s = sp.bindMemory(to: UInt32.self)
                let d = dp.bindMemory(to: UInt32.self)
                // 回したあとの幅は h
                for y in 0..<h {
                    for x in 0..<w {
                        let nx = clockwise ? h - 1 - y : y
                        let ny = clockwise ? x : w - 1 - x
                        d[ny * h + nx] = s[y * w + x]
                    }
                }
            }
        }
        return dst
    }

    /// ワープの格子の点の番号（回す前 → 回したあと）。回すと格子の縦横が入れ替わる
    func warpIndex(_ i: Int, cols: Int, rows: Int) -> Int {
        let c = i % (cols + 1), r = i / (cols + 1)
        // 回したあとの格子は cols' = rows, rows' = cols
        let nc = clockwise ? rows - r : r
        let nr = clockwise ? c : cols - c
        return nr * (rows + 1) + nc
    }

    func form(_ f: DeformerForm, deformer d: Deformer) -> DeformerForm {
        var out = f
        out.move = vector(f.move)
        guard d.kind == .warp else { return out }
        let n = d.pointCount
        if !f.offsets.isEmpty {
            var offsets = [RigPoint](repeating: .zero, count: n)
            for i in 0..<n { offsets[warpIndex(i, cols: d.cols, rows: d.rows)] = vector(f.offset(i)) }
            out.offsets = offsets
        }
        if !f.tangents.isEmpty {
            var tangents = [RigTangent](repeating: .zero, count: n)
            for i in 0..<n {
                let t = f.tangent(i)
                // 時計回り: 新しい横（右へ）は元の上へ、新しい縦（下へ）は元の右へ。反時計回りはその逆
                tangents[warpIndex(i, cols: d.cols, rows: d.rows)] = clockwise
                    ? RigTangent(u: vector(t.v * -1), v: vector(t.u))
                    : RigTangent(u: vector(t.v), v: vector(t.u * -1))
            }
            out.tangents = tangents
        }
        return out
    }

    public func rig(_ rig: Rig) -> Rig {
        var out = rig
        let old = Dictionary(uniqueKeysWithValues: rig.deformers.map { ($0.id, $0) })
        out.deformers = rig.deformers.map { d in
            var n = d
            n.pivot = point(d.pivot)
            if d.kind == .warp {
                n.rect = rect(d.rect)
                n.cols = d.rows
                n.rows = d.cols
            }
            return n
        }
        out.parameters = rig.parameters.map { p in
            var np = p
            np.keys = p.keys.map { k in
                var nk = k
                nk.forms = k.forms.reduce(into: [:]) { acc, e in
                    acc[e.key] = old[e.key].map { form(e.value, deformer: $0) } ?? e.value
                }
                return nk
            }
            return np
        }
        if var t = rig.turn {
            t.center = point(t.center)
            t.radius = RigPoint(t.radius.y, t.radius.x)
            out.turn = t
        }
        return out
    }
}
