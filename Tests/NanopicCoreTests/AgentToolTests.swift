import XCTest
@testable import NanopicCore
import ImageIO

final class AgentToolTests: XCTestCase {
    func text(_ c: [AgentContent]) -> String {
        c.compactMap { if case let .text(t) = $0 { return t } else { return nil } }.joined()
    }

    func object(_ c: [AgentContent]) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(c).utf8)) as? [String: Any])
    }

    func pixel(_ ed: Editor, _ id: UUID, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        ed.doc.node(id)!.tiles.pixel(x, y)
    }

    /// 線画を描き、範囲を探して塗る。線の下まで塗られ、隣の範囲にははみ出さないこと
    func testFlatColoringFlow() throws {
        let ed = Editor(width: 200, height: 120)
        let tb = AgentToolbox(editor: ed)
        let line = try object(tb.call("add_layer", ["name": "線画"]))["layer_id"] as! String
        // 外枠と、中央の縦線で左右 2 つの範囲を作る
        let frame: [[Double]] = [[20, 20], [180, 20], [180, 100], [20, 100], [20, 20]]
        _ = try tb.call("stroke", ["points": frame, "size": 4, "color": "#000000", "brush": "丸ペン"])
        _ = try tb.call("stroke", ["points": [[100, 20], [100, 100]], "size": 4, "color": "#000000", "brush": "丸ペン"])
        let fill = try object(tb.call("add_layer", ["name": "下塗り", "below": line]))["layer_id"] as! String

        let found = try tb.call("find_regions", ["reference": line])
        XCTAssertTrue(found.contains { if case .png = $0 { return true } else { return false } })
        let regions = try object(found)["regions"] as! [[String: Any]]
        // 外側（背景）と、枠の中の左右
        let inner = regions.filter { $0["touches_edge"] == nil }
        XCTAssertEqual(inner.count, 2)
        let left = inner.first { (($0["point"] as! [Int])[0]) < 100 }!["region"] as! Int
        let right = inner.first { (($0["point"] as! [Int])[0]) > 100 }!["region"] as! Int

        _ = try tb.call("fill_regions", ["fills": [["region": left, "color": "#FF0000"], ["region": right, "color": "#0000FF"]],
                                         "layer_id": fill])
        // 範囲の中
        XCTAssertEqual(pixel(ed, UUID(uuidString: fill)!, 60, 60).0, 255)
        XCTAssertEqual(pixel(ed, UUID(uuidString: fill)!, 140, 60).2, 255)
        // 線の下（中央の線の左半分）まで赤が届いている
        XCTAssertEqual(pixel(ed, UUID(uuidString: fill)!, 99, 60).0, 255)
        // 右の範囲には赤がはみ出さない
        XCTAssertEqual(pixel(ed, UUID(uuidString: fill)!, 102, 60).0, 0)
        // 枠の外は塗らない
        XCTAssertEqual(pixel(ed, UUID(uuidString: fill)!, 5, 5).3, 0)
        // 1 回で取り消せる
        _ = try tb.call("undo", [:])
        XCTAssertEqual(pixel(ed, UUID(uuidString: fill)!, 60, 60).3, 0)
    }

    func testGapCloseSeparatesBrokenLine() throws {
        let ed = Editor(width: 200, height: 120)
        let tb = AgentToolbox(editor: ed)
        let line = try object(tb.call("add_layer", ["name": "線画"]))["layer_id"] as! String
        _ = try tb.call("stroke", ["points": [[20, 20], [180, 20], [180, 100], [20, 100], [20, 20]], "size": 3, "color": "#000000", "brush": "丸ペン"])
        // 中央の線に 4px の切れ目
        _ = try tb.call("stroke", ["points": [[100, 20], [100, 58]], "size": 3, "color": "#000000", "brush": "丸ペン"])
        _ = try tb.call("stroke", ["points": [[100, 63], [100, 100]], "size": 3, "color": "#000000", "brush": "丸ペン"])
        let open = try object(tb.call("find_regions", ["reference": line]))["regions"] as! [[String: Any]]
        XCTAssertEqual(open.filter { $0["touches_edge"] == nil }.count, 1)
        let closed = try object(tb.call("find_regions", ["reference": line, "gap_close": 3]))["regions"] as! [[String: Any]]
        XCTAssertEqual(closed.filter { $0["touches_edge"] == nil }.count, 2)
    }

    func testStrokeIsDeterministicAndRestoresBrush() throws {
        func draw() throws -> [UInt8] {
            let ed = Editor(width: 120, height: 80)
            let tb = AgentToolbox(editor: ed)
            let sizeBefore = ed.brushes.first { $0.name == "チョーク" }!.size
            _ = try tb.call("stroke", ["points": [[10, 40, 0.2], [60, 20, 1], [110, 40, 0.3]], "brush": "チョーク", "size": 18])
            XCTAssertEqual(ed.brushes.first { $0.name == "チョーク" }!.size, sizeBefore)
            XCTAssertEqual(ed.tool, .brush)
            XCTAssertEqual(ed.activeBrushIndex, 0)
            return Compositor.compositeFull(ed.doc)
        }
        XCTAssertEqual(try draw(), try draw())
    }

    func testErrorsAreReported() {
        let tb = AgentToolbox(editor: Editor(width: 10, height: 10))
        XCTAssertThrowsError(try tb.call("fill_regions", ["fills": [["region": 1, "color": "#000000"]]]))
        XCTAssertThrowsError(try tb.call("fill", ["x": 3, "y": 3, "color": "red"]))
        XCTAssertThrowsError(try tb.call("nope", [:]))
    }

    func testGetImageWithGrid() throws {
        let tb = AgentToolbox(editor: Editor(width: 3000, height: 2000))
        let out = try tb.call("get_image", ["grid": true, "max_size": 600])
        guard case let .png(data) = out[0] else { return XCTFail() }
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil))
        XCTAssertEqual(img.width, 600)
        XCTAssertEqual(img.height, 400)
        XCTAssertTrue(text(out).contains("5.00"))
    }
}

extension AgentToolTests {
    /// 線の上から塗りつぶすと警告が出ること
    func testFillOnLineWarns() throws {
        let ed = Editor(width: 200, height: 120)
        let tb = AgentToolbox(editor: ed)
        _ = try tb.call("stroke", ["points": [[20, 60], [180, 60]], "size": 6, "color": "#000000", "brush": "丸ペン"])
        let onLine = try object(tb.call("fill", ["x": 100, "y": 60, "color": "#FF0000"]))
        XCTAssertNotNil(onLine["warning"])
        let inside = try object(tb.call("fill", ["x": 100, "y": 20, "color": "#FF0000"]))
        XCTAssertNil(inside["warning"])
        XCTAssertGreaterThan(inside["area"] as! Int, 0)
    }
}
