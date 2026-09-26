import Foundation
import simd

public typealias RGBA = SIMD4<Float>

// MARK: - ブレンド関数（ストレートカラー、b = 下地, s = 合成色）

@inline(__always) private func lum(_ c: SIMD3<Float>) -> Float { 0.3 * c.x + 0.59 * c.y + 0.11 * c.z }

@inline(__always) private func clipColor(_ c: SIMD3<Float>) -> SIMD3<Float> {
    let l = lum(c)
    let n = min(c.x, min(c.y, c.z))
    let x = max(c.x, max(c.y, c.z))
    var r = c
    if n < 0 { r = SIMD3(repeating: l) + (r - SIMD3(repeating: l)) * l / max(l - n, 1e-6) }
    if x > 1 { r = SIMD3(repeating: l) + (r - SIMD3(repeating: l)) * (1 - l) / max(x - l, 1e-6) }
    return r
}

@inline(__always) private func setLum(_ c: SIMD3<Float>, _ l: Float) -> SIMD3<Float> {
    clipColor(c + SIMD3(repeating: l - lum(c)))
}

@inline(__always) private func sat(_ c: SIMD3<Float>) -> Float {
    max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z))
}

@inline(__always) private func setSat(_ c: SIMD3<Float>, _ s: Float) -> SIMD3<Float> {
    let mx = max(c.x, max(c.y, c.z))
    let mn = min(c.x, min(c.y, c.z))
    let range = mx - mn
    if range <= 1e-6 { return .zero }
    return (c - SIMD3(repeating: mn)) * (s / range)
}

@inline(__always) private func colorDodge(_ b: Float, _ s: Float) -> Float {
    if b <= 0 { return 0 }
    if s >= 1 { return 1 }
    return min(1, b / (1 - s))
}

@inline(__always) private func colorBurn(_ b: Float, _ s: Float) -> Float {
    if b >= 1 { return 1 }
    if s <= 0 { return 0 }
    return 1 - min(1, (1 - b) / s)
}

@inline(__always) private func softLight(_ b: Float, _ s: Float) -> Float {
    if s <= 0.5 { return b - (1 - 2 * s) * b * (1 - b) }
    let d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : sqrt(b)
    return b + (2 * s - 1) * (d - b)
}

@inline(__always) private func hardLight(_ b: Float, _ s: Float) -> Float {
    s <= 0.5 ? b * 2 * s : b + (2 * s - 1) - b * (2 * s - 1)
}

@inline(__always) private func vividLight(_ b: Float, _ s: Float) -> Float {
    s <= 0.5 ? colorBurn(b, 2 * s) : colorDodge(b, 2 * (s - 0.5))
}

@inline(__always) private func perChannel(_ b: SIMD3<Float>, _ s: SIMD3<Float>, _ f: (Float, Float) -> Float) -> SIMD3<Float> {
    SIMD3(f(b.x, s.x), f(b.y, s.y), f(b.z, s.z))
}

@inline(__always) func blendColor(_ mode: BlendMode, _ b: SIMD3<Float>, _ s: SIMD3<Float>) -> SIMD3<Float> {
    switch mode {
    case .normal, .passThrough, .dissolve: return s
    case .multiply: return b * s
    case .screen: return b + s - b * s
    case .overlay: return perChannel(b, s) { b, s in hardLight(s, b) }
    case .darken: return simd_min(b, s)
    case .lighten: return simd_max(b, s)
    case .colorDodge: return perChannel(b, s, colorDodge)
    case .colorBurn: return perChannel(b, s, colorBurn)
    case .hardLight: return perChannel(b, s, hardLight)
    case .softLight: return perChannel(b, s, softLight)
    case .difference: return abs(b - s)
    case .exclusion: return b + s - 2 * b * s
    case .linearBurn: return simd_max(b + s - SIMD3(repeating: 1), .zero)
    case .linearDodge: return simd_min(b + s, SIMD3(repeating: 1))
    case .subtract: return simd_max(b - s, .zero)
    case .divide: return perChannel(b, s) { b, s in s <= 0 ? (b <= 0 ? 0 : 1) : min(1, b / s) }
    case .vividLight: return perChannel(b, s, vividLight)
    case .linearLight: return simd_clamp(b + 2 * s - SIMD3(repeating: 1), .zero, SIMD3(repeating: 1))
    case .pinLight: return perChannel(b, s) { b, s in s <= 0.5 ? min(b, 2 * s) : max(b, 2 * s - 1) }
    case .hardMix: return perChannel(b, s) { b, s in b + s >= 1 ? 1 : 0 }
    case .hue: return setLum(setSat(s, sat(b)), lum(b))
    case .saturation: return setLum(setSat(b, sat(s)), lum(b))
    case .color: return setLum(s, lum(b))
    case .luminosity: return setLum(b, lum(s))
    case .darkerColor: return lum(s) < lum(b) ? s : b
    case .lighterColor: return lum(s) > lum(b) ? s : b
    }
}

// MARK: - 合成

public struct CompositeOptions {
    /// このレイヤーのタイルは overrideTile で生成したものに置き換える（ストローク・変形のプレビュー）
    public var overrideLayerID: UUID?
    /// (key, 元タイル, 出力先) -> 出力したかどうか（false なら透明扱い）
    public var overrideTile: ((TileKey, UnsafePointer<UInt8>?, UnsafeMutablePointer<UInt8>) -> Bool)?
    /// 参照レイヤーのみ合成
    public var referenceOnly = false
    /// 非表示レイヤーも含める
    public var ignoreVisibility = false

    public init() {}
}

public enum Compositor {
    final class Context {
        let options: CompositeOptions
        init(options: CompositeOptions) { self.options = options }
    }

    /// タイル 1 枚分を premultiplied Float で合成する。acc は呼び出し側でゼロ初期化しておく。
    public static func compositeTile(_ layers: [LayerNode], key: TileKey, options: CompositeOptions,
                                     into acc: UnsafeMutablePointer<RGBA>) {
        let ctx = Context(options: options)
        compositeList(layers, key: key, ctx: ctx, acc: acc, inReference: false)
    }

    /// 指定矩形を合成して RGBA8 premultiplied でバッファに書き込む
    public static func composite(_ doc: DocumentState, rect: IntRect, options: CompositeOptions = CompositeOptions(),
                                 into buffer: UnsafeMutablePointer<UInt8>, bufferWidth: Int) {
        let r = rect.intersection(doc.bounds)
        if r.isEmpty { return }
        let keys = r.tileKeys
        let layers = doc.layers
        let ctx = Context(options: options)
        let bufAddr = UInt(bitPattern: buffer)
        DispatchQueue.concurrentPerform(iterations: keys.count) { i in
            let key = keys[i]
            let acc = UnsafeMutablePointer<RGBA>.allocate(capacity: kTilePixelCount)
            acc.initialize(repeating: .zero, count: kTilePixelCount)
            defer { acc.deallocate() }
            compositeList(layers, key: key, ctx: ctx, acc: acc, inReference: false)
            let tr = key.rect.intersection(r)
            let out = UnsafeMutablePointer<UInt8>(bitPattern: bufAddr)!
            for y in tr.minY..<tr.maxY {
                let srcRow = acc + (y - key.y * kTileSize) * kTileSize
                let dstRow = out + (y * bufferWidth) * 4
                for x in tr.minX..<tr.maxX {
                    let v = srcRow[x - key.x * kTileSize]
                    let o = x * 4
                    dstRow[o] = toByte(v.x)
                    dstRow[o + 1] = toByte(v.y)
                    dstRow[o + 2] = toByte(v.z)
                    dstRow[o + 3] = toByte(v.w)
                }
            }
        }
    }

    /// キャンバス全体を合成した RGBA8 premultiplied バッファ
    public static func compositeFull(_ doc: DocumentState, options: CompositeOptions = CompositeOptions()) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: doc.width * doc.height * 4)
        buf.withUnsafeMutableBufferPointer { p in
            composite(doc, rect: doc.bounds, options: options, into: p.baseAddress!, bufferWidth: doc.width)
        }
        return buf
    }

    @inline(__always) static func toByte(_ v: Float) -> UInt8 {
        UInt8(clamp01(v) * 255 + 0.5)
    }

    // MARK: 内部

    private static func rasterSource(_ node: LayerNode, key: TileKey, ctx: Context,
                                     scratch: UnsafeMutablePointer<UInt8>) -> UnsafePointer<UInt8>? {
        let tile = node.tiles[key]
        if let oid = ctx.options.overrideLayerID, oid == node.id, let ov = ctx.options.overrideTile {
            return ov(key, tile.map { UnsafePointer($0.data) }, scratch) ? UnsafePointer(scratch) : nil
        }
        return tile.map { UnsafePointer($0.data) }
    }

    /// ノードの内容をタイル単位の Float バッファとして得る（空なら false）
    private static func source(_ node: LayerNode, key: TileKey, ctx: Context, inReference: Bool,
                               out: UnsafeMutablePointer<RGBA>) -> Bool {
        switch node.kind {
        case .raster:
            if ctx.options.referenceOnly && !(inReference || node.isReference) { return false }
            let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: kTilePixelCount * 4)
            defer { scratch.deallocate() }
            guard let src = rasterSource(node, key: key, ctx: ctx, scratch: scratch) else { return false }
            let k: Float = 1.0 / 255.0
            for i in 0..<kTilePixelCount {
                let p = src + i * 4
                out[i] = RGBA(Float(p[0]), Float(p[1]), Float(p[2]), Float(p[3])) * k
            }
            return true
        case .folder:
            out.initialize(repeating: .zero, count: kTilePixelCount)
            compositeList(node.children, key: key, ctx: ctx, acc: out, inReference: inReference || node.isReference)
            return true
        }
    }

    private static func compositeList(_ nodes: [LayerNode], key: TileKey, ctx: Context,
                                      acc: UnsafeMutablePointer<RGBA>, inReference: Bool) {
        var baseMask: UnsafeMutablePointer<Float>?
        defer { baseMask?.deallocate() }
        var baseValid = false
        let src = UnsafeMutablePointer<RGBA>.allocate(capacity: kTilePixelCount)
        defer { src.deallocate() }

        for (i, node) in nodes.enumerated() {
            let visible = node.visible || ctx.options.ignoreVisibility
            let nextClips = i + 1 < nodes.count && nodes[i + 1].clipping
            if !node.clipping {
                baseValid = false
                guard visible else { continue }
                let passThrough = node.isFolder && node.blendMode == .passThrough
                if passThrough {
                    // 通過: 子を直接 acc に合成
                    let childRef = inReference || node.isReference
                    if node.opacity >= 1 {
                        compositeList(node.children, key: key, ctx: ctx, acc: acc, inReference: childRef)
                    } else {
                        let before = UnsafeMutablePointer<RGBA>.allocate(capacity: kTilePixelCount)
                        defer { before.deallocate() }
                        before.update(from: acc, count: kTilePixelCount)
                        compositeList(node.children, key: key, ctx: ctx, acc: acc, inReference: childRef)
                        let o = node.opacity
                        for j in 0..<kTilePixelCount {
                            acc[j] = before[j] + (acc[j] - before[j]) * o
                        }
                    }
                    if nextClips, source(node, key: key, ctx: ctx, inReference: inReference, out: src) {
                        if baseMask == nil { baseMask = .allocate(capacity: kTilePixelCount) }
                        for j in 0..<kTilePixelCount { baseMask![j] = src[j].w * node.opacity }
                        baseValid = true
                    }
                    continue
                }
                guard source(node, key: key, ctx: ctx, inReference: inReference, out: src) else { continue }
                blend(acc, src, mode: node.blendMode, opacity: node.opacity, mask: nil, key: key)
                if nextClips {
                    if baseMask == nil { baseMask = .allocate(capacity: kTilePixelCount) }
                    for j in 0..<kTilePixelCount { baseMask![j] = src[j].w * node.opacity }
                    baseValid = true
                }
            } else {
                guard baseValid, visible, let mask = baseMask else { continue }
                guard source(node, key: key, ctx: ctx, inReference: inReference, out: src) else { continue }
                blend(acc, src, mode: node.blendMode, opacity: node.opacity, mask: mask, key: key)
            }
        }
    }

    static func blend(_ acc: UnsafeMutablePointer<RGBA>, _ src: UnsafePointer<RGBA>, mode: BlendMode,
                      opacity: Float, mask: UnsafePointer<Float>?, key: TileKey) {
        if opacity <= 0 { return }
        switch mode {
        case .normal, .passThrough:
            for i in 0..<kTilePixelCount {
                let s = src[i]
                if s.w <= 0 { continue }
                let f = opacity * (mask?[i] ?? 1)
                let sa = s.w * f
                acc[i] = s * f + acc[i] * (1 - sa)
            }
        case .dissolve:
            let ox = key.x * kTileSize, oy = key.y * kTileSize
            for i in 0..<kTilePixelCount {
                let s = src[i]
                if s.w <= 0 { continue }
                let sa = s.w * opacity * (mask?[i] ?? 1)
                let h = pixelHash(ox + i % kTileSize, oy + i / kTileSize)
                if h < sa {
                    acc[i] = RGBA(s.x / s.w, s.y / s.w, s.z / s.w, 1)
                }
            }
        default:
            for i in 0..<kTilePixelCount {
                let s = src[i]
                if s.w <= 0 { continue }
                let sa = s.w * opacity * (mask?[i] ?? 1)
                let d = acc[i]
                let ba = d.w
                let cs = SIMD3(s.x, s.y, s.z) / s.w
                if ba <= 0 {
                    acc[i] = RGBA(cs.x * sa, cs.y * sa, cs.z * sa, sa)
                    continue
                }
                let cb = SIMD3(d.x, d.y, d.z) / ba
                let b = simd_clamp(blendColor(mode, cb, cs), .zero, SIMD3(repeating: 1))
                let rgb = (1 - ba) * sa * cs + sa * ba * b + (1 - sa) * SIMD3(d.x, d.y, d.z)
                acc[i] = RGBA(rgb.x, rgb.y, rgb.z, sa + ba * (1 - sa))
            }
        }
    }
}
