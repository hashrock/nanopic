import NanopicCore
import UIKit

/// 選択範囲の点線、投げなわの途中経過、変形のハンドルを重ねて表示する
final class SelectionOverlayView: UIView {
    weak var canvas: PadCanvasView?
    private var phase: CGFloat = 0
    private var timer: Timer?
    private var wasShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            phase += 1
            refresh()
        }
    }

    deinit { timer?.invalidate() }

    private var hasContent: Bool {
        guard let canvas else { return false }
        return canvas.editor.doc.selection != nil || canvas.editor.floating != nil
            || canvas.lassoPoints.count > 1 || canvas.shapePreview != nil
    }

    /// 表示するものがあるとき（または消えたとき）だけ描き直す
    func refresh() {
        let showing = hasContent
        if showing || wasShowing { setNeedsDisplay() }
        wasShowing = showing
    }

    override func draw(_ rect: CGRect) {
        guard let canvas, let ctx = UIGraphicsGetCurrentContext() else { return }
        let editor = canvas.editor
        let t = canvas.canvasToView

        if let f = editor.floating {
            if let sel = f.originalSelection {
                var tt = f.matrix.concatenating(t)
                if let path = sel.outline.copy(using: &tt) { drawAnts(ctx, path) }
            }
        } else if let sel = editor.doc.selection {
            var tt = t
            if let path = sel.outline.copy(using: &tt) { drawAnts(ctx, path) }
        }

        if let (r, ellipse) = canvas.shapePreview {
            var tt = t
            drawAnts(ctx, ellipse ? CGPath(ellipseIn: r, transform: &tt) : CGPath(rect: r, transform: &tt))
        }

        if canvas.lassoPoints.count > 1 {
            let path = CGMutablePath()
            path.addLines(between: canvas.lassoPoints.map { $0.applying(t) })
            if editor.tool == .lassoFill {
                let c = editor.mainColor
                ctx.addPath(path)
                ctx.closePath()
                ctx.setFillColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 0.4)
                ctx.fillPath()
            }
            drawAnts(ctx, path)
        }

        if let f = editor.floating, editor.tool == .transform {
            let path = CGMutablePath()
            path.addLines(between: f.corners.map { $0.applying(t) })
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setStrokeColor(UIColor.systemBlue.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            for (_, p) in f.handlePoints(t) {
                let r = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fill(r)
                ctx.setStrokeColor(UIColor.systemBlue.cgColor)
                ctx.stroke(r)
            }
        }
    }

    private func drawAnts(_ ctx: CGContext, _ path: CGPath) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineDash(phase: phase, lengths: [4, 4])
        ctx.strokePath()
        ctx.restoreGState()
    }
}
