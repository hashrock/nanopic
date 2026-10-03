import XCTest
@testable import NanopicCore
@testable import NanopicAgent

final class CropTests: XCTestCase {
    /// 赤い点 (60, 40) と青い点 (150, 90) を描いた 200×120 のキャンバス
    func editor() -> Editor {
        let ed = Editor(width: 200, height: 120)
        ed.mainColor = SIMD3(1, 0, 0)
        ed.lassoFill(path: CGPath(rect: CGRect(x: 60, y: 40, width: 1, height: 1), transform: nil))
        ed.mainColor = SIMD3(0, 0, 1)
        ed.lassoFill(path: CGPath(rect: CGRect(x: 150, y: 90, width: 1, height: 1), transform: nil))
        return ed
    }

    func testCropToSelectionMovesPixelsAndClearsSelection() {
        let ed = editor()
        ed.select(path: CGPath(rect: CGRect(x: 50, y: 30, width: 110, height: 70), transform: nil), op: .replace)
        XCTAssertTrue(ed.cropToSelection())
        XCTAssertEqual(ed.doc.width, 110)
        XCTAssertEqual(ed.doc.height, 70)
        XCTAssertNil(ed.doc.selection)
        let l = ed.doc.activeLayer!.tiles
        XCTAssertEqual(l.pixel(10, 10).0, 255, "赤は (60-50, 40-30)")
        XCTAssertEqual(l.pixel(100, 60).2, 255, "青は (150-50, 90-30)")
        // 用紙も一緒に切り詰められる
        XCTAssertEqual(ed.doc.layers[0].tiles.pixel(109, 69).3, 255)
        ed.undo()
        XCTAssertEqual(ed.doc.width, 200)
        XCTAssertEqual(ed.doc.activeLayer!.tiles.pixel(60, 40).0, 255)
    }

    func testCropWithoutSelectionDoesNothing() {
        let ed = editor()
        XCTAssertFalse(ed.cropToSelection())
        XCTAssertEqual(ed.doc.width, 200)
        XCTAssertFalse(ed.canUndo && ed.undoLabel == "トリミング")
    }

    func testResizeKeepsTopLeftByDefault() {
        let ed = editor()
        ed.resizeCanvas(width: 300, height: 200)
        XCTAssertEqual(ed.doc.activeLayer!.tiles.pixel(60, 40).0, 255)
        XCTAssertEqual(ed.doc.activeLayer!.tiles.pixel(150, 90).2, 255)
    }

    func testAgentCrop() throws {
        let ed = editor()
        let tb = AgentToolbox(editor: ed)
        XCTAssertThrowsError(try tb.call("crop", [:]))
        _ = try tb.call("crop", ["rect": ["x": 140, "y": 80, "width": 100, "height": 100]])
        XCTAssertEqual(ed.doc.width, 60, "キャンバスの外ははみ出さない")
        XCTAssertEqual(ed.doc.height, 40)
        XCTAssertEqual(ed.doc.activeLayer!.tiles.pixel(10, 10).2, 255)
    }
}
