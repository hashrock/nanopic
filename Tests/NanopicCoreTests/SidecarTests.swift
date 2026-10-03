import XCTest
@testable import NanopicCore

final class SidecarTests: XCTestCase {
    func names(_ doc: DocumentState) -> [String: UInt32] {
        var out: [String: UInt32] = [:]
        doc.forEachNode { out[$0.name] = $0.psdID }
        return out
    }

    /// 保存すると全レイヤー（フォルダー含む）に ID が入り、開き直しても変わらない
    func testPSDLayerIDsSurviveRoundTrip() throws {
        let ed = Editor(width: 64, height: 64)
        ed.addFolder(name: "顔")
        ed.addLayer(name: "目")
        ed.assignPSDIDs()
        let before = names(ed.doc)
        XCTAssertEqual(Set(before.keys), ["用紙", "レイヤー 1", "顔", "目"])
        XCTAssertFalse(before.values.contains(0))
        XCTAssertEqual(Set(before.values).count, before.count, "ID は重ならない")

        let back = try PSD.read(PSD.write(ed.doc))
        XCTAssertEqual(names(back), before)
        XCTAssertEqual(back.node(psdID: before["目"]!)?.name, "目")
    }

    /// 複製で重なった ID は、あとから足したほう（上）に新しく振る
    func testDuplicatedLayerGetsNewID() {
        let ed = Editor(width: 32, height: 32)
        ed.assignPSDIDs()
        let original = ed.doc.activeLayer!.psdID
        ed.duplicateActiveLayer()
        XCTAssertEqual(ed.doc.activeLayer!.psdID, original, "複製直後は同じ ID を持っている")
        ed.assignPSDIDs()
        XCTAssertEqual(ed.doc.node(psdID: original)?.name, "レイヤー 1")
        XCTAssertNotEqual(ed.doc.activeLayer!.psdID, original)
    }

    /// PSD.write は呼び出し側が振っていなくても ID を入れる
    func testWriteAssignsIDsEvenIfCallerDidNot() throws {
        let ed = Editor(width: 32, height: 32)
        let back = try PSD.read(PSD.write(ed.doc))
        var ids: [UInt32] = []
        back.forEachNode { ids.append($0.psdID) }
        XCTAssertFalse(ids.contains(0))
    }

    func testSidecarFileNameAndLifecycle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let psd = dir.appendingPathComponent("作品.psd")
        XCTAssertEqual(Sidecar.url(for: psd).lastPathComponent, "作品.nanopic.json")
        XCTAssertNil(try Sidecar.read(for: psd))

        // 持つものがなければ作らず、古いファイルが残っていれば消す
        try Data("{}".utf8).write(to: Sidecar.url(for: psd))
        try Sidecar().write(for: psd)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Sidecar.url(for: psd).path))
    }

    func testDecodeToleratesUnknownAndMissingFields() throws {
        let s = try JSONDecoder().decode(Sidecar.self, from: Data(#"{"future": [1, 2]}"#.utf8))
        XCTAssertEqual(s.version, Sidecar.currentVersion)
    }
}
