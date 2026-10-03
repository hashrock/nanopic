import Foundation

/// 再生中に合成した絵のキャッシュ。コマの見た目の状態（各トラックのキー、パラメータの値）ごとに 1 枚持つ
final class PlaybackCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: [UInt8]] = [:]
    private var bytes = 0
    /// これを超えたら持たない（毎回作る）
    private let limit = 1_500_000_000
    private var cancelled = false

    func image(_ key: String) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return images[key]
    }

    func store(_ key: String, _ image: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        guard images[key] == nil, bytes + image.count <= limit else { return }
        images[key] = image
        bytes += image.count
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

/// 再生: 再生中はレイヤーの状態を書き換えず、コマごとに合成した絵をキャッシュして出す
extension Editor {
    public var isPlayingBack: Bool { playback != nil }

    /// 再生を始める。裏で全コマの絵を先に作っておく
    public func beginPlayback() {
        commitTransform()
        playback?.cache.cancel()
        let cache = PlaybackCache()
        playback = (revision, cache)
        prewarm(cache)
    }

    /// 再生を止め、レイヤーの表示を今のコマに合わせる
    public func endPlayback() {
        guard let p = playback else { return }
        p.cache.cancel()
        playback = nil
        applyFrame()
        markAllDirty()
    }

    /// 再生中に出す今のコマの絵（RGBA8 premultiplied、キャンバスの大きさ）と、その見た目の状態のキー
    public func playbackImage() -> (key: String, image: [UInt8])? {
        guard var p = playback else { return nil }
        // 再生中に絵が変わったら作り直す
        if p.revision != revision {
            p.cache.cancel()
            p = (revision, PlaybackCache())
            playback = p
            prewarm(p.cache)
        }
        let key = Self.frameKey(doc, frame: currentFrame, values: parameterValues, deformed: showsDeformation)
        if let img = p.cache.image(key) { return (key, img) }
        let img = Self.renderFrame(doc, frame: currentFrame, values: parameterValues, deformed: showsDeformation)
        p.cache.store(key, img)
        return (key, img)
    }

    private func prewarm(_ cache: PlaybackCache) {
        let doc = self.doc, values = parameterValues, deformed = showsDeformation
        let count = doc.timeline.frameCount, start = currentFrame
        DispatchQueue.global(qos: .userInitiated).async {
            // 今のコマから順に
            for i in 0..<count {
                if cache.isCancelled { return }
                let f = (start + i) % count
                let key = Editor.frameKey(doc, frame: f, values: values, deformed: deformed)
                if cache.image(key) != nil { continue }
                cache.store(key, Editor.renderFrame(doc, frame: f, values: values, deformed: deformed))
            }
        }
    }

    /// コマの見た目の状態（同じなら同じ絵になる）
    static func frameKey(_ doc: DocumentState, frame: Int, values: [String: Double], deformed: Bool) -> String {
        var s = ""
        for t in doc.timeline.tracks {
            guard let k = t.key(at: frame) else { continue }
            s += "\(t.layer):\(k.visible.map { $0 ? 1 : 0 } ?? -1):\(k.child ?? 0);"
        }
        if deformed {
            let v = values.merging(doc.timeline.parameterValues(at: frame)) { _, new in new }
            for id in v.keys.sorted() { s += "\(id)=\(v[id]!);" }
        }
        return s
    }

    /// 書き出しと同じやり方でコマを合成する
    static func renderFrame(_ doc: DocumentState, frame: Int, values: [String: Double], deformed: Bool) -> [UInt8] {
        var d = doc
        d.applyTimeline(frame: frame)
        let v = values.merging(d.timeline.parameterValues(at: frame)) { _, new in new }
        let shown = deformed && !d.rig.isEmpty && !d.rig.isRest(values: v) ? d.posed(values: v) : d
        return Compositor.compositeFull(shown)
    }
}
