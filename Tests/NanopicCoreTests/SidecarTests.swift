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

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func sidecar(switchFolders: [UInt32]) -> Sidecar {
        var s = Sidecar()
        s.switchFolders = switchFolders
        return s
    }

    /// 名前は「書類と同じ名前 + 拡張子 1 段」（Sandbox の関連ファイルにできる形）
    func testSidecarFileNameAndLifecycle() throws {
        let psd = try tempDir().appendingPathComponent("作品.psd")
        XCTAssertEqual(Sidecar.url(for: psd).lastPathComponent, "作品.nanopic")
        XCTAssertEqual(Sidecar.legacyURL(for: psd).lastPathComponent, "作品.nanopic.json")
        XCTAssertEqual(Sidecar.url(for: psd).deletingPathExtension().lastPathComponent, psd.deletingPathExtension().lastPathComponent)
        XCTAssertNil(try Sidecar.read(for: psd))

        // 書いて読み戻す
        try sidecar(switchFolders: [3, 5]).write(for: psd)
        XCTAssertTrue(exists(Sidecar.url(for: psd)))
        XCTAssertFalse(exists(Sidecar.legacyURL(for: psd)), "古い名前には書かない")
        XCTAssertEqual(try Sidecar.read(for: psd)?.switchFolders, [3, 5])

        // 上書き
        try sidecar(switchFolders: [7]).write(for: psd)
        XCTAssertEqual(try Sidecar.read(for: psd)?.switchFolders, [7])

        // 持つものがなくなったら消す。もう無いときに空を書いても何も起きない
        try Sidecar().write(for: psd)
        XCTAssertFalse(exists(Sidecar.url(for: psd)))
        try Sidecar().write(for: psd)
        XCTAssertFalse(exists(Sidecar.url(for: psd)))
    }

    /// 古い名前（作品.nanopic.json）は読める。保存は新しい名前にだけ書き、古いファイルは消さない・変えない
    func testLegacyNameIsReadButNeverWritten() throws {
        let psd = try tempDir().appendingPathComponent("作品.psd")
        let old = try JSONEncoder().encode(sidecar(switchFolders: [1]))
        try old.write(to: Sidecar.legacyURL(for: psd))
        XCTAssertEqual(try Sidecar.read(for: psd)?.switchFolders, [1])

        try sidecar(switchFolders: [1, 2]).write(for: psd)
        XCTAssertEqual(try Data(contentsOf: Sidecar.legacyURL(for: psd)), old, "古いファイルはそのまま")
        XCTAssertEqual(try Sidecar.read(for: psd)?.switchFolders, [1, 2], "新しい名前があればそちらを使う")
    }

    /// 古いファイルが残っているときは、空になっても新しい名前に書く（消すと、次に開いたとき古い中身が戻ってしまう）
    func testEmptySidecarShadowsLegacyFile() throws {
        let psd = try tempDir().appendingPathComponent("作品.psd")
        try JSONEncoder().encode(sidecar(switchFolders: [1])).write(to: Sidecar.legacyURL(for: psd))
        try Sidecar().write(for: psd)
        XCTAssertTrue(exists(Sidecar.url(for: psd)))
        XCTAssertTrue(exists(Sidecar.legacyURL(for: psd)))
        XCTAssertEqual(try Sidecar.read(for: psd)?.isEmpty, true)
    }

    /// 新しい名前のファイルが壊れていたら、読み込みは失敗する（古い名前へは逃げない。呼び出し側は素の PSD として開く）
    func testBrokenSidecarThrows() throws {
        let psd = try tempDir().appendingPathComponent("作品.psd")
        try Data("こわれた".utf8).write(to: Sidecar.url(for: psd))
        try JSONEncoder().encode(sidecar(switchFolders: [1])).write(to: Sidecar.legacyURL(for: psd))
        XCTAssertThrowsError(try Sidecar.read(for: psd))
    }

    /// 関連ファイルの読み書き（NSFileCoordinator 経由）
    func testRelatedFile() throws {
        let psd = try tempDir().appendingPathComponent("作品.psd")
        let url = Sidecar.url(for: psd)
        XCTAssertNil(try RelatedFile.read(url, primary: psd))
        try RelatedFile.remove(url, primary: psd)
        try RelatedFile.write(Data("a".utf8), to: url, primary: psd)
        try RelatedFile.write(Data("bc".utf8), to: url, primary: psd)
        XCTAssertEqual(try RelatedFile.read(url, primary: psd), Data("bc".utf8))
        try RelatedFile.remove(url, primary: psd)
        XCTAssertNil(try RelatedFile.read(url, primary: psd))
    }

    /// 読み書きを続けても待たされない（プレゼンターを使い回す。毎回登録し直すと、書いた直後の読み込みが約 0.5 秒かかる）
    func testRepeatedReadWriteIsFast() throws {
        let psd = try tempDir().appendingPathComponent("作品.psd")
        let start = Date()
        for i in 0..<10 {
            try sidecar(switchFolders: [UInt32(i)]).write(for: psd)
            XCTAssertEqual(try Sidecar.read(for: psd)?.switchFolders, [UInt32(i)])
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "10 往復。毎回登録し直すと 5 秒以上かかる")
    }

    /// 別の書類に移っても読み書きできる（プレゼンターを登録し直す）
    func testSwitchingDocuments() throws {
        let dir = try tempDir()
        let a = dir.appendingPathComponent("a.psd"), b = dir.appendingPathComponent("b.psd")
        try sidecar(switchFolders: [1]).write(for: a)
        try sidecar(switchFolders: [2]).write(for: b)
        XCTAssertEqual(try Sidecar.read(for: a)?.switchFolders, [1])
        XCTAssertEqual(try Sidecar.read(for: b)?.switchFolders, [2])
    }

    /// PSD とサイドカーを保存して開き直すと、スイッチフォルダーとタイムラインが戻る
    func testSaveAndReopenWithSidecar() throws {
        let psd = try tempDir().appendingPathComponent("作品.psd")
        let ed = Editor(width: 32, height: 32)
        ed.addFolder(name: "表情")
        let folder = ed.doc.activeLayerID!
        ed.setSwitch(folder, true)
        ed.prepareForSave()
        try PSD.write(ed.doc).write(to: psd)
        try ed.sidecar.write(for: psd)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: psd.deletingLastPathComponent().path).sorted(),
                       ["作品.nanopic", "作品.psd"])

        let ed2 = Editor(width: 1, height: 1)
        ed2.load(try PSD.read(Data(contentsOf: psd)), url: psd, sidecar: try XCTUnwrap(Sidecar.read(for: psd)))
        var reopened: LayerNode?
        ed2.doc.forEachNode { if $0.name == "表情" { reopened = $0 } }
        XCTAssertEqual(reopened?.isSwitch, true)
    }

    func testDecodeToleratesUnknownAndMissingFields() throws {
        let s = try JSONDecoder().decode(Sidecar.self, from: Data(#"{"future": [1, 2]}"#.utf8))
        XCTAssertEqual(s.version, Sidecar.currentVersion)
    }
}
