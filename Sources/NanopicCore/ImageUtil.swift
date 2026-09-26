import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageUtil {
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// premultiplied RGBA8 バッファから CGImage を作る
    public static func makeImage(premultiplied buf: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = Data(buf) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 画像を premultiplied RGBA8 で読み込む
    public static func loadPremultiplied(_ image: CGImage) -> (buffer: [UInt8], width: Int, height: Int)? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (buf, w, h) : nil
    }

    public static func loadImage(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// レイヤーのサムネイル（premultiplied、最大辺 maxSize）
    public static func thumbnail(tiles: TileMap, docWidth: Int, docHeight: Int, maxSize: Int) -> CGImage? {
        let scale = Double(maxSize) / Double(max(docWidth, docHeight))
        let tw = max(1, Int(Double(docWidth) * scale)), th = max(1, Int(Double(docHeight) * scale))
        var buf = [UInt8](repeating: 0, count: tw * th * 4)
        let step = Double(docWidth) / Double(tw)
        // 各サムネイル画素につき 3x3 サンプルの平均
        let n = 3
        for ty in 0..<th {
            for tx in 0..<tw {
                var s = (0, 0, 0, 0)
                for j in 0..<n {
                    for i in 0..<n {
                        let x = Int((Double(tx) + (Double(i) + 0.5) / Double(n)) * step)
                        let y = Int((Double(ty) + (Double(j) + 0.5) / Double(n)) * step)
                        let p = tiles.pixel(min(x, docWidth - 1), min(y, docHeight - 1))
                        s.0 += Int(p.0); s.1 += Int(p.1); s.2 += Int(p.2); s.3 += Int(p.3)
                    }
                }
                let o = (ty * tw + tx) * 4
                let c = n * n
                buf[o] = UInt8(s.0 / c); buf[o + 1] = UInt8(s.1 / c); buf[o + 2] = UInt8(s.2 / c); buf[o + 3] = UInt8(s.3 / c)
            }
        }
        return makeImage(premultiplied: buf, width: tw, height: th)
    }
}
