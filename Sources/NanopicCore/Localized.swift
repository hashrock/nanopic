import Foundation

// 表示言語（日本語・英語）。元の言語は日本語で、日本語の文言がそのままキーになる。
// 訳は Resources/*.xcstrings にあり、ビルドのスクリプトが .lproj にしてアプリ（.app）の Resources に入れる。
// SwiftPM のリソース（Bundle.module）は使わない。SwiftUI の Text("…") がアプリ本体（Bundle.main）を引くので、
// 自分で引く側（NSAlert、エラー、enum の表示名、取り消しの名前）も同じ所を引く。
// `swift run` やテストのように .lproj が無いときは、キー（日本語）がそのまま出る。

public enum Localization {
    /// 訳を引く先
    public static var bundle: Bundle = .main
    /// 設定に入る既定の名前（ブラシ・ブラシ先端）の訳の表
    public static let nameTable = "Names"
}

/// 画面に出す文言を引く。`L("\(n) 個")` のような埋め込みは `%lld 個` のキーになる（String は `%@`、Double は `%lf`）
public func L(_ key: String.LocalizationValue, table: String? = nil) -> String {
    String(localized: key, table: table, bundle: Localization.bundle)
}

/// `%.1f` のような書式つきの文言を引いて組み立てる。キーは書いたとおりの文字列
public func LFormat(_ key: String, table: String? = nil, _ args: CVarArg...) -> String {
    String(format: Localization.bundle.localizedString(forKey: key, value: key, table: table), arguments: args)
}

/// アプリの設定に入っている既定の名前（ブラシ・ブラシ先端）を、出すときに訳す。
///
/// 設定はその Mac・iPad の中だけのものなので、日本語のまま保存し、画面の言語に合わせて出す
/// （「Gペン」→ G-Pen）。ユーザーが自分で付けた名前は表に無いので、そのまま返る。
///
/// 書類（PSD）・サイドカーに入る既定の名前（レイヤー・フォルダー・用紙・デフォーマ・パラメータ）にはこれを使わない。
/// そちらは作ったときの表示言語で決めて（`L("用紙")`）そのまま保存し、開く環境の言語では変えない。
public func LName(_ name: String) -> String {
    NameLocalizer.shared.localized(name)
}

/// 名前の入力欄に出す値と、打ち替えたときだけ保存する値の組。訳した名前をそのまま確定しても、保存する名前は変えない
public func LNameEdited(_ text: String, original: String) -> String {
    text == LName(original) ? original : text
}

final class NameLocalizer: @unchecked Sendable {
    static let shared = NameLocalizer { key in
        let missing = "\u{0}"
        let v = Localization.bundle.localizedString(forKey: key, value: missing, table: Localization.nameTable)
        return v == missing ? nil : v
    }

    /// 名前の一部を埋めて作る既定の名前（複製したブラシ）
    static let patterns = ["%@ コピー"]

    private let lookup: (String) -> String?
    private let compiled: [(key: String, regex: NSRegularExpression, isNumber: Bool)]
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    init(lookup: @escaping (String) -> String?) {
        self.lookup = lookup
        compiled = Self.patterns.map { key in
            let isNumber = key.contains("%lld")
            let hole = isNumber ? "%lld" : "%@"
            let parts = key.components(separatedBy: hole).map(NSRegularExpression.escapedPattern(for:))
            let pattern = "^" + parts.joined(separator: isNumber ? "([0-9]+)" : "(.+)") + "$"
            // 決め打ちの式なので必ず作れる
            return (key, try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]), isNumber)
        }
    }

    func localized(_ name: String) -> String {
        lock.lock()
        if let hit = cache[name] { lock.unlock(); return hit }
        lock.unlock()
        let result = translate(name, depth: 0)
        lock.lock()
        if cache.count > 4096 { cache.removeAll() }
        cache[name] = result
        lock.unlock()
        return result
    }

    private func translate(_ name: String, depth: Int) -> String {
        if let exact = lookup(name) { return exact }
        guard depth < 4 else { return name }
        let range = NSRange(name.startIndex..., in: name)
        for p in compiled {
            guard let m = p.regex.firstMatch(in: name, range: range), let r = Range(m.range(at: 1), in: name),
                  let format = lookup(p.key) else { continue }
            let inner = String(name[r])
            if p.isNumber {
                guard let n = Int(inner) else { continue }
                return String(format: format, n)
            }
            return String(format: format, translate(inner, depth: depth + 1))
        }
        return name
    }
}
