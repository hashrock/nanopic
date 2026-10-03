import Foundation

/// タイムラインの操作
extension Editor {
    public var timeline: Timeline { doc.timeline }

    /// レイヤーのトラックを足す（今の表示状態を 0 コマ目のキーにする）。PSD のレイヤー ID がなければ振る
    public func addTrack(_ id: UUID) {
        doc.assignPSDIDs()
        guard let n = doc.node(id), doc.timeline.track(for: n.psdID) == nil, let key = currentKey(n, frame: 0) else { return }
        checkpoint("トラックを追加")
        doc.timeline.tracks.append(TimelineTrack(layer: n.psdID, keys: [key]))
        revision += 1
    }

    /// タイムラインの行にするレイヤー（スイッチフォルダーの子なら、そのフォルダー）
    public func timelineTarget(_ id: UUID) -> UUID {
        guard isInSwitch(id), let path = doc.indexPath(of: id),
              let parent = doc.node(at: Array(path.dropLast())) else { return id }
        return parent.id
    }

    /// id（スイッチの子ならそのフォルダー）がタイムラインに行を持っているか
    public func hasTrack(_ id: UUID) -> Bool {
        guard let n = doc.node(timelineTarget(id)), n.psdID != 0 else { return false }
        return doc.timeline.track(for: n.psdID) != nil
    }

    /// id（スイッチの子ならそのフォルダー）の行をタイムラインから外す（キーも消える）
    public func removeTrack(of id: UUID) {
        guard let n = doc.node(timelineTarget(id)), n.psdID != 0 else { return }
        removeTrack(layer: n.psdID)
    }

    public func removeTrack(layer: UInt32) {
        guard doc.timeline.track(for: layer) != nil else { return }
        checkpoint("トラックを削除")
        doc.timeline.tracks.removeAll { $0.layer == layer }
        revision += 1
    }

    /// 今のレイヤーの状態を、frame のキーにして置く
    public func setKeyFromCurrentState(layer: UInt32, frame: Int) {
        guard let n = doc.node(psdID: layer), let key = currentKey(n, frame: frame),
              let ti = doc.timeline.tracks.firstIndex(where: { $0.layer == layer }) else { return }
        checkpoint("キーを打つ")
        doc.timeline.tracks[ti].set(key)
        revision += 1
    }

    /// キーを直接置く（エージェント用）
    public func setKey(layer: UInt32, _ key: TimelineKey) {
        guard let ti = doc.timeline.tracks.firstIndex(where: { $0.layer == layer }) else { return }
        checkpoint("キーを打つ")
        doc.timeline.tracks[ti].set(key)
        revision += 1
        applyFrame()
    }

    public func deleteKey(layer: UInt32, frame: Int) {
        guard let ti = doc.timeline.tracks.firstIndex(where: { $0.layer == layer }),
              doc.timeline.tracks[ti].keys.contains(where: { $0.frame == frame }) else { return }
        checkpoint("キーを削除")
        doc.timeline.tracks[ti].keys.removeAll { $0.frame == frame }
        if doc.timeline.tracks[ti].keys.isEmpty { doc.timeline.tracks.remove(at: ti) }
        revision += 1
        applyFrame()
    }

    /// キーを別のコマへ動かす（行き先にキーがあれば置き換える）
    public func moveKey(layer: UInt32, from: Int, to: Int) {
        guard from != to, let ti = doc.timeline.tracks.firstIndex(where: { $0.layer == layer }),
              var key = doc.timeline.tracks[ti].keys.first(where: { $0.frame == from }) else { return }
        checkpoint("キーを動かす")
        doc.timeline.tracks[ti].keys.removeAll { $0.frame == from }
        key.frame = max(0, to)
        doc.timeline.tracks[ti].set(key)
        revision += 1
        applyFrame()
    }

    public func setTimeline(fps: Int? = nil, frameCount: Int? = nil, loop: Bool? = nil) {
        var t = doc.timeline
        if let fps { t.fps = min(max(fps, 1), 60) }
        if let frameCount { t.frameCount = min(max(frameCount, 1), 10_000) }
        if let loop { t.loop = loop }
        guard t != doc.timeline else { return }
        checkpoint("タイムラインの設定", coalesceKey: "timeline-settings")
        doc.timeline = t
        currentFrame = min(currentFrame, t.frameCount - 1)
        revision += 1
    }

    /// 再生位置を動かし、そのコマの表示状態をレイヤーに当てる（履歴には残さない）
    public func goToFrame(_ frame: Int) {
        let f = min(max(frame, 0), max(doc.timeline.frameCount - 1, 0))
        currentFrame = f
        // 再生中はレイヤーを書き換えず、キャッシュした絵を出すだけ（止めたときに合わせる）
        if isPlayingBack {
            onNeedsDisplay?()
            return
        }
        applyFrame()
    }

    /// 今のコマの表示状態をレイヤーに当てる
    func applyFrame() {
        // 変形を表示していなければ（描くモード）値だけ合わせる
        let values = doc.timeline.parameterValues(at: currentFrame)
        if !values.isEmpty {
            parameterValues.merge(values) { _, new in new }
            if showsDeformation { markAllDirty() }
        }
        if doc.applyTimeline(frame: currentFrame) {
            followCel()
            structureChanged()
        }
    }

    /// frame のコマで、レイヤーのいまの状態を表すキー
    func currentKey(_ n: LayerNode, frame: Int) -> TimelineKey? {
        if n.isSwitch {
            // フォルダーを隠していれば「なし」（空のコマ）
            if !n.visible { return TimelineKey(frame: frame, visible: false) }
            guard let shown = n.children.first(where: \.visible) else { return nil }
            return TimelineKey(frame: frame, child: shown.psdID)
        }
        return TimelineKey(frame: frame, visible: n.visible)
    }

    /// タイムラインを開いている間に表示を切り替えたら、そのレイヤーのトラックに今のコマのキーを打つ（履歴は呼び出し側で）
    func autoKey(_ id: UUID) {
        guard timelineOpen, let n = doc.node(id), n.psdID != 0,
              let ti = doc.timeline.tracks.firstIndex(where: { $0.layer == n.psdID }),
              let key = currentKey(n, frame: currentFrame) else { return }
        doc.timeline.tracks[ti].set(key)
    }
}
