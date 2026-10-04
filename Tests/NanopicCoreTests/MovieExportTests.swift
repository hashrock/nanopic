import AVFoundation
import XCTest
@testable import NanopicCore

final class MovieExportTests: XCTestCase {
    func testOutputSizeIsEvenAndFits() {
        XCTAssertEqual(MovieExport.outputSize(width: 801, height: 599).width, 802)
        XCTAssertEqual(MovieExport.outputSize(width: 801, height: 599).height, 600)
        let big = MovieExport.outputSize(width: 7680, height: 4320)
        XCTAssertEqual(big.width, 3840)
        XCTAssertEqual(big.height, 2160)
    }

    /// 「口」スイッチ（閉じ＝白、あ＝黒）を 0 コマ目と 2 コマ目で切り替えた 4 コマの動画
    func testExportsFramesFromTimeline() async throws {
        let ed = Editor(width: 64, height: 48)
        ed.addFolder(name: "口")
        let mouth = ed.activeLayerID!
        var kids: [UUID] = []
        for (name, color) in [("閉じ", SIMD3<Float>(1, 0, 0)), ("あ", SIMD3<Float>(0, 0, 1))] {
            ed.addLayer(name: name)
            let id = ed.activeLayerID!
            ed.moveLayer(id, relativeTo: mouth, placement: .into)
            ed.mainColor = color
            ed.fillSelection()
            kids.append(id)
        }
        ed.setSwitch(mouth, true)
        ed.addTrack(mouth)
        let layer = ed.doc.node(mouth)!.psdID
        ed.setKey(layer: layer, TimelineKey(frame: 0, child: ed.doc.node(kids[0])!.psdID))
        ed.setKey(layer: layer, TimelineKey(frame: 2, child: ed.doc.node(kids[1])!.psdID))
        ed.setTimeline(fps: 4, frameCount: 4)
        let before = ed.doc.node(mouth)!.children.map(\.visible)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        var calls: [Int] = []
        try MovieExport.export(ed.doc, to: url) { done, _ in calls.append(done); return true }
        XCTAssertEqual(calls.last, 4)
        XCTAssertEqual(ed.doc.node(mouth)!.children.map(\.visible), before, "書き出しで編集中の絵は変えない")

        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        func center(_ t: Double) throws -> (Int, Int, Int) {
            let img = try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: -img.width / 2, y: -img.height / 2, width: img.width, height: img.height))
            return (Int(px[0]), Int(px[1]), Int(px[2]))
        }
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.05)
        let first = try center(0.1), third = try center(0.6)
        XCTAssertGreaterThan(first.0, 180, "0 コマ目は赤"); XCTAssertLessThan(first.2, 80)
        XCTAssertGreaterThan(third.2, 180, "2 コマ目は青"); XCTAssertLessThan(third.0, 80)
    }

    func testCancel() {
        let ed = Editor(width: 32, height: 32)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        XCTAssertThrowsError(try MovieExport.export(ed.doc, to: url) { done, _ in done < 2 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

/// 透明を持つ形式（ProRes 4444・APNG・PNG の連番）
final class AlphaMovieExportTests: XCTestCase {
    /// 64×48、用紙は隠す。左半分を赤く塗ったレイヤーを、0・1 コマ目は出し、2・3 コマ目は隠す（4 fps）
    func document() -> DocumentState {
        let ed = Editor(width: 64, height: 48)
        ed.toggleVisibility(ed.doc.layers[0].id)
        let layer = ed.activeLayerID!
        ed.select(path: CGPath(rect: CGRect(x: 0, y: 0, width: 32, height: 48), transform: nil), op: .replace)
        ed.mainColor = SIMD3<Float>(1, 0, 0)
        ed.fillSelection()
        ed.deselect()
        ed.addTrack(layer)
        let id = ed.doc.node(layer)!.psdID
        ed.setKey(layer: id, TimelineKey(frame: 0, visible: true))
        ed.setKey(layer: id, TimelineKey(frame: 2, visible: false))
        ed.setTimeline(fps: 4, frameCount: 4)
        ed.goToFrame(0)
        return ed.doc
    }

    func options(_ f: MovieFormat) -> MovieExport.Options {
        var o = MovieExport.Options()
        o.format = f
        o.background = .transparent
        return o
    }

    func temp(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
    }

    func testProResKeepsAlpha() async throws {
        let url = temp("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try MovieExport.export(document(), to: url, options: options(.prores))
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        reader.startReading()
        let sample = try XCTUnwrap(out.copyNextSampleBuffer())
        let pb = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pb)
        func px(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let p = base + y * row + x * 4
            return (p[0], p[1], p[2], p[3])
        }
        XCTAssertEqual(CVPixelBufferGetWidth(pb), 64)
        XCTAssertGreaterThan(px(10, 24).a, 240, "塗った所は不透明")
        XCTAssertGreaterThan(px(10, 24).r, 200)
        XCTAssertLessThan(px(50, 24).a, 10, "塗っていない所は透明")
    }

    func testAPNGMergesSameFrames() throws {
        let url = temp("png")
        defer { try? FileManager.default.removeItem(at: url) }
        try MovieExport.export(document(), to: url, options: options(.apng))
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 2, "同じ見た目が続くコマは 1 枚にまとめる")
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        let png = props[kCGImagePropertyPNGDictionary] as! [CFString: Any]
        let delay = (png[kCGImagePropertyAPNGUnclampedDelayTime] ?? png[kCGImagePropertyAPNGDelayTime]) as! Double
        XCTAssertEqual(delay, 0.5, accuracy: 0.01, "2 コマ分（4 fps）")
        let first = ImageUtil.loadPremultiplied(CGImageSourceCreateImageAtIndex(src, 0, nil)!)!.buffer
        XCTAssertEqual(first[(24 * 64 + 50) * 4 + 3], 0, "透明のまま")
        XCTAssertEqual(first[(24 * 64 + 10) * 4 + 3], 255)
    }

    func testPNGSequenceWritesEveryFrame() throws {
        let dir = temp("")
        defer { try? FileManager.default.removeItem(at: dir) }
        try MovieExport.export(document(), to: dir, options: options(.pngSequence))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(files.count, 4)
        XCTAssertEqual(files.first, dir.lastPathComponent + "_0001.png")
        let last = ImageUtil.loadPremultiplied(ImageUtil.loadImage(url: dir.appendingPathComponent(files[3]))!)!.buffer
        XCTAssertEqual(last[(24 * 64 + 10) * 4 + 3], 0, "隠したコマは透明")
    }

    func testMP4IsAlwaysWhite() {
        var o = options(.mp4)
        o.background = .transparent
        XCTAssertEqual(o.effectiveBackground, .white)
    }
}
