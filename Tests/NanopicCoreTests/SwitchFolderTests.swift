import XCTest
@testable import NanopicCore

final class SwitchFolderTests: XCTestCase {
    /// 「表情」フォルダーに 通常・笑顔・驚き（下から）
    func editor() -> (Editor, folder: UUID, kids: [UUID]) {
        let ed = Editor(width: 32, height: 32)
        ed.addFolder(name: "表情")
        let folder = ed.activeLayerID!
        var kids: [UUID] = []
        for name in ["通常", "笑顔", "驚き"] {
            ed.addLayer(name: name)
            let id = ed.activeLayerID!
            ed.moveLayer(id, relativeTo: folder, placement: .into)
            kids.append(id)
        }
        return (ed, folder, kids)
    }

    func visibleNames(_ ed: Editor, _ folder: UUID) -> [String] {
        ed.doc.node(folder)!.children.filter(\.visible).map(\.name)
    }

    func testTurningOnKeepsActiveChildOnly() {
        let (ed, folder, kids) = editor()
        ed.setActiveLayer(kids[1])
        ed.setSwitch(folder, true)
        XCTAssertEqual(visibleNames(ed, folder), ["笑顔"])
        ed.undo()
        XCTAssertFalse(ed.doc.node(folder)!.isSwitch)
        XCTAssertEqual(visibleNames(ed, folder).count, 3)
    }

    func testEyeActsLikeRadio() {
        let (ed, folder, kids) = editor()
        ed.setSwitch(folder, true)
        ed.toggleVisibility(kids[0])
        XCTAssertEqual(visibleNames(ed, folder), ["通常"])
        ed.toggleVisibility(kids[0])
        XCTAssertEqual(visibleNames(ed, folder), ["通常"], "表示中の子は隠せない")
        ed.undo()
        XCTAssertEqual(visibleNames(ed, folder).count, 1)
        XCTAssertNotEqual(visibleNames(ed, folder), ["通常"])
    }

    func testSelectingHiddenChildRevealsIt() {
        let (ed, folder, kids) = editor()
        ed.setActiveLayer(kids[2])
        ed.setSwitch(folder, true)
        ed.setActiveLayer(kids[0])
        XCTAssertEqual(visibleNames(ed, folder), ["通常"])
        XCTAssertEqual(ed.activeLayerID, kids[0])
        XCTAssertTrue(ed.canPaintOnActiveLayer)
    }

    func testNewLayerInsideSwitchBecomesTheShownOne() {
        let (ed, folder, kids) = editor()
        ed.setSwitch(folder, true)
        ed.setActiveLayer(kids[0])
        ed.addLayer(name: "泣き")
        XCTAssertEqual(visibleNames(ed, folder), ["泣き"])
    }

    func testSidecarRoundTrip() throws {
        let (ed, folder, kids) = editor()
        ed.setActiveLayer(kids[1])
        ed.setSwitch(folder, true)
        ed.prepareForSave()
        XCTAssertEqual(ed.sidecar.switchFolders, [ed.doc.node(folder)!.psdID])
        XCTAssertFalse(ed.sidecar.isEmpty)

        let data = try PSD.write(ed.doc)
        let sidecar = try JSONDecoder().decode(Sidecar.self, from: JSONEncoder().encode(ed.sidecar))
        // PSD だけ読むとふつうのフォルダー（今の表情だけ表示）
        let plain = try PSD.read(data)
        var plainFolder: LayerNode?
        plain.forEachNode { if $0.name == "表情" { plainFolder = $0 } }
        XCTAssertFalse(plainFolder!.isSwitch)
        XCTAssertEqual(plainFolder!.children.filter(\.visible).map(\.name), ["笑顔"])
        // サイドカーと一緒に開くとスイッチに戻る
        let ed2 = Editor(width: 1, height: 1)
        ed2.load(plain, url: nil, sidecar: sidecar)
        var f2: LayerNode?
        ed2.doc.forEachNode { if $0.name == "表情" { f2 = $0 } }
        XCTAssertTrue(f2!.isSwitch)
        XCTAssertEqual(f2!.children.filter(\.visible).map(\.name), ["笑顔"])
    }
}

extension SwitchFolderTests {
    func testAgentSwitch() throws {
        let (ed, folder, kids) = editor()
        let tb = AgentToolbox(editor: ed)
        _ = try tb.call("update_layer", ["layer_id": folder.uuidString, "switch": true])
        XCTAssertTrue(ed.doc.node(folder)!.isSwitch)
        _ = try tb.call("update_layer", ["layer_id": kids[0].uuidString, "visible": true])
        XCTAssertEqual(visibleNames(ed, folder), ["通常"])
        XCTAssertThrowsError(try tb.call("update_layer", ["layer_id": kids[0].uuidString, "visible": false]))
        XCTAssertThrowsError(try tb.call("update_layer", ["layer_id": kids[1].uuidString, "switch": true]))
        let info = try JSONSerialization.jsonObject(with: Data(tb.json(tb.documentInfo()).utf8)) as! [String: Any]
        let top = (info["layers"] as! [[String: Any]]).first { $0["name"] as? String == "表情" }!
        XCTAssertEqual(top["switch"] as? Bool, true)
    }
}
