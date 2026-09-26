import Foundation
import ImageIO
import XCTest
@testable import NanopicCore

final class PSDTests: XCTestCase {
    // MARK: - Fixtures

    private let W = 200
    private let H = 150

    /// Fills a canvas-sized premultiplied buffer via a straight-color generator.
    private func makeTiles(_ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)?) -> TileMap {
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H {
            for x in 0..<W {
                guard let (r, g, b, a) = f(x, y) else { continue }
                let o = (y * W + x) * 4
                let al = Int(a)
                buf[o] = UInt8((Int(r) * al + 127) / 255)
                buf[o + 1] = UInt8((Int(g) * al + 127) / 255)
                buf[o + 2] = UInt8((Int(b) * al + 127) / 255)
                buf[o + 3] = a
            }
        }
        return buf.withUnsafeBufferPointer { TileMap.from(buffer: $0.baseAddress!, width: W, height: H, gen: 0) }
    }

    private func raster(_ name: String, _ f: @escaping (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)?) -> LayerNode {
        var n = LayerNode(name: name)
        n.tiles = makeTiles(f)
        return n
    }

    private func sampleDoc() -> DocumentState {
        var doc = DocumentState(width: W, height: H)
        doc.dpi = 300

        let bg = raster("背景") { _, _ in (255, 255, 255, 255) }

        var multiply = raster("乗算レイヤー") { x, y in
            (x > 20 && x < 120 && y > 10 && y < 90) ? (200, 50, 30, 255) : nil
        }
        multiply.blendMode = .multiply
        multiply.opacity = 0.5

        var clipped = raster("クリッピング") { x, y in
            (x > 40 && x < 160 && y > 30 && y < 70) ? (10, 120, 250, UInt8((x * 3) % 256)) : nil
        }
        clipped.clipping = true
        clipped.blendMode = .screen

        var hidden = raster("hidden layer") { x, y in (x < 50 && y < 50) ? (0, 255, 0, 128) : nil }
        hidden.visible = false

        var alphaLocked = raster("透明ピクセルロック") { x, y in
            (x + y) % 7 == 0 ? (UInt8(x % 256), UInt8(y % 256), 77, UInt8((x * y) % 255 + 1)) : nil
        }
        alphaLocked.lockAlpha = true
        alphaLocked.blendMode = .overlay
        alphaLocked.locked = true

        var closedNormal = LayerNode(name: "閉じたフォルダ", kind: .folder)
        closedNormal.blendMode = .normal
        closedNormal.expanded = false
        closedNormal.opacity = 0.75
        closedNormal.children = [hidden, alphaLocked]

        let empty = LayerNode(name: "空のレイヤー")

        var pass = LayerNode(name: "通過フォルダ", kind: .folder)
        pass.children = [multiply, clipped, closedNormal, empty]

        // Top layer: content extending past the right/bottom canvas edge (tile has pixels outside the canvas).
        var edge = LayerNode(name: "はみ出しレイヤー🎨")
        edge.blendMode = .linearDodge
        let key = TileKey(x: 1, y: 1)
        let t = edge.tiles.mutableTile(key, gen: 0)
        for y in 0..<kTileSize {
            for x in 0..<kTileSize where x > 30 {
                let o = (y * kTileSize + x) * 4
                t.data[o] = 60; t.data[o + 1] = 30; t.data[o + 2] = 90; t.data[o + 3] = 90
            }
        }

        var hiddenFolder = LayerNode(name: "hidden folder", kind: .folder)
        hiddenFolder.visible = false
        hiddenFolder.blendMode = .difference
        hiddenFolder.children = []

        doc.layers = [bg, pass, hiddenFolder, edge]
        doc.activeLayerID = edge.id
        return doc
    }

    // MARK: - Comparison

    private func assertSameTree(_ a: [LayerNode], _ b: [LayerNode], width: Int, height: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, "child count", file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.name, y.name, file: file, line: line)
            XCTAssertEqual(x.kind, y.kind, x.name, file: file, line: line)
            XCTAssertEqual(x.visible, y.visible, x.name, file: file, line: line)
            XCTAssertEqual(x.opacity, y.opacity, accuracy: 0.003, x.name, file: file, line: line)
            XCTAssertEqual(x.blendMode, y.blendMode, x.name, file: file, line: line)
            XCTAssertEqual(x.clipping, y.clipping, x.name, file: file, line: line)
            XCTAssertEqual(x.lockAlpha, y.lockAlpha, x.name, file: file, line: line)
            XCTAssertEqual(x.locked, y.locked, x.name, file: file, line: line)
            if x.isFolder {
                XCTAssertEqual(x.expanded, y.expanded, x.name, file: file, line: line)
                assertSameTree(x.children, y.children, width: width, height: height, file: file, line: line)
            } else {
                assertSamePixels(x.tiles.toBuffer(width: width, height: height),
                                 y.tiles.toBuffer(width: width, height: height), x.name, tolerance: 2,
                                 file: file, line: line)
            }
        }
    }

    private func assertSamePixels(_ a: [UInt8], _ b: [UInt8], _ label: String, tolerance: Int,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        var failures = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            var ok = a[i + 3] == b[i + 3]
            for c in 0..<3 where abs(Int(a[i + c]) - Int(b[i + c])) > tolerance { ok = false }
            if !ok {
                failures += 1
                if failures <= 3 {
                    XCTFail("\(label): pixel \(i / 4) \(a[i..<i + 4].map { $0 }) vs \(b[i..<i + 4].map { $0 })",
                            file: file, line: line)
                }
            }
        }
        XCTAssertEqual(failures, 0, "\(label): mismatched pixels", file: file, line: line)
    }

    // MARK: - Tests

    func testRoundTrip() throws {
        let doc = sampleDoc()
        let data = try PSD.write(doc)
        XCTAssertEqual(Array(data.prefix(4)), Array("8BPS".utf8))
        let back = try PSD.read(data)
        XCTAssertEqual(back.width, W)
        XCTAssertEqual(back.height, H)
        XCTAssertEqual(back.dpi, 300, accuracy: 0.01)
        assertSameTree(doc.layers, back.layers, width: W, height: H)

        // Structure specifics
        XCTAssertEqual(back.layers[1].blendMode, .passThrough)
        XCTAssertTrue(back.layers[1].expanded)
        XCTAssertEqual(back.layers[1].children[2].blendMode, .normal)
        XCTAssertFalse(back.layers[1].children[2].expanded)
        XCTAssertTrue(back.layers[1].children[3].tiles.isEmpty)
        XCTAssertEqual(back.activeLayerID, back.layers[3].id)

        // The out-of-canvas part is clipped.
        let edgeBounds = back.layers[3].tiles.contentBounds()
        XCTAssertEqual(edgeBounds, IntRect(minX: 128 + 31, minY: 128, maxX: W, maxY: H))

        // Composite of the loaded document matches the original composite.
        assertSamePixels(Compositor.compositeFull(doc), Compositor.compositeFull(back), "composite", tolerance: 3)
    }

    func testRoundTripAlternateEncodings() throws {
        let doc = sampleDoc()
        let variants: [PSDWriteOptions] = [
            PSDWriteOptions(compression: .raw),
            PSDWriteOptions(compression: .zip),
            PSDWriteOptions(compression: .zipPrediction),
            PSDWriteOptions(psb: true),
            PSDWriteOptions(psb: true, compression: .zipPrediction),
            PSDWriteOptions(depth: 16),
            PSDWriteOptions(depth: 16, compression: .zipPrediction),
            PSDWriteOptions(psb: true, depth: 16, compression: .raw),
        ]
        for opt in variants {
            let data = try PSD.write(doc, options: opt)
            let back = try PSD.read(data)
            assertSameTree(doc.layers, back.layers, width: W, height: H)
        }
    }

    func testFlatImageFallback() throws {
        var doc = DocumentState(width: 10, height: 5)
        doc.layers = []
        // No layers → no layer info; merged image only.
        var src = DocumentState(width: 10, height: 5)
        src.layers = [LayerNode(name: "x")]
        src.layers[0].tiles = TileMap.filled(width: 10, height: 5, rgba: (10, 20, 30, 255), gen: 0)
        let merged = try PSD.write(src)
        let empty = try PSD.write(doc)
        let flat = try PSD.read(empty)
        XCTAssertEqual(flat.layers.count, 1)
        XCTAssertEqual(flat.layers[0].kind, .raster)
        XCTAssertNotNil(flat.activeLayerID)
        // Fully transparent merged → opaque flat image of black (no alpha semantics for flat files).
        XCTAssertEqual(flat.layers[0].tiles.pixel(0, 0).3, 255)
        XCTAssertEqual(try PSD.read(merged).layers[0].tiles.pixel(3, 3).0, 10)
    }

    func testEmptyLayerOnly() throws {
        var doc = DocumentState(width: 64, height: 64)
        doc.layers = [LayerNode(name: "empty")]
        let back = try PSD.read(try PSD.write(doc))
        XCTAssertEqual(back.layers.count, 1)
        XCTAssertEqual(back.layers[0].name, "empty")
        XCTAssertTrue(back.layers[0].tiles.isEmpty)
    }

    func testErrors() {
        XCTAssertThrowsError(try PSD.read(Data([1, 2, 3])))
        XCTAssertThrowsError(try PSD.read(Data(repeating: 0, count: 64))) { e in
            guard case PSDError.invalidSignature = e else { return XCTFail("\(e)") }
        }
        var d = [UInt8](try! PSD.write(sampleDoc()))
        d[25] = 4 // CMYK
        XCTAssertThrowsError(try PSD.read(Data(d))) { e in
            guard case PSDError.unsupportedColorMode(4) = e else { return XCTFail("\(e)") }
        }
        d[25] = 3
        d[23] = 32
        XCTAssertThrowsError(try PSD.read(Data(d))) { e in
            guard case PSDError.unsupportedDepth(32) = e else { return XCTFail("\(e)") }
        }
        d[23] = 8
        d[5] = 3
        XCTAssertThrowsError(try PSD.read(Data(d))) { e in
            guard case PSDError.unsupportedVersion = e else { return XCTFail("\(e)") }
        }
        d[5] = 1
        // Truncated file must throw, not crash.
        XCTAssertThrowsError(try PSD.read(Data(d.prefix(d.count / 3))))
    }

    func testPackBits() {
        func rt(_ src: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
            let enc = PSD.packBitsEncode(src)
            XCTAssertEqual(PSD.packBitsDecode(enc, expectedLength: src.count), src, file: file, line: line)
        }
        rt([])
        rt([7])
        rt([1, 2])
        rt([5, 5])
        rt([5, 5, 5])
        rt(Array(repeating: 9, count: 128))
        rt(Array(repeating: 9, count: 129))
        rt(Array(repeating: 9, count: 300))
        rt((0..<128).map { UInt8($0) })
        rt((0..<129).map { UInt8($0) })
        rt((0..<1000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        rt([1, 2, 2, 3, 3, 3, 4, 4, 4, 4, 5] + Array(repeating: 0, count: 200) + [1, 2, 3])
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let n = Int.random(in: 0..<600, using: &rng)
            rt((0..<n).map { _ in UInt8.random(in: 0...3, using: &rng) })
        }

        // Exact encodings
        XCTAssertEqual(PSD.packBitsEncode([7]), [0, 7])
        XCTAssertEqual(PSD.packBitsEncode(Array(repeating: 9, count: 128)), [0x81, 9])
        XCTAssertEqual(PSD.packBitsEncode(Array(repeating: 9, count: 130)), [0x81, 9, 1, 9, 9])
        XCTAssertEqual(PSD.packBitsEncode((0..<129).map { UInt8($0) }).count, 1 + 128 + 1 + 1)

        // Decoding: -128 no-op, truncated / overlong input handled safely.
        XCTAssertEqual(PSD.packBitsDecode([0x80, 0xFE, 4], expectedLength: 3), [4, 4, 4])
        XCTAssertEqual(PSD.packBitsDecode([0x05, 1, 2], expectedLength: 4), [1, 2, 0, 0])
        XCTAssertEqual(PSD.packBitsDecode([0x81, 1], expectedLength: 5), [1, 1, 1, 1, 1])
    }

    func testImageIOReadsFile() throws {
        let doc = sampleDoc()
        let data = try PSD.write(doc)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nanopic-psdtest-\(UUID().uuidString).psd")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return XCTFail("ImageIO could not open PSD")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, W)
        XCTAssertEqual(props?[kCGImagePropertyPixelHeight] as? Int, H)
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, W)
        XCTAssertEqual(image?.height, H)
    }

    func testPerformanceLargeCanvas() throws {
        var doc = DocumentState(width: 2000, height: 2000)
        var n = LayerNode(name: "big")
        n.tiles = TileMap.filled(width: 2000, height: 2000, rgba: (100, 50, 25, 200), gen: 0)
        doc.layers = [n]
        let start = Date()
        let data = try PSD.write(doc)
        let back = try PSD.read(data)
        XCTAssertEqual(back.layers[0].tiles.pixel(1999, 1999).3, 200)
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }
}
