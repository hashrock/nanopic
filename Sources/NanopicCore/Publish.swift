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

    /// 拡張子から（知らなければ nil）
    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        default: return nil
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

/// 範囲の縦横比の固定（幅:高さ）
public struct PublishAspect: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    public var ratio: Double { Double(width) / Double(height) }
    public var displayName: String { "\(width):\(height)" }

    /// 選べる比率
    public static let presets = [PublishAspect(1, 1), PublishAspect(4, 3), PublishAspect(3, 4), PublishAspect(3, 2), PublishAspect(2, 3),
                                 PublishAspect(16, 9), PublishAspect(9, 16)]
}

/// 書き出しの設定。作品ごとに 1 組をサイドカーに持つ。元の絵は変えずに、範囲を切り抜いて大きさを変えて書き出す
public struct PublishSettings: Codable, Equatable, Sendable {
    /// 書き出す範囲（キャンバスの座標）。nil ならキャンバス全体
    public var rect: IntRect?
    /// 範囲の縦横比の固定。nil なら自由
    public var aspect: PublishAspect?
    /// 出力の幅。nil なら範囲と同じ（等倍。範囲を変えても等倍のまま）。高さは範囲の比から決める（ゆがめない）
    public var outputWidth: Int?
    public var format = PublishFormat.png
    /// JPEG の品質（1〜100）
    public var quality = 90
    public var background = PublishBackground.transparent
    /// 書き出し先。PSD と同じフォルダー（の下）なら PSD からの相対パス、そうでなければ絶対パス
    public var destination: String?

    public init() {}

    private enum CodingKeys: String, CodingKey { case rect, aspect, outputWidth, format, quality, background, destination }

    /// 足りない項目があっても読めるようにする
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rect = try c.decodeIfPresent(IntRect.self, forKey: .rect)
        aspect = try c.decodeIfPresent(PublishAspect.self, forKey: .aspect)
        outputWidth = try c.decodeIfPresent(Int.self, forKey: .outputWidth)
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

    /// 範囲の縦横比（幅 / 高さ）。固定していればその比
    public func ratio(canvas: IntRect) -> Double {
        if let a = aspect { return a.ratio }
        let r = resolvedRect(canvas: canvas)
        return Double(r.width) / Double(r.height)
    }

    /// 出力の大きさ（高さは比から）
    public func resolvedOutputSize(canvas: IntRect) -> (width: Int, height: Int) {
        let r = resolvedRect(canvas: canvas)
        let w = max(1, outputWidth ?? r.width)
        if outputWidth == nil && aspect == nil { return (w, r.height) }
        return (w, max(1, Int((Double(w) / ratio(canvas: canvas)).rounded())))
    }

    /// 透明の扱い（JPEG はいつも白）
    public var effectiveBackground: PublishBackground { format.supportsAlpha ? background : .white }
}

/// 書き出し設定を開いている間の編集
extension PublishSettings {
    /// 範囲を省略なしの値にする（出力の幅は、等倍なら等倍のまま）
    public func normalized(canvas: IntRect) -> PublishSettings {
        var s = self
        s.rect = resolvedRect(canvas: canvas)
        return s
    }

    /// 等倍（出力を範囲に合わせる）か
    public var isActualSize: Bool { outputWidth == nil }

    /// 範囲の左上を動かす（キャンバスに収める）
    public mutating func setRectOrigin(x: Int? = nil, y: Int? = nil, canvas: IntRect) {
        var r = resolvedRect(canvas: canvas)
        if let x { r.x = min(max(x, canvas.minX), canvas.maxX - r.width) }
        if let y { r.y = min(max(y, canvas.minY), canvas.maxY - r.height) }
        rect = r
    }

    /// 範囲の幅か高さを変える（比を固定していればもう一方も比から。左上を保ち、キャンバスに収める）
    public mutating func setRectSize(width: Int? = nil, height: Int? = nil, canvas: IntRect) {
        let r = resolvedRect(canvas: canvas)
        var w = Double(r.width), h = Double(r.height)
        if let width { w = Double(max(1, width)); if let a = aspect { h = w / a.ratio } }
        if let height { h = Double(max(1, height)); if let a = aspect { w = h * a.ratio } }
        let maxW = Double(canvas.maxX - r.x), maxH = Double(canvas.maxY - r.y)
        if aspect != nil {
            let k = min(1, maxW / w, maxH / h)
            w *= k
            h *= k
        } else {
            w = min(w, maxW)
            h = min(h, maxH)
        }
        rect = IntRect(x: r.x, y: r.y, width: max(1, Int(w.rounded())), height: max(1, Int(h.rounded())))
    }

    /// 出力の幅か高さを変える（もう一方は範囲の比から決まる）
    public mutating func setOutputSize(width: Int? = nil, height: Int? = nil, canvas: IntRect) {
        if let width { outputWidth = max(1, width) }
        if let height { outputWidth = max(1, Int((Double(max(1, height)) * ratio(canvas: canvas)).rounded())) }
    }

    /// 比率の固定を変える。固定するなら範囲をその比に合わせ直す
    public mutating func setAspect(_ a: PublishAspect?, canvas: IntRect) {
        let r = resolvedRect(canvas: canvas)
        aspect = a
        if let a { rect = Publish.fit(r, aspect: a.ratio, canvas: canvas) }
    }

    /// 範囲をキャンバス全体にする（比を固定していれば、その比でいちばん大きく）
    public mutating func setWholeCanvas(_ canvas: IntRect) {
        if let a = aspect {
            let s = min(Double(canvas.width) / a.ratio, Double(canvas.height))
            rect = Publish.place(width: s * a.ratio, height: s, centerX: Double(canvas.x) + Double(canvas.width) / 2, centerY: Double(canvas.y) + Double(canvas.height) / 2, canvas: canvas)
        } else {
            rect = canvas
        }
    }

    /// 出力を範囲と同じ大きさ（等倍）にする。範囲を変えても等倍のまま
    public mutating func setActualSize(canvas: IntRect) {
        outputWidth = nil
    }
}

public enum Publish {
    /// 書き出し枠のつまみ: 0〜3 は角（左上・右上・右下・左下）、4〜7 は辺（上・右・下・左）、8 は内側（移動）
    public static let insideHandle = 8

    /// 枠のつまみを (dx, dy) だけドラッグしたあとの範囲。aspect（幅 / 高さ）を渡せばその比を保つ。キャンバスに収める
    public static func dragRect(_ start: IntRect, handle: Int, dx: Double, dy: Double, aspect: Double?, canvas: IntRect) -> IntRect {
        guard let a = aspect else { return dragFree(start, handle: handle, dx: dx, dy: dy, canvas: canvas) }
        let x0 = Double(start.minX), y0 = Double(start.minY), x1 = Double(start.maxX), y1 = Double(start.maxY)
        let minSize = 4.0
        switch handle {
        case 0...3:
            // 反対の角を止め、指した所を覆う大きさにする
            let ax = handle == 0 || handle == 3 ? x1 : x0
            let ay = handle == 0 || handle == 1 ? y1 : y0
            let px = (handle == 0 || handle == 3 ? x0 : x1) + dx, py = (handle == 0 || handle == 1 ? y0 : y1) + dy
            var w = max(abs(px - ax), abs(py - ay) * a, minSize)
            let maxW = (handle == 0 || handle == 3 ? ax - Double(canvas.minX) : Double(canvas.maxX) - ax)
            let maxH = (handle == 0 || handle == 1 ? ay - Double(canvas.minY) : Double(canvas.maxY) - ay)
            w = min(w, maxW, maxH * a)
            let h = w / a
            let x = handle == 0 || handle == 3 ? ax - w : ax, y = handle == 0 || handle == 1 ? ay - h : ay
            return IntRect(x: Int(x.rounded()), y: Int(y.rounded()), width: max(1, Int(w.rounded())), height: max(1, Int(h.rounded())))
        case 4, 6:
            // 上下の辺: 高さを変え、幅は比から。反対の辺と横の中心を保つ
            let ay = handle == 4 ? y1 : y0
            var h = max(handle == 4 ? y1 - (y0 + dy) : (y1 + dy) - y0, minSize)
            h = min(h, handle == 4 ? ay - Double(canvas.minY) : Double(canvas.maxY) - ay, Double(canvas.width) / a)
            let w = h * a, cx = (x0 + x1) / 2
            let x = min(max(cx - w / 2, Double(canvas.minX)), Double(canvas.maxX) - w)
            return IntRect(x: Int(x.rounded()), y: Int((handle == 4 ? ay - h : ay).rounded()), width: max(1, Int(w.rounded())), height: max(1, Int(h.rounded())))
        case 5, 7:
            // 左右の辺: 幅を変え、高さは比から。反対の辺と縦の中心を保つ
            let ax = handle == 7 ? x1 : x0
            var w = max(handle == 7 ? x1 - (x0 + dx) : (x1 + dx) - x0, minSize)
            w = min(w, handle == 7 ? ax - Double(canvas.minX) : Double(canvas.maxX) - ax, Double(canvas.height) * a)
            let h = w / a, cy = (y0 + y1) / 2
            let y = min(max(cy - h / 2, Double(canvas.minY)), Double(canvas.maxY) - h)
            return IntRect(x: Int((handle == 7 ? ax - w : ax).rounded()), y: Int(y.rounded()), width: max(1, Int(w.rounded())), height: max(1, Int(h.rounded())))
        default:
            return dragFree(start, handle: handle, dx: dx, dy: dy, canvas: canvas)
        }
    }

    /// 比を保たないドラッグ: 角は 2 辺、辺は 1 辺を動かす。内側は全体を動かす
    private static func dragFree(_ start: IntRect, handle: Int, dx: Double, dy: Double, canvas: IntRect) -> IntRect {
        let minSize = 4
        let ix = Int(dx.rounded()), iy = Int(dy.rounded())
        var x0 = start.minX, y0 = start.minY, x1 = start.maxX, y1 = start.maxY
        let left = [0, 3, 7].contains(handle), right = [1, 2, 5].contains(handle)
        let top = [0, 1, 4].contains(handle), bottom = [2, 3, 6].contains(handle)
        if handle == insideHandle {
            let x = min(max(x0 + ix, canvas.minX), canvas.maxX - start.width)
            let y = min(max(y0 + iy, canvas.minY), canvas.maxY - start.height)
            return IntRect(x: x, y: y, width: start.width, height: start.height)
        }
        if left { x0 = min(max(x0 + ix, canvas.minX), x1 - minSize) }
        if right { x1 = max(min(x1 + ix, canvas.maxX), x0 + minSize) }
        if top { y0 = min(max(y0 + iy, canvas.minY), y1 - minSize) }
        if bottom { y1 = max(min(y1 + iy, canvas.maxY), y0 + minSize) }
        return IntRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

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
        let (ow, oh) = s.resolvedOutputSize(canvas: canvas)
        guard let out = render(buf, canvasWidth: cw, canvasHeight: ch, rect: s.resolvedRect(canvas: canvas),
                               outputWidth: ow, outputHeight: oh, white: s.effectiveBackground == .white) else { return nil }
        return ImageUtil.makeImage(premultiplied: out, width: ow, height: oh)
    }

    /// 範囲 r を切り抜き、白で埋め（white のとき）、ow × oh に大きさを変えた premultiplied RGBA8
    public static func render(_ buf: [UInt8], canvasWidth cw: Int, canvasHeight ch: Int, rect r: IntRect,
                              outputWidth ow: Int, outputHeight oh: Int, white: Bool) -> [UInt8]? {
        // 切り抜く
        var crop = [UInt8](repeating: 0, count: r.width * r.height * 4)
        for y in 0..<r.height {
            let src = ((r.y + y) * cw + r.x) * 4
            crop.replaceSubrange((y * r.width * 4)..<((y + 1) * r.width * 4), with: buf[src..<(src + r.width * 4)])
        }
        // 白で埋める（premultiplied なので、足りない不透明度の分だけ白を足す）
        if white {
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
        guard ow != r.width || oh != r.height else { return crop }
        // 大きさを変える（高品質な補間。premultiplied のまま）
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        let err = crop.withUnsafeMutableBytes { sp in
            out.withUnsafeMutableBytes { dp in
                var src = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(r.height), width: vImagePixelCount(r.width), rowBytes: r.width * 4)
                var dst = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(oh), width: vImagePixelCount(ow), rowBytes: ow * 4)
                return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return err == kvImageNoError ? out : nil
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

    /// 動画の書き出しの設定（書き出しの設定の範囲と大きさ、透明の扱いを使う）
    public func movieOptions(format: MovieFormat = .mp4) -> MovieExport.Options {
        var o = MovieExport.Options(publish: doc.publish ?? PublishSettings(), canvas: doc.bounds)
        o.format = format
        return o
    }

    /// 選択範囲を囲む矩形を書き出し範囲にする
    @discardableResult
    public func setPublishRectFromSelection() -> Bool {
        guard let sel = doc.selection, !sel.bounds.isEmpty else { return false }
        var s = publishSettings
        let r = sel.bounds.intersection(doc.bounds)
        // 比を固定していれば、選択範囲を囲むようにその比で広げる
        s.rect = s.aspect.map { Publish.expand(r, aspect: $0.ratio, canvas: doc.bounds) } ?? r
        setPublishSettings(s, label: "書き出し範囲")
        return true
    }
}
