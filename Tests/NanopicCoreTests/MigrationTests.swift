import XCTest
@testable import NanopicCore

final class MigrationTests: XCTestCase {
    func testLegacyDefaultsAreCopiedOnce() {
        let old = "test.nanopic.old." + UUID().uuidString, new = "test.nanopic.new." + UUID().uuidString
        let d = UserDefaults.standard
        defer { d.removePersistentDomain(forName: old); d.removePersistentDomain(forName: new) }
        d.setPersistentDomain(["palette.v1": ["#FF0000"], "experimental.rig": true, "grid.v1": Data([1])], forName: old)
        d.setPersistentDomain(["experimental.rig": false], forName: new)

        XCTAssertEqual(LegacyDefaults.migrate(from: old, to: new, defaults: d), 2)
        let got = d.persistentDomain(forName: new) ?? [:]
        XCTAssertEqual(got["palette.v1"] as? [String], ["#FF0000"])
        XCTAssertEqual(got["grid.v1"] as? Data, Data([1]))
        XCTAssertEqual(got["experimental.rig"] as? Bool, false, "新しい側にもうある項目は上書きしない")
        XCTAssertNotNil(d.persistentDomain(forName: old), "古い側は消さない")

        // 2 回目は何もしない（新しい側で消した項目が戻らない）
        var edited = got
        edited["palette.v1"] = nil
        d.setPersistentDomain(edited, forName: new)
        XCTAssertEqual(LegacyDefaults.migrate(from: old, to: new, defaults: d), 0)
        XCTAssertNil(d.persistentDomain(forName: new)?["palette.v1"])
    }

    func testMigrationWithoutLegacyDomain() {
        let new = "test.nanopic.new." + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: new) }
        XCTAssertEqual(LegacyDefaults.migrate(from: "test.nanopic.none." + UUID().uuidString, to: new), 0)
    }

    #if os(macOS)
    func testBookmarksRememberWritablePlaces() throws {
        let suite = "test.nanopic.bookmarks." + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("作品.png")
        let store = ScopedBookmarks(defaults: d, securityScoped: false)

        XCTAssertNil(store.access(file), "覚えていない場所")
        XCTAssertThrowsError(try store.save(file), "まだないファイルは覚えられない")
        try Data([1]).write(to: file)
        try store.save(file)
        let a = try XCTUnwrap(store.access(file))
        XCTAssertEqual(a.url.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
        a.stop()
        // 上書き（置き換え）しても同じ場所として解ける
        try Data([2]).write(to: file, options: .atomic)
        XCTAssertNotNil(store.access(file))
        // 別の場所へ動かしたら、追いかけない
        try FileManager.default.moveItem(at: file, to: dir.appendingPathComponent("別.png"))
        XCTAssertNil(store.access(file))
    }
    #endif
}

final class AppFoldersTests: XCTestCase {
    func testContains() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let docs = base.appendingPathComponent("Documents"), cloud = base.appendingPathComponent("Mobile Documents/iCloud~x/Documents")
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let folders = AppFolders(roots: [docs, cloud])
        XCTAssertTrue(folders.contains(docs.appendingPathComponent("作品.psd")))
        XCTAssertTrue(folders.contains(docs.appendingPathComponent("sub/作品.psd")))
        XCTAssertTrue(folders.contains(cloud.appendingPathComponent("作品.psd")), "まだないフォルダーでも場所で決まる")
        XCTAssertFalse(folders.contains(base.appendingPathComponent("Documents2/作品.psd")), "名前の前が同じだけの別のフォルダー")
        XCTAssertFalse(folders.contains(base.appendingPathComponent("作品.psd")))
        // /var と /private/var の違いは同じ場所として扱う
        let alt = URL(fileURLWithPath: docs.path.replacingOccurrences(of: "/private/var/", with: "/var/"))
        XCTAssertTrue(folders.contains(alt.appendingPathComponent("作品.psd")))
        XCTAssertFalse(AppFolders(roots: []).contains(docs))
    }

    func testCoordinatedReadWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.bin")
        XCTAssertThrowsError(try CoordinatedFile.read(url))
        try CoordinatedFile.write(Data([1, 2, 3]), to: url)
        try CoordinatedFile.write(Data([4]), to: url)
        XCTAssertEqual(try CoordinatedFile.read(url), Data([4]))
    }
}
