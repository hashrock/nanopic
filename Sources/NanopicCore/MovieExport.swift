import AVFoundation
import CoreGraphics
import Foundation

/// タイムラインを MP4（H.264）に書き出す。透明な部分は白にする
public enum MovieExport {
    public struct Options: Sendable {
        /// 長辺をこれ以下にする（H.264 の上限に収めるため）
        public var maxLongSide = 3840
        public init() {}
    }

    public struct Cancelled: Error {}

    /// 出力される動画の大きさ（偶数に切り上げ、長辺を maxLongSide 以下に）
    public static func outputSize(width: Int, height: Int, options: Options = Options()) -> (width: Int, height: Int) {
        let scale = min(1, Double(options.maxLongSide) / Double(max(width, height)))
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded(.up)) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// doc の写しにコマごとの表示状態を当てて書き出す。progress は (書いたコマ数, 全コマ数) で、false を返すと中止する
    public static func export(_ doc: DocumentState, to url: URL, options: Options = Options(),
                              progress: (Int, Int) -> Bool = { _, _ in true }) throws {
        let t = doc.timeline
        let (w, h) = outputSize(width: doc.width, height: doc.height, options: options)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
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

        let scale = min(1, Double(options.maxLongSide) / Double(max(doc.width, doc.height)))
        var frameDoc = doc
        let fps = Int32(max(t.fps, 1))
        for f in 0..<max(t.frameCount, 1) {
            guard progress(f, t.frameCount) else {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                throw Cancelled()
            }
            frameDoc.applyTimeline(frame: f)
            let buf = Compositor.compositeFull(frameDoc)
            guard let image = ImageUtil.makeImage(premultiplied: buf, width: doc.width, height: doc.height),
                  let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: ImageUtil.sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            ctx?.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx?.interpolationQuality = .high
            // 偶数に切り上げた分は右と下に白で足す（CGContext は下が原点）
            ctx?.draw(image, in: CGRect(x: 0, y: Double(h) - Double(doc.height) * scale,
                                        width: Double(doc.width) * scale, height: Double(doc.height) * scale))
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(max(t.frameCount, 1)), timescale: fps))
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        _ = progress(t.frameCount, t.frameCount)
    }
}
