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

    /// 書いたあと、ファイルの大きさが書いたものと合っているかを確かめる（合わなければ失敗として投げる）。
    /// ネットワークドライブ（SMB など）のように、隣に一時ファイルを作れず、まとめて置き換える書き方（atomic）が通らない場所では、
    /// 今あるファイルに直接上書きし直す
    public static func write(_ data: Data, to url: URL) throws {
        try coordinate(url, write: .forReplacing) { u in
            do {
                try data.write(to: u, options: .atomic)
            } catch let atomicError {
                guard FileManager.default.fileExists(atPath: u.path) else { throw atomicError }
                do {
                    try data.write(to: u)
                } catch {
                    // 直接の上書きも通らなければ、両方の失敗を伝える
                    throw WriteError.failed(atomic: atomicError, direct: error)
                }
            }
            try verifySize(u, expected: data.count)
        }
    }

    static func verifySize(_ url: URL, expected: Int) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        if size != expected { throw WriteError.sizeMismatch(expected: expected, actual: size) }
    }

    public enum WriteError: LocalizedError {
        /// まとめて置き換える書き方も、直接の上書きも通らなかった
        case failed(atomic: Error, direct: Error)
        /// 書いたあとのファイルの大きさが、書いたものと合わない
        case sizeMismatch(expected: Int, actual: Int)

        public var errorDescription: String? {
            switch self {
            case let .failed(atomic, direct):
                return CoordinatedFile.describe(atomic) + " / " + CoordinatedFile.describe(direct)
            case let .sizeMismatch(expected, actual):
                return L("書いたファイルの大きさが合いません（\(expected) バイト書いて、\(actual) バイト）")
            }
        }
    }

    /// エラーの説明に、元の原因（下にあるエラー）とドメイン・コードを足す。ネットワークドライブの失敗の見分けに使う
    public static func describe(_ error: Error) -> String {
        if let e = error as? WriteError { return e.errorDescription ?? "\(e)" }
        let ns = error as NSError
        var parts = [ns.localizedDescription]
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append(u.localizedDescription + " (\(u.domain) \(u.code))") // l10n:skip
        }
        parts.append("(\(ns.domain) \(ns.code))") // l10n:skip
        return parts.joined(separator: " ")
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
