import XCTest
@testable import NanopicCore

private final class MemoryStorage: BookmarkStorage {
    var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

final class RecentFilesTests: XCTestCase {
    private var dir: URL!
    private var storage: MemoryStorage!
    private var recent: RecentFiles!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecentFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storage = MemoryStorage()
        recent = RecentFiles(defaults: storage, securityScoped: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testNewestFirstWithoutDuplicates() throws {
        let a = try file("a.psd"), b = try file("b.png")
        recent.add(a)
        recent.add(b)
        recent.add(a)
        XCTAssertEqual(recent.items.map(\.name), ["a.psd", "b.png"])
    }

    func testCapacity() throws {
        for i in 0..<(RecentFiles.capacity + 3) { recent.add(try file("\(i).psd")) }
        XCTAssertEqual(recent.items.count, RecentFiles.capacity)
        XCTAssertEqual(recent.items.first?.name, "\(RecentFiles.capacity + 2).psd")
    }

    func testClear() throws {
        recent.add(try file("a.psd"))
        recent.clear()
        XCTAssertTrue(recent.items.isEmpty)
    }

    func testRemovedFileCannotBeResolved() throws {
        let a = try file("a.psd")
        recent.add(a)
        try FileManager.default.removeItem(at: a)
        XCTAssertNil(recent.resolve(recent.items[0]))
    }

    func testMovedFileIsFollowed() throws {
        let a = try file("a.psd")
        recent.add(a)
        let moved = dir.appendingPathComponent("renamed.psd")
        try FileManager.default.moveItem(at: a, to: moved)
        let url = try XCTUnwrap(recent.resolve(recent.items[0]))
        XCTAssertEqual(RecentFiles.normalized(url), RecentFiles.normalized(moved))
        XCTAssertEqual(recent.items.map(\.name), ["renamed.psd"])
    }

    func testStoredLocallyOnly() {
        // iCloud で同期する設定のキー（NanopicUI の PreferenceSync.keys）とは別のキー
        XCTAssertFalse(["brushes.v1", "erasers.v1", "palette.v1"].contains(RecentFiles.defaultsKey))
    }

    func testEntriesMarkMissingFilesAndDisambiguateNames() throws {
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let a = try file("a.psd"), b = try file("b.psd")
        let a2 = sub.appendingPathComponent("a.psd")
        try Data("x".utf8).write(to: a2)
        recent.add(a); recent.add(b); recent.add(a2)
        try FileManager.default.removeItem(at: b)
        let e = recent.entries()
        XCTAssertEqual(e.map(\.isAvailable), [true, false, true])
        XCTAssertEqual(RecentFiles.displayName(e[0], in: e), "a.psd — sub")
        XCTAssertEqual(RecentFiles.displayName(e[1], in: e), "b.psd")
    }
}
