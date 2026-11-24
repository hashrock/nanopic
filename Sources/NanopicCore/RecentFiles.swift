import Foundation

/// 最近開いたファイルの一覧（Mac 版・iPad 版の共通）。
///
/// その端末の中だけに持つ（UserDefaults。iCloud の設定の同期 `PreferenceSync.keys` には入れない）。
/// 開き直せるよう、パスと一緒に bookmark を持つ。App Sandbox の中（Mac App Store 版）と iPad では、
/// アプリの外のファイルはパスだけでは開けないため（Mac は security-scoped bookmark、iPad はふつうの bookmark が
/// アクセス権を持つ）。bookmark はファイルが動いても追えるので、解いたら新しい場所を覚え直す。
public struct RecentFiles {
    /// 覚えておく数（古いものから捨てる）
    public static let capacity = 10
    public static let defaultsKey = "recentFiles.v1"

    public struct Item: Codable, Equatable, Identifiable, Sendable {
        /// 開いたときの場所（同じファイルかどうかの比較と、表示に使う）
        public var path: String
        var bookmark: Data?
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
        /// 入っているフォルダーの名前（同じ名前のファイルを見分けるため）
        public var folderName: String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
    }

    private let defaults: BookmarkStorage
    private let key: String
    private let securityScoped: Bool

    /// securityScoped を false にすると、ふつうの bookmark を使う（iPad とテスト）
    public init(defaults: BookmarkStorage = UserDefaults.standard, key: String = RecentFiles.defaultsKey, securityScoped: Bool = RecentFiles.platformSecurityScoped) {
        self.defaults = defaults
        self.key = key
        self.securityScoped = securityScoped
    }

    /// Mac は security-scoped bookmark（Sandbox の外でも作れる）。iOS には無く、ふつうの bookmark がアクセス権を持つ
    public static var platformSecurityScoped: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private var creationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        securityScoped ? [.withSecurityScope] : []
        #else
        []
        #endif
    }

    private var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        securityScoped ? [.withSecurityScope, .withoutUI, .withoutMounting] : [.withoutUI, .withoutMounting]
        #else
        [.withoutUI, .withoutMounting]
        #endif
    }

    public static func normalized(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    /// 新しいものから順
    public var items: [Item] {
        guard let d = defaults.data(forKey: key) else { return [] }
        return (try? PropertyListDecoder().decode([Item].self, from: d)) ?? []
    }

    private func store(_ items: [Item]) {
        defaults.set(try? PropertyListEncoder().encode(Array(items.prefix(Self.capacity))), forKey: key)
    }

    /// 開いた・保存したファイルを先頭に足す。読めるうちに呼ぶ（bookmark を作るのにアクセス権が要る）。
    /// bookmark を作れなくても、パスだけで覚える（Sandbox の外の Mac なら開ける）
    public func add(_ url: URL) {
        guard url.isFileURL else { return }
        let path = Self.normalized(url)
        let bookmark = try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        store([Item(path: path, bookmark: bookmark)] + items.filter { $0.path != path })
    }

    public func remove(_ item: Item) {
        store(items.filter { $0.path != item.path })
    }

    /// 履歴をクリア
    public func clear() {
        defaults.set(nil, forKey: key)
    }

    /// 開ける場所を返す（ファイルが消えた・解けないときは nil）。動いていたら新しい場所を覚え直す。
    /// 返す URL は security-scoped のことがあるので、読む側で startAccessingSecurityScopedResource を呼ぶ
    public func resolve(_ item: Item) -> URL? {
        if let bookmark = item.bookmark {
            var stale = false
            // 一覧を出すたびに解くので、ネットワークの場所をつなぎに行ったり、ダイアログを出したりしない
            if let url = try? URL(resolvingBookmarkData: bookmark, options: resolutionOptions,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let path = Self.normalized(url)
                if path != item.path || stale {
                    // 動いた（名前が変わった）。一覧の同じ位置で覚え直す
                    var list = items
                    if let i = list.firstIndex(where: { $0.path == item.path }) {
                        let renewed = (try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? bookmark
                        list[i] = Item(path: path, bookmark: renewed)
                        list = list.enumerated().filter { $0.offset == i || $0.element.path != path }.map(\.element)
                        store(list)
                    }
                }
                // ゴミ箱に入れたファイルも bookmark は解けるので、ゴミ箱の中なら開けないものとして扱う
                return path.contains("/.Trash/") ? nil : url
            }
        }
        return FileManager.default.fileExists(atPath: item.path) ? URL(fileURLWithPath: item.path) : nil
    }

    /// 一覧の 1 行
    public struct Entry: Identifiable, Equatable, Sendable {
        public let item: Item
        /// 開ける（ファイルが消えていない）
        public let isAvailable: Bool
        public var id: String { item.id }
    }

    /// 一覧と、それぞれ開けるか。bookmark を解くと動いたファイルの新しい場所を覚え直すので、解いたあとの一覧を返す
    public func entries() -> [Entry] {
        var available: [String: Bool] = [:]
        for item in items {
            let url = resolve(item)
            available[url.map(Self.normalized) ?? item.path] = url != nil
        }
        return items.map { Entry(item: $0, isAvailable: available[$0.path] ?? false) }
    }

    /// 一覧に出す名前。同じ名前のファイルがほかにもあれば、フォルダーの名前を添える
    public static func displayName(_ entry: Entry, in entries: [Entry]) -> String {
        let name = entry.item.name
        guard entries.contains(where: { $0.id != entry.id && $0.item.name == name }) else { return name }
        return name + " — " + entry.item.folderName
    }
}
