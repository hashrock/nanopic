import AppKit
import NanopicCore
import SwiftUI

// パラメータ・デフォーマ・レイヤーのつながりを見せる・たどる（リグモード）

extension AppState {
    /// 指しているものと関係するもの（リグモードで何かを指しているときだけ）
    var rigFocus: RigFocus? {
        guard mode == .rig, let t = rigHover else { return nil }
        let f = editor.doc.rigFocus(t)
        return f.isEmpty ? nil : f
    }

    /// カーソルが乗った・外れた。外れたときは、まだ外側の行に乗っていれば outer に戻す
    func hoverRig(_ target: RigLinkTarget, _ hovering: Bool, outer: RigLinkTarget? = nil) {
        if hovering {
            rigHover = target
        } else if rigHover == target {
            rigHover = outer
        }
    }

    /// デフォーマへ移る: 付いているレイヤーを編集中にして（親フォルダーを開く）、そのデフォーマのハンドルだけを出す
    func revealDeformer(_ id: String) {
        guard let d = editor.rig.deformer(id), let n = editor.doc.node(psdID: d.layer) else { return }
        revealLayer(n.id)
        selectedDeformer = id
    }

    /// レイヤーへ移る: 編集中にして、レイヤーの一覧で見えるよう親フォルダーを開く
    func revealLayer(_ id: UUID) {
        if let path = editor.doc.indexPath(of: id) {
            for depth in stride(from: path.count - 1, through: 1, by: -1) {
                if let p = editor.doc.node(at: Array(path.prefix(depth))), !p.expanded {
                    editor.setLayerUIState(p.id) { $0.expanded = true }
                }
            }
        }
        editor.setActiveLayer(id)
    }

    /// パラメータへ移る: 形を記録する対象にする（リグのパネルはそこまで送る）
    func revealParameter(_ id: String) {
        editingParameter = id
    }
}

/// つながり先を表す小さな札。クリックで移り、カーソルを乗せると関係するものを光らせる
struct RigLinkChip: View {
    let state: AppState
    let target: RigLinkTarget
    let systemImage: String
    let title: String
    var detail: String?
    /// 札を含む行のつながり（札から外れたとき、行の光らせ方に戻す）
    var outer: RigLinkTarget?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 9))
                Text(title).lineLimit(1)
                if let detail { Text(detail).foregroundStyle(.secondary).lineLimit(1) }
            }
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(hovering ? Color.orange.opacity(0.3) : Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in
            hovering = h
            state.hoverRig(target, h, outer: outer)
        }
    }
}

/// 札を横に並べ、入りきらなければ折り返す
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let w = rows.map { $0.width }.max() ?? 0
        let h = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var cur: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let w = cur.indices.isEmpty ? s.width : cur.width + spacing + s.width
            if w > width && !cur.indices.isEmpty {
                rows.append(cur)
                cur = ([i], s.width, s.height)
            } else {
                cur = (cur.indices + [i], w, max(cur.height, s.height))
            }
        }
        if !cur.indices.isEmpty { rows.append(cur) }
        return rows
    }
}

extension OverlayView {
    /// 指しているものと関係するレイヤーの輪郭と、デフォーマの中心・範囲を光らせる
    func drawRigFocus(_ ctx: CGContext, canvas: CanvasView, t: CGAffineTransform) {
        guard let focus = canvas.state.rigFocus else { return }
        let doc = canvas.editor.doc
        let forms = canvas.currentForms
        let color = NSColor.systemOrange
        ctx.saveGState()
        // 付いているレイヤー（フォルダーなら中身全部）の輪郭
        for id in focus.layers {
            guard let pts = doc.posedOutline(of: id, forms: forms), pts.count > 2 else { continue }
            let path = CGMutablePath()
            path.addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y).applying(t) })
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(color.withAlphaComponent(0.1).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        // デフォーマの中心（移動・回転）と範囲（ワープ）
        for d in doc.rig.deformers where focus.deformers.contains(d.id) {
            let f = forms[d.id] ?? DeformerForm()
            switch d.kind {
            case .rotation:
                let q = doc.outerMap(d.pivot + f.move, after: d, forms: forms)
                let c = CGPoint(x: q.x, y: q.y).applying(t)
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18))
                ctx.strokeLineSegments(between: [CGPoint(x: c.x - 14, y: c.y), CGPoint(x: c.x + 14, y: c.y),
                                                 CGPoint(x: c.x, y: c.y - 14), CGPoint(x: c.x, y: c.y + 14)])
            case .warp:
                let r = d.rect
                let corners = [RigPoint(r.x, r.y), RigPoint(r.x + r.width, r.y), RigPoint(r.x + r.width, r.y + r.height), RigPoint(r.x, r.y + r.height)]
                let path = CGMutablePath()
                path.addLines(between: corners.map { p in
                    let q = doc.outerMap(d.map(p, f), after: d, forms: forms)
                    return CGPoint(x: q.x, y: q.y).applying(t)
                })
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(2)
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }
}
