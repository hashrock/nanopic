import Foundation

/// タイムラインのキーを指す（トラックとコマ）
public enum TimelineKeyRef: Hashable, Sendable {
    /// レイヤー・スイッチフォルダーのトラック（PSD レイヤー ID）
    case layer(UInt32, frame: Int)
    /// パラメータのトラック
    case parameter(String, frame: Int)

    public var frame: Int {
        switch self {
        case let .layer(_, f), let .parameter(_, f): return f
        }
    }

    func moved(by d: Int) -> TimelineKeyRef {
        switch self {
        case let .layer(l, f): return .layer(l, frame: f + d)
        case let .parameter(p, f): return .parameter(p, frame: f + d)
        }
    }
}

/// コピーしたキー（コマは、いちばん前のキーからの差）
public struct TimelineClipboard: Sendable {
    var layerKeys: [(layer: UInt32, key: TimelineKey)] = []
    var parameterKeys: [(parameter: String, key: ParameterKeyframe)] = []

    public var isEmpty: Bool { layerKeys.isEmpty && parameterKeys.isEmpty }
}

/// キーをまとめて扱う（どれも取り消しは 1 回分）
extension Editor {
    /// 今あるキーだけに絞る
    public func existingKeys(_ refs: Set<TimelineKeyRef>) -> Set<TimelineKeyRef> {
        refs.filter { r in
            switch r {
            case let .layer(l, f): return doc.timeline.track(for: l)?.keys.contains { $0.frame == f } ?? false
            case let .parameter(p, f):
                return doc.timeline.parameterTracks.first { $0.parameter == p }?.keys.contains { $0.frame == f } ?? false
            }
        }
    }

    public func deleteKeys(_ refs: Set<TimelineKeyRef>) {
        let refs = existingKeys(refs)
        guard !refs.isEmpty else { return }
        checkpoint("キーを削除")
        for r in refs {
            switch r {
            case let .layer(l, f):
                if let ti = doc.timeline.tracks.firstIndex(where: { $0.layer == l }) { doc.timeline.tracks[ti].keys.removeAll { $0.frame == f } }
            case let .parameter(p, f):
                if let ti = doc.timeline.parameterTracks.firstIndex(where: { $0.parameter == p }) {
                    doc.timeline.parameterTracks[ti].keys.removeAll { $0.frame == f }
                }
            }
        }
        doc.timeline.tracks.removeAll { $0.keys.isEmpty }
        doc.timeline.parameterTracks.removeAll { $0.keys.isEmpty }
        revision += 1
        applyFrame()
    }

    /// キーをまとめて offset コマ動かす（0 より前には動かさない。行き先のキーは置き換える）。動かしたあとのキーを返す
    @discardableResult
    public func moveKeys(_ refs: Set<TimelineKeyRef>, by offset: Int) -> Set<TimelineKeyRef> {
        let refs = existingKeys(refs)
        guard let minFrame = refs.map(\.frame).min() else { return refs }
        let d = max(offset, -minFrame)
        guard d != 0 else { return refs }
        checkpoint("キーを動かす")
        var layerMoved: [UInt32: [TimelineKey]] = [:]
        var paramMoved: [String: [ParameterKeyframe]] = [:]
        // 先に全部取り出してから置く（動かすキーどうしで消し合わないように）
        for r in refs {
            switch r {
            case let .layer(l, f):
                guard let ti = doc.timeline.tracks.firstIndex(where: { $0.layer == l }),
                      var k = doc.timeline.tracks[ti].keys.first(where: { $0.frame == f }) else { continue }
                doc.timeline.tracks[ti].keys.removeAll { $0.frame == f }
                k.frame += d
                layerMoved[l, default: []].append(k)
            case let .parameter(p, f):
                guard let ti = doc.timeline.parameterTracks.firstIndex(where: { $0.parameter == p }),
                      var k = doc.timeline.parameterTracks[ti].keys.first(where: { $0.frame == f }) else { continue }
                doc.timeline.parameterTracks[ti].keys.removeAll { $0.frame == f }
                k.frame += d
                paramMoved[p, default: []].append(k)
            }
        }
        for (l, ks) in layerMoved {
            guard let ti = doc.timeline.tracks.firstIndex(where: { $0.layer == l }) else { continue }
            for k in ks { doc.timeline.tracks[ti].set(k) }
        }
        for (p, ks) in paramMoved {
            guard let ti = doc.timeline.parameterTracks.firstIndex(where: { $0.parameter == p }) else { continue }
            for k in ks { doc.timeline.parameterTracks[ti].set(frame: k.frame, value: k.value, easing: k.easing) }
        }
        if let maxFrame = refs.map(\.frame).max(), maxFrame + d >= doc.timeline.frameCount {
            doc.timeline.frameCount = maxFrame + d + 1
        }
        revision += 1
        applyFrame()
        return Set(refs.map { $0.moved(by: d) })
    }

    public func copyKeys(_ refs: Set<TimelineKeyRef>) -> TimelineClipboard {
        let refs = existingKeys(refs)
        var clip = TimelineClipboard()
        guard let base = refs.map(\.frame).min() else { return clip }
        for r in refs {
            switch r {
            case let .layer(l, f):
                if var k = doc.timeline.track(for: l)?.keys.first(where: { $0.frame == f }) {
                    k.frame -= base
                    clip.layerKeys.append((l, k))
                }
            case let .parameter(p, f):
                if var k = doc.timeline.parameterTracks.first(where: { $0.parameter == p })?.keys.first(where: { $0.frame == f }) {
                    k.frame -= base
                    clip.parameterKeys.append((p, k))
                }
            }
        }
        return clip
    }

    /// frame を先頭にして貼り付ける（トラックがなければ作る）。貼り付けたキーを返す
    @discardableResult
    public func pasteKeys(_ clip: TimelineClipboard, at frame: Int) -> Set<TimelineKeyRef> {
        guard !clip.isEmpty else { return [] }
        checkpoint("キーを貼り付け")
        var out = Set<TimelineKeyRef>()
        var last = 0
        for (l, k0) in clip.layerKeys where doc.node(psdID: l) != nil {
            var k = k0
            k.frame += frame
            if let ti = doc.timeline.tracks.firstIndex(where: { $0.layer == l }) {
                doc.timeline.tracks[ti].set(k)
            } else {
                doc.timeline.tracks.append(TimelineTrack(layer: l, keys: [k]))
            }
            out.insert(.layer(l, frame: k.frame))
            last = max(last, k.frame)
        }
        for (p, k0) in clip.parameterKeys where doc.rig.parameter(p) != nil {
            var k = k0
            k.frame += frame
            if !doc.timeline.parameterTracks.contains(where: { $0.parameter == p }) {
                doc.timeline.parameterTracks.append(ParameterTrack(parameter: p))
            }
            let ti = doc.timeline.parameterTracks.firstIndex { $0.parameter == p }!
            doc.timeline.parameterTracks[ti].set(frame: k.frame, value: k.value, easing: k.easing)
            out.insert(.parameter(p, frame: k.frame))
            last = max(last, k.frame)
        }
        if last >= doc.timeline.frameCount { doc.timeline.frameCount = last + 1 }
        revision += 1
        applyFrame()
        return out
    }
}
