import Foundation

/// ストローク中の描画先（プレビューと確定で共通に使う）
public protocol StrokeTarget: AnyObject {
    var touched: IntRect { get }
    var tileKeys: [TileKey] { get }
    func apply(key: TileKey, src: UnsafePointer<UInt8>?, out: UnsafeMutablePointer<UInt8>,
               mode: StrokeApplyMode, selection: SelectionMask?) -> Bool
}

extension StrokeBuffer: StrokeTarget {}

/// ダブ 1 個分の形状（円 or 先端画像、角度・扁平率つき）
struct DabShape {
    let cx: Float, cy: Float
    let radius: Float
    let cosA: Float, sinA: Float
    let invRound: Float
    let tip: BrushTip
    let lod: Float
    let falloff: Float
    let smooth: Bool

    init(dab: Dab, radius: Float, tip: BrushTip, hardness: Float, roundness: Float) {
        cx = dab.x
        cy = dab.y
        self.radius = radius
        cosA = cos(dab.angle)
        sinA = sin(dab.angle)
        invRound = 1 / max(roundness, 0.05)
        self.tip = tip
        lod = tip.isRound ? 0 : tip.lod(forDiameter: radius * 2)
        falloff = max(radius * (1 - clamp01(hardness)), 1)
        smooth = hardness < 0.99
    }

    /// ピクセル中心 (px + 0.5, py + 0.5) での被覆率 0...1
    @inline(__always) func value(_ px: Int, _ py: Int) -> Float {
        let dx = Float(px) + 0.5 - cx, dy = Float(py) + 0.5 - cy
        let lx = dx * cosA + dy * sinA
        let ly = (-dx * sinA + dy * cosA) * invRound
        if tip.isRound {
            let d = (lx * lx + ly * ly).squareRoot()
            let t = clamp01((radius + 0.5 - d) / falloff)
            return smooth ? t * t * (3 - 2 * t) : t
        }
        let inv2R = 1 / (2 * radius)
        return tip.sample(lx * inv2R + 0.5, ly * inv2R + 0.5, lod: lod)
    }
}

/// 色混ぜブラシ用。レイヤーの作業コピー（premultiplied Float）に直接描き、
/// 前の位置の画素をパッチとして持ち運んで新しい位置に置く（下の絵を引きずる）。
public final class MixBuffer: StrokeTarget, @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// ストローク開始時のレイヤー（ストローク中は不変）
    private let layer: TileMap
    private var tiles: [TileKey: UnsafeMutablePointer<RGBA>] = [:]
    public private(set) var touched: IntRect = .zero

    // 持ち運んでいる絵の具（ダブ中心を原点とするグリッド、premultiplied）
    private var carried: [RGBA] = []
    private var carriedGrid = 0
    private var carriedExtent: Float = 0

    public init(layer: TileMap, width: Int, height: Int) {
        self.layer = layer
        self.width = width
        self.height = height
    }

    deinit {
        for (_, p) in tiles { p.deallocate() }
    }

    public var tileKeys: [TileKey] { Array(tiles.keys) }

    private func workingTile(_ key: TileKey) -> UnsafeMutablePointer<RGBA> {
        if let t = tiles[key] { return t }
        let t = UnsafeMutablePointer<RGBA>.allocate(capacity: kTilePixelCount)
        if let src = layer[key] {
            let k: Float = 1.0 / 255.0
            for i in 0..<kTilePixelCount {
                let p = src.data + i * 4
                t[i] = RGBA(Float(p[0]), Float(p[1]), Float(p[2]), Float(p[3])) * k
            }
        } else {
            t.initialize(repeating: .zero, count: kTilePixelCount)
        }
        tiles[key] = t
        return t
    }

    @inline(__always) private func pixel(_ x: Int, _ y: Int) -> RGBA {
        let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
        let key = TileKey(x: cx / kTileSize, y: cy / kTileSize)
        let i = (cy % kTileSize) * kTileSize + (cx % kTileSize)
        if let t = tiles[key] { return t[i] }
        guard let src = layer[key] else { return .zero }
        let p = src.data + i * 4
        return RGBA(Float(p[0]), Float(p[1]), Float(p[2]), Float(p[3])) / 255
    }

    /// 作業コピーのバイリニアサンプル（座標はピクセル単位、ピクセル中心が +0.5）
    private func sample(_ fx: Float, _ fy: Float) -> RGBA {
        let x = fx - 0.5, y = fy - 0.5
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let tx = x - Float(x0), ty = y - Float(y0)
        let a = pixel(x0, y0), b = pixel(x0 + 1, y0), c = pixel(x0, y0 + 1), d = pixel(x0 + 1, y0 + 1)
        let top = a + (b - a) * tx
        let bot = c + (d - c) * tx
        return top + (bot - top) * ty
    }

    /// 持ち運んでいるパッチのバイリニアサンプル（ダブ中心からの相対座標）
    @inline(__always) private func carriedAt(_ lx: Float, _ ly: Float) -> RGBA {
        let g = carriedGrid
        let cell = 2 * carriedExtent / Float(g)
        let fx = (lx + carriedExtent) / cell - 0.5, fy = (ly + carriedExtent) / cell - 0.5
        let x0 = min(max(Int(floor(fx)), 0), g - 1), y0 = min(max(Int(floor(fy)), 0), g - 1)
        let x1 = min(x0 + 1, g - 1), y1 = min(y0 + 1, g - 1)
        let tx = clamp01(fx - Float(x0)), ty = clamp01(fy - Float(y0))
        let top = carried[y0 * g + x0] + (carried[y0 * g + x1] - carried[y0 * g + x0]) * tx
        let bot = carried[y1 * g + x0] + (carried[y1 * g + x1] - carried[y1 * g + x0]) * tx
        return top + (bot - top) * ty
    }

    /// 色混ぜダブを描く
    /// - paintAmount: 絵の具量（ブラシ色の補給、ブラシ直径の移動あたり）
    /// - colorStretch: 色延び（持ち運んだ色が残る割合。小さいほど下の色に置き換わりやすい）
    @discardableResult
    public func render(_ dab: Dab, brushColor: SIMD3<Float>, tip: BrushTip, hardness: Float, roundness: Float,
                       flow: Float, spacing: Float, paintAmount: Float, colorStretch: Float) -> IntRect {
        guard dab.x.isFinite, dab.y.isFinite, dab.radius.isFinite, dab.alpha.isFinite,
              abs(dab.x) < 1e6, abs(dab.y) < 1e6, dab.radius < 1e5 else { return .zero }
        var radius = dab.radius
        var strength = dab.alpha * clamp01(flow)
        if radius < 0.5 {
            strength *= max(0, radius / 0.5) * max(0, radius / 0.5)
            radius = 0.5
        }
        let extent = radius + 1.5
        let brushP = RGBA(brushColor.x, brushColor.y, brushColor.z, 1)
        // ブラシ直径あたりの割合をダブあたりに換算（1 画素が受けるダブ数 ≒ 1 / 間隔）
        let e = max(spacing, 0.02)
        let supply = 1 - pow(1 - clamp01(paintAmount), e)
        // 色延び → 持ち運んだ色が半分入れ替わるまでの距離（ブラシ直径の何倍か）
        let stretch = clamp01(colorStretch)
        let halfLife = 0.03 + 1.5 * stretch * stretch
        let pickup = 1 - pow(0.5, e / halfLife)

        // 新しい位置の下の絵をパッチとしてサンプル
        let g = min(max(Int(ceil(2 * extent)), 2), 96)
        let cell = 2 * extent / Float(g)
        var under = [RGBA](repeating: .zero, count: g * g)
        for j in 0..<g {
            for i in 0..<g {
                under[j * g + i] = sample(dab.x - extent + (Float(i) + 0.5) * cell, dab.y - extent + (Float(j) + 0.5) * cell)
            }
        }
        if carried.isEmpty {
            // 最初のダブ: 下の色とブラシ色を絵の具量で混ぜたものを持つ
            carried = under.map { $0 + (brushP - $0) * clamp01(paintAmount) }
        } else if carriedGrid != g || carriedExtent != extent {
            // 筆圧でサイズが変わったらグリッドを取り直す（外側は下の色）
            var re = [RGBA](repeating: .zero, count: g * g)
            let oldExtent = carriedExtent
            for j in 0..<g {
                for i in 0..<g {
                    let lx = -extent + (Float(i) + 0.5) * cell, ly = -extent + (Float(j) + 0.5) * cell
                    re[j * g + i] = (abs(lx) <= oldExtent && abs(ly) <= oldExtent) ? carriedAt(lx, ly) : under[j * g + i]
                }
            }
            carried = re
        }
        carriedGrid = g
        carriedExtent = extent

        // 持ち運んだ絵の具を置く
        let bb = IntRect(minX: Int(floor(dab.x - extent)), minY: Int(floor(dab.y - extent)),
                         maxX: Int(ceil(dab.x + extent)), maxY: Int(ceil(dab.y + extent)))
            .intersection(IntRect(x: 0, y: 0, width: width, height: height))
        if !bb.isEmpty && strength > 0.0005 {
            touched = touched.union(bb)
            let shape = DabShape(dab: dab, radius: radius, tip: tip, hardness: hardness, roundness: roundness)
            for key in bb.tileKeys {
                let t = workingTile(key)
                let tr = key.rect.intersection(bb)
                let ox = key.x * kTileSize, oy = key.y * kTileSize
                for py in tr.minY..<tr.maxY {
                    let row = t + (py - oy) * kTileSize
                    for px in tr.minX..<tr.maxX {
                        let sv = shape.value(px, py)
                        if sv <= 0 { continue }
                        let k = 1 - pow(1 - clamp01(sv * strength), e)
                        let c = carriedAt(Float(px) + 0.5 - dab.x, Float(py) + 0.5 - dab.y)
                        let i = px - ox
                        row[i] += (c - row[i]) * k
                    }
                }
            }
        }

        // 下の絵を拾い、ブラシ色を補給する
        for i in 0..<carried.count {
            var c = carried[i]
            c += (under[i] - c) * pickup
            c += (brushP - c) * supply
            carried[i] = c
        }
        return bb
    }

    public func apply(key: TileKey, src: UnsafePointer<UInt8>?, out: UnsafeMutablePointer<UInt8>,
                      mode: StrokeApplyMode, selection: SelectionMask?) -> Bool {
        guard let wt = tiles[key] else {
            if let src {
                if UnsafePointer(out) != src { out.update(from: src, count: kTilePixelCount * 4) }
                return true
            }
            return false
        }
        if src == nil {
            if mode == .lockAlpha { return false }
            out.initialize(repeating: 0, count: kTilePixelCount * 4)
        } else if UnsafePointer(out) != src {
            out.update(from: src!, count: kTilePixelCount * 4)
        }
        let ox = key.x * kTileSize, oy = key.y * kTileSize
        let k: Float = 1.0 / 255.0
        func run(_ sel: UnsafePointer<UInt8>?, _ selW: Int) {
            for y in 0..<kTileSize {
                let gy = oy + y
                if gy >= height { break }
                for x in 0..<kTileSize {
                    let gx = ox + x
                    if gx >= width { break }
                    let i = y * kTileSize + x
                    let o = out + i * 4
                    let s = RGBA(Float(o[0]), Float(o[1]), Float(o[2]), Float(o[3])) * k
                    var w = wt[i]
                    if mode == .lockAlpha {
                        // 透明度は元のまま、色だけ差し替える
                        let rgb = w.w > 0.0001 ? SIMD3(w.x, w.y, w.z) / w.w : SIMD3(s.x, s.y, s.z) / max(s.w, 0.0001)
                        w = RGBA(rgb.x * s.w, rgb.y * s.w, rgb.z * s.w, s.w)
                    }
                    let m: Float = sel.map { Float($0[gy * selW + gx]) * k } ?? 1
                    let r = s + (w - s) * m
                    if r == s { continue }
                    let n = pixelHash(gx, gy) - 0.5
                    let aq = min(max((r.w * 255 + n).rounded(), 0), 255)
                    o[3] = UInt8(aq)
                    o[0] = UInt8(min(max((r.x * 255 + n).rounded(), 0), aq))
                    o[1] = UInt8(min(max((r.y * 255 + n).rounded(), 0), aq))
                    o[2] = UInt8(min(max((r.z * 255 + n).rounded(), 0), aq))
                }
            }
        }
        if let selection {
            selection.data.withUnsafeBufferPointer { run($0.baseAddress, selection.width) }
        } else {
            run(nil, 0)
        }
        return true
    }
}
