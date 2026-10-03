import Foundation

/// タイムライン（簡易アニメーション）。レイヤーの表示／非表示と、スイッチフォルダーの子の切り替えを
/// コマごとに切り替える。値は補間せず、次のキーまで保つ。最初のキーより前は最初のキーの値。
/// レイヤーは PSD のレイヤー ID で指すので、そのままサイドカーに書ける。
public struct Timeline: Codable, Equatable, Sendable {
    public var fps = 12
    /// 長さ（コマ数）
    public var frameCount = 24
    public var loop = true
    public var tracks: [TimelineTrack] = []

    public init() {}

    public var isEmpty: Bool { tracks.isEmpty }

    public func track(for layer: UInt32) -> TimelineTrack? {
        tracks.first { $0.layer == layer }
    }

    /// 知らない項目や足りない項目があっても読めるようにする
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Timeline()
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        frameCount = try c.decodeIfPresent(Int.self, forKey: .frameCount) ?? d.frameCount
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? d.loop
        tracks = try c.decodeIfPresent([TimelineTrack].self, forKey: .tracks) ?? []
    }

    private enum CodingKeys: String, CodingKey { case fps, frameCount, loop, tracks }
}

public struct TimelineTrack: Codable, Equatable, Sendable {
    /// 対象レイヤーの PSD レイヤー ID
    public var layer: UInt32
    /// コマの順に並べる
    public var keys: [TimelineKey]

    public init(layer: UInt32, keys: [TimelineKey] = []) {
        self.layer = layer
        self.keys = keys
    }

    /// frame で効いているキー（その前の最後のキー。なければ最初のキー）
    public func key(at frame: Int) -> TimelineKey? {
        keys.last { $0.frame <= frame } ?? keys.first
    }

    /// frame にキーを置く（あれば置き換える）
    public mutating func set(_ key: TimelineKey) {
        keys.removeAll { $0.frame == key.frame }
        keys.append(key)
        keys.sort { $0.frame < $1.frame }
    }
}

public struct TimelineKey: Codable, Equatable, Sendable {
    public var frame: Int
    /// ふつうのレイヤー: 表示するか
    public var visible: Bool?
    /// スイッチフォルダー: 表示する子の PSD レイヤー ID
    public var child: UInt32?

    public init(frame: Int, visible: Bool? = nil, child: UInt32? = nil) {
        self.frame = frame
        self.visible = visible
        self.child = child
    }
}
