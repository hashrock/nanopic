import Foundation

/// オニオンスキン: 前後のコマを薄く重ねて見せる（前は赤、後ろは青）。作品には保存しない表示の設定
public struct OnionSkin: Equatable, Sendable {
    public var enabled = false
    /// 前に何コマ出すか
    public var before = 1
    /// 後ろに何コマ出すか
    public var after = 1

    public init(enabled: Bool = false, before: Int = 1, after: Int = 1) {
        self.enabled = enabled
        self.before = before
        self.after = after
    }
}

extension Editor {
    /// 今のコマに重ねるオニオンスキンの絵（RGBA8 premultiplied、キャンバスの大きさ）。出さないときは nil
    /// 前後のコマのうち、今のコマと見た目が違う所だけを、暗いほど濃く色をつけて重ねる（用紙や動かない所は出ない）
    public func onionSkinImage() -> [UInt8]? {
        let o = onionSkin
        let t = doc.timeline
        guard o.enabled, timelineOpen, o.before + o.after > 0,
              !t.tracks.isEmpty || !t.parameterTracks.isEmpty, t.frameCount > 1 else { return nil }
        let key = OnionCacheKey(revision: revision, frame: currentFrame, values: parameterValues,
                                deformed: showsDeformation, settings: o)
        if let c = onionCache, c.key == key { return c.image }

        let w = doc.width, h = doc.height
        let current = Compositor.compositeFull(displayDoc)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        // 遠いコマから先に重ね、近いコマが上に来るようにする
        var ghosts: [(frame: Int, tint: (Float, Float, Float), weight: Float)] = []
        for k in stride(from: o.before, through: 1, by: -1) {
            if let f = onionFrame(currentFrame - k, t) { ghosts.append((f, (0.92, 0.22, 0.2), onionWeight(k, o.before))) }
        }
        for k in stride(from: o.after, through: 1, by: -1) {
            if let f = onionFrame(currentFrame + k, t) { ghosts.append((f, (0.15, 0.45, 0.95), onionWeight(k, o.after))) }
        }
        for g in ghosts where g.frame != currentFrame {
            var d = doc
            d.applyTimeline(frame: g.frame)
            let values = parameterValues.merging(t.parameterValues(at: g.frame)) { _, new in new }
            let frameDoc = showsDeformation && !d.rig.isEmpty && !d.rig.isRest(values: values) ? d.posed(values: values) : d
            let img = Compositor.compositeFull(frameDoc)
            img.withUnsafeBufferPointer { src in
                current.withUnsafeBufferPointer { cur in
                    out.withUnsafeMutableBufferPointer { dst in
                        Self.blendGhost(src: src, current: cur, into: dst, tint: g.tint, weight: g.weight)
                    }
                }
            }
        }
        onionCache = (key, out)
        onionSkinVersion += 1
        return out
    }

    /// 前後に何コマ目か（ループするならはみ出した分を回り込ませる）
    private func onionFrame(_ f: Int, _ t: Timeline) -> Int? {
        if (0..<t.frameCount).contains(f) { return f }
        guard t.loop else { return nil }
        return ((f % t.frameCount) + t.frameCount) % t.frameCount
    }

    /// 遠いコマほど薄く
    private func onionWeight(_ k: Int, _ n: Int) -> Float {
        0.55 * Float(n - k + 1) / Float(n)
    }

    private static func blendGhost(src: UnsafeBufferPointer<UInt8>, current: UnsafeBufferPointer<UInt8>,
                                   into dst: UnsafeMutableBufferPointer<UInt8>,
                                   tint: (Float, Float, Float), weight: Float) {
        let count = src.count / 4
        let rows = 64
        let per = (count + rows - 1) / rows
        let s = UInt(bitPattern: src.baseAddress), c = UInt(bitPattern: current.baseAddress)
        let d = UInt(bitPattern: dst.baseAddress)
        DispatchQueue.concurrentPerform(iterations: rows) { r in
            let src = UnsafePointer<UInt8>(bitPattern: s)!, cur = UnsafePointer<UInt8>(bitPattern: c)!
            let dst = UnsafeMutablePointer<UInt8>(bitPattern: d)!
            for i in (r * per)..<min(count, (r + 1) * per) {
                let o = i * 4
                // 今のコマと同じ所は出さない
                if abs(Int(src[o]) - Int(cur[o])) + abs(Int(src[o + 1]) - Int(cur[o + 1]))
                    + abs(Int(src[o + 2]) - Int(cur[o + 2])) + abs(Int(src[o + 3]) - Int(cur[o + 3])) < 8 { continue }
                // 暗いほど濃く（白い所は透明）。透けている所はその分薄く
                let alpha = Float(src[o + 3]) / 255
                let lum = (Float(src[o]) + Float(src[o + 1]) + Float(src[o + 2])) / (3 * 255) + (1 - alpha)
                let a = max(0, 1 - lum) * alpha * weight
                guard a > 0.004 else { continue }
                // 前に重ねた分の上に重ねる（premultiplied）
                let k = 1 - a
                dst[o] = UInt8(min(255, tint.0 * a * 255 + Float(dst[o]) * k + 0.5))
                dst[o + 1] = UInt8(min(255, tint.1 * a * 255 + Float(dst[o + 1]) * k + 0.5))
                dst[o + 2] = UInt8(min(255, tint.2 * a * 255 + Float(dst[o + 2]) * k + 0.5))
                dst[o + 3] = UInt8(min(255, a * 255 + Float(dst[o + 3]) * k + 0.5))
            }
        }
    }
}

struct OnionCacheKey: Equatable {
    var revision: Int
    var frame: Int
    var values: [String: Double]
    var deformed: Bool
    var settings: OnionSkin
}
