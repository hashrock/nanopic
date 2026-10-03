import AVFoundation
import XCTest
@testable import NanopicCore

final class PublishTests: XCTestCase {
    /// 8×4 のキャンバス。用紙は隠し、左半分（x < 4）を赤で塗る
    func editor() -> Editor {
        let ed = Editor(width: 8, height: 4)
        ed.toggleVisibility(ed.doc.layers[0].id)
        ed.select(path: CGPath(rect: CGRect(x: 0, y: 0, width: 4, height: 4), transform: nil), op: .replace)
        ed.mainColor = SIMD3<Float>(1, 0, 0)
        ed.fillSelection()
        ed.deselect()
        return ed
    }

    func pixels(_ img: CGImage) -> [UInt8] { ImageUtil.loadPremultiplied(img)!.buffer }

    func testFitKeepsAspectInsideCanvas() {
        let canvas = IntRect(x: 0, y: 0, width: 100, height: 50)
        let r = Publish.fit(IntRect(x: 10, y: 10, width: 20, height: 20), aspect: 2, canvas: canvas)
        XCTAssertEqual(Double(r.width) / Double(r.height), 2, accuracy: 0.1)
        XCTAssertEqual(r.width * r.height, 400, accuracy: 40, "面積をだいたい保つ")
        // 端からはみ出す分はずらし、大きすぎれば縮める
        let edge = Publish.fit(IntRect(x: 90, y: 40, width: 10, height: 10), aspect: 1, canvas: canvas)
        XCTAssertLessThanOrEqual(edge.maxX, 100)
        XCTAssertLessThanOrEqual(edge.maxY, 50)
        let big = Publish.fit(IntRect(x: 0, y: 0, width: 100, height: 50), aspect: 1, canvas: canvas)
        XCTAssertEqual(big.width, 50)
        XCTAssertEqual(big.height, 50)
    }

    func testCropScaleAndBackground() {
        let ed = editor()
        var s = PublishSettings()
        s.rect = IntRect(x: 2, y: 0, width: 4, height: 4) // 左 2 列が赤、右 2 列が透明
        var img = ed.publishImage(s)!
        XCTAssertEqual(img.width, 4)
        XCTAssertEqual(img.height, 4)
        var p = pixels(img)
        XCTAssertEqual(Array(p[0..<4]), [255, 0, 0, 255])
        XCTAssertEqual(p[3 * 4 + 3], 0, "透明のまま")

        s.background = .white
        p = pixels(ed.publishImage(s)!)
        XCTAssertEqual(Array(p[(3 * 4)..<(3 * 4 + 4)]), [255, 255, 255, 255], "白で埋める")
        XCTAssertEqual(Array(p[0..<4]), [255, 0, 0, 255])

        // 縮小（元の絵は変えない）
        s.outputWidth = 2
        s.outputHeight = 2
        img = ed.publishImage(s)!
        XCTAssertEqual(img.width, 2)
        XCTAssertEqual(img.height, 2)
        p = pixels(img)
        XCTAssertGreaterThan(Int(p[0]), 200)
        XCTAssertLessThan(Int(p[1]), 60)
        XCTAssertEqual(ed.doc.width, 8)
    }

    func testEncodeFormats() throws {
        let ed = editor()
        var s = PublishSettings()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let png = dir.appendingPathComponent("a.png")
        try ed.publish(to: png, settings: s)
        XCTAssertEqual(ImageUtil.loadImage(url: png)?.width, 8)

        s.format = .jpeg
        s.quality = 50
        let jpg = dir.appendingPathComponent("a.jpg")
        try ed.publish(to: jpg, settings: s)
        let img = ImageUtil.loadImage(url: jpg)!
        XCTAssertEqual(img.width, 8)
        XCTAssertEqual(s.effectiveBackground, .white, "JPEG はいつも白")
        let p = pixels(img)
        XCTAssertGreaterThan(Int(p[7 * 4]), 230, "透明だった所は白")
    }

    func testSidecarAndDestination() throws {
        let ed = editor()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        ed.fileURL = dir.appendingPathComponent("作品.psd")

        var s = ed.publishSettings
        s.rect = IntRect(x: 1, y: 1, width: 4, height: 2)
        s.outputWidth = 400
        s.outputHeight = 200
        s.format = .jpeg
        s.destination = ed.publishDestinationString(for: dir.appendingPathComponent("out/作品.jpg"))
        XCTAssertEqual(s.destination, "out/作品.jpg", "PSD と同じフォルダーの下なら相対パス")
        XCTAssertEqual(ed.publishDestinationString(for: URL(fileURLWithPath: "/tmp/x.png")), "/tmp/x.png")
        ed.setPublishSettings(s)
        XCTAssertEqual(ed.publishDestinationURL()?.path, dir.appendingPathComponent("out/作品.jpg").path)

        ed.prepareForSave()
        let data = try JSONEncoder().encode(ed.sidecar)
        let back = try JSONDecoder().decode(Sidecar.self, from: data)
        XCTAssertEqual(back.publish, s)
        XCTAssertFalse(back.isEmpty)

        // 取り消せる
        ed.undo()
        XCTAssertNil(ed.doc.publish)
    }

    func testResizeCanvasMovesRect() {
        let ed = editor()
        var s = PublishSettings()
        s.rect = IntRect(x: 4, y: 1, width: 4, height: 2)
        ed.setPublishSettings(s)
        ed.resizeCanvas(width: 6, height: 4, originX: 2, originY: 0)
        XCTAssertEqual(ed.doc.publish?.rect, IntRect(x: 2, y: 1, width: 4, height: 2))
        ed.resizeCanvas(width: 2, height: 2, originX: 0, originY: 0)
        XCTAssertNil(ed.doc.publish?.rect, "外れたらキャンバス全体")
    }

    func testSelectionBecomesRectWithAspect() {
        let ed = editor()
        var s = PublishSettings()
        s.outputWidth = 200
        s.outputHeight = 100
        ed.setPublishSettings(s)
        ed.select(path: CGPath(rect: CGRect(x: 2, y: 0, width: 2, height: 2), transform: nil), op: .replace)
        XCTAssertTrue(ed.setPublishRectFromSelection())
        let r = ed.doc.publish!.rect!
        XCTAssertEqual(r.width, 2 * r.height, "出力の比に合わせる")
        XCTAssertEqual(r, IntRect(x: 1, y: 0, width: 4, height: 2), "選択範囲を囲むように広げる")
    }

    func testMovieUsesPublishSize() async throws {
        let ed = Editor(width: 64, height: 48)
        ed.addLayer(name: "a")
        ed.addTrack(ed.activeLayerID!)
        ed.setTimeline(fps: 4, frameCount: 2)
        var s = PublishSettings()
        s.rect = IntRect(x: 0, y: 0, width: 32, height: 16)
        s.outputWidth = 64
        s.outputHeight = 32
        ed.setPublishSettings(s)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try MovieExport.export(ed.doc, to: url, options: ed.movieOptions)
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 64)
        XCTAssertEqual(size.height, 32)
    }
}

extension PublishTests {
    func testDragRectKeepsAspectAndCanvas() {
        let canvas = IntRect(x: 0, y: 0, width: 100, height: 100)
        let start = IntRect(x: 20, y: 20, width: 40, height: 20) // 2:1
        // 右下の角を広げる（左上を止める）
        var r = Publish.dragRect(start, handle: 2, dx: 20, dy: 0, aspect: 2, canvas: canvas)
        XCTAssertEqual(r, IntRect(x: 20, y: 20, width: 60, height: 30))
        // キャンバスの外までは広げない
        r = Publish.dragRect(start, handle: 2, dx: 500, dy: 500, aspect: 2, canvas: canvas)
        XCTAssertEqual(r.maxX, 100)
        XCTAssertEqual(r.width, 2 * r.height)
        // 左上の角（右下を止める）
        r = Publish.dragRect(start, handle: 0, dx: -10, dy: -10, aspect: 2, canvas: canvas)
        XCTAssertEqual(r.maxX, 60)
        XCTAssertEqual(r.maxY, 40)
        XCTAssertEqual(r.width, 2 * r.height)
        // 右の辺: 幅が変わり、高さは比から、縦の中心は保つ
        r = Publish.dragRect(start, handle: 5, dx: 20, dy: 0, aspect: 2, canvas: canvas)
        XCTAssertEqual(r, IntRect(x: 20, y: 15, width: 60, height: 30))
        // 内側: 動かす。端で止まる
        r = Publish.dragRect(start, handle: Publish.insideHandle, dx: 100, dy: -100, aspect: 2, canvas: canvas)
        XCTAssertEqual(r, IntRect(x: 60, y: 0, width: 40, height: 20))
    }

    func testEditingFieldsKeepsAspect() {
        let canvas = IntRect(x: 0, y: 0, width: 200, height: 100)
        var s = PublishSettings().normalized(canvas: canvas)
        XCTAssertEqual(s.rect, canvas)
        XCTAssertEqual(s.outputWidth, 200)
        // 比を保って出力の幅を変える
        s.setOutputSize(width: 100, lock: true, canvas: canvas)
        XCTAssertEqual(s.outputHeight, 50)
        // 比を変える → 範囲も合わせ直す
        s.setOutputSize(height: 100, lock: false, canvas: canvas)
        XCTAssertEqual(s.outputWidth, 100)
        XCTAssertEqual(s.rect!.width, s.rect!.height)
        // 範囲の幅を変えると高さは比から
        s.setRectSize(width: 40, canvas: canvas)
        XCTAssertEqual(s.rect!.width, 40)
        XCTAssertEqual(s.rect!.height, 40)
        s.setRectOrigin(x: 500, y: -5, canvas: canvas)
        XCTAssertEqual(s.rect!.x, 160)
        XCTAssertEqual(s.rect!.y, 0)
        // 等倍とキャンバス全体
        s.setActualSize(canvas: canvas)
        XCTAssertEqual(s.outputWidth, 40)
        s.setWholeCanvas(canvas)
        XCTAssertEqual(s.rect, canvas)
        XCTAssertEqual(s.outputHeight, 20)
    }
}
