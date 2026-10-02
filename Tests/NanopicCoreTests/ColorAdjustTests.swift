import XCTest
@testable import NanopicCore
import simd

final class ColorAdjustTests: XCTestCase {
    func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ e: Float = 0.01, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), e, "\(a) != \(b)", file: file, line: line)
    }

    func testFormulas() {
        let red = SIMD3<Float>(1, 0, 0)
        near(ColorAdjustment().apply(SIMD3(0.3, 0.6, 0.2)), SIMD3(0.3, 0.6, 0.2))
        near(ColorAdjustment(hue: 180).apply(red), SIMD3(0, 1, 1))
        near(ColorAdjustment(hue: 120).apply(red), SIMD3(0, 1, 0))
        let gray = ColorAdjustment(saturation: -100).apply(SIMD3(0.8, 0.2, 0.2))
        XCTAssertEqual(gray.x, gray.y, accuracy: 0.001)
        XCTAssertEqual(gray.y, gray.z, accuracy: 0.001)
        near(ColorAdjustment(lightness: 100).apply(red), SIMD3(1, 1, 1))
        near(ColorAdjustment(lightness: -100).apply(red), SIMD3(0, 0, 0))
        // コントラストを上げると中間から離れ、下げると近づく
        XCTAssertGreaterThan(ColorAdjustment(contrast: 50).apply(SIMD3(repeating: 0.7)).x, 0.7)
        XCTAssertLessThan(ColorAdjustment(contrast: -50).apply(SIMD3(repeating: 0.7)).x, 0.7)
        XCTAssertGreaterThan(ColorAdjustment(brightness: 40).apply(SIMD3(repeating: 0.5)).x, 0.5)
    }

    func editorWithRedSquare() -> Editor {
        let ed = Editor(width: 200, height: 200)
        ed.mainColor = SIMD3(1, 0, 0)
        ed.lassoFill(path: CGPath(rect: CGRect(x: 20, y: 20, width: 100, height: 100), transform: nil))
        return ed
    }

    func testPreviewDoesNotChangeLayerUntilCommit() {
        let ed = editorWithRedSquare()
        let id = ed.activeLayerID!
        XCTAssertTrue(ed.previewAdjustment(ColorAdjustment(hue: 180)))
        XCTAssertEqual(ed.doc.node(id)!.tiles.pixel(50, 50).0, 255, "プレビュー中はレイヤーの中身を変えない")
        // 表示（合成）には反映される
        let shown = Compositor.compositeFull(ed.doc, options: ed.compositeOptions())
        XCTAssertEqual(shown[(50 * 200 + 50) * 4], 0)
        XCTAssertEqual(shown[(50 * 200 + 50) * 4 + 1], 255)
        ed.cancelAdjustment()
        XCTAssertNil(ed.adjustment)
        XCTAssertEqual(ed.doc.node(id)!.tiles.pixel(50, 50).0, 255)

        ed.previewAdjustment(ColorAdjustment(hue: 180))
        ed.commitAdjustment()
        let p = ed.doc.node(id)!.tiles.pixel(50, 50)
        XCTAssertEqual(p.0, 0)
        XCTAssertEqual(p.1, 255)
        XCTAssertEqual(p.3, 255)
        ed.undo()
        XCTAssertEqual(ed.doc.node(id)!.tiles.pixel(50, 50).0, 255)
    }

    func testSelectionLimitsAdjustment() {
        let ed = editorWithRedSquare()
        let id = ed.activeLayerID!
        ed.select(path: CGPath(rect: CGRect(x: 20, y: 20, width: 50, height: 100), transform: nil), op: .replace)
        ed.previewAdjustment(ColorAdjustment(hue: 120))
        ed.commitAdjustment()
        XCTAssertEqual(ed.doc.node(id)!.tiles.pixel(40, 50).1, 255)
        XCTAssertEqual(ed.doc.node(id)!.tiles.pixel(100, 50).0, 255, "選択範囲の外は変えない")
    }

    func testAgentAdjustColor() throws {
        let ed = editorWithRedSquare()
        let tb = AgentToolbox(editor: ed)
        _ = try tb.call("adjust_color", ["hue": 180])
        XCTAssertEqual(ed.doc.activeLayer!.tiles.pixel(50, 50).2, 255)
        XCTAssertNil(ed.adjustment)
    }
}

final class PaletteTests: XCTestCase {
    func testAddRemoveReplace() {
        let ed = Editor(width: 10, height: 10)
        let n = ed.palette.count
        XCTAssertGreaterThan(n, 0)
        ed.addToPalette(SIMD3(0.5, 0.25, 0.75))
        ed.addToPalette(SIMD3(0.5, 0.25, 0.75))
        XCTAssertEqual(ed.palette.count, n + 1, "同じ色は足さない")
        ed.replacePaletteColor(at: n, with: SIMD3(1, 0, 0))
        XCTAssertEqual(AgentToolbox.hex(ed.palette[n]), "#FF0000")
        ed.removeFromPalette(at: n)
        ed.removeFromPalette(at: 999)
        XCTAssertEqual(ed.palette.count, n)
    }

    func testAgentEditPalette() throws {
        let ed = Editor(width: 10, height: 10)
        ed.palette = []
        let tb = AgentToolbox(editor: ed)
        _ = try tb.call("edit_palette", ["add": ["#112233", "#445566", "#112233"]])
        XCTAssertEqual(ed.palette.map(AgentToolbox.hex), ["#112233", "#445566"])
        _ = try tb.call("edit_palette", ["remove": ["#112233"]])
        XCTAssertEqual(ed.palette.map(AgentToolbox.hex), ["#445566"])
        XCTAssertThrowsError(try tb.call("edit_palette", ["add": ["red"]]))
    }
}
