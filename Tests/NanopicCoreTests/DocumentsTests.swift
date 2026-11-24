import XCTest
@testable import NanopicCore

/// 複数の書類（タブ）: 道具は引き継ぎ、中身と取り消しの履歴は書類ごと
final class DocumentsTests: XCTestCase {
    func testAdoptToolStateCopiesToolsButNotDocument() {
        let a = Editor(width: 64, height: 64)
        let b = Editor(width: 32, height: 16)
        a.mainColor = SIMD3(1, 0, 0)
        a.subColor = SIMD3(0, 0, 1)
        a.palette = [SIMD3(0.5, 0.5, 0.5)]
        a.tool = .fill
        a.activeBrushIndex = 2
        a.setBrushSize(33)
        a.grid.visible = true
        a.addTip(BrushTip(id: "test", name: "test", size: 4, pixels: [Float](repeating: 1, count: 16)))
        a.addLayer()
        XCTAssertTrue(a.canUndo)

        b.adoptToolState(from: a)
        XCTAssertEqual(b.mainColor, a.mainColor)
        XCTAssertEqual(b.subColor, a.subColor)
        XCTAssertEqual(b.palette, a.palette)
        XCTAssertEqual(b.tool, .fill)
        XCTAssertEqual(b.activeBrushIndex, 2)
        XCTAssertEqual(b.brushes, a.brushes)
        XCTAssertEqual(b.currentBrush.size, 33)
        XCTAssertTrue(b.grid.visible)
        XCTAssertEqual(b.tip("test").id, "test")
        // 書類の中身・履歴・保存状態は引き継がない
        XCTAssertEqual(b.doc.width, 32)
        XCTAssertEqual(b.doc.layers.count, 2)
        XCTAssertFalse(b.canUndo)
        XCTAssertFalse(b.isDirty)
    }

    func testAdoptToolStateDoesNotStartTransform() {
        let a = Editor(width: 16, height: 16)
        let b = Editor(width: 16, height: 16)
        a.tool = .transform
        b.adoptToolState(from: a)
        XCTAssertNotEqual(b.tool, .transform)
        XCTAssertNil(b.floating)
    }

    func testUndoIsPerDocument() {
        let a = Editor(width: 16, height: 16)
        let b = Editor(width: 16, height: 16)
        a.addLayer()
        b.adoptToolState(from: a)
        XCTAssertTrue(a.canUndo)
        XCTAssertFalse(b.canUndo)
        b.undo()
        XCTAssertEqual(a.doc.layers.count, 3)
        a.undo()
        XCTAssertEqual(a.doc.layers.count, 2)
        XCTAssertEqual(b.doc.layers.count, 2)
    }
}
