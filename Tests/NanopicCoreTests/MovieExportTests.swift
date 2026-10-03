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
