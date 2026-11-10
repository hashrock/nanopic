#if os(macOS)
import Foundation

/// ユーザーが保存パネルで選んだ場所を、次の起動でも書けるように覚えておく（security-scoped bookmark）。
///
/// App Sandbox の中では、パスの文字列だけ持っていても書けない。保存パネルで選んでもらったファイルの bookmark を
/// アプリの設定（UserDefaults）に持ち、次からはそれを解いて書く（entitlement は files.bookmarks.app-scope）。
/// bookmark は実在するファイルにしか作れないので、初回は書いたあとで覚える。
/// Sandbox の外では要らない（パスの文字列だけで書ける）。
/// bookmark の置き場。本物は UserDefaults。テストでは実際の設定に触らないよう、メモリー上の入れ物を渡す
public protocol BookmarkStorage {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: BookmarkStorage {}

public struct ScopedBookmarks {
    /// App Sandbox の中で動いているか
    public static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    /// 覚えておく数（古いものから捨てる）
    public static let capacity = 200

    private struct Entry: Codable {
        var path: String
        var bookmark: Data
    }

    private let defaults: BookmarkStorage
    private let key: String
    private let securityScoped: Bool

    /// securityScoped を false にすると、ふつうの bookmark を使う（テスト用）
    public init(defaults: BookmarkStorage = UserDefaults.standard, key: String = "publish.bookmarks.v1", securityScoped: Bool = true) {
        self.defaults = defaults
        self.key = key
        self.securityScoped = securityScoped
    }

    /// 解いた bookmark。使い終わったら stop() を呼ぶ
    public final class Access {
        public let url: URL
        private var scoped: Bool

        init(url: URL, scoped: Bool) {
            self.url = url
            self.scoped = scoped
        }

        public func stop() {
            if scoped { url.stopAccessingSecurityScopedResource() }
            scoped = false
        }

        deinit { stop() }
    }

    private static func normalized(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    private func load() -> [Entry] {
        guard let d = defaults.data(forKey: key) else { return [] }
        return (try? PropertyListDecoder().decode([Entry].self, from: d)) ?? []
    }

    private func store(_ entries: [Entry]) {
        defaults.set(try? PropertyListEncoder().encode(Array(entries.suffix(Self.capacity))), forKey: key)
    }

    /// いま読み書きできるファイルを覚える（ファイルがなければ失敗する）
    public func save(_ url: URL) throws {
        let data = try url.bookmarkData(options: securityScoped ? [.withSecurityScope] : [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let path = Self.normalized(url)
        store(load().filter { $0.path != path } + [Entry(path: path, bookmark: data)])
    }

    public func remove(_ url: URL) {
        let path = Self.normalized(url)
        store(load().filter { $0.path != path })
    }

    /// 覚えている場所なら、書けるようにして返す。覚えていない・解けない・ファイルが別の場所に動いていたら nil
    public func access(_ url: URL) -> Access? {
        let path = Self.normalized(url)
        guard let entry = load().last(where: { $0.path == path }) else { return nil }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: entry.bookmark, options: securityScoped ? [.withSecurityScope] : [],
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
              Self.normalized(resolved) == path else {
            remove(url)
            return nil
        }
        let started = securityScoped && resolved.startAccessingSecurityScopedResource()
        let access = Access(url: resolved, scoped: started)
        if stale { try? save(resolved) }
        return access
    }
}
#endif
