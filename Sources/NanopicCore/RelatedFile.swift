import Foundation

/// 開いている書類（primary）の隣にある、名前が同じで拡張子だけ違うファイルの読み書き。
///
/// App Sandbox の中では、ユーザーが選んだ書類そのものにしかアクセス権がない。隣のファイルは、
/// - Info.plist の CFBundleDocumentTypes で、その拡張子を NSIsRelatedItemType = true・CFBundleTypeRole = Editor の型として宣言し
///   （None や Viewer だと読めるだけで、書けない）、
/// - 毎回 NSFileCoordinator と、primaryPresentedItemURL に書類を持つ NSFilePresenter を通す
/// ときだけ読み書きできる（一度通したあとでも、直接の読み書きは拒否される）。
/// Sandbox の外でも同じコードで動く。iPadOS にはこの仕組みがないので、直接読み書きする。
public enum RelatedFile {
    /// 読む。ファイルがなければ nil
    public static func read(_ url: URL, primary: URL) throws -> Data? {
        try coordinate(url, primary: primary, write: nil) { u in
            do {
                return try Data(contentsOf: u)
            } catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile {
                return nil
            }
        }
    }

    public static func write(_ data: Data, to url: URL, primary: URL) throws {
        try coordinate(url, primary: primary, write: []) { u in
            try data.write(to: u, options: .atomic)
        }
    }

    /// 消す。ファイルがなければ何もしない
    public static func remove(_ url: URL, primary: URL) throws {
        try coordinate(url, primary: primary, write: .forDeleting) { u in
            do {
                try FileManager.default.removeItem(at: u)
            } catch let e as CocoaError where e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile {
            }
        }
    }

    #if os(macOS)
    private final class Presenter: NSObject, NSFilePresenter {
        let primaryPresentedItemURL: URL?
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()

        init(primary: URL, related: URL) {
            primaryPresentedItemURL = primary
            presentedItemURL = related
        }
    }

    /// いま扱っている関連ファイルのプレゼンター。読み書きのたびに登録・解除すると、解除の直後の操作が約 0.5 秒待たされるので、
    /// 1 つ持って使い回し、別の書類に移ったときだけ登録し直す
    private static var current: Presenter?
    private static let lock = NSLock()

    private static func presenter(primary: URL, related: URL) -> Presenter {
        lock.lock()
        defer { lock.unlock() }
        if let p = current, p.primaryPresentedItemURL == primary, p.presentedItemURL == related { return p }
        if let p = current { NSFileCoordinator.removeFilePresenter(p) }
        let p = Presenter(primary: primary, related: related)
        NSFileCoordinator.addFilePresenter(p)
        current = p
        return p
    }

    /// write が nil なら読み込み
    private static func coordinate<T>(_ url: URL, primary: URL, write: NSFileCoordinator.WritingOptions?,
                                      _ body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: presenter(primary: primary, related: url))
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
    #else
    private static func coordinate<T>(_ url: URL, primary: URL, write: NSFileCoordinator.WritingOptions?,
                                      _ body: (URL) throws -> T) throws -> T {
        try body(url)
    }
    #endif
}
