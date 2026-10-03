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
    /// パラメータのトラック（値を直線で補間）
    public var parameterTracks: [ParameterTrack] = []

    public init() {}

    public var isEmpty: Bool { tracks.isEmpty && parameterTracks.isEmpty }

    /// frame でのパラメータの値（トラックのあるものだけ）
    public func parameterValues(at frame: Int) -> [String: Double] {
        var out: [String: Double] = [:]
        for t in parameterTracks { if let v = t.value(at: frame) { out[t.parameter] = v } }
        return out
    }

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
        parameterTracks = try c.decodeIfPresent([ParameterTrack].self, forKey: .parameterTracks) ?? []
    }

    private enum CodingKeys: String, CodingKey { case fps, frameCount, loop, tracks, parameterTracks }
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

public struct ParameterTrack: Codable, Equatable, Sendable {
    public var parameter: String
    /// コマの順に並べる
    public var keys: [ParameterKeyframe] = []

    public init(parameter: String, keys: [ParameterKeyframe] = []) {
        self.parameter = parameter
        self.keys = keys
    }

    /// キーの間は前のキーのイージングで補間、外側は端のキーの値
    public func value(at frame: Int) -> Double? {
        guard let first = keys.first, let last = keys.last else { return nil }
        if frame <= first.frame { return first.value }
        if frame >= last.frame { return last.value }
        for i in 1..<keys.count where frame <= keys[i].frame {
            let a = keys[i - 1], b = keys[i]
            let t = a.easing.apply(Double(frame - a.frame) / Double(max(b.frame - a.frame, 1)))
            return a.value + (b.value - a.value) * t
        }
        return last.value
    }

    /// frame にキーを置く（あれば値を置き換え、イージングは前のものを残す）
    public mutating func set(frame: Int, value: Double, easing: Easing? = nil) {
        let old = keys.first { $0.frame == frame }
        keys.removeAll { $0.frame == frame }
        keys.append(ParameterKeyframe(frame: frame, value: value, easing: easing ?? old?.easing ?? .linear))
        keys.sort { $0.frame < $1.frame }
    }
}

public struct ParameterKeyframe: Codable, Equatable, Sendable {
    public var frame: Int
    public var value: Double
    /// このキーから次のキーまでの動き方
    public var easing: Easing = .linear

    public init(frame: Int, value: Double, easing: Easing = .linear) {
        self.frame = frame
        self.value = value
        self.easing = easing
    }

    private enum CodingKeys: String, CodingKey { case frame, value, easing }

    /// イージングのなかった頃のデータは直線として読む
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Int.self, forKey: .frame)
        value = try c.decode(Double.self, forKey: .value)
        easing = try c.decodeIfPresent(Easing.self, forKey: .easing) ?? .linear
    }
}

/// キーから次のキーまでの動き方
public enum Easing: String, Codable, CaseIterable, Sendable {
    case linear
    /// ゆっくり始まる
    case easeIn
    /// ゆっくり止まる
    case easeOut
    /// ゆっくり始まり、ゆっくり止まる
    case easeInOut
    /// 次のキーまで値を保つ
    case hold

    public var displayName: String {
        switch self {
        case .linear: return "直線"
        case .easeIn: return "ゆっくり始まる"
        case .easeOut: return "ゆっくり止まる"
        case .easeInOut: return "ゆっくり始まり、ゆっくり止まる"
        case .hold: return "止める（次のキーまで保つ）"
        }
    }

    /// 0...1 の進み具合を、動き方に合わせて変える
    public func apply(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear: return t
        case .easeIn: return t * t * t
        case .easeOut: return 1 - pow(1 - t, 3)
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .hold: return t < 1 ? 0 : 1
        }
    }
}

extension DocumentState {
    /// frame のコマの表示状態をレイヤーに当てる（再生と書き出しで共通）。変わったら true
    @discardableResult
    public mutating func applyTimeline(frame: Int) -> Bool {
        var changed = false
        for track in timeline.tracks {
            guard let n = node(psdID: track.layer), let key = track.key(at: frame),
                  let path = indexPath(of: n.id) else { continue }
            if let child = key.child, n.isSwitch {
                guard let k = n.children.firstIndex(where: { $0.psdID == child }), !n.children[k].visible else { continue }
                modifySiblings(parentPath: path) { kids in
                    for i in kids.indices { kids[i].visible = i == k }
                }
                changed = true
            } else if let v = key.visible, n.visible != v {
                modify(n.id) { $0.visible = v }
                changed = true
            }
        }
        return changed
    }
}
