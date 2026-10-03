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

extension AgentToolTests {
    func testBatchRunsInOrderAndStopsOnError() throws {
        let ed = Editor(width: 100, height: 100)
        let tb = AgentToolbox(editor: ed)
        let out = try tb.call("batch", ["calls": [
            ["tool": "add_layer", "arguments": ["name": "a"]],
            ["tool": "mcp__nanopic__fill_selection", "arguments": ["color": "#00FF00"]],
        ]])
        XCTAssertTrue(text(out).contains("2 件すべて成功"))
        XCTAssertEqual(ed.doc.activeLayer?.name, "a")
        XCTAssertEqual(ed.doc.activeLayer?.tiles.pixel(50, 50).1, 255)
        XCTAssertThrowsError(try tb.call("batch", ["calls": [["tool": "set_color", "arguments": ["main": "bad"]],
                                                              ["tool": "add_layer"]]]))
        XCTAssertEqual(ed.doc.activeLayer?.name, "a", "失敗した後は実行しない")
    }

    func testTransformMovesSelection() throws {
        let ed = Editor(width: 100, height: 100)
        let tb = AgentToolbox(editor: ed)
        _ = try tb.call("select", ["shape": "rect", "rect": ["x": 10, "y": 10, "width": 20, "height": 20]])
        _ = try tb.call("fill_selection", ["color": "#FF0000"])
        _ = try tb.call("transform", ["dx": 50, "dy": 0])
        let l = ed.doc.activeLayer!.tiles
        XCTAssertEqual(l.pixel(20, 20).3, 0)
        XCTAssertEqual(l.pixel(70, 20).0, 255)
    }

    func testSelectLayerAndWand() throws {
        let ed = Editor(width: 100, height: 100)
        let tb = AgentToolbox(editor: ed)
        let id = try object(tb.call("add_layer", ["name": "a"]))["layer_id"] as! String
        _ = try tb.call("lasso_fill", ["points": [[10, 10], [40, 10], [40, 40], [10, 40]], "color": "#000000", "antialias": false])
        _ = try tb.call("select", ["shape": "layer", "layer_id": id])
        XCTAssertEqual(ed.doc.selection?.bounds, IntRect(x: 10, y: 10, width: 30, height: 30))
        _ = try tb.call("select", ["shape": "wand", "x": 80, "y": 80])
        XCTAssertEqual(ed.doc.selection?.value(80, 80), 255)
        XCTAssertEqual(ed.doc.selection?.value(20, 20), 0)
    }

    func testBrushSettingsOverrideAndPersistentEdits() throws {
        let ed = Editor(width: 100, height: 100)
        let tb = AgentToolbox(editor: ed)
        XCTAssertThrowsError(try tb.call("stroke", ["points": [[10, 10], [90, 90]], "settings": ["nope": 1]]))
        _ = try tb.call("stroke", ["points": [[10, 10], [90, 90]], "settings": ["hardness": 0.2]])
        XCTAssertEqual(ed.brushes[0].hardness, BrushSettings.defaultPresets[0].hardness, "一時的な上書きは残らない")
        _ = try tb.call("update_brush", ["brush": "丸ペン", "settings": ["size": 33]])
        XCTAssertEqual(ed.brushes.first { $0.name == "丸ペン" }?.size, 33)
        let made = try object(tb.call("create_brush", ["from": "丸ペン", "name": "太丸", "settings": ["size": 60]]))
        XCTAssertEqual(ed.brushes.last?.name, "太丸")
        XCTAssertEqual(ed.brushes.last?.id.uuidString, made["id"] as? String)
        _ = try tb.call("select_brush", ["brush": "太丸"])
        XCTAssertEqual(ed.currentBrush.name, "太丸")
    }

    func testGroupLayers() throws {
        let ed = Editor(width: 50, height: 50)
        let tb = AgentToolbox(editor: ed)
        let a = try object(tb.call("add_layer", ["name": "a"]))["layer_id"] as! String
        let b = try object(tb.call("add_layer", ["name": "b"]))["layer_id"] as! String
        let f = try object(tb.call("group_layers", ["layer_ids": [a, b], "name": "人物"]))["folder_id"] as! String
        let folder = try XCTUnwrap(ed.doc.node(UUID(uuidString: f)))
        XCTAssertEqual(folder.name, "人物")
        XCTAssertEqual(Set(folder.children.map(\.name)), ["a", "b"])
    }
}

extension AgentToolTests {
    /// lasso_fill で塗り残したすき間を、接している色で埋めること
    func testFillLeftovers() throws {
        let ed = Editor(width: 200, height: 120)
        let tb = AgentToolbox(editor: ed)
        let line = try object(tb.call("add_layer", ["name": "線画"]))["layer_id"] as! String
        _ = try tb.call("stroke", ["points": [[20, 20], [180, 20], [180, 100], [20, 100], [20, 20]], "size": 4, "color": "#000000", "brush": "丸ペン"])
        _ = try tb.call("stroke", ["points": [[100, 20], [100, 100]], "size": 4, "color": "#000000", "brush": "丸ペン"])
        let flat = try object(tb.call("add_layer", ["name": "下塗り", "below": line]))["layer_id"] as! String
        // 左は少し塗り残し、右は赤で全部
        _ = try tb.call("lasso_fill", ["points": [[22, 22], [90, 22], [90, 98], [22, 98]], "color": "#00FF00", "antialias": false])
        _ = try tb.call("lasso_fill", ["points": [[102, 22], [178, 22], [178, 98], [102, 98]], "color": "#FF0000", "antialias": false])
        let fid = UUID(uuidString: flat)!
        XCTAssertEqual(ed.doc.node(fid)!.tiles.pixel(95, 60).3, 0)
        let out = try object(tb.call("fill_leftovers", ["reference": line, "max_area": 2000]))
        XCTAssertEqual(out["filled"] as? Int, 1)
        let px = ed.doc.node(fid)!.tiles.pixel(95, 60)
        XCTAssertEqual(px.1, 255)
        XCTAssertEqual(px.0, 0)
        // 枠の外（背景）は大きいので塗らない
        XCTAssertEqual(ed.doc.node(fid)!.tiles.pixel(5, 5).3, 0)
    }

    func testSmallRegionIsMagnified() throws {
        let tb = AgentToolbox(editor: Editor(width: 300, height: 300))
        let out = try tb.call("get_image", ["region": ["x": 10, "y": 10, "width": 32, "height": 16]])
        guard case let .png(data) = out[0] else { return XCTFail() }
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil))
        XCTAssertEqual(img.width, 512)
        XCTAssertEqual(img.height, 256)
        XCTAssertTrue(text(out).contains("16 倍"))
    }
}

extension AgentToolTests {
    /// 開いた線を、非表示の閉じ線レイヤーと一緒に参照すると範囲が分かれること
    func testClosingLineLayer() throws {
        let ed = Editor(width: 200, height: 120)
        let tb = AgentToolbox(editor: ed)
        let line = try object(tb.call("add_layer", ["name": "線画"]))["layer_id"] as! String
        // 下が開いたコの字
        _ = try tb.call("stroke", ["points": [[20, 110], [20, 20], [180, 20], [180, 110]], "size": 4, "color": "#000000", "brush": "丸ペン"])
        let before = try object(tb.call("find_regions", ["reference": line]))["regions"] as! [[String: Any]]
        XCTAssertEqual(before.filter { $0["touches_edge"] == nil }.count, 0)
        let closing = try object(tb.call("add_layer", ["name": "閉じ線"]))["layer_id"] as! String
        _ = try tb.call("stroke", ["points": [[20, 100], [180, 100]], "size": 4, "color": "#000000", "brush": "丸ペン"])
        _ = try tb.call("update_layer", ["layer_id": closing, "visible": false])
        let after = try object(tb.call("find_regions", ["reference": [line, closing]]))["regions"] as! [[String: Any]]
        XCTAssertEqual(after.filter { $0["touches_edge"] == nil }.count, 1)
    }
}

extension AgentToolTests {
    /// パーツごとのレイヤーに塗り分け、フォルダーごと塗り残しを埋められること
    func testSeparateLayersAndLeftoversInFolder() throws {
        let ed = Editor(width: 200, height: 120)
        let tb = AgentToolbox(editor: ed)
        let line = try object(tb.call("add_layer", ["name": "線画"]))["layer_id"] as! String
        _ = try tb.call("stroke", ["points": [[20, 20], [180, 20], [180, 100], [20, 100], [20, 20]], "size": 4, "color": "#000000", "brush": "丸ペン"])
        _ = try tb.call("stroke", ["points": [[100, 20], [100, 100]], "size": 4, "color": "#000000", "brush": "丸ペン"])
        let regions = try object(tb.call("find_regions", ["reference": line]))["regions"] as! [[String: Any]]
        let inner = regions.filter { $0["touches_edge"] == nil }.map { $0["region"] as! Int }
        let out = try object(tb.call("fill_regions", ["separate_layers": true, "fills": [
            ["region": inner[0], "color": "#FF0000", "name": "服"], ["region": inner[1], "color": "#0000FF", "name": "肌"]]]))
        let layers = out["layers"] as! [String: String]
        XCTAssertEqual(Set(layers.keys), ["服", "肌"])
        let folder = try XCTUnwrap(ed.doc.node(UUID(uuidString: out["folder_id"] as! String)))
        XCTAssertEqual(folder.name, "下塗り")
        XCTAssertEqual(folder.children.count, 2)
        // フォルダーは線画のすぐ下
        let order = ed.doc.layers.map(\.name)
        XCTAssertEqual(order.firstIndex(of: "下塗り")! + 1, order.firstIndex(of: "線画")!)
        // 同じ name で呼ぶと同じレイヤーに足す
        let again = try object(tb.call("fill_regions", ["separate_layers": true, "fills": [["region": inner[0], "color": "#FF0000", "name": "服"]]]))
        XCTAssertEqual((again["layers"] as! [String: String])["服"], layers["服"])
        XCTAssertEqual(ed.doc.node(folder.id)!.children.count, 2)
        // フォルダー指定で塗り残しを埋める（今回は塗り残しなし）
        let left = try object(tb.call("fill_leftovers", ["layer_id": folder.id.uuidString]))
        XCTAssertEqual(left["filled"] as? Int, 0)
    }

    func testCurveAndHiddenLayerStroke() throws {
        let ed = Editor(width: 200, height: 120)
        let tb = AgentToolbox(editor: ed)
        let id = try object(tb.call("add_layer", ["name": "閉じ線"]))["layer_id"] as! String
        _ = try tb.call("update_layer", ["layer_id": id, "visible": false])
        XCTAssertThrowsError(try tb.call("stroke", ["points": [[10, 60], [100, 20], [190, 60]]]), "layer_id なしでは描かない")
        _ = try tb.call("stroke", ["points": [[10, 60], [100, 20], [190, 60]], "curve": true, "layer_id": id, "size": 4, "brush": "丸ペン"])
        let n = ed.doc.node(UUID(uuidString: id)!)!
        XCTAssertFalse(n.visible)
        // 曲線なので、中間の点 (55, ~33) あたりを通り、折れ線の (55, 40) は通らない
        XCTAssertEqual(n.tiles.pixel(100, 20).3, 255)
        XCTAssertLessThan(n.tiles.pixel(55, 40).3, 255)
    }
}

extension AgentToolTests {
    func framedLineArt(_ tb: AgentToolbox, brokenDivider: Bool) throws -> String {
        let line = try object(tb.call("add_layer", ["name": "線画"]))["layer_id"] as! String
        _ = try tb.call("stroke", ["points": [[20, 20], [180, 20], [180, 100], [20, 100], [20, 20]], "size": 3, "color": "#000000", "brush": "丸ペン"])
        if brokenDivider {
            _ = try tb.call("stroke", ["points": [[100, 20], [100, 50]], "size": 3, "color": "#000000", "brush": "丸ペン"])
            _ = try tb.call("stroke", ["points": [[100, 68], [100, 100]], "size": 3, "color": "#000000", "brush": "丸ペン"])
        } else {
            _ = try tb.call("stroke", ["points": [[100, 20], [100, 100]], "size": 3, "color": "#000000", "brush": "丸ペン"])
        }
        return line
    }

    func testFindAndCloseGaps() throws {
        let ed = Editor(width: 200, height: 120)
        let tb = AgentToolbox(editor: ed)
        let line = try framedLineArt(tb, brokenDivider: true)
        let found = try tb.call("find_gaps", ["reference": line])
        let gaps = try object(found)["gaps"] as! [[String: Any]]
        XCTAssertEqual(gaps.count, 1)
        let g = gaps[0]
        XCTAssertEqual((g["from"] as! [Int])[0], 100, accuracy: 2)
        XCTAssertEqual(g["length"] as! Int, 17, accuracy: 4)
        let closed = try object(tb.call("close_gaps", ["gaps": "all"]))
        let closing = closed["layer_id"] as! String
        XCTAssertFalse(ed.doc.node(UUID(uuidString: closing)!)!.visible)
        let regions = try object(tb.call("find_regions", ["reference": [line, closing]]))["regions"] as! [[String: Any]]
        XCTAssertEqual(regions.filter { $0["touches_edge"] == nil }.count, 2)
    }

    func testClosedLineArtHasNoGaps() throws {
        let tb = AgentToolbox(editor: Editor(width: 200, height: 120))
        let line = try framedLineArt(tb, brokenDivider: false)
        XCTAssertEqual(try object(tb.call("find_gaps", ["reference": line]))["count"] as? Int, 0)
    }

}

extension AgentToolTests {
    /// どのツールにも説明と引数の形があり、使われていない説明もない
    func testEveryToolHasSchema() {
        let tb = AgentToolbox(editor: Editor(width: 8, height: 8))
        let schemaNames = Set(AgentToolbox.parseSchemas(coreToolSchemas).keys)
        let toolNames = Set(tb.tools.map(\.name))
        XCTAssertEqual(toolNames, schemaNames)
        for t in tb.tools {
            XCTAssertFalse(t.description.isEmpty, t.name)
            XCTAssertEqual(t.inputSchema["type"] as? String, "object", t.name)
        }
    }
}
