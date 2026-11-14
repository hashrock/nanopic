import Foundation

/// ブラシ・消しゴム・パレットの設定を iCloud（キー値ストア）で Mac と iPad の間で同期する。
///
/// 設定はこれまでどおり UserDefaults に保存し、同期がオンのときだけ同じ値を iCloud にも書く。
/// ほかの端末で変わった値が届いたら UserDefaults に写して `onRemoteChange` を呼ぶ（アプリは設定を読み直す）。
/// 両方で同じ項目を変えたときは、あとから書いたほうが残る。メインスレッドから使う
@MainActor
public final class PreferenceSync {
    /// 同期する UserDefaults のキー（Mac 版・iPad 版で同じキーと形式）
    public static let keys = ["brushes.v1", "erasers.v1", "palette.v1"]
    private static let enabledKey = "sync.enabled"

    private let store = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private let onRemoteChange: () -> Void
    private var observer: NSObjectProtocol?

    public private(set) var isEnabled: Bool

    public init(onRemoteChange: @escaping () -> Void) {
        self.onRemoteChange = onRemoteChange
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { [weak self] note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            // queue: .main で受けている
            MainActor.assumeIsolated { self?.receive(changedKeys: changed) }
        }
    }

    /// 起動時、設定を読む前に呼ぶ。起動していない間にほかの端末で変わった値を UserDefaults に取り込む
    public func pullOnLaunch() {
        guard isEnabled else { return }
        store.synchronize()
        _ = pull(Self.keys)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 同期をオン・オフする。オンにしたとき iCloud に値があればそちらを使い、なければ手元の値を上げる
    public func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        defaults.set(on, forKey: Self.enabledKey)
        guard on else { return }
        store.synchronize()
        if Self.keys.contains(where: { store.object(forKey: $0) != nil }) {
            if pull(Self.keys) { onRemoteChange() }
            // iCloud にまだない項目は手元の値を上げる
            for key in Self.keys where store.object(forKey: key) == nil { upload(key) }
        } else {
            push()
        }
    }

    /// UserDefaults に保存したあとに呼ぶ。同期がオンなら iCloud にも書く。
    /// 変わった項目だけ書くので、届いた値を読み直して保存し直しても、書き戻しは起きない
    public func push() {
        guard isEnabled else { return }
        for key in Self.keys { upload(key) }
    }

    private func upload(_ key: String) {
        guard let value = defaults.object(forKey: key) else { return }
        if !Self.same(store.object(forKey: key), value) { store.set(value, forKey: key) }
    }

    /// iCloud の値を UserDefaults に写す。変わったものがあれば true
    private func pull(_ keys: [String]) -> Bool {
        var changed = false
        for key in keys where Self.keys.contains(key) {
            guard let value = store.object(forKey: key) else { continue }
            // 形が違うもの（壊れた値）は取り込まない
            guard value is Data || value is [String] else { continue }
            if !Self.same(defaults.object(forKey: key), value) {
                defaults.set(value, forKey: key)
                changed = true
            }
        }
        return changed
    }

    private func receive(changedKeys: [String]?) {
        guard isEnabled else { return }
        if pull(changedKeys ?? Self.keys) { onRemoteChange() }
    }

    private static func same(_ a: Any?, _ b: Any) -> Bool {
        switch (a, b) {
        case let (a as Data, b as Data): return a == b
        case let (a as [String], b as [String]): return a == b
        default: return false
        }
    }
}
