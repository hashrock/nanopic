import CoreGraphics
import Foundation
import ImageIO

// MARK: - ブラシ設定

public enum BrushKind: String, Codable, Sendable {
    case brush
    case eraser
}

public struct BrushSettings: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var kind: BrushKind = .brush
    /// 直径 (px)
    public var size: Float = 10
    public var sizePressure = true
    /// 筆圧 0 のときのサイズ比
    public var minSizeRatio: Float = 0.0
    public var opacity: Float = 1
    public var opacityPressure = false
    public var minOpacityRatio: Float = 0.0
    /// 1 ダブあたりの濃度（1 = 最大値合成、小さいほど重ね塗りで濃くなる）
    public var flow: Float = 1
    public var hardness: Float = 0.9
    /// ダブ間隔（直径比）
    public var spacing: Float = 0.08
    /// ブラシ先端の ID（"round" は解析的な円）
    public var tipID: String = "round"
    public var angle: Float = 0
    public var followDirection = false
    public var roundness: Float = 1
    /// 手ブレ補正 0...1
    public var smoothing: Float = 0.3
    /// 筆圧カーブ（ガンマ）
    public var pressureGamma: Float = 1.0
    /// 筆圧変化の滑らかさ：サイズ変化の最大勾配（半径 px / 移動 px）
    public var pressureSlope: Float = 0.45
    /// 色混ぜ
    public var mixEnabled = false
    /// 絵の具量（ブラシ色の補給率）
    public var paintAmount: Float = 0.6
    /// 色延び（取り込んだ色の持続）
    public var colorStretch: Float = 0.6
    /// 散布・ランダム回転
    public var angleJitter: Float = 0
    /// サイズのランダム（ダブごとに最大この割合だけ小さくする。輪郭がギザギザになる）
    public var sizeJitter: Float = 0
    /// ぼかし 0...1（ブラシの下を周囲の平均に近づける）
    public var blurAmount: Float = 0
    /// ゆがみ: 前方（ブラシの進行方向に画素を押し出す）0...1
    public var warpPush: Float = 0
    /// ゆがみ: 膨張(+) / 縮小(-) -1...1
    public var warpRadial: Float = 0
    /// ゆがみ: 回転 右(+) / 左(-) -1...1
    public var warpTwist: Float = 0

    public var hasWarp: Bool { warpPush != 0 || warpRadial != 0 || warpTwist != 0 }
    /// レイヤーに直接作用するブラシ（色混ぜ・ぼかし・ゆがみ）
    public var isDirect: Bool { kind == .brush && (mixEnabled || blurAmount > 0 || hasWarp) }

    public init(name: String) {
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, size, sizePressure, minSizeRatio, opacity, opacityPressure, minOpacityRatio, flow, hardness
        case spacing, tipID, angle, followDirection, roundness, smoothing, pressureGamma, pressureSlope
        case mixEnabled, paintAmount, colorStretch, angleJitter, sizeJitter
        case blurAmount, warpPush, warpRadial, warpTwist
    }

    /// 項目が足りない古い保存データも読めるよう、無い項目は既定値にする
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BrushSettings(name: "")
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? def }
        id = try v(.id, d.id)
        name = try v(.name, d.name)
        kind = try v(.kind, d.kind)
        size = try v(.size, d.size)
        sizePressure = try v(.sizePressure, d.sizePressure)
        minSizeRatio = try v(.minSizeRatio, d.minSizeRatio)
        opacity = try v(.opacity, d.opacity)
        opacityPressure = try v(.opacityPressure, d.opacityPressure)
        minOpacityRatio = try v(.minOpacityRatio, d.minOpacityRatio)
        flow = try v(.flow, d.flow)
        hardness = try v(.hardness, d.hardness)
        spacing = try v(.spacing, d.spacing)
        tipID = try v(.tipID, d.tipID)
        angle = try v(.angle, d.angle)
        followDirection = try v(.followDirection, d.followDirection)
        roundness = try v(.roundness, d.roundness)
        smoothing = try v(.smoothing, d.smoothing)
        pressureGamma = try v(.pressureGamma, d.pressureGamma)
        pressureSlope = try v(.pressureSlope, d.pressureSlope)
        mixEnabled = try v(.mixEnabled, d.mixEnabled)
        paintAmount = try v(.paintAmount, d.paintAmount)
        colorStretch = try v(.colorStretch, d.colorStretch)
        angleJitter = try v(.angleJitter, d.angleJitter)
        sizeJitter = try v(.sizeJitter, d.sizeJitter)
        blurAmount = try v(.blurAmount, d.blurAmount)
        warpPush = try v(.warpPush, d.warpPush)
        warpRadial = try v(.warpRadial, d.warpRadial)
        warpTwist = try v(.warpTwist, d.warpTwist)
    }

    public static func == (a: BrushSettings, b: BrushSettings) -> Bool {
        a.id == b.id && a.name == b.name && a.kind == b.kind && a.size == b.size && a.sizePressure == b.sizePressure
            && a.minSizeRatio == b.minSizeRatio && a.opacity == b.opacity && a.opacityPressure == b.opacityPressure
            && a.minOpacityRatio == b.minOpacityRatio && a.flow == b.flow && a.hardness == b.hardness
            && a.spacing == b.spacing && a.tipID == b.tipID && a.angle == b.angle
            && a.followDirection == b.followDirection && a.roundness == b.roundness && a.smoothing == b.smoothing
            && a.pressureGamma == b.pressureGamma && a.pressureSlope == b.pressureSlope
            && a.mixEnabled == b.mixEnabled && a.paintAmount == b.paintAmount && a.colorStretch == b.colorStretch
            && a.angleJitter == b.angleJitter && a.sizeJitter == b.sizeJitter
            && a.blurAmount == b.blurAmount && a.warpPush == b.warpPush
            && a.warpRadial == b.warpRadial && a.warpTwist == b.warpTwist
    }

    public static var defaultPresets: [BrushSettings] {
        var pen = BrushSettings(name: "Gペン")
        pen.size = 8; pen.hardness = 1; pen.minSizeRatio = 0; pen.smoothing = 0.35

        var mapping = BrushSettings(name: "丸ペン")
        mapping.size = 3; mapping.hardness = 1; mapping.minSizeRatio = 0.2; mapping.smoothing = 0.45

        var pencil = BrushSettings(name: "鉛筆")
        pencil.size = 6; pencil.tipID = "pencil"; pencil.hardness = 1; pencil.minSizeRatio = 0.5
        pencil.opacityPressure = true; pencil.minOpacityRatio = 0.1; pencil.spacing = 0.12; pencil.smoothing = 0.15
        pencil.angleJitter = 1

        var airbrush = BrushSettings(name: "エアブラシ")
        airbrush.size = 120; airbrush.hardness = 0; airbrush.sizePressure = false
        airbrush.opacityPressure = true; airbrush.flow = 0.08; airbrush.spacing = 0.05; airbrush.smoothing = 0.2

        var watercolor = BrushSettings(name: "水彩")
        watercolor.size = 40; watercolor.hardness = 0.3; watercolor.minSizeRatio = 0.4
        watercolor.opacityPressure = true; watercolor.minOpacityRatio = 0.2; watercolor.mixEnabled = true
        watercolor.paintAmount = 0.35; watercolor.colorStretch = 0.7; watercolor.flow = 0.5

        var oil = BrushSettings(name: "油彩")
        oil.size = 30; oil.tipID = "bristle"; oil.hardness = 1; oil.minSizeRatio = 0.5
        oil.followDirection = true; oil.mixEnabled = true; oil.paintAmount = 0.7; oil.colorStretch = 0.5
        oil.spacing = 0.06

        var blender = BrushSettings(name: "色混ぜ")
        blender.size = 40; blender.hardness = 0.2; blender.minSizeRatio = 0.5
        blender.mixEnabled = true; blender.paintAmount = 0; blender.colorStretch = 0.85
        blender.opacityPressure = true

        var chalk = BrushSettings(name: "チョーク")
        chalk.size = 24; chalk.tipID = "chalk"; chalk.minSizeRatio = 0.6; chalk.angleJitter = 1
        chalk.spacing = 0.15; chalk.opacityPressure = true; chalk.minOpacityRatio = 0.3

        return [pen, mapping, pencil, airbrush, watercolor, oil, blender, chalk] + effectPresets
    }

    /// 指先ぼかし・ぼかし・ゆがみ（後から追加したプリセット）
    public static var effectPresets: [BrushSettings] {
        var finger = BrushSettings(name: "指先ぼかし")
        finger.size = 40; finger.hardness = 0.3; finger.sizePressure = true; finger.minSizeRatio = 0.5
        finger.opacityPressure = true; finger.minOpacityRatio = 0.2
        finger.mixEnabled = true; finger.paintAmount = 0; finger.colorStretch = 0.75
        finger.blurAmount = 0.35; finger.smoothing = 0.2

        var blur = BrushSettings(name: "ぼかし")
        blur.size = 60; blur.hardness = 0; blur.sizePressure = false
        blur.opacityPressure = true; blur.blurAmount = 0.8; blur.smoothing = 0.1

        var warp = BrushSettings(name: "ゆがみ")
        warp.size = 100; warp.hardness = 0; warp.sizePressure = false
        warp.opacityPressure = true; warp.minOpacityRatio = 0.3
        warp.warpPush = 0.5; warp.spacing = 0.05; warp.smoothing = 0.3
        return [finger, blur, warp]
    }

    public static var defaultErasers: [BrushSettings] {
        var hard = BrushSettings(name: "硬め")
        hard.kind = .eraser; hard.size = 30; hard.hardness = 1; hard.sizePressure = false; hard.smoothing = 0.1
        var soft = BrushSettings(name: "軟らかめ")
        soft.kind = .eraser; soft.size = 80; soft.hardness = 0; soft.sizePressure = false
        soft.opacityPressure = true; soft.flow = 0.3; soft.smoothing = 0.1
        var fine = BrushSettings(name: "細かい")
        fine.kind = .eraser; fine.size = 6; fine.hardness = 1; fine.minSizeRatio = 0.3; fine.smoothing = 0.2
        return [hard, soft, fine]
    }
}

// MARK: - ブラシ先端

/// ブラシ先端形状。ミップマップ付きのグレースケール（0...1）画像。
public final class BrushTip: @unchecked Sendable, Identifiable {
    public let id: String
    public let name: String
    /// true なら解析的な円（hardness を使う）
    public let isRound: Bool
    let levels: [(size: Int, data: [Float])]

    public init(roundTip: ()) {
        id = "round"
        name = "円"
        isRound = true
        levels = []
    }

    public init(id: String, name: String, size: Int, pixels: [Float]) {
        self.id = id
        self.name = name
        isRound = false
        var lv: [(Int, [Float])] = [(size, pixels)]
        var s = size
        var cur = pixels
        while s > 1 {
            let ns = s / 2
            var next = [Float](repeating: 0, count: ns * ns)
            for y in 0..<ns {
                for x in 0..<ns {
                    let a = cur[(2 * y) * s + 2 * x], b = cur[(2 * y) * s + 2 * x + 1]
                    let c = cur[(2 * y + 1) * s + 2 * x], d = cur[(2 * y + 1) * s + 2 * x + 1]
                    next[y * ns + x] = (a + b + c + d) * 0.25
                }
            }
            lv.append((ns, next))
            cur = next
            s = ns
        }
        levels = lv
    }

    /// 画像ファイルから読み込む（透明部分があればアルファ、なければ輝度の反転を濃度とする）
    public convenience init?(id: String, name: String, image: CGImage, size: Int = 256) {
        let n = size
        var rgba = [UInt8](repeating: 0, count: n * n * 4)
        let ok = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let scale = CGFloat(n) / max(w, h)
            let dw = w * scale, dh = h * scale
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: (CGFloat(n) - dw) / 2, y: (CGFloat(n) - dh) / 2, width: dw, height: dh))
            return true
        }
        guard ok else { return nil }
        // 不透明な領域の外側（余白）は透明なので、画像内部に透明ピクセルがあるかで判定
        var hasTransparency = false
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = CGFloat(n) / max(w, h)
        let x0 = Int((CGFloat(n) - w * scale) / 2) + 1, x1 = Int((CGFloat(n) + w * scale) / 2) - 1
        let y0 = Int((CGFloat(n) - h * scale) / 2) + 1, y1 = Int((CGFloat(n) + h * scale) / 2) - 1
        if x0 < x1 && y0 < y1 {
            outer: for y in y0..<y1 {
                for x in x0..<x1 where rgba[(y * n + x) * 4 + 3] < 250 {
                    hasTransparency = true
                    break outer
                }
            }
        }
        var px = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) {
            let a = Float(rgba[i * 4 + 3]) / 255
            if hasTransparency {
                px[i] = a
            } else {
                // premultiplied → 白地前提で輝度の反転
                let r = Float(rgba[i * 4]) / 255, g = Float(rgba[i * 4 + 1]) / 255, b = Float(rgba[i * 4 + 2]) / 255
                let l = 0.299 * r + 0.587 * g + 0.114 * b + (1 - a)
                px[i] = clamp01(1 - l)
            }
        }
        self.init(id: id, name: name, size: n, pixels: px)
    }

    public convenience init?(id: String, name: String, url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        self.init(id: id, name: name, image: img)
    }

    @inline(__always) private func sampleLevel(_ l: Int, _ u: Float, _ v: Float) -> Float {
        let (s, d) = levels[l]
        let fx = u * Float(s) - 0.5, fy = v * Float(s) - 0.5
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        @inline(__always) func at(_ x: Int, _ y: Int) -> Float {
            (x >= 0 && y >= 0 && x < s && y < s) ? d[y * s + x] : 0
        }
        let a = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * tx
        let b = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * tx
        return a + (b - a) * ty
    }

    /// u, v は 0...1。lod はミップレベル（小数でトライリニア）
    @inline(__always) func sample(_ u: Float, _ v: Float, lod: Float) -> Float {
        if u < 0 || v < 0 || u > 1 || v > 1 { return 0 }
        let maxL = levels.count - 1
        let l = min(max(lod, 0), Float(maxL))
        let l0 = Int(l)
        let f = l - Float(l0)
        let a = sampleLevel(l0, u, v)
        if f < 0.01 || l0 >= maxL { return a }
        return a + (sampleLevel(l0 + 1, u, v) - a) * f
    }

    func lod(forDiameter d: Float) -> Float {
        guard let base = levels.first?.size else { return 0 }
        return max(0, log2(Float(base) / max(d, 1)))
    }

    /// UI 用プレビュー画像（黒 on 透明）
    public func previewImage(size: Int = 48) -> CGImage? {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let u = (Float(x) + 0.5) / Float(size), v = (Float(y) + 0.5) / Float(size)
                var a: Float
                if isRound {
                    let dx = u - 0.5, dy = v - 0.5
                    a = sqrt(dx * dx + dy * dy) < 0.45 ? 1 : 0
                } else {
                    a = sample(u, v, lod: lod(forDiameter: Float(size)))
                }
                px[(y * size + x) * 4 + 3] = UInt8(clamp01(a) * 255)
            }
        }
        let data = Data(px) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: 組み込み先端

    public static func builtins() -> [BrushTip] {
        [BrushTip(roundTip: ()), pencilTip(), chalkTip(), bristleTip(), flatTip(), sprayTip()]
    }

    private static func noise(_ x: Int, _ y: Int, _ seed: Int) -> Float {
        pixelHash(x &+ seed &* 7919, y &- seed &* 104_729)
    }

    private static func valueNoise(_ fx: Float, _ fy: Float, _ seed: Int) -> Float {
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let a = noise(x0, y0, seed), b = noise(x0 + 1, y0, seed)
        let c = noise(x0, y0 + 1, seed), d = noise(x0 + 1, y0 + 1, seed)
        return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
    }

    private static func generate(_ id: String, _ name: String, size: Int = 256, _ f: (Float, Float, Int, Int) -> Float) -> BrushTip {
        var px = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let u = (Float(x) + 0.5) / Float(size) * 2 - 1
                let v = (Float(y) + 0.5) / Float(size) * 2 - 1
                px[y * size + x] = clamp01(f(u, v, x, y))
            }
        }
        return BrushTip(id: id, name: name, size: size, pixels: px)
    }

    static func pencilTip() -> BrushTip {
        generate("pencil", "鉛筆") { u, v, x, y in
            let r = sqrt(u * u + v * v)
            let edge = clamp01((0.95 - r) / 0.12)
            let grain = noise(x, y, 3)
            return edge * (grain > 0.45 ? 1 : grain * 1.4)
        }
    }

    static func chalkTip() -> BrushTip {
        generate("chalk", "チョーク") { u, v, x, y in
            let r = sqrt(u * u + v * v)
            let n = valueNoise(Float(x) / 9, Float(y) / 9, 11) * 0.6 + valueNoise(Float(x) / 3, Float(y) / 3, 5) * 0.4
            let edge = clamp01((0.9 - r + (n - 0.5) * 0.35) / 0.08)
            return edge * clamp01((n - 0.32) * 3)
        }
    }

    static func bristleTip() -> BrushTip {
        generate("bristle", "毛筆") { u, v, x, _ in
            let r = sqrt(u * u * 1.0 + v * v * 1.0)
            let bristle = valueNoise(Float(x) / 3.5, 0.5, 21)
            let edge = clamp01((0.92 - r) / 0.1)
            return edge * (0.35 + 0.65 * clamp01((bristle - 0.2) * 1.6))
        }
    }

    static func flatTip() -> BrushTip {
        generate("flat", "平筆") { u, v, _, _ in
            let ex = clamp01((0.95 - abs(u)) / 0.05)
            let ey = clamp01((0.3 - abs(v)) / 0.05)
            return ex * ey
        }
    }

    static func sprayTip() -> BrushTip {
        generate("spray", "スプレー") { u, v, x, y in
            let r = sqrt(u * u + v * v)
            let n = noise(x, y, 77)
            let density = clamp01(1 - r) * 0.35
            return n < density ? 1 : 0
        }
    }
}

// MARK: - ダブ

public struct Dab: Sendable {
    public var x: Float
    public var y: Float
    public var radius: Float
    /// 濃度の上限（不透明度 × 筆圧）
    public var alpha: Float
    /// ラジアン
    public var angle: Float
    public var color: SIMD3<Float>

    public init(x: Float, y: Float, radius: Float, alpha: Float, angle: Float = 0, color: SIMD3<Float> = .zero) {
        self.x = x
        self.y = y
        self.radius = radius
        self.alpha = alpha
        self.angle = angle
        self.color = color
    }
}

// MARK: - ストロークバッファ

public enum StrokeApplyMode: Sendable {
    case normal
    case lockAlpha
    case erase
}

/// ストローク中の描画を Float 精度で蓄積するスパースバッファ。
/// 各ピクセルはストレートカラー (r, g, b) と濃度 a を持つ。
public final class StrokeBuffer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    private(set) var tiles: [TileKey: UnsafeMutablePointer<RGBA>] = [:]
    public private(set) var touched: IntRect = .zero

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    deinit {
        for (_, p) in tiles { p.deallocate() }
    }

    public var tileKeys: [TileKey] { Array(tiles.keys) }

    private func tile(_ key: TileKey) -> UnsafeMutablePointer<RGBA> {
        if let t = tiles[key] { return t }
        let t = UnsafeMutablePointer<RGBA>.allocate(capacity: kTilePixelCount)
        t.initialize(repeating: .zero, count: kTilePixelCount)
        tiles[key] = t
        return t
    }

    @inline(__always) func pixel(_ x: Int, _ y: Int) -> RGBA {
        guard x >= 0, y >= 0, x < width, y < height else { return .zero }
        guard let t = tiles[TileKey(x: x / kTileSize, y: y / kTileSize)] else { return .zero }
        return t[(y % kTileSize) * kTileSize + (x % kTileSize)]
    }

    /// ダブを描画し、変更された矩形を返す
    @discardableResult
    public func render(_ dab: Dab, tip: BrushTip, hardness: Float, roundness: Float, flow: Float) -> IntRect {
        guard dab.x.isFinite, dab.y.isFinite, dab.radius.isFinite, dab.alpha.isFinite,
              abs(dab.x) < 1e6, abs(dab.y) < 1e6, dab.radius < 1e5 else { return .zero }
        var radius = dab.radius
        var cap = dab.alpha
        // 半径 0.5 未満はサイズではなく濃度で表現（細い線の入り抜きを滑らかに）
        if radius < 0.5 {
            cap *= max(0, radius / 0.5) * max(0, radius / 0.5)
            radius = 0.5
        }
        if cap <= 0.0005 { return .zero }
        let extent = radius + 1.5
        let bb = IntRect(minX: Int(floor(dab.x - extent)), minY: Int(floor(dab.y - extent)),
                         maxX: Int(ceil(dab.x + extent)), maxY: Int(ceil(dab.y + extent)))
            .intersection(IntRect(x: 0, y: 0, width: width, height: height))
        if bb.isEmpty { return .zero }
        touched = touched.union(bb)

        let cosA = cos(dab.angle), sinA = sin(dab.angle)
        let invRound = 1 / max(roundness, 0.05)
        let color = dab.color
        let flow = clamp01(flow)
        let isRound = tip.isRound
        let lod = isRound ? 0 : tip.lod(forDiameter: radius * 2)
        let inv2R = 1 / (2 * radius)
        // 円形の縁のぼかし幅（最低 1px でアンチエイリアス）
        let falloff = max(radius * (1 - clamp01(hardness)), 1)
        let smooth = hardness < 0.99

        for key in bb.tileKeys {
            let t = tile(key)
            let tr = key.rect.intersection(bb)
            let ox = key.x * kTileSize, oy = key.y * kTileSize
            for py in tr.minY..<tr.maxY {
                let dy = Float(py) + 0.5 - dab.y
                let row = t + (py - oy) * kTileSize
                for px in tr.minX..<tr.maxX {
                    let dx = Float(px) + 0.5 - dab.x
                    let lx = dx * cosA + dy * sinA
                    let ly = (-dx * sinA + dy * cosA) * invRound
                    var shape: Float
                    if isRound {
                        let d = (lx * lx + ly * ly).squareRoot()
                        let tt = clamp01((radius + 0.5 - d) / falloff)
                        if tt <= 0 { continue }
                        shape = smooth ? tt * tt * (3 - 2 * tt) : tt
                    } else {
                        shape = tip.sample(lx * inv2R + 0.5, ly * inv2R + 0.5, lod: lod)
                        if shape <= 0 { continue }
                    }
                    let target = cap * shape
                    let i = px - ox
                    var p = row[i]
                    let a0 = p.w
                    if target > a0 {
                        p.w = a0 + (target - a0) * flow
                    }
                    // 色は被覆率に応じて新しい色へ寄せる
                    let w = a0 <= 0 ? 1 : clamp01(shape * flow)
                    p.x += (color.x - p.x) * w
                    p.y += (color.y - p.y) * w
                    p.z += (color.z - p.z) * w
                    row[i] = p
                }
            }
        }
        return bb
    }

    /// レイヤーのタイル（premultiplied RGBA8）にストロークを適用して out に書き込む。
    /// src と out は同じポインタでもよい。
    public func apply(key: TileKey, src: UnsafePointer<UInt8>?, out: UnsafeMutablePointer<UInt8>,
                      mode: StrokeApplyMode, selection: SelectionMask?) -> Bool {
        guard let st = tiles[key] else {
            if let src {
                if UnsafePointer(out) != src { out.update(from: src, count: kTilePixelCount * 4) }
                return true
            }
            return false
        }
        if src == nil {
            out.initialize(repeating: 0, count: kTilePixelCount * 4)
            if mode != .normal { return false }
        } else if UnsafePointer(out) != src {
            out.update(from: src!, count: kTilePixelCount * 4)
        }
        let ox = key.x * kTileSize, oy = key.y * kTileSize
        let k: Float = 1.0 / 255.0
        let selW = selection?.width ?? 0
        func run(_ selData: UnsafePointer<UInt8>?) {
        for y in 0..<kTileSize {
            let gy = oy + y
            if gy >= height { break }
            for x in 0..<kTileSize {
                let gx = ox + x
                if gx >= width { break }
                let i = y * kTileSize + x
                let s = st[i]
                if s.w <= 0 { continue }
                var a = s.w
                if let selData {
                    a *= Float(selData[gy * selW + gx]) * k
                    if a <= 0 { continue }
                }
                let o = out + i * 4
                let d = RGBA(Float(o[0]), Float(o[1]), Float(o[2]), Float(o[3])) * k
                var r: RGBA
                switch mode {
                case .normal:
                    r = RGBA(s.x * a, s.y * a, s.z * a, a) + d * (1 - a)
                case .lockAlpha:
                    r = RGBA(s.x * a * d.w, s.y * a * d.w, s.z * a * d.w, 0) + d * (1 - a)
                    r.w = d.w
                case .erase:
                    r = d * (1 - a)
                }
                // ディザ付き量子化（8bit 化による段差を抑える）
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
            selection.data.withUnsafeBufferPointer { run($0.baseAddress) }
        } else {
            run(nil)
        }
        return true
    }

    public func clear() {
        for (_, p) in tiles { p.deallocate() }
        tiles.removeAll()
        touched = .zero
    }
}
