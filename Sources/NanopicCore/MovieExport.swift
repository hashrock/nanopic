import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 動画の形式
public enum MovieFormat: String, CaseIterable, Sendable {
    /// H.264。透明は持てない（白で埋める）
    case mp4
    /// ProRes 4444。透明を持てる（動画編集ソフト向け）
    case prores
    /// アニメーション PNG。透明を持てる（Web 向け）
    case apng
    /// コマごとの PNG をフォルダーに並べる
    case pngSequence

    public var displayName: String {
        switch self {
        case .mp4: return "MP4（H.264）"
        case .prores: return "MOV（ProRes 4444、透過）"
        case .apng: return "APNG（透過）"
        case .pngSequence: return "PNG の連番（透過）"
        }
    }

    public var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .prores: return "mov"
        case .apng: return "png"
        case .pngSequence: return ""
        }
    }

    public var supportsAlpha: Bool { self != .mp4 }
    /// 動画ファイル（大きさを偶数にそろえる）か
    var isVideo: Bool { self == .mp4 || self == .prores }
}

/// タイムラインを動画（MP4・ProRes 4444・APNG・PNG の連番）に書き出す
public enum MovieExport {
    public struct Options: Sendable {
        public var format = MovieFormat.mp4
        /// 透明な所の扱い（MP4 はいつも白）
        public var background = PublishBackground.white
        /// MP4 の長辺の上限（H.264 の上限に収めるため）
        public var maxLongSide = 3840
        /// 切り抜く範囲（キャンバスの座標）。nil ならキャンバス全体
        public var crop: IntRect?
        /// 出力の大きさ。nil なら範囲と同じ
        public var outputWidth: Int?
        public var outputHeight: Int?
        public init() {}

        /// 書き出しの設定の範囲と大きさ、透明の扱いを使う
        public init(publish s: PublishSettings, canvas: IntRect) {
            crop = s.resolvedRect(canvas: canvas)
            (outputWidth, outputHeight) = s.resolvedOutputSize(canvas: canvas)
            background = s.background
        }

        /// 透明の扱い（透明を持てない形式は白）
        public var effectiveBackground: PublishBackground { format.supportsAlpha ? background : .white }
    }

    public struct Cancelled: Error {}

    /// 出力される動画の大きさ（偶数に切り上げ、長辺を maxLongSide 以下に）
    public static func outputSize(width: Int, height: Int, options: Options = Options()) -> (width: Int, height: Int) {
        let scale = min(1, Double(options.maxLongSide) / Double(max(width, height)))
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded(.up)) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// doc の写しにコマごとの表示状態を当てて書き出す。progress は (書いたコマ数, 全コマ数) で、false を返すと中止する
    /// values: パラメータの値（トラックのないもの）。トラックのあるパラメータはコマごとの値を使う
    /// PNG の連番では url はフォルダー（なければ作る）
    public static func export(_ doc: DocumentState, to url: URL, values: [String: Double] = [:], options: Options = Options(),
                              progress: (Int, Int) -> Bool = { _, _ in true }) throws {
        switch options.format {
        case .mp4, .prores: try writeVideo(doc, to: url, values: values, options: options, progress: progress)
        case .apng: try writeAPNG(doc, to: url, values: values, options: options, progress: progress)
        case .pngSequence: try writePNGSequence(doc, to: url, values: values, options: options, progress: progress)
        }
        _ = progress(max(doc.timeline.frameCount, 1), max(doc.timeline.frameCount, 1))
    }

    // MARK: コマの絵

    /// 範囲と、書き出す絵の大きさ（動画なら偶数にそろえる前の大きさ）、ファイルの大きさ
    static func sizes(_ doc: DocumentState, _ options: Options) -> (crop: IntRect, frame: (Int, Int), file: (Int, Int)) {
        let crop = (options.crop ?? doc.bounds).intersection(doc.bounds)
        let w = options.outputWidth ?? crop.width, h = options.outputHeight ?? crop.height
        guard options.format.isVideo else { return (crop, (w, h), (w, h)) }
        var o = options
        if options.format == .prores { o.maxLongSide = 8192 }
        let file = outputSize(width: w, height: h, options: o)
        let scale = min(1, Double(o.maxLongSide) / Double(max(w, h)))
        return (crop, (max(1, Int((Double(w) * scale).rounded())), max(1, Int((Double(h) * scale).rounded()))), file)
    }

    /// 同じ見た目のコマのまとまり（先頭のコマと長さ）
    static func runs(_ doc: DocumentState, values: [String: Double]) -> [(frame: Int, length: Int)] {
        var out: [(Int, Int)] = []
        var lastKey: String?
        for f in 0..<max(doc.timeline.frameCount, 1) {
            let key = Editor.frameKey(doc, frame: f, values: values, deformed: true)
            if key == lastKey, !out.isEmpty { out[out.count - 1].1 += 1 } else { out.append((f, 1)) }
            lastKey = key
        }
        return out
    }

    /// コマ f の絵（premultiplied RGBA8、frame の大きさ）
    static func frameImage(_ doc: DocumentState, frame f: Int, values: [String: Double], crop: IntRect, size: (Int, Int), white: Bool) throws -> CGImage {
        var d = doc
        d.applyTimeline(frame: f)
        let pose = values.merging(d.timeline.parameterValues(at: f)) { _, new in new }
        let buf = Compositor.compositeFull(d.posed(values: pose))
        guard let out = Publish.render(buf, canvasWidth: doc.width, canvasHeight: doc.height, rect: crop,
                                       outputWidth: size.0, outputHeight: size.1, white: white),
              let img = ImageUtil.makeImage(premultiplied: out, width: size.0, height: size.1) else { throw CocoaError(.fileWriteUnknown) }
        return img
    }

    // MARK: 形式ごと

    private static func writeVideo(_ doc: DocumentState, to url: URL, values: [String: Double], options: Options,
                                   progress: (Int, Int) -> Bool) throws {
        let t = doc.timeline
        let (crop, frame, (w, h)) = sizes(doc, options)
        let white = options.effectiveBackground == .white
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: options.format == .prores ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.format == .prores ? AVVideoCodecType.proRes4444 : AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let fps = Int32(max(t.fps, 1))
        var written = 0
        for run in runs(doc, values: values) {
            let image = try frameImage(doc, frame: run.frame, values: values, crop: crop, size: frame, white: white)
            for k in 0..<run.length {
                let f = run.frame + k
                guard progress(written, t.frameCount) else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    throw Cancelled()
                }
                guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let pb else { throw CocoaError(.fileWriteUnknown) }
                CVPixelBufferLockBaseAddress(pb, [])
                let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: ImageUtil.sRGB,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                // 偶数に切り上げた分は右と下に足す（白か透明。CGContext は下が原点）
                ctx?.clear(CGRect(x: 0, y: 0, width: w, height: h))
                if white {
                    ctx?.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h))
                }
                ctx?.draw(image, in: CGRect(x: 0, y: h - frame.1, width: frame.0, height: frame.1))
                CVPixelBufferUnlockBaseAddress(pb, [])
                // 透明を持つ形式では、色が不透明度をかけた値（premultiplied）であることを伝える
                if options.format.supportsAlpha {
                    CVBufferSetAttachment(pb, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate)
                }
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                written += 1
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(max(t.frameCount, 1)), timescale: fps))
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// 同じ見た目が続くコマは、1 枚の表示時間を延ばしてまとめる
    private static func writeAPNG(_ doc: DocumentState, to url: URL, values: [String: Double], options: Options,
                                  progress: (Int, Int) -> Bool) throws {
        let t = doc.timeline
        let (crop, frame, _) = sizes(doc, options)
        let white = options.effectiveBackground == .white
        let runs = runs(doc, values: values)
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, runs.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let loop: [CFString: Any] = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: t.loop ? 0 : 1]]
        CGImageDestinationSetProperties(dest, loop as CFDictionary)
        var written = 0
        for run in runs {
            guard progress(written, t.frameCount) else {
                try? FileManager.default.removeItem(at: url)
                throw Cancelled()
            }
            let image = try frameImage(doc, frame: run.frame, values: values, crop: crop, size: frame, white: white)
            let delay = Double(run.length) / Double(max(t.fps, 1))
            let props: [CFString: Any] = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay,
                                                                          kCGImagePropertyAPNGUnclampedDelayTime: delay]]
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            written += run.length
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// フォルダーに「フォルダー名_0001.png」から順に書く（同じ見た目のコマも 1 枚ずつ）
    private static func writePNGSequence(_ doc: DocumentState, to dir: URL, values: [String: Double], options: Options,
                                         progress: (Int, Int) -> Bool) throws {
        let t = doc.timeline
        let (crop, frame, _) = sizes(doc, options)
        let white = options.effectiveBackground == .white
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = dir.lastPathComponent
        var written = 0
        for run in runs(doc, values: values) {
            let image = try frameImage(doc, frame: run.frame, values: values, crop: crop, size: frame, white: white)
            guard let data = ImageUtil.pngData(image) else { throw CocoaError(.fileWriteUnknown) }
            for k in 0..<run.length {
                guard progress(written, t.frameCount) else { throw Cancelled() }
                let name = String(format: "%@_%04d.png", base, run.frame + k + 1)
                try data.write(to: dir.appendingPathComponent(name), options: .atomic)
                written += 1
            }
        }
    }
}
