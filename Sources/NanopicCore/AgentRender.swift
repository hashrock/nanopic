import CoreGraphics
import CoreText
import Foundation

/// エージェントに見せる画像を作る（縮小・座標グリッド・領域の番号）
enum AgentRender {
    struct Output {
        var png: Data
        /// 出力画像の 1px がドキュメントの何 px か
        var scale: Double
        var width: Int
        var height: Int
    }

    /// premultiplied RGBA8 の rect 部分を、長辺 maxSize 以下に縮小して描く。draw でその上に重ねて描ける（座標はドキュメント座標）
    static func render(_ buf: [UInt8], width w: Int, height h: Int, rect: IntRect, maxSize: Int,
                       grid: Bool, draw: ((CGContext, Double) -> Void)? = nil) -> Output? {
        guard let full = ImageUtil.makeImage(premultiplied: buf, width: w, height: h),
              let cropped = full.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) else { return nil }
        let scale = max(1, Double(max(rect.width, rect.height)) / Double(max(maxSize, 64)))
        let ow = max(1, Int((Double(rect.width) / scale).rounded())), oh = max(1, Int((Double(rect.height) / scale).rounded()))
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0, space: ImageUtil.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ow, height: oh))
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: ow, height: oh))
        // ここからはドキュメント座標（左上原点・下向き）で描く
        ctx.translateBy(x: 0, y: CGFloat(oh))
        ctx.scaleBy(x: CGFloat(1 / scale), y: CGFloat(-1 / scale))
        ctx.translateBy(x: CGFloat(-rect.x), y: CGFloat(-rect.y))
        if grid { drawGrid(ctx, rect: rect, scale: scale) }
        draw?(ctx, scale)
        guard let img = ctx.makeImage(), let png = ImageUtil.pngData(img) else { return nil }
        return Output(png: png, scale: scale, width: ow, height: oh)
    }

    /// 目盛り（ドキュメント座標）。画像上でおおよそ 80〜160px ごと
    private static func drawGrid(_ ctx: CGContext, rect: IntRect, scale: Double) {
        let target = 110 * scale
        let steps = [10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000]
        let step = steps.first { Double($0) >= target } ?? 10000
        ctx.saveGState()
        ctx.setLineWidth(CGFloat(scale))
        ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0.4, alpha: 0.45))
        let fs = 11 * scale
        var x = (rect.minX / step + 1) * step
        while x < rect.maxX {
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY)])
            label(ctx, "\(x)", at: CGPoint(x: Double(x) + 2 * scale, y: Double(rect.minY) + 2 * scale), size: fs)
            x += step
        }
        var y = (rect.minY / step + 1) * step
        while y < rect.maxY {
            ctx.strokeLineSegments(between: [CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)])
            label(ctx, "\(y)", at: CGPoint(x: Double(rect.minX) + 2 * scale, y: Double(y) + 2 * scale), size: fs)
            y += step
        }
        ctx.restoreGState()
    }

    /// 文字を背景つきで描く（at は左上、ドキュメント座標）
    static func label(_ ctx: CGContext, _ text: String, at p: CGPoint, size: Double, centered: Bool = false) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(size), nil)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let pad = size * 0.25
        var origin = p
        if centered { origin = CGPoint(x: p.x - b.width / 2 - pad, y: p.y - size / 2 - pad) }
        let box = CGRect(x: origin.x, y: origin.y, width: b.width + pad * 2, height: size + pad * 2)
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        ctx.fill(box)
        // 文字は上下反転を戻して描く
        ctx.translateBy(x: box.minX + pad, y: box.maxY - pad - size * 0.22)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 領域ごとに色をのせ、番号を描く
    static func regions(_ map: RegionMap, base: [UInt8], maxSize: Int, maxLabels: Int) -> Output? {
        let w = map.width, h = map.height
        var buf = base
        // 白背景に重ねてから、領域ごとの色を半透明でのせる
        for i in 0..<(w * h) {
            let a = 255 - Int(buf[i * 4 + 3])
            var r = Int(buf[i * 4]) + a, g = Int(buf[i * 4 + 1]) + a, b = Int(buf[i * 4 + 2]) + a
            let l = Int(map.labels[i])
            if l > 0 {
                let c = tint(l)
                r = (r * 6 + c.0 * 4) / 10; g = (g * 6 + c.1 * 4) / 10; b = (b * 6 + c.2 * 4) / 10
            }
            buf[i * 4] = UInt8(min(r, 255)); buf[i * 4 + 1] = UInt8(min(g, 255)); buf[i * 4 + 2] = UInt8(min(b, 255)); buf[i * 4 + 3] = 255
        }
        return render(buf, width: w, height: h, rect: IntRect(x: 0, y: 0, width: w, height: h), maxSize: maxSize, grid: false) { ctx, scale in
            for r in map.regions.prefix(maxLabels) {
                // 画像上で小さすぎる領域は番号を省く
                if Double(min(r.bounds.width, r.bounds.height)) / scale < 6 { continue }
                label(ctx, "\(r.id)", at: CGPoint(x: Double(r.point.x), y: Double(r.point.y)), size: 11 * scale, centered: true)
            }
        }
    }

    /// 領域の番号から決まる、見分けやすい色
    static func tint(_ id: Int) -> (Int, Int, Int) {
        let hue = Double((id * 137) % 360) / 60
        let x = 1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1)
        let (r, g, b): (Double, Double, Double)
        switch Int(hue) {
        case 0: (r, g, b) = (1, x, 0)
        case 1: (r, g, b) = (x, 1, 0)
        case 2: (r, g, b) = (0, 1, x)
        case 3: (r, g, b) = (0, x, 1)
        case 4: (r, g, b) = (x, 0, 1)
        default: (r, g, b) = (1, 0, x)
        }
        return (Int(r * 200 + 30), Int(g * 200 + 30), Int(b * 200 + 30))
    }
}
