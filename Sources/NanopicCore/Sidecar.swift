import Foundation

/// PSD の隣に置く `作品.nanopic.json`。PSD に入らない、この作品だけの情報を持つ。
/// レイヤーは PSD のレイヤー ID（LayerNode.psdID）で指す。
public struct Sidecar: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = Sidecar.currentVersion
    /// スイッチフォルダーにしたフォルダーの PSD レイヤー ID
    public var switchFolders: [UInt32] = []
    public var timeline: Timeline?
    public var rig: Rig?
    public var publish: PublishSettings?

    public init() {}

    /// 持つものがなければファイルを作らない
    public var isEmpty: Bool { switchFolders.isEmpty && (timeline?.isEmpty ?? true) && (rig?.isEmpty ?? true) && publish == nil }

    /// `作品.psd` → `作品.nanopic.json`
    public static func url(for psd: URL) -> URL {
        psd.deletingPathExtension().appendingPathExtension("nanopic.json")
    }

    /// なければ nil
    public static func read(for psd: URL) throws -> Sidecar? {
        let url = url(for: psd)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: url))
    }

    /// 書く。持つものがなければ、残っている古いファイルを消す
    public func write(for psd: URL) throws {
        let url = Self.url(for: psd)
        if isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        var s = self
        s.version = Self.currentVersion
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(s).write(to: url, options: .atomic)
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
