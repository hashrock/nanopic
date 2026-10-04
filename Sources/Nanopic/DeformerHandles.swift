import AppKit
import NanopicCore

/// キャンバス上のデフォーマのハンドル。タイムラインで形を記録するパラメータを選んでいる間だけ出す
enum DeformerHandle: Hashable {
    /// 中心の点: 移動量を記録する
    case pivot(String)
    /// Option を押しながら中心の点: 基本の形の中心を置き直す
    case restPivot(String)
    case arm(String)
    case point(String, Int)
    /// ワープの点のハンドル（デフォーマ, 点, 向き 0: 右 1: 左 2: 下 3: 上）
    case tangent(String, Int, Int)
}

extension CanvasView {
    /// 形を記録する対象（パラメータと、編集中のレイヤーとその親フォルダーのデフォーマ。左の一覧で選んでいればそれだけ）。
    /// リグモードだけ（描くモードでタイムラインを出していても、変形は表示しないので出さない）
    var deformerEditing: (parameter: String, deformers: [Deformer])? {
        guard state.mode == .rig, let pid = state.editingParameter, editor.rig.parameter(pid) != nil,
              let active = editor.activeLayerID, let path = editor.doc.indexPath(of: active) else { return nil }
        var ds: [Deformer] = []
        for depth in stride(from: path.count, through: 1, by: -1) {
            if let n = editor.doc.node(at: Array(path.prefix(depth))) { ds += editor.deformers(on: n.id) }
        }
        if let sel = state.selectedDeformer, ds.contains(where: { $0.id == sel }) { ds = ds.filter { $0.id == sel } }
        return ds.isEmpty ? nil : (pid, ds)
    }

    /// 回転の腕の長さ（画面上で一定）
    var armLength: Double { 70 / Double(zoom) }

    /// 今の形（変形を表示していなければ空 = 描いた絵そのまま）
    var currentForms: [String: DeformerForm] {
        editor.showsDeformation ? editor.rig.forms(values: editor.parameterValues) : [:]
    }

    func outerMap(_ p: RigPoint, after d: Deformer, _ forms: [String: DeformerForm]) -> RigPoint {
        editor.doc.outerMap(p, after: d, forms: forms)
    }

    func localDelta(_ delta: CGPoint, at p: RigPoint, after d: Deformer, _ forms: [String: DeformerForm]) -> RigPoint {
        editor.doc.localDelta(RigPoint(delta.x, delta.y), at: p, after: d, forms: forms)
    }

    /// ハンドルの位置（キャンバス座標、今のポーズ）
    func deformerHandlePositions() -> [(DeformerHandle, CGPoint)] {
        guard let (_, ds) = deformerEditing else { return [] }
        // 変形を表示していなければ、描いた絵そのままの位置（基本の形）に出す。
        // 表示していれば、自分の形に加えて外側（親フォルダーなど）の変形もかけた、画面に見えている位置に出す
        let forms = currentForms
        var out: [(DeformerHandle, CGPoint)] = []
        func screen(_ p: RigPoint, _ d: Deformer) -> CGPoint {
            let q = outerMap(p, after: d, forms)
            return CGPoint(x: q.x, y: q.y)
        }
        for d in ds {
            let f = forms[d.id] ?? DeformerForm()
            switch d.kind {
            case .rotation:
                // 中心は移動したあとの位置、腕は画面上の中心から伸ばす（角度は外側の回転も足した向き）
                let c = screen(RigPoint(d.pivot.x + f.move.x, d.pivot.y + f.move.y), d)
                let tip = screen(d.map(RigPoint(d.pivot.x + 1, d.pivot.y), f), d)
                let a = atan2(tip.y - c.y, tip.x - c.x)
                out.append((.pivot(d.id), c))
                out.append((.arm(d.id), CGPoint(x: c.x + armLength * cos(a), y: c.y + armLength * sin(a))))
            case .warp:
                for i in 0..<d.pointCount {
                    out.append((.point(d.id, i), screen(d.map(d.restPoint(i), f), d)))
                }
                // 選んでいる点のハンドル（隣の点がある向きだけ）
                for case let .point(id, i) in selectedDeformerHandles where id == d.id && i < d.pointCount {
                    let h = d.warpHandles(i, f)
                    let c = i % (d.cols + 1), r = i / (d.cols + 1)
                    if c < d.cols { out.append((.tangent(d.id, i, 0), screen(h.point + h.u, d))) }
                    if c > 0 { out.append((.tangent(d.id, i, 1), screen(h.point - h.u, d))) }
                    if r < d.rows { out.append((.tangent(d.id, i, 2), screen(h.point + h.v, d))) }
                    if r > 0 { out.append((.tangent(d.id, i, 3), screen(h.point - h.v, d))) }
                }
            }
        }
        return out
    }

    /// ワープの格子の線（曲線に沿って細かく区切った、キャンバス座標の点の列）
    func warpGridLines(_ d: Deformer) -> [[CGPoint]] {
        let forms = currentForms
        let f = forms[d.id] ?? DeformerForm()
        let steps = 8
        func screen(_ x: Double, _ y: Double) -> CGPoint {
            let q = outerMap(d.map(RigPoint(x, y), f), after: d, forms)
            return CGPoint(x: q.x, y: q.y)
        }
        var lines: [[CGPoint]] = []
        let r = d.rect
        for row in 0...d.rows {
            let y = r.y + r.height * Double(row) / Double(d.rows)
            lines.append((0...(d.cols * steps)).map { screen(r.x + r.width * Double($0) / Double(d.cols * steps), y) })
        }
        for col in 0...d.cols {
            let x = r.x + r.width * Double(col) / Double(d.cols)
            lines.append((0...(d.rows * steps)).map { screen(x, r.y + r.height * Double($0) / Double(d.rows * steps)) })
        }
        return lines
    }

    /// 点のハンドルを自動に戻す（記録先のパラメータの形で）
    func resetWarpTangent(_ id: String, _ i: Int) {
        guard let (pid, _) = deformerEditing, let p = editor.rig.parameter(pid) else { return }
        let value = editor.parameterValue(pid)
        var f = p.form(for: id, at: value) ?? DeformerForm()
        guard i < f.tangents.count, f.tangents[i] != .zero else { return }
        f.tangents[i] = .zero
        editor.setForm(parameter: pid, value: value, deformer: id, f)
    }

    func hitDeformerHandle(_ vp: CGPoint) -> DeformerHandle? {
        let t = canvasToView
        var best: (DeformerHandle, CGFloat)?
        for (h, p) in deformerHandlePositions() {
            let q = p.applying(t)
            let d = hypot(q.x - vp.x, q.y - vp.y)
            if d < 9 && (best == nil || d < best!.1) { best = (h, d) }
        }
        return best?.0
    }

    /// ハンドルのドラッグ。start はドラッグを始めた所（キャンバス座標）、base は始めたときのパラメータの形
    func dragDeformer(_ h: DeformerHandle, start: CGPoint, base: DeformerForm, startPivot: RigPoint, cp: CGPoint) {
        guard let (pid, _) = deformerEditing, let p = editor.rig.parameter(pid) else { return }
        let value = editor.parameterValue(pid)
        let forms = currentForms
        let delta = CGPoint(x: cp.x - start.x, y: cp.y - start.y)
        switch h {
        case let .restPivot(id):
            guard let d = editor.rig.deformer(id) else { return }
            let l = localDelta(delta, at: startPivot, after: d, forms)
            editor.updateDeformer(id, label: "回転の中心") { $0.pivot = RigPoint(startPivot.x + l.x, startPivot.y + l.y) }
        case let .pivot(id):
            guard let d = editor.rig.deformer(id) else { return }
            let m = forms[id]?.move ?? .zero
            let l = localDelta(delta, at: RigPoint(d.pivot.x + m.x, d.pivot.y + m.y), after: d, forms)
            var f = base
            f.move = RigPoint(base.move.x + l.x, base.move.y + l.y)
            editor.setForm(parameter: p.id, value: value, deformer: id, f)
        case let .arm(id):
            guard let d = editor.rig.deformer(id) else { return }
            // 画面上の中心（移動と外側の変形をかけた位置）を軸に角度を測る
            let m = forms[id]?.move ?? .zero
            let cc = outerMap(RigPoint(d.pivot.x + m.x, d.pivot.y + m.y), after: d, forms)
            let c = CGPoint(x: cc.x, y: cc.y)
            let a0 = atan2(start.y - c.y, start.x - c.x), a1 = atan2(cp.y - c.y, cp.x - c.x)
            var delta = (a1 - a0) * 180 / .pi
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            var f = base
            f.angle = base.angle + delta
            editor.setForm(parameter: p.id, value: value, deformer: id, f)
        case let .tangent(id, i, dir):
            guard let d = editor.rig.deformer(id) else { return }
            // ハンドルの先を動かした量の 3 倍が、向きの変わり方（反対側のハンドルも一緒に回る）
            let h = d.warpHandles(i, forms[id] ?? DeformerForm())
            let arm: RigPoint = dir < 2 ? h.u : h.v
            let tip: RigPoint = dir == 0 || dir == 2 ? h.point + arm : h.point - arm
            let l = localDelta(delta, at: tip, after: d, forms)
            let k = dir == 0 || dir == 2 ? 3.0 : -3.0
            var f = base
            if f.tangents.count < d.pointCount { f.tangents += Array(repeating: .zero, count: d.pointCount - f.tangents.count) }
            let t = i < base.tangents.count ? base.tangents[i] : .zero
            if dir < 2 { f.tangents[i].u = t.u + l * k } else { f.tangents[i].v = t.v + l * k }
            editor.setForm(parameter: p.id, value: value, deformer: id, f)
        case let .point(id, i):
            guard let d = editor.rig.deformer(id) else { return }
            var f = base
            if f.offsets.count < d.pointCount { f.offsets += Array(repeating: .zero, count: d.pointCount - f.offsets.count) }
            let l = localDelta(delta, at: d.map(d.restPoint(i), forms[id] ?? DeformerForm()), after: d, forms)
            let o = base.offsets.indices.contains(i) ? base.offsets[i] : .zero
            f.offsets[i] = RigPoint(o.x + l.x, o.y + l.y)
            editor.setForm(parameter: p.id, value: value, deformer: id, f)
        }
    }

    /// 選んだハンドル（中心の点・ワープの点）をまとめて動かす。bases は始めたときの各デフォーマの形
    func dragDeformerGroup(start: CGPoint, bases: [String: DeformerForm], cp: CGPoint) {
        guard let (pid, _) = deformerEditing, let p = editor.rig.parameter(pid) else { return }
        let value = editor.parameterValue(pid)
        let forms = currentForms
        let delta = CGPoint(x: cp.x - start.x, y: cp.y - start.y)
        for (id, base) in bases {
            guard let d = editor.rig.deformer(id) else { continue }
            let total = forms[id] ?? DeformerForm()
            var f = base
            if f.offsets.count < d.pointCount { f.offsets += Array(repeating: .zero, count: d.pointCount - f.offsets.count) }
            for h in selectedDeformerHandles {
                switch h {
                case .pivot(id):
                    let l = localDelta(delta, at: RigPoint(d.pivot.x + total.move.x, d.pivot.y + total.move.y), after: d, forms)
                    f.move = RigPoint(base.move.x + l.x, base.move.y + l.y)
                case let .point(hid, i) where hid == id:
                    // 外側の変形をさかのぼった量を、その点のずれに足す（移動量の分はずらしたままにする）
                    let l = localDelta(delta, at: d.map(d.restPoint(i), total), after: d, forms)
                    let o = base.offsets.indices.contains(i) ? base.offsets[i] : .zero
                    f.offsets[i] = RigPoint(o.x + l.x, o.y + l.y)
                default:
                    break
                }
            }
            editor.setForm(parameter: p.id, value: value, deformer: id, f)
        }
    }

    /// 選んだハンドルが属するデフォーマの、記録先のパラメータでの形
    func baseForms(for handles: Set<DeformerHandle>) -> [String: DeformerForm] {
        guard let (pid, _) = deformerEditing, let p = editor.rig.parameter(pid) else { return [:] }
        var out: [String: DeformerForm] = [:]
        for h in handles {
            let id: String
            switch h {
            case let .pivot(i), let .point(i, _): id = i
            default: continue
            }
            out[id] = p.form(for: id, at: editor.parameterValue(pid)) ?? DeformerForm()
        }
        return out
    }

    /// 範囲選択の枠（キャンバス座標）に入るハンドル。腕は選ばない
    func deformerHandles(in rect: CGRect) -> Set<DeformerHandle> {
        Set(deformerHandlePositions().compactMap { h, p in
            if case .arm = h { return nil }
            if case .tangent = h { return nil }
            return rect.contains(p) ? h : nil
        })
    }

    /// 始めたときの、記録先のパラメータの形
    func baseForm(_ h: DeformerHandle) -> DeformerForm {
        guard let (pid, _) = deformerEditing, let p = editor.rig.parameter(pid) else { return DeformerForm() }
        let id: String
        switch h {
        case let .pivot(i), let .restPivot(i), let .arm(i): id = i
        case let .point(i, _), let .tangent(i, _, _): id = i
        }
        return p.form(for: id, at: editor.parameterValue(pid)) ?? DeformerForm()
    }
}

extension OverlayView {
    /// デフォーマのハンドルを描く（ビュー座標の変換 t）
    func drawDeformerHandles(_ ctx: CGContext, canvas: CanvasView, t: CGAffineTransform) {
        guard let (_, ds) = canvas.deformerEditing else { return }
        let handles = canvas.deformerHandlePositions()
        let selected = canvas.selectedDeformerHandles
        func fill(_ h: DeformerHandle, _ normal: NSColor) -> NSColor { selected.contains(h) ? .controlAccentColor : normal }
        func pos(_ h: DeformerHandle) -> CGPoint? { handles.first { $0.0 == h }?.1.applying(t) }
        ctx.saveGState()
        ctx.setLineWidth(1)
        for d in ds {
            switch d.kind {
            case .rotation:
                guard let c = pos(.pivot(d.id)), let a = pos(.arm(d.id)) else { continue }
                ctx.setStrokeColor(NSColor.systemOrange.cgColor)
                ctx.strokeLineSegments(between: [c, a])
                ctx.strokeEllipse(in: CGRect(x: c.x - 70, y: c.y - 70, width: 140, height: 140))
                dot(ctx, c, fill: fill(.pivot(d.id), .systemOrange))
                dot(ctx, a, fill: .white)
            case .warp:
                // 格子の線は曲線に沿って描く
                ctx.setStrokeColor(NSColor.systemTeal.withAlphaComponent(0.9).cgColor)
                for line in canvas.warpGridLines(d) {
                    ctx.addLines(between: line.map { $0.applying(t) })
                    ctx.strokePath()
                }
                // 選んでいる点のハンドル
                ctx.setStrokeColor(NSColor.systemOrange.cgColor)
                for i in 0..<d.pointCount {
                    guard let p = pos(.point(d.id, i)) else { continue }
                    for dir in 0..<4 {
                        guard let q = pos(.tangent(d.id, i, dir)) else { continue }
                        ctx.strokeLineSegments(between: [p, q])
                        let r = CGRect(x: q.x - 3.5, y: q.y - 3.5, width: 7, height: 7)
                        ctx.setFillColor(NSColor.systemOrange.cgColor)
                        ctx.fill(r)
                    }
                }
                for i in 0..<d.pointCount { if let p = pos(.point(d.id, i)) { dot(ctx, p, fill: fill(.point(d.id, i), .white)) } }
            }
        }
        // 範囲選択の枠
        if let r = canvas.handleMarquee {
            var tt = t
            ctx.addPath(CGPath(rect: r, transform: &tt))
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func dot(_ ctx: CGContext, _ p: CGPoint, fill: NSColor) {
        let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
        ctx.setFillColor(fill.cgColor)
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.strokeEllipse(in: r)
    }
}
