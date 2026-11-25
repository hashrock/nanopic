// SVG からアプリアイコンを作る。書き出す形は出力の拡張子で決まる
//   swift scripts/make-icon.swift Resources/AppIcon.svg build/AppIcon.icns   # Mac（白い角丸の板にロゴ、影つき）
//   swift scripts/make-icon.swift Resources/AppIcon.svg <…>/AppIcon.png      # iPad（1024px、白地いっぱい、透明なし）
// iPad 用は、iPad のビルドの最初に Xcode が呼ぶ（iPad/project.yml の preBuildScripts）。手で作り直さなくてよい
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let svg = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: make-icon.swift <in.svg> <out.icns>\n".data(using: .utf8)!)
    exit(1)
}
let out = URL(fileURLWithPath: args[2])
/// macOS のアイコングリッドに合わせ、白い角丸四角の上にロゴを置く
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // 1024 中 824 の角丸四角（Big Sur 以降の標準グリッド）
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: plate, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 20 * s
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    // ロゴは角丸四角の内側に余白を取って配置
    let logo = plate.insetBy(dx: 90 * s, dy: 90 * s)
    svg.draw(in: logo, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// iPad（iOS）のアイコン。角は OS が丸めるので白地いっぱいに描く。App Store は透明のあるアイコンを受け付けないので、透明なしで書く。
/// ロゴは、アイコンに対して Mac 版の板に対するのと同じ割合（644 / 824 ≒ 78%）。1024 の中の 112〜912
func renderIOS() -> CGImage {
    let px = 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    svg.draw(in: NSRect(x: 112, y: 112, width: 800, height: 800), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

if out.pathExtension.lowercased() == "png" {
    guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else {
        FileHandle.standardError.write("cannot create \(out.path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, renderIOS(), nil)
    exit(CGImageDestinationFinalize(dest) ? 0 : 1)
}

// iconutil は使わない（macOS 26 の iconutil は、正しい iconset でも「Invalid Iconset」で失敗する）。ImageIO で .icns を直に書く
try? FileManager.default.removeItem(at: out)
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "com.apple.icns" as CFString, 10, nil) else {
    FileHandle.standardError.write("cannot create \(out.path)\n".data(using: .utf8)!)
    exit(1)
}
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = NSBitmapImageRep(data: render(base * scale))!
        // 2 倍の画像は 144dpi にして、@2x として入れる
        let dpi = 72 * scale
        CGImageDestinationAddImage(dest, rep.cgImage!, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    }
}
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
