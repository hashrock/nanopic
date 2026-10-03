import AppKit
import NanopicCore

/// キャンバス上のデフォーマのハンドル。タイムラインで形を記録するパラメータを選んでいる間だけ出す
enum DeformerHandle: Equatable {
    /// 中心の点: 移動量を記録する
    case pivot(String)
    /// Option を押しながら中心の点: 基本の形の中心を置き直す
    case restPivot(String)
    case arm(String)
    case point(String, Int)
}

extension CanvasView {
    /// 形を記録する対象（パラメータと、編集中のレイヤーとその親フォルダーのデフォーマ）
    var deformerEditing: (parameter: String, deformers: [Deformer])? {
        guard state.timelineOpen, let pid = state.editingParameter, editor.rig.parameter(pid) != nil,
              let active = editor.activeLayerID, let path = editor.doc.indexPath(of: active) else { return nil }
        var ds: [Deformer] = []
        for depth in stride(from: path.count, through: 1, by: -1) {
            if let n = editor.doc.node(at: Array(path.prefix(depth))) { ds += editor.deformers(on: n.id) }
        }
        return ds.isEmpty ? nil : (pid, ds)
    }

    /// 回転の腕の長さ（画面上で一定）
    var armLength: Double { 70 / Double(zoom) }

    /// ハンドルの位置（キャンバス座標、今のポーズ）
    func deformerHandlePositions() -> [(DeformerHandle, CGPoint)] {
        guard let (_, ds) = deformerEditing else { return [] }
        // 変形を表示していなければ、描いた絵そのままの位置（基本の形）に出す
        let forms = editor.showsDeformation ? editor.rig.forms(values: editor.parameterValues) : [:]
        var out: [(DeformerHandle, CGPoint)] = []
        for d in ds {
            let f = forms[d.id] ?? DeformerForm()
            switch d.kind {
            case .rotation:
                // 中心も腕も、移動したあとの位置に出す
                let a = f.angle * .pi / 180
                let c = CGPoint(x: d.pivot.x + f.move.x, y: d.pivot.y + f.move.y)
                out.append((.pivot(d.id), c))
                out.append((.arm(d.id), CGPoint(x: c.x + armLength * cos(a), y: c.y + armLength * sin(a))))
            case .warp:
                for i in 0..<d.pointCount {
                    let p = d.map(d.restPoint(i), f)
                    out.append((.point(d.id, i), CGPoint(x: p.x, y: p.y)))
                }
            }
        }
        return out
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
        switch h {
        case let .restPivot(id):
            editor.updateDeformer(id, label: "回転の中心") { $0.pivot = RigPoint(startPivot.x + cp.x - start.x, startPivot.y + cp.y - start.y) }
        case let .pivot(id):
            var f = base
            f.move = RigPoint(base.move.x + cp.x - start.x, base.move.y + cp.y - start.y)
            editor.setForm(parameter: p.id, value: value, deformer: id, f)
        case let .arm(id):
            guard let d = editor.rig.deformer(id) else { return }
            // 移動したあとの中心を軸に角度を測る
            let m = editor.showsDeformation ? (editor.rig.forms(values: editor.parameterValues)[id]?.move ?? .zero) : .zero
            let c = CGPoint(x: d.pivot.x + m.x, y: d.pivot.y + m.y)
            let a0 = atan2(start.y - c.y, start.x - c.x), a1 = atan2(cp.y - c.y, cp.x - c.x)
            var delta = (a1 - a0) * 180 / .pi
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            var f = base
            f.angle = base.angle + delta
            editor.setForm(parameter: p.id, value: value, deformer: id, f)
        case let .point(id, i):
            guard let d = editor.rig.deformer(id) else { return }
            var f = base
            if f.offsets.count < d.pointCount { f.offsets += Array(repeating: .zero, count: d.pointCount - f.offsets.count) }
            let o = base.offsets.indices.contains(i) ? base.offsets[i] : .zero
            f.offsets[i] = RigPoint(o.x + cp.x - start.x, o.y + cp.y - start.y)
            editor.setForm(parameter: p.id, value: value, deformer: id, f)
        }
    }

    /// 始めたときの、記録先のパラメータの形
    func baseForm(_ h: DeformerHandle) -> DeformerForm {
        guard let (pid, _) = deformerEditing, let p = editor.rig.parameter(pid) else { return DeformerForm() }
        let id: String
        switch h {
        case let .pivot(i), let .restPivot(i), let .arm(i): id = i
        case let .point(i, _): id = i
        }
        return p.form(for: id, at: editor.parameterValue(pid)) ?? DeformerForm()
    }
}

extension OverlayView {
    /// デフォーマのハンドルを描く（ビュー座標の変換 t）
    func drawDeformerHandles(_ ctx: CGContext, canvas: CanvasView, t: CGAffineTransform) {
        guard let (_, ds) = canvas.deformerEditing else { return }
        let handles = canvas.deformerHandlePositions()
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
                dot(ctx, c, fill: .systemOrange)
                dot(ctx, a, fill: .white)
            case .warp:
                let w = d.cols + 1
                ctx.setStrokeColor(NSColor.systemTeal.withAlphaComponent(0.9).cgColor)
                for r in 0...d.rows {
                    for c in 0...d.cols {
                        guard let p = pos(.point(d.id, r * w + c)) else { continue }
                        if c < d.cols, let q = pos(.point(d.id, r * w + c + 1)) { ctx.strokeLineSegments(between: [p, q]) }
                        if r < d.rows, let q = pos(.point(d.id, (r + 1) * w + c)) { ctx.strokeLineSegments(between: [p, q]) }
                    }
                }
                for i in 0..<d.pointCount { if let p = pos(.point(d.id, i)) { dot(ctx, p, fill: .white) } }
            }
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
