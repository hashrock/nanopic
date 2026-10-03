import Foundation

/// デフォーマとパラメータの操作、ポーズの表示
extension Editor {
    public var rig: Rig { doc.rig }

    /// 変形を表示していて、描いた絵と違う見た目になっている（この間は描けない）
    public var isPosed: Bool { showsDeformation && !doc.rig.isEmpty && !doc.rig.isRest(values: parameterValues) }

    /// 変形の表示を入り切りする（切れば描いた絵そのままを表示し、描ける）
    public func setShowsDeformation(_ on: Bool) {
        guard showsDeformation != on else { return }
        if on { commitTransform() }
        showsDeformation = on
        markAllDirty()
    }

    /// 表示用のドキュメント（ポーズ中ならデフォーマをかけたもの）
    public var displayDoc: DocumentState {
        guard isPosed else { return doc }
        if let c = poseCache, c.revision == revision, c.values == parameterValues { return c.doc }
        let posed = doc.posed(values: parameterValues)
        poseCache = (revision, parameterValues, posed)
        return posed
    }

    public func parameterValue(_ id: String) -> Double {
        guard let p = doc.rig.parameter(id) else { return 0 }
        return p.clamp(parameterValues[id] ?? p.defaultValue)
    }

    /// つまみを動かす（履歴には残さない）。タイムラインを開いていて、トラックがあれば今のコマにキーを打つ
    public func setParameterValue(_ id: String, _ value: Double) {
        guard let p = doc.rig.parameter(id) else { return }
        let v = p.clamp(value)
        commitTransform()
        parameterValues[id] = v
        showsDeformation = true
        if timelineOpen, let ti = doc.timeline.parameterTracks.firstIndex(where: { $0.parameter == id }) {
            checkpoint("キーを打つ", coalesceKey: "param-key-\(id)-\(currentFrame)")
            doc.timeline.parameterTracks[ti].set(frame: currentFrame, value: v)
            revision += 1
        }
        markAllDirty()
    }

    /// すべてのつまみを既定値に戻す
    public func resetPose() {
        guard !parameterValues.isEmpty else { return }
        parameterValues = [:]
        markAllDirty()
    }

    // MARK: デフォーマ

    /// レイヤー（フォルダー）にデフォーマを付ける。範囲と中心は描かれている所から決める
    @discardableResult
    public func addDeformer(to id: UUID, kind: DeformerKind, name: String? = nil, cols: Int = 4, rows: Int = 4) -> String? {
        doc.assignPSDIDs()
        guard let n = doc.node(id) else { return nil }
        let b = Self.contentBounds(n) ?? doc.bounds
        var d = Deformer(id: Self.newID("d", existing: doc.rig.deformers.map(\.id)),
                         name: name ?? "\(n.name)の\(kind == .rotation ? "移動・回転" : "ワープ")", layer: n.psdID, kind: kind)
        d.pivot = RigPoint(Double(b.x) + Double(b.width) / 2, Double(b.y) + Double(b.height) / 2)
        d.rect = RigRect(x: Double(b.x), y: Double(b.y), width: Double(b.width), height: Double(b.height))
        d.cols = max(1, min(cols, 16))
        d.rows = max(1, min(rows, 16))
        commitTransform()
        checkpoint("デフォーマを付ける")
        doc.rig.deformers.append(d)
        revision += 1
        markAllDirty()
        return d.id
    }

    public func updateDeformer(_ id: String, label: String = "デフォーマの設定", _ body: (inout Deformer) -> Void) {
        guard let i = doc.rig.deformers.firstIndex(where: { $0.id == id }) else { return }
        checkpoint(label, coalesceKey: "deformer-\(id)-\(label)")
        body(&doc.rig.deformers[i])
        revision += 1
        markAllDirty()
    }

    /// ワープの格子のマス数を変える。記録済みの形は、古い格子のずれを新しい格子の点の位置で読み取って写し直す
    public func setWarpGrid(_ id: String, cols: Int, rows: Int) {
        guard let di = doc.rig.deformers.firstIndex(where: { $0.id == id }), doc.rig.deformers[di].kind == .warp else { return }
        let old = doc.rig.deformers[di]
        var new = old
        new.cols = max(1, min(cols, 16))
        new.rows = max(1, min(rows, 16))
        guard new.cols != old.cols || new.rows != old.rows else { return }
        checkpoint("格子のマス数")
        doc.rig.deformers[di] = new
        for p in doc.rig.parameters.indices {
            for k in doc.rig.parameters[p].keys.indices {
                guard let f = doc.rig.parameters[p].keys[k].forms[id] else { continue }
                // 移動量は格子と関係ないので、点のずれだけを写し直す
                var points = f
                points.move = .zero
                let offsets = (0..<new.pointCount).map { i -> RigPoint in
                    let q = new.restPoint(i)
                    let m = old.map(q, points)
                    return RigPoint(m.x - q.x, m.y - q.y)
                }
                doc.rig.parameters[p].keys[k].forms[id] = DeformerForm(angle: f.angle, move: f.move, offsets: offsets)
            }
        }
        revision += 1
        markAllDirty()
    }

    /// デフォーマの範囲と中心を、付けているレイヤーの描かれている所に合わせ直す
    public func fitDeformerToContent(_ id: String) {
        guard let d = doc.rig.deformer(id), let n = doc.node(psdID: d.layer), let b = Self.contentBounds(n) else { return }
        updateDeformer(id, label: "範囲を合わせる") { d in
            d.rect = RigRect(x: Double(b.x), y: Double(b.y), width: Double(b.width), height: Double(b.height))
            if d.kind == .rotation { d.pivot = RigPoint(Double(b.x) + Double(b.width) / 2, Double(b.y) + Double(b.height) / 2) }
        }
    }

    public func removeDeformer(_ id: String) {
        guard doc.rig.deformer(id) != nil else { return }
        checkpoint("デフォーマを外す")
        doc.rig.deformers.removeAll { $0.id == id }
        for p in doc.rig.parameters.indices {
            for k in doc.rig.parameters[p].keys.indices { doc.rig.parameters[p].keys[k].forms[id] = nil }
        }
        revision += 1
        markAllDirty()
    }

    /// レイヤー（フォルダー）に付いているデフォーマ
    public func deformers(on id: UUID) -> [Deformer] {
        guard let n = doc.node(id), n.psdID != 0 else { return [] }
        return doc.rig.deformers.filter { $0.layer == n.psdID }
    }

    // MARK: パラメータ

    @discardableResult
    public func addParameter(name: String, min: Double = -1, max: Double = 1, defaultValue: Double = 0) -> String {
        let id = Self.newID("p", existing: doc.rig.parameters.map(\.id))
        var p = RigParameter(id: id, name: name, min: Swift.min(min, max), max: Swift.max(min, max))
        p.defaultValue = p.clamp(defaultValue)
        checkpoint("パラメータを足す")
        doc.rig.parameters.append(p)
        revision += 1
        return id
    }

    public func updateParameter(_ id: String, _ body: (inout RigParameter) -> Void) {
        guard let i = doc.rig.parameters.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("パラメータの設定", coalesceKey: "param-\(id)")
        body(&doc.rig.parameters[i])
        doc.rig.parameters[i].keys.sort { $0.value < $1.value }
        revision += 1
        markAllDirty()
    }

    public func removeParameter(_ id: String) {
        guard doc.rig.parameter(id) != nil else { return }
        checkpoint("パラメータを消す")
        doc.rig.parameters.removeAll { $0.id == id }
        doc.timeline.parameterTracks.removeAll { $0.parameter == id }
        parameterValues[id] = nil
        revision += 1
        markAllDirty()
    }

    /// パラメータの value のキーで、デフォーマの形を決める（キーがなければ作る）
    public func setForm(parameter: String, value: Double, deformer: String, _ form: DeformerForm) {
        guard let pi = doc.rig.parameters.firstIndex(where: { $0.id == parameter }), doc.rig.deformer(deformer) != nil else { return }
        let v = doc.rig.parameters[pi].clamp(value)
        checkpoint("形を記録", coalesceKey: "form-\(parameter)-\(v)-\(deformer)")
        if let ki = doc.rig.parameters[pi].keys.firstIndex(where: { abs($0.value - v) < 1e-9 }) {
            doc.rig.parameters[pi].keys[ki].forms[deformer] = form
        } else {
            doc.rig.parameters[pi].keys.append(RigParameterKey(value: v, forms: [deformer: form]))
            doc.rig.parameters[pi].keys.sort { $0.value < $1.value }
        }
        showsDeformation = true
        revision += 1
        markAllDirty()
    }

    public func removeParameterKey(parameter: String, value: Double) {
        guard let pi = doc.rig.parameters.firstIndex(where: { $0.id == parameter }) else { return }
        checkpoint("キーを消す")
        doc.rig.parameters[pi].keys.removeAll { abs($0.value - value) < 1e-9 }
        revision += 1
        markAllDirty()
    }

    // MARK: パラメータのタイムライン

    /// パラメータのトラックを足す（今の値を 0 コマ目のキーにする）
    public func addParameterTrack(_ id: String) {
        guard doc.rig.parameter(id) != nil, !doc.timeline.parameterTracks.contains(where: { $0.parameter == id }) else { return }
        checkpoint("トラックを追加")
        doc.timeline.parameterTracks.append(ParameterTrack(parameter: id, keys: [ParameterKeyframe(frame: 0, value: parameterValue(id))]))
        revision += 1
    }

    public func setParameterKey(_ id: String, frame: Int, value: Double) {
        guard let p = doc.rig.parameter(id) else { return }
        if !doc.timeline.parameterTracks.contains(where: { $0.parameter == id }) {
            doc.timeline.parameterTracks.append(ParameterTrack(parameter: id))
        }
        checkpoint("キーを打つ")
        let ti = doc.timeline.parameterTracks.firstIndex { $0.parameter == id }!
        doc.timeline.parameterTracks[ti].set(frame: max(0, frame), value: p.clamp(value))
        revision += 1
        applyFrame()
    }

    /// パラメータのキーの動き方（次のキーまでの補間）を変える
    public func setParameterKeyEasing(_ id: String, frame: Int, easing: Easing) {
        guard let ti = doc.timeline.parameterTracks.firstIndex(where: { $0.parameter == id }),
              let ki = doc.timeline.parameterTracks[ti].keys.firstIndex(where: { $0.frame == frame }),
              doc.timeline.parameterTracks[ti].keys[ki].easing != easing else { return }
        checkpoint("キーの動き方")
        doc.timeline.parameterTracks[ti].keys[ki].easing = easing
        revision += 1
        applyFrame()
    }

    public func deleteParameterKey(_ id: String, frame: Int) {
        guard let ti = doc.timeline.parameterTracks.firstIndex(where: { $0.parameter == id }),
              doc.timeline.parameterTracks[ti].keys.contains(where: { $0.frame == frame }) else { return }
        checkpoint("キーを削除")
        doc.timeline.parameterTracks[ti].keys.removeAll { $0.frame == frame }
        if doc.timeline.parameterTracks[ti].keys.isEmpty { doc.timeline.parameterTracks.remove(at: ti) }
        revision += 1
        applyFrame()
    }

    public func moveParameterKey(_ id: String, from: Int, to: Int) {
        guard from != to, let ti = doc.timeline.parameterTracks.firstIndex(where: { $0.parameter == id }),
              let key = doc.timeline.parameterTracks[ti].keys.first(where: { $0.frame == from }) else { return }
        checkpoint("キーを動かす")
        doc.timeline.parameterTracks[ti].keys.removeAll { $0.frame == from }
        doc.timeline.parameterTracks[ti].set(frame: max(0, to), value: key.value, easing: key.easing)
        revision += 1
        applyFrame()
    }

    public func removeParameterTrack(_ id: String) {
        guard doc.timeline.parameterTracks.contains(where: { $0.parameter == id }) else { return }
        checkpoint("トラックを削除")
        doc.timeline.parameterTracks.removeAll { $0.parameter == id }
        revision += 1
    }

    // MARK: 補助

    static func contentBounds(_ n: LayerNode) -> IntRect? {
        var r: IntRect?
        func walk(_ n: LayerNode) {
            if let b = n.tiles.contentBounds() { r = r.map { $0.union(b) } ?? b }
            n.children.forEach(walk)
        }
        walk(n)
        return r
    }

    static func newID(_ prefix: String, existing: [String]) -> String {
        var i = existing.count + 1
        while existing.contains("\(prefix)\(i)") { i += 1 }
        return "\(prefix)\(i)"
    }
}
