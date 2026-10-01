import Foundation
import simd

/// 色調補正（明るさ・コントラスト → 色相・彩度・明度 の順にかける）
public struct ColorAdjustment: Equatable, Sendable {
    /// 色相 -180...180（度）
    public var hue: Float = 0
    /// 彩度 -100...100
    public var saturation: Float = 0
    /// 明度 -100...100
    public var lightness: Float = 0
    /// 明るさ -100...100
    public var brightness: Float = 0
    /// コントラスト -100...100
    public var contrast: Float = 0

    public init(hue: Float = 0, saturation: Float = 0, lightness: Float = 0, brightness: Float = 0, contrast: Float = 0) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
        self.brightness = brightness
        self.contrast = contrast
    }

    public var isIdentity: Bool { self == ColorAdjustment() }

    /// ストレートカラー（0...1）に補正をかける
    @inline(__always) public func apply(_ c: SIMD3<Float>) -> SIMD3<Float> {
        var c = c
        if brightness != 0 || contrast != 0 {
            let k = contrast > 0 ? 1 / max(1 - contrast / 100, 0.01) : 1 + contrast / 100
            c = (c - 0.5) * k + 0.5 + brightness / 100 * 0.5
            c = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
        }
        if hue != 0 || saturation != 0 || lightness != 0 {
            var (h, s, l) = Self.hsl(c)
            h = (h + hue / 360).truncatingRemainder(dividingBy: 1)
            if h < 0 { h += 1 }
            let sv = saturation / 100
            s = sv >= 0 ? s + (1 - s) * sv * s : s * (1 + sv)
            let lv = lightness / 100
            l = lv >= 0 ? l + (1 - l) * lv : l * (1 + lv)
            c = Self.rgb(h, min(max(s, 0), 1), min(max(l, 0), 1))
        }
        return c
    }

    /// premultiplied RGBA8 のタイル（128×128）に補正をかけて out に書く。selection があればその分だけ混ぜる
    public func apply(tile src: UnsafePointer<UInt8>, out: UnsafeMutablePointer<UInt8>, key: TileKey, selection: SelectionMask?) {
        let ox = key.x * kTileSize, oy = key.y * kTileSize
        for y in 0..<kTileSize {
            for x in 0..<kTileSize {
                let o = (y * kTileSize + x) * 4
                let a = src[o + 3]
                var m: Float = 1
                if let selection {
                    let gx = ox + x, gy = oy + y
                    m = gx < selection.width && gy < selection.height ? Float(selection.value(gx, gy)) / 255 : 0
                }
                if a == 0 || m == 0 {
                    if src != UnsafePointer(out) { for k in 0..<4 { out[o + k] = src[o + k] } }
                    continue
                }
                let af = Float(a) / 255
                let c = SIMD3(Float(src[o]), Float(src[o + 1]), Float(src[o + 2])) / 255 / af
                var r = apply(simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1)))
                if m < 1 { r = c + (r - c) * m }
                out[o] = UInt8(min(r.x * af, 1) * 255 + 0.5)
                out[o + 1] = UInt8(min(r.y * af, 1) * 255 + 0.5)
                out[o + 2] = UInt8(min(r.z * af, 1) * 255 + 0.5)
                out[o + 3] = a
            }
        }
    }

    static func hsl(_ c: SIMD3<Float>) -> (Float, Float, Float) {
        let mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z))
        let l = (mx + mn) / 2
        let d = mx - mn
        if d < 1e-6 { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Float
        if mx == c.x {
            h = (c.y - c.z) / d + (c.y < c.z ? 6 : 0)
        } else if mx == c.y {
            h = (c.z - c.x) / d + 2
        } else {
            h = (c.x - c.y) / d + 4
        }
        return (h / 6, s, l)
    }

    static func rgb(_ h: Float, _ s: Float, _ l: Float) -> SIMD3<Float> {
        if s < 1e-6 { return SIMD3(repeating: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func f(_ t0: Float) -> Float {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return SIMD3(f(h + 1 / 3), f(h), f(h - 1 / 3))
    }
}

extension Editor {
    /// 補正の対象になる範囲（レイヤーの描かれている所と選択範囲の重なり）
    func adjustmentBounds(_ layer: LayerNode) -> IntRect {
        let r = layer.tiles.contentBounds() ?? .zero
        return doc.selection.map { r.intersection($0.bounds) } ?? r
    }
}
