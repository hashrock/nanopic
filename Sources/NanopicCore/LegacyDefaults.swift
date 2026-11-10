import Foundation

/// Bundle ID を変えたときに、古い ID の設定（UserDefaults）を新しい ID に引き継ぐ。
///
/// 一度だけ行う。新しい側にもうある項目は上書きしない。古い側は消さない（古い版に戻しても設定が残る）。
/// App Sandbox の中ではほかのアプリの設定を読めないので、何も引き継がれない（落ちはしない）。
/// 設定の置き場（ドメインごとの辞書）。本物は UserDefaults。テストでは実際の設定に触らないよう、メモリー上の辞書を渡す
public protocol DefaultsDomains {
    func persistentDomain(forName domainName: String) -> [String: Any]?
    func setPersistentDomain(_ domain: [String: Any], forName domainName: String)
}

extension UserDefaults: DefaultsDomains {}

public enum LegacyDefaults {
    /// 引き継いだ項目の数を返す（済んでいれば・古い設定がなければ 0）
    @discardableResult
    public static func migrate(from old: String, to new: String, defaults: DefaultsDomains = UserDefaults.standard) -> Int {
        let doneKey = "migratedFrom." + old
        let current = defaults.persistentDomain(forName: new) ?? [:]
        guard old != new, current[doneKey] == nil else { return 0 }
        var merged = current
        var count = 0
        for (k, v) in defaults.persistentDomain(forName: old) ?? [:] where merged[k] == nil {
            merged[k] = v
            count += 1
        }
        merged[doneKey] = true
        defaults.setPersistentDomain(merged, forName: new)
        return count
    }
}
