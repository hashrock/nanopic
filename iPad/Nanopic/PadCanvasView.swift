import MetalKit
import NanopicCore
import NanopicUI
import SwiftUI
import UIKit

/// iPad のキャンバス。Metal で表示し、Apple Pencil で描き、指で表示を動かす。
/// - Apple Pencil: 描く（筆圧つき）。ダブルタップでブラシと消しゴムを切り替え
/// - 指 1 本: 表示の移動（「指で描く」がオンなら描く）
/// - 指 2 本: 移動・拡大縮小・回転。2 本指タップで取り消し、3 本指タップでやり直し
final class PadCanvasView: UIView, CanvasRenderHost, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    let state: PadState
    var editor: Editor { state.editor }
    private let mtkView = MTKView()
    private var renderer: MetalRenderer?
    private let cursor = BrushCursorView()
    private let perf = PadPerfMonitor()
    private let perfLabel = UILabel()

    // 表示変換: view = T(offset) · R(rotation) · S(zoom) · canvas
    private(set) var zoom: CGFloat = 1
    private(set) var rotation: CGFloat = 0
    private var offset = CGPoint(x: 40, y: 40)
    let backgroundGray: Double = 0.32
    var isPlaybackActive: Bool { false }
    var displayScale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }

    var canvasToView: CGAffineTransform {
        CGAffineTransform(translationX: offset.x, y: offset.y).rotated(by: rotation).scaledBy(x: zoom, y: zoom)
    }

    var viewToCanvas: CGAffineTransform { canvasToView.inverted() }

    private var didInitialFit = false

    // 入力
    private enum Action {
        case stroke
        case eyedropper
    }

    /// 描いている（またはスポイトしている）タッチ
    private var activeTouch: UITouch?
    private var action: Action?
    /// 指で描くとき、2 本目の指が来たら取り消せるよう、描き始めを少し待つ
    private var pendingFinger: (touch: UITouch, inputs: [StrokeInput], start: CGPoint, time: TimeInterval)?
    /// 指で描き始めたストローク（ジェスチャーに変わったら取り消す）
    private var fingerStroke = false

    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let rotate = UIRotationGestureRecognizer()
    private let twoFingerTap = UITapGestureRecognizer()
    private let threeFingerTap = UITapGestureRecognizer()
    private let hover = UIHoverGestureRecognizer()

    init(state: PadState) {
        self.state = state
        super.init(frame: .zero)
        backgroundColor = UIColor(white: backgroundGray, alpha: 1)
        clipsToBounds = true
        isMultipleTouchEnabled = true

        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.framebufferOnly = true
        mtkView.isUserInteractionEnabled = false
        renderer = MetalRenderer(view: mtkView)
        renderer?.canvas = self
        mtkView.delegate = renderer
        addSubview(mtkView)

        cursor.isUserInteractionEnabled = false
        cursor.isHidden = true
        addSubview(cursor)

        perfLabel.numberOfLines = 0
        perfLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        perfLabel.textColor = .white
        perfLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        perfLabel.isUserInteractionEnabled = false
        addSubview(perfLabel)
        perf.onSummary = { [weak self] text in
            guard let self else { return }
            perfLabel.text = text
            layoutPerfLabel()
        }

        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for g in [pan, pinch, rotate] as [UIGestureRecognizer] {
            g.allowedTouchTypes = direct
            g.delegate = self
            addGestureRecognizer(g)
        }
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pinch.addTarget(self, action: #selector(handlePinch(_:)))
        rotate.addTarget(self, action: #selector(handleRotate(_:)))
        pan.maximumNumberOfTouches = 2

        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = direct
        twoFingerTap.addTarget(self, action: #selector(handleUndoTap))
        addGestureRecognizer(twoFingerTap)
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.allowedTouchTypes = direct
        threeFingerTap.addTarget(self, action: #selector(handleRedoTap))
        addGestureRecognizer(threeFingerTap)
        twoFingerTap.require(toFail: threeFingerTap)

        // Apple Pencil を近づけたとき（ホバー）にブラシの大きさを見せる
        hover.addTarget(self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)

        editor.onNeedsDisplay = { [weak self] in self?.requestDisplay() }
        state.canvas = self
        updateGestureConfiguration()
        updatePerfConfiguration()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        mtkView.frame = bounds
        layoutPerfLabel()
        if !didInitialFit && bounds.width > 10 {
            didInitialFit = true
            fitToView()
        } else {
            requestDisplay()
        }
    }

    func updateGestureConfiguration() {
        // 指で描くときは、移動は 2 本指だけ
        pan.minimumNumberOfTouches = state.fingerDrawing ? 2 : 1
    }

    func updatePerfConfiguration() {
        perfLabel.isHidden = !state.perfEnabled
        renderer?.onTiming = state.perfEnabled ? { [weak self] in self?.perf.frame($0) } : nil
        if state.perfEnabled, perfLabel.text == nil { perfLabel.text = "ペンで描くと計測します" }
        if !state.perfEnabled { perf.cancel() }
        layoutPerfLabel()
    }

    private func layoutPerfLabel() {
        let size = perfLabel.sizeThatFits(CGSize(width: 340, height: CGFloat.greatestFiniteMagnitude))
        perfLabel.frame = CGRect(origin: CGPoint(x: 12, y: 72), size: size)
    }

    private func feedStroke(_ touches: [UITouch]) {
        let t0 = CACurrentMediaTime()
        for c in touches {
            if state.perfEnabled { perf.record(c, in: self) }
            editor.continueStroke(input(c))
        }
        if state.perfEnabled { perf.handler(ms: (CACurrentMediaTime() - t0) * 1000) }
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        guard state.perfEnabled else { return }
        for t in touches { perf.estimatedUpdate(t) }
    }

    func requestDisplay() {
        mtkView.setNeedsDisplay()
    }

    // MARK: - 表示変換

    func fitToView() {
        let doc = editor.doc
        guard bounds.width > 0, bounds.height > 0 else { return }
        let z = min(bounds.width / CGFloat(doc.width), bounds.height / CGFloat(doc.height)) * 0.9
        rotation = 0
        zoom = min(max(z, 0.01), 64)
        offset = CGPoint(x: (bounds.width - CGFloat(doc.width) * zoom) / 2, y: (bounds.height - CGFloat(doc.height) * zoom) / 2)
        viewChanged()
    }

    func setActualSize() {
        zoom(to: 1, around: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func zoom(to z: CGFloat, around viewPoint: CGPoint) {
        let c = viewPoint.applying(viewToCanvas)
        zoom = min(max(z, 0.01), 64)
        let t = CGAffineTransform(rotationAngle: rotation).scaledBy(x: zoom, y: zoom)
        let m = c.applying(t)
        offset = CGPoint(x: viewPoint.x - m.x, y: viewPoint.y - m.y)
        viewChanged()
    }

    func rotate(by delta: CGFloat, around viewPoint: CGPoint) {
        let c = viewPoint.applying(viewToCanvas)
        rotation += delta
        let t = CGAffineTransform(rotationAngle: rotation).scaledBy(x: zoom, y: zoom)
        let m = c.applying(t)
        offset = CGPoint(x: viewPoint.x - m.x, y: viewPoint.y - m.y)
        viewChanged()
    }

    func resetRotation() {
        rotate(by: -rotation, around: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    private func viewChanged() {
        state.zoom = Double(zoom)
        state.rotationDegrees = Double(rotation * 180 / .pi)
        requestDisplay()
    }

    // MARK: - タッチ（描く）

    private func input(_ t: UITouch) -> StrokeInput {
        let p = t.preciseLocation(in: self).applying(viewToCanvas)
        let pressure: Double
        if t.type == .pencil, t.maximumPossibleForce > 0 {
            pressure = min(1, Double(t.force / t.maximumPossibleForce) * 1.6)
        } else {
            pressure = 1
        }
        return StrokeInput(x: Double(p.x), y: Double(p.y), pressure: pressure, time: t.timestamp)
    }

    private func directTouchCount(_ event: UIEvent?) -> Int {
        event?.allTouches?.filter { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled }.count ?? 0
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if t.type == .pencil {
                // ペンが来たら、指で描きかけていたものは捨てる
                pendingFinger = nil
                if activeTouch == nil || activeTouch?.type != .pencil {
                    if fingerStroke { cancelFingerStroke() }
                    begin(t, event: event)
                }
            } else if t.type == .direct, state.fingerDrawing, activeTouch == nil {
                if directTouchCount(event) == 1 {
                    pendingFinger = (t, [input(t)], t.location(in: self), t.timestamp)
                } else {
                    pendingFinger = nil
                }
            }
        }
        if let p = pendingFinger, directTouchCount(event) > 1 || !touches.contains(p.touch) && touches.contains(where: { $0.type == .direct }) {
            pendingFinger = nil
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let p = pendingFinger, touches.contains(p.touch) {
            let loc = p.touch.location(in: self)
            var inputs = p.inputs
            for c in event?.coalescedTouches(for: p.touch) ?? [p.touch] { inputs.append(input(c)) }
            pendingFinger?.inputs = inputs
            // 少し動くか少し待ってから描き始める（2 本指の操作と区別する）
            if hypot(loc.x - p.start.x, loc.y - p.start.y) > 8 || p.touch.timestamp - p.time > 0.12 {
                pendingFinger = nil
                if directTouchCount(event) == 1 {
                    startFingerStroke(p.touch, inputs: inputs)
                }
            }
            return
        }
        guard let t = activeTouch, touches.contains(t) else { return }
        switch action {
        case .stroke:
            feedStroke(event?.coalescedTouches(for: t) ?? [t])
            updateCursor(at: t.location(in: self), visible: t.type == .pencil)
        case .eyedropper:
            pick(t.location(in: self))
        case nil:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let p = pendingFinger, touches.contains(p.touch) {
            // 指で軽く触っただけ: 点を描く（塗りつぶし・スポイトはその場所で）
            pendingFinger = nil
            if directTouchCount(event) == 0 {
                startFingerStroke(p.touch, inputs: p.inputs)
                end()
            }
            return
        }
        guard let t = activeTouch, touches.contains(t) else { return }
        if action == .stroke {
            feedStroke(event?.coalescedTouches(for: t) ?? [])
        }
        end()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let p = pendingFinger, touches.contains(p.touch) { pendingFinger = nil }
        guard let t = activeTouch, touches.contains(t) else { return }
        if fingerStroke {
            // 指のストロークがジェスチャーに変わった: なかったことにする
            cancelFingerStroke()
        } else {
            end()
        }
    }

    private func startFingerStroke(_ t: UITouch, inputs: [StrokeInput]) {
        guard let first = inputs.first else { return }
        if begin(t, event: nil, firstInput: first) {
            fingerStroke = action == .stroke
            if action == .stroke {
                for i in inputs.dropFirst() { editor.continueStroke(i) }
            }
        }
    }

    /// タッチでツールを使い始める。ストロークを始めたら true
    @discardableResult
    private func begin(_ t: UITouch, event: UIEvent?, firstInput: StrokeInput? = nil) -> Bool {
        let vp = t.location(in: self)
        let cp = vp.applying(viewToCanvas)
        switch editor.tool {
        case .brush, .eraser:
            let i = firstInput ?? input(t)
            let beginStart = CACurrentMediaTime()
            if editor.beginStroke(i, usePressure: t.type == .pencil, zoom: Double(zoom)) {
                if state.perfEnabled {
                    let b = editor.currentBrush
                    let doc = editor.doc
                    let meta = String(format: "%dx%d 層%d %.0fpx 手ブレ%.0f 倍率%.2f", doc.width, doc.height, doc.layers.count,
                                      Double(b.size), Double(b.smoothing) * 100, Double(zoom))
                    perf.begin(meta: meta, beginMs: (CACurrentMediaTime() - beginStart) * 1000)
                    perf.record(t, in: self)
                }
                activeTouch = t
                action = .stroke
                updateCursor(at: vp, visible: t.type == .pencil)
                return true
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                state.show(lockedMessage)
            }
        case .fill:
            if editor.canPaintOnActiveLayer {
                editor.fill(atX: Int(floor(cp.x)), y: Int(floor(cp.y)))
            } else {
                state.show(lockedMessage)
            }
        case .eyedropper:
            activeTouch = t
            action = .eyedropper
            pick(vp)
        default:
            break
        }
        return false
    }

    private var lockedMessage: String {
        guard let l = editor.doc.activeLayer else { return "描けるレイヤーがありません" }
        if l.isFolder { return "フォルダーには描けません" }
        if l.locked { return "レイヤーがロックされています" }
        if !l.visible { return "非表示のレイヤーには描けません" }
        return "このレイヤーには描けません"
    }

    private func end() {
        if action == .stroke {
            let t0 = CACurrentMediaTime()
            editor.endStroke()
            if state.perfEnabled { perf.end(endMs: (CACurrentMediaTime() - t0) * 1000, dabs: editor.strokeDabCount) }
        }
        activeTouch = nil
        action = nil
        fingerStroke = false
        cursor.isHidden = true
    }

    private func cancelFingerStroke() {
        perf.cancel()
        if action == .stroke {
            editor.endStroke()
            editor.undo()
        }
        activeTouch = nil
        action = nil
        fingerStroke = false
    }

    private func pick(_ vp: CGPoint) {
        let cp = vp.applying(viewToCanvas)
        if let c = editor.pickColor(x: Int(floor(cp.x)), y: Int(floor(cp.y))) {
            editor.mainColor = c
        }
    }

    // MARK: - ジェスチャー（表示）

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let nav: [UIGestureRecognizer] = [pan, pinch, rotate]
        return nav.contains(g) && nav.contains(other)
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // Apple Pencil で描いている間も指で表示は動かせる。指で描いている途中に 2 本目が来たら表示の操作に切り替える
        true
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let d = g.translation(in: self)
        offset.x += d.x
        offset.y += d.y
        g.setTranslation(.zero, in: self)
        viewChanged()
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard g.numberOfTouches >= 2 else { return }
        zoom(to: zoom * g.scale, around: g.location(in: self))
        g.scale = 1
    }

    @objc private func handleRotate(_ g: UIRotationGestureRecognizer) {
        guard g.numberOfTouches >= 2 else { return }
        rotate(by: g.rotation, around: g.location(in: self))
        g.rotation = 0
        if g.state == .ended {
            // 0° 付近で離したらまっすぐに戻す
            let deg = rotation * 180 / .pi
            let r = deg.truncatingRemainder(dividingBy: 360)
            if abs(r) < 4 || abs(abs(r) - 360) < 4 { resetRotation() }
        }
    }

    @objc private func handleUndoTap() {
        guard activeTouch == nil || fingerStroke else { return }
        if fingerStroke { cancelFingerStroke() }
        if editor.undoLabel != nil {
            let label = editor.undoLabel ?? ""
            editor.undo()
            state.show("取り消し: \(label)")
        }
    }

    @objc private func handleRedoTap() {
        guard activeTouch == nil else { return }
        if let label = editor.redoLabel {
            editor.redo()
            state.show("やり直し: \(label)")
        }
    }

    // MARK: - Apple Pencil

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            updateCursor(at: g.location(in: self), visible: true)
        default:
            if activeTouch == nil { cursor.isHidden = true }
        }
    }

    private func updateCursor(at vp: CGPoint, visible: Bool) {
        guard visible, [.brush, .eraser].contains(editor.tool) else {
            cursor.isHidden = true
            return
        }
        let d = max(4, CGFloat(editor.currentBrush.size) * zoom)
        cursor.bounds = CGRect(x: 0, y: 0, width: d + 2, height: d + 2)
        cursor.center = vp
        cursor.isHidden = false
        cursor.setNeedsDisplay()
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        handlePencilTap(UIPencilInteraction.preferredTapAction)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        handlePencilTap(UIPencilInteraction.preferredTapAction)
    }

    private var toolBeforeEraser: Tool = .brush

    private func handlePencilTap(_ action: UIPencilPreferredAction) {
        switch action {
        case .ignore:
            return
        case .showColorPalette:
            state.showColorPanelRequest += 1
        default:
            // ブラシ ⇄ 消しゴム（直前のツールに戻す設定でも同じ動き）
            if editor.tool == .eraser {
                editor.selectTool(toolBeforeEraser == .eraser ? .brush : toolBeforeEraser)
            } else {
                toolBeforeEraser = editor.tool
                editor.selectTool(.eraser)
            }
        }
    }
}

/// ブラシの大きさを示す円
final class BrushCursorView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.6).cgColor)
        ctx.strokeEllipse(in: r)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
        ctx.strokeEllipse(in: r.insetBy(dx: 1, dy: 1))
    }
}

/// SwiftUI に載せるためのラッパー
struct CanvasRepresentable: UIViewRepresentable {
    let state: PadState

    func makeUIView(context: Context) -> PadCanvasView {
        PadCanvasView(state: state)
    }

    func updateUIView(_ view: PadCanvasView, context: Context) {}
}
