import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 書き出し（publish）の形式
public enum PublishFormat: String, Codable, CaseIterable, Sendable {
    case png, jpeg

    public var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    public var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        }
    }

    /// 透明を持てるか（持てなければいつも白で埋める）
    public var supportsAlpha: Bool { self == .png }
    /// 品質を選べるか
    public var hasQuality: Bool { self == .jpeg }
}

/// 透明な所の扱い
public enum PublishBackground: String, Codable, CaseIterable, Sendable {
    case transparent, white

    public var displayName: String { self == .transparent ? "透明のまま" : "白で埋める" }
}

/// 書き出しの設定。作品ごとに 1 組をサイドカーに持つ。元の絵は変えずに、範囲を切り抜いて大きさを変えて書き出す
public struct PublishSettings: Codable, Equatable, Sendable {
    /// 書き出す範囲（キャンバスの座標）。nil ならキャンバス全体
    public var rect: IntRect?
    /// 出力の大きさ。nil なら範囲と同じ。範囲の縦横比はこの比に固定する
    public var outputWidth: Int?
    public var outputHeight: Int?
    public var format = PublishFormat.png
    /// JPEG の品質（1〜100）
    public var quality = 90
    public var background = PublishBackground.transparent
    /// 書き出し先。PSD と同じフォルダー（の下）なら PSD からの相対パス、そうでなければ絶対パス
    public var destination: String?

    public init() {}

    private enum CodingKeys: String, CodingKey { case rect, outputWidth, outputHeight, format, quality, background, destination }

    /// 足りない項目があっても読めるようにする
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rect = try c.decodeIfPresent(IntRect.self, forKey: .rect)
        outputWidth = try c.decodeIfPresent(Int.self, forKey: .outputWidth)
        outputHeight = try c.decodeIfPresent(Int.self, forKey: .outputHeight)
        format = try c.decodeIfPresent(PublishFormat.self, forKey: .format) ?? .png
        quality = try c.decodeIfPresent(Int.self, forKey: .quality) ?? 90
        background = try c.decodeIfPresent(PublishBackground.self, forKey: .background) ?? .transparent
        destination = try c.decodeIfPresent(String.self, forKey: .destination)
    }

    /// キャンバスの中に収めた範囲（空ならキャンバス全体）
    public func resolvedRect(canvas: IntRect) -> IntRect {
        guard let r = rect else { return canvas }
        let c = r.intersection(canvas)
        return c.isEmpty ? canvas : c
    }

    /// 出力の大きさ
    public func resolvedOutputSize(canvas: IntRect) -> (width: Int, height: Int) {
        let r = resolvedRect(canvas: canvas)
        return (max(1, outputWidth ?? r.width), max(1, outputHeight ?? r.height))
    }

    /// 透明の扱い（JPEG はいつも白）
    public var effectiveBackground: PublishBackground { format.supportsAlpha ? background : .white }
}

public enum Publish {
    /// rect を縦横比 aspect（幅 / 高さ）に合わせる。中心を保ち、キャンバスに収まるように縮めたりずらしたりする
    public static func fit(_ rect: IntRect, aspect: Double, canvas: IntRect) -> IntRect {
        guard aspect > 0, rect.width > 0, rect.height > 0 else { return rect.intersection(canvas) }
        let cx = Double(rect.x) + Double(rect.width) / 2, cy = Double(rect.y) + Double(rect.height) / 2
        // 面積をだいたい保つ
        var w = (Double(rect.width * rect.height) * aspect).squareRoot()
        var h = w / aspect
        // キャンバスより大きければ縮める
        let s = min(1, Double(canvas.width) / w, Double(canvas.height) / h)
        w *= s
        h *= s
        return place(width: w, height: h, centerX: cx, centerY: cy, canvas: canvas)
    }

    /// rect を囲むように広げて縦横比 aspect に合わせる（足りない向きだけ広げる）。中心を保ち、キャンバスに収める
    public static func expand(_ rect: IntRect, aspect: Double, canvas: IntRect) -> IntRect {
        guard aspect > 0, rect.width > 0, rect.height > 0 else { return rect.intersection(canvas) }
        var w = Double(rect.width), h = Double(rect.height)
        if w / h < aspect { w = h * aspect } else { h = w / aspect }
        let s = min(1, Double(canvas.width) / w, Double(canvas.height) / h)
        return place(width: w * s, height: h * s, centerX: Double(rect.x) + Double(rect.width) / 2,
                     centerY: Double(rect.y) + Double(rect.height) / 2, canvas: canvas)
    }

    /// 中心と大きさから、キャンバスに収まる整数の矩形を作る（はみ出せばずらす）
    public static func place(width w: Double, height h: Double, centerX cx: Double, centerY cy: Double, canvas: IntRect) -> IntRect {
        let iw = min(canvas.width, max(1, Int(w.rounded()))), ih = min(canvas.height, max(1, Int(h.rounded())))
        var x = Int((cx - Double(iw) / 2).rounded()), y = Int((cy - Double(ih) / 2).rounded())
        x = min(max(x, canvas.minX), canvas.maxX - iw)
        y = min(max(y, canvas.minY), canvas.maxY - ih)
        return IntRect(x: x, y: y, width: iw, height: ih)
    }

    /// 合成した絵（premultiplied RGBA8、キャンバスの大きさ）から、書き出す画像を作る
    public static func image(from buf: [UInt8], canvasWidth cw: Int, canvasHeight ch: Int, settings s: PublishSettings) -> CGImage? {
        let canvas = IntRect(x: 0, y: 0, width: cw, height: ch)
        let r = s.resolvedRect(canvas: canvas)
        let (ow, oh) = s.resolvedOutputSize(canvas: canvas)
        // 切り抜く
        var crop = [UInt8](repeating: 0, count: r.width * r.height * 4)
        for y in 0..<r.height {
            let src = ((r.y + y) * cw + r.x) * 4
            crop.replaceSubrange((y * r.width * 4)..<((y + 1) * r.width * 4), with: buf[src..<(src + r.width * 4)])
        }
        // 白で埋める（premultiplied なので、足りない不透明度の分だけ白を足す）
        if s.effectiveBackground == .white {
            crop.withUnsafeMutableBufferPointer { p in
                for i in stride(from: 0, to: p.count, by: 4) {
                    let k = 255 - Int(p[i + 3])
                    if k == 0 { continue }
                    p[i] = UInt8(min(255, Int(p[i]) + k))
                    p[i + 1] = UInt8(min(255, Int(p[i + 1]) + k))
                    p[i + 2] = UInt8(min(255, Int(p[i + 2]) + k))
                    p[i + 3] = 255
                }
            }
        }
        guard ow != r.width || oh != r.height else {
            return ImageUtil.makeImage(premultiplied: crop, width: r.width, height: r.height)
        }
        // 大きさを変える（高品質な補間。premultiplied のまま）
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        let err = crop.withUnsafeMutableBytes { sp in
            out.withUnsafeMutableBytes { dp in
                var src = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(r.height), width: vImagePixelCount(r.width), rowBytes: r.width * 4)
                var dst = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(oh), width: vImagePixelCount(ow), rowBytes: ow * 4)
                return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard err == kvImageNoError else { return nil }
        return ImageUtil.makeImage(premultiplied: out, width: ow, height: oh)
    }

    /// 画像をファイルの中身にする
    public static func encode(_ image: CGImage, settings s: PublishSettings) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, s.format.utType.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if s.format.hasQuality { props[kCGImageDestinationLossyCompressionQuality] = Double(min(max(s.quality, 1), 100)) / 100 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

/// 書き出しの操作
extension Editor {
    /// 今の書き出しの設定（まだなければ既定: キャンバス全体、同じ大きさ、PNG）
    public var publishSettings: PublishSettings { doc.publish ?? PublishSettings() }

    /// 書き出しの設定を変える（取り消せる。保存が必要な変更になる）
    public func setPublishSettings(_ s: PublishSettings, label: String = "書き出しの設定") {
        guard s != doc.publish else { return }
        checkpoint(label)
        doc.publish = s
        revision += 1
    }

    /// 書き出し先の URL（相対パスなら PSD のフォルダーから）
    public func publishDestinationURL(_ s: PublishSettings? = nil) -> URL? {
        guard let d = (s ?? publishSettings).destination, !d.isEmpty else { return nil }
        if d.hasPrefix("/") { return URL(fileURLWithPath: d) }
        guard let dir = fileURL?.deletingLastPathComponent() else { return nil }
        return dir.appendingPathComponent(d)
    }

    /// 書き出し先として持つ文字列（PSD と同じフォルダーの下なら相対パス）
    public func publishDestinationString(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let dir = fileURL?.deletingLastPathComponent().standardizedFileURL.path, path.hasPrefix(dir + "/") {
            return String(path.dropFirst(dir.count + 1))
        }
        return path
    }

    /// 今見えている状態（表示中のレイヤー、今のコマ、ポーズ）を、設定どおりに切り抜いて大きさを変えた画像
    public func publishImage(_ s: PublishSettings? = nil) -> CGImage? {
        commitTransform()
        let d = displayDoc
        return Publish.image(from: Compositor.compositeFull(d), canvasWidth: d.width, canvasHeight: d.height, settings: s ?? publishSettings)
    }

    /// 設定どおりに書き出す
    public func publish(to url: URL, settings: PublishSettings? = nil) throws {
        let s = settings ?? publishSettings
        guard let img = publishImage(s), let data = Publish.encode(img, settings: s) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }

    /// 動画の書き出しの設定（書き出しの設定があれば、その範囲と大きさを使う）
    public var movieOptions: MovieExport.Options {
        doc.publish.map { MovieExport.Options(publish: $0, canvas: doc.bounds) } ?? MovieExport.Options()
    }

    /// 選択範囲を囲む矩形を、出力の縦横比に合わせて書き出し範囲にする
    @discardableResult
    public func setPublishRectFromSelection() -> Bool {
        guard let sel = doc.selection, !sel.bounds.isEmpty else { return false }
        var s = publishSettings
        let r = sel.bounds.intersection(doc.bounds)
        if let w = s.outputWidth, let h = s.outputHeight, w > 0, h > 0 {
            s.rect = Publish.expand(r, aspect: Double(w) / Double(h), canvas: doc.bounds)
        } else {
            s.rect = r
        }
        setPublishSettings(s, label: "書き出し範囲")
        return true
    }
}
