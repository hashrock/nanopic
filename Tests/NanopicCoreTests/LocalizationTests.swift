import XCTest
@testable import NanopicCore

/// 表示言語（日本語・英語）。訳のカタログと、保存する名前の訳し方
final class LocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// カタログ（Resources/<表>.xcstrings）の英語の訳。複数形で分けてあるものは other を取る
    private func english(_ table: String) throws -> [String: String] {
        let url = Self.root.appendingPathComponent("Resources/\(table).xcstrings")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        var out: [String: String] = [:]
        for (key, entry) in strings {
            let en = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
            let unit = en?["stringUnit"] as? [String: Any]
            out[key] = unit?["value"] as? String
        }
        return out
    }

    /// 訳の抜け・取りこぼしの検査（scripts/check-localization.py）を走らせる
    func testCatalogMatchesSources() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "python3 がありません")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [Self.root.appendingPathComponent("scripts/check-localization.py").path, "--quiet"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\n" + output)
    }

    /// 訳の表が無いとき（テスト、swift run）は、日本語がそのまま出る
    func testSourceLanguageIsTheFallback() {
        XCTAssertEqual(L("描画"), "描画")
        XCTAssertEqual(L("取り消し: \("描画")"), "取り消し: 描画")
        XCTAssertEqual(L("不透明度: \(50)%"), "不透明度: 50%")
        XCTAssertEqual(LFormat("拡大率: %.1f%% × %.1f%%", 50.0, 25.0), "拡大率: 50.0% × 25.0%")
        XCTAssertEqual(LName("Gペン"), "Gペン")
        XCTAssertEqual(Tool.brush.displayName, "ブラシ")
    }

    /// 英語の訳だけを入れた仮のバンドル（en.lproj）を作り、そのあいだだけ訳を引く先にする
    private func withEnglish(_ body: () throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nanopic-l10n-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lproj = dir.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        for table in ["Localizable", "Names"] {
            let data = try PropertyListSerialization.data(fromPropertyList: try english(table), format: .xml, options: 0)
            try data.write(to: lproj.appendingPathComponent("\(table).strings"))
        }
        let saved = Localization.bundle
        Localization.bundle = try XCTUnwrap(Bundle(url: dir))
        defer { Localization.bundle = saved }
        try body()
    }

    /// 書類に入る既定の名前は、作ったときの表示言語で決める（日本語）
    func testDefaultNamesInJapanese() {
        let ed = Editor(width: 16, height: 16)
        XCTAssertEqual(ed.doc.layers.map(\.name), ["用紙", "レイヤー 1"])
        ed.addLayer()
        XCTAssertEqual(ed.doc.activeLayer?.name, "レイヤー 2")
        ed.duplicateActiveLayer()
        XCTAssertEqual(ed.doc.activeLayer?.name, "レイヤー 2 のコピー")
        ed.addFolder()
        XCTAssertEqual(ed.doc.activeLayer?.name, "フォルダー 1")
        let id = ed.doc.layers[1].id
        let deformer = ed.addDeformer(to: id, kind: .warp)
        XCTAssertEqual(ed.rig.deformers.first { $0.id == deformer }?.name, "レイヤー 1のワープ")
    }

    /// 英語の画面で作れば英語の名前になり、日本語の環境で読み直しても変わらない
    func testDefaultNamesInEnglishSurviveReopeningInJapanese() throws {
        var psd = Data()
        var sidecar = Data()
        try withEnglish {
            XCTAssertEqual(L("描画"), "Brush Stroke")
            let ed = Editor(width: 16, height: 16)
            XCTAssertEqual(ed.doc.layers.map(\.name), ["Paper", "Layer 1"])
            ed.addLayer()
            XCTAssertEqual(ed.doc.activeLayer?.name, "Layer 2")
            ed.addLayer()
            ed.duplicateActiveLayer()
            XCTAssertEqual(ed.doc.activeLayer?.name, "Layer 3 copy")
            ed.addFolder()
            XCTAssertEqual(ed.doc.activeLayer?.name, "Folder 1")
            ed.addCel()
            let layer1 = try XCTUnwrap(ed.doc.layers.first { $0.name == "Layer 1" })
            _ = ed.addDeformer(to: layer1.id, kind: .rotation)
            _ = ed.addDeformer(to: layer1.id, kind: .warp)
            // おまかせで動かすのデフォーマ名（レイヤー名 + 動きの名前）
            XCTAssertEqual(L("\(layer1.name)の\(MotionPreset.breathe.displayName)"), "Layer 1 Breathe")
            XCTAssertEqual(ed.rig.deformers.map(\.name), ["Layer 1 Move/Rotate", "Layer 1 Warp"])
            psd = try PSD.write(ed.doc)
            var sc = Sidecar()
            sc.rig = ed.doc.rig
            sidecar = try JSONEncoder().encode(sc)
        }
        // ここからは日本語（訳の表なし）
        XCTAssertEqual(L("描画"), "描画")
        let doc = try PSD.read(psd)
        let rig = try XCTUnwrap(JSONDecoder().decode(Sidecar.self, from: sidecar).rig)
        var names: [String] = []
        doc.forEachNode { names.append($0.name) }
        XCTAssertTrue(names.contains("Paper") && names.contains("Layer 1") && names.contains("Layer 3 copy") && names.contains("Folder 1"), "\(names)")
        XCTAssertNil(names.first { hasJapanese($0) }, "\(names)")
        XCTAssertEqual(rig.deformers.map(\.name), ["Layer 1 Move/Rotate", "Layer 1 Warp"])
        // 日本語の画面で足したものは日本語の名前になる。英語の名前の番号とは別に数える
        let ed = Editor(width: 16, height: 16)
        ed.doc = doc
        ed.addLayer()
        XCTAssertEqual(ed.doc.activeLayer?.name, "レイヤー 1")
    }

    private func hasJapanese(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) || (0x4e00...0x9fff).contains($0.value) }
    }

    /// 設定に入る既定の名前（ブラシ・ブラシ先端）は日本語で保存し、英語の画面では訳して出す。自分で付けた名前はそのまま
    func testBrushNamesAreTranslatedForDisplay() throws {
        let names = try english("Names")
        let en = NameLocalizer { names[$0] }
        XCTAssertEqual(BrushSettings.defaultPresets.first?.name, "Gペン")
        XCTAssertEqual(en.localized("Gペン"), "G-Pen")
        XCTAssertEqual(en.localized("Gペン コピー"), "G-Pen copy")
        XCTAssertEqual(en.localized("Gペン コピー コピー"), "G-Pen copy copy")
        XCTAssertEqual(en.localized("線画用"), "線画用")
        XCTAssertEqual(en.localized(""), "")
        for name in (BrushSettings.defaultPresets + BrushSettings.defaultErasers).map(\.name) + BrushTip.builtins().map(\.name) {
            XCTAssertFalse(hasJapanese(en.localized(name)), "「\(name)」の訳が Names の表にありません")
        }
        // レイヤーの名前は訳さない（書類に入っている名前をそのまま出す）
        XCTAssertEqual(en.localized("レイヤー 1"), "レイヤー 1")
        XCTAssertEqual(en.localized("用紙"), "用紙")
    }

    /// 訳して出したブラシ名をそのまま確定しても、保存してある名前は変えない
    func testEditingALocalizedNameKeepsTheStoredName() {
        XCTAssertEqual(LNameEdited(LName("Gペン"), original: "Gペン"), "Gペン")
        XCTAssertEqual(LNameEdited("線画用", original: "Gペン"), "線画用")
    }
}
