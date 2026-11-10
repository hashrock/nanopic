import XCTest
@testable import NanopicCore

/// 実際の UserDefaults（~/Library/Preferences）に触らないための、メモリー上の設定の置き場
private final class MemoryDefaults: DefaultsDomains, BookmarkStorage {
    var domains: [String: [String: Any]] = [:]
    var values: [String: Any] = [:]

    func persistentDomain(forName domainName: String) -> [String: Any]? { domains[domainName] }
    func setPersistentDomain(_ domain: [String: Any], forName domainName: String) { domains[domainName] = domain }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

final class MigrationTests: XCTestCase {
    func testLegacyDefaultsAreCopiedOnce() {
        let old = "old.example", new = "new.example"
        let d = MemoryDefaults()
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
        let d = MemoryDefaults()
        XCTAssertEqual(LegacyDefaults.migrate(from: "none.example", to: "new.example", defaults: d), 0)
        XCTAssertEqual(d.persistentDomain(forName: "new.example")?.count, 1, "済んだ印だけが付く")
    }

    #if os(macOS)
    func testBookmarksRememberWritablePlaces() throws {
        let d = MemoryDefaults()
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
