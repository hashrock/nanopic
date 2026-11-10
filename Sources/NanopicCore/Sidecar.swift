import Foundation

/// PSD の隣に置く `作品.nanopic`（サイドカー）。PSD に入らない、この作品だけの情報を持つ。
/// レイヤーは PSD のレイヤー ID（LayerNode.psdID）で指す。
///
/// 名前は「書類と同じ名前 + 拡張子 1 段」にしている。App Sandbox の中では、ユーザーが選んだ書類の隣のファイルは
/// 「関連ファイル」（名前が同じで拡張子だけ違うファイル。Info.plist で NSIsRelatedItemType の型として宣言する）
/// としてしか読み書きできないため。読み書きは RelatedFile を通す。
///
/// 古い名前 `作品.nanopic.json` は読むだけで、書かない・消さない。
public struct Sidecar: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let pathExtension = "nanopic"

    public var version = Sidecar.currentVersion
    /// スイッチフォルダーにしたフォルダーの PSD レイヤー ID
    public var switchFolders: [UInt32] = []
    public var timeline: Timeline?
    public var rig: Rig?
    public var publish: PublishSettings?

    public init() {}

    /// 持つものがなければファイルを作らない
    public var isEmpty: Bool { switchFolders.isEmpty && (timeline?.isEmpty ?? true) && (rig?.isEmpty ?? true) && publish == nil }

    /// `作品.psd` → `作品.nanopic`
    public static func url(for psd: URL) -> URL {
        psd.deletingPathExtension().appendingPathExtension(pathExtension)
    }

    /// 古い名前: `作品.psd` → `作品.nanopic.json`
    public static func legacyURL(for psd: URL) -> URL {
        psd.deletingPathExtension().appendingPathExtension("nanopic.json")
    }

    /// 読む。なければ nil。新しい名前があればそちらを使い、なければ古い名前を読む。
    /// Sandbox の中では古い名前は読めない（関連ファイルにならない）ので、そのときも nil
    public static func read(for psd: URL) throws -> Sidecar? {
        if let data = try RelatedFile.read(url(for: psd), primary: psd) {
            return try JSONDecoder().decode(Sidecar.self, from: data)
        }
        // 古い名前は関連ファイルにならないので、直接読む（Sandbox の中では読めず、nil になる）
        guard let old = try? Data(contentsOf: legacyURL(for: psd)) else { return nil }
        return try JSONDecoder().decode(Sidecar.self, from: old)
    }

    /// 新しい名前に書く。持つものがなければ、残っているファイルを消す。古い名前のファイルには触らない
    public func write(for psd: URL) throws {
        let url = Self.url(for: psd)
        // 古い名前のファイルを読める場所では、空でも書いておく（消すと、次に開いたとき古い中身が戻ってしまう）。
        // Sandbox の中のように古いファイルを読めない場所では、空のファイルで覆い隠さない（直接配布版で開けば古い中身を読める）
        let legacyReadable = (try? Data(contentsOf: Self.legacyURL(for: psd))) != nil
        if isEmpty && !legacyReadable {
            do {
                try RelatedFile.remove(url, primary: psd)
            } catch let e as CocoaError where e.code == .fileWriteNoPermission || e.code == .fileReadNoPermission {
                // 隣に手を出せない場所（Sandbox で関連ファイルとして扱えないとき）。書くものはないので、保存は失敗にしない
            }
            return
        }
        var s = self
        s.version = Self.currentVersion
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try RelatedFile.write(try enc.encode(s), to: url, primary: psd)
    }

    private enum CodingKeys: String, CodingKey { case version, switchFolders, timeline, rig, publish }

    /// 知らない項目や足りない項目があっても読めるようにする
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        switchFolders = try c.decodeIfPresent([UInt32].self, forKey: .switchFolders) ?? []
        timeline = try c.decodeIfPresent(Timeline.self, forKey: .timeline)
        rig = try c.decodeIfPresent(Rig.self, forKey: .rig)
        publish = try c.decodeIfPresent(PublishSettings.self, forKey: .publish)
    }
}
