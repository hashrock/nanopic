import Foundation

/// アプリ自身のフォルダー（iPad 版の書類フォルダーと iCloud container）。
///
/// iPadOS には Mac の「関連ファイル」の仕組みがなく、ファイル App で選んだ書類の隣のファイルには手を出せない。
/// サイドカー（作品.nanopic）を読み書きできるのは、アプリ自身のフォルダーの中だけ。
/// 外の場所の書類は素の PSD として扱い、サイドカーに頼る機能（スイッチフォルダー・タイムライン・リグ・書き出し設定）を止める。
public struct AppFolders: Sendable {
    public var roots: [URL]

    public init(roots: [URL]) {
        self.roots = roots
    }

    /// url がアプリのフォルダーの中（下の階層も含む）にあるか
    public func contains(_ url: URL) -> Bool {
        let path = Self.normalized(url)
        return roots.contains { root in
            let r = Self.normalized(root)
            return path.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
    }

    /// /var と /private/var のような見かけの違いをそろえる
    private static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// NSFileCoordinator を通した読み書き。iCloud Drive やほかのアプリのフォルダー（ファイルプロバイダー）の書類は、
/// 同期や別のアプリの読み書きとぶつからないよう、これを通す（まだ落ちてきていない iCloud の書類は、読むときに落ちてくるのを待つ）
public enum CoordinatedFile {
    public static func read(_ url: URL) throws -> Data {
        try coordinate(url, write: nil) { try Data(contentsOf: $0) }
    }

    public static func write(_ data: Data, to url: URL) throws {
        try coordinate(url, write: .forReplacing) { try data.write(to: $0, options: .atomic) }
    }

    /// write が nil なら読み込み
    static func coordinate<T>(_ url: URL, write: NSFileCoordinator.WritingOptions?, presenter: NSFilePresenter? = nil,
                              _ body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        if let write {
            coordinator.coordinate(writingItemAt: url, options: write, error: &coordinationError) { u in
                result = Result { try body(u) }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { u in
                result = Result { try body(u) }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
