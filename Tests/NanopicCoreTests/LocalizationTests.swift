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
        XCTAssertEqual(LName("レイヤー 1"), "レイヤー 1")
        XCTAssertEqual(Tool.brush.displayName, "ブラシ")
    }

    /// 書類に入る既定の名前は、表示言語によらず日本語で保存する
    func testDefaultNamesAreStoredInSourceLanguage() {
        let ed = Editor(width: 16, height: 16)
        XCTAssertEqual(ed.doc.layers.map(\.name).sorted(), ["レイヤー 1", "用紙"])
        ed.addLayer()
        XCTAssertEqual(ed.doc.activeLayer?.name, "レイヤー 2")
        ed.duplicateActiveLayer()
        XCTAssertEqual(ed.doc.activeLayer?.name, "レイヤー 2 のコピー")
        ed.addFolder()
        XCTAssertEqual(ed.doc.activeLayer?.name, "フォルダー 1")
    }

    /// 既定の名前は、英語の画面では訳して出す。自分で付けた名前はそのまま
    func testStoredNamesAreTranslatedForDisplay() throws {
        let names = try english("Names")
        let en = NameLocalizer { names[$0] }
        XCTAssertEqual(en.localized("用紙"), "Paper")
        XCTAssertEqual(en.localized("レイヤー 12"), "Layer 12")
        XCTAssertEqual(en.localized("レイヤー 2 のコピー"), "Layer 2 copy")
        XCTAssertEqual(en.localized("フォルダー 1 のコピー のコピー"), "Folder 1 copy copy")
        XCTAssertEqual(en.localized("アニメーション 3"), "Animation 3")
        XCTAssertEqual(en.localized("パラメータ2"), "Parameter 2")
        XCTAssertEqual(en.localized("Gペン コピー"), "G-Pen copy")
        XCTAssertEqual(en.localized("レイヤー 1の呼吸"), "Layer 1 Breathe")
        XCTAssertEqual(en.localized("顔の左右の向き"), "顔 Horizontal Angle")
        XCTAssertEqual(en.localized("フォルダー 1の向き"), "Folder 1 Turn")
        XCTAssertEqual(en.localized("レイヤー 3の移動・回転"), "Layer 3 Move/Rotate")
        // 自分で付けた名前
        XCTAssertEqual(en.localized("線画"), "線画")
        XCTAssertEqual(en.localized("Layer 1"), "Layer 1")
        XCTAssertEqual(en.localized("レイヤー A"), "レイヤー A")
        XCTAssertEqual(en.localized(""), "")
    }

    /// アプリが作る既定の名前は、どれも Names の表に訳がある
    func testEveryDefaultNameHasATranslation() throws {
        let names = try english("Names")
        let en = NameLocalizer { names[$0] }
        var defaults = (BrushSettings.defaultPresets + BrushSettings.defaultErasers).map(\.name)
        defaults += BrushTip.builtins().map(\.name)
        defaults += MotionPreset.allCases.map(\.storedName)
        let ed = Editor(width: 16, height: 16)
        ed.addFolder()
        ed.addCel()
        ed.doc.forEachNode { defaults.append($0.name) }
        for pattern in NameLocalizer.patterns {
            XCTAssertNotNil(names[pattern], "Names の表に \(pattern) がありません")
            defaults.append(pattern.replacingOccurrences(of: "%lld", with: "7").replacingOccurrences(of: "%@", with: "用紙"))
        }
        func hasJapanese(_ s: String) -> Bool {
            s.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) || (0x4e00...0x9fff).contains($0.value) }
        }
        // セルの名前（「1」「2」…）のように日本語の入らない名前は、訳さずそのまま出す
        for name in defaults where hasJapanese(name) {
            let shown = en.localized(name)
            XCTAssertFalse(hasJapanese(shown), "「\(name)」の訳が Names の表にありません（\(shown)）")
        }
    }

    /// 訳して出した既定の名前をそのまま確定しても、保存してある名前は変えない
    func testEditingALocalizedNameKeepsTheStoredName() {
        XCTAssertEqual(LNameEdited(LName("レイヤー 1"), original: "レイヤー 1"), "レイヤー 1")
        XCTAssertEqual(LNameEdited("線画", original: "レイヤー 1"), "線画")
    }
}
