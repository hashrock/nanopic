import AppKit
import MetalKit
import NanopicCore
import SwiftUI

/// キャンバス。Metal で画像を表示し、上に補助表示（グリッド・選択範囲・ハンドル）を重ねる。
/// マウス・ペンタブレットのイベントはすべてこのビューで受ける。
final class CanvasView: NSView {
    let state: AppState
    var editor: Editor { state.editor }
    private let mtkView: MTKView
    private var renderer: MetalRenderer?
    let overlay: OverlayView

    // 表示変換: view = T(offset) · R(rotation) · S(zoom) · canvas
    private(set) var zoom: CGFloat = 1
    private(set) var rotation: CGFloat = 0
    private var offset = CGPoint(x: 40, y: 40)
    let backgroundGray: Double = 0.32

    var canvasToView: CGAffineTransform {
        CGAffineTransform(translationX: offset.x, y: offset.y).rotated(by: rotation).scaledBy(x: zoom, y: zoom)
    }

    var viewToCanvas: CGAffineTransform { canvasToView.inverted() }

    // 入力状態
    private enum Drag {
        case none
        case stroke
        case pan(start: CGPoint, startOffset: CGPoint)
        case zoomDrag(start: CGPoint, startZoom: CGFloat, anchor: CGPoint)
        case brushSize(start: CGPoint, startSize: Float)
        case selectShape(start: CGPoint, ellipse: Bool, op: SelectionOp)
        case lasso(op: SelectionOp)
        case lassoFill(erase: Bool)
        case transform(handle: TransformHandle, startCanvas: CGPoint, startParams: TransformParams)
        case move(startCanvas: CGPoint, startParams: TransformParams)
        case eyedropper
        case deformer(DeformerHandle, start: CGPoint, base: DeformerForm, startPivot: RigPoint)
        case deformerGroup(start: CGPoint, bases: [String: DeformerForm])
        case handleMarquee(start: CGPoint, initial: Set<DeformerHandle>)
        case publishFrame(handle: Int, start: IntRect, startPoint: CGPoint)
    }

    enum TransformHandle: Equatable {
        case corner(Int)   // 0:左上 1:右上 2:右下 3:左下
        case edge(Int)     // 0:上 1:右 2:下 3:左
        case inside
        case rotate
    }

    private var drag: Drag = .none
    /// 選んでいるデフォーマのハンドル（まとめて動かす）
    var selectedDeformerHandles: Set<DeformerHandle> = []
    /// ハンドルを囲んでいる枠（キャンバス座標）
    private(set) var handleMarquee: CGRect?
    private(set) var spaceHeld = false
    private var eraserInProximity = false
    private var toolBeforeEraser: Tool?
    var mouseViewPoint: CGPoint?
    var lassoPoints: [CGPoint] = []
    var shapePreview: (rect: CGRect, ellipse: Bool)?
    private var didInitialFit = false

    init(state: AppState) {
        self.state = state
        mtkView = MTKView(frame: .zero)
        overlay = OverlayView(frame: .zero)
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.framebufferOnly = true
        mtkView.autoresizingMask = [.width, .height]
        renderer = MetalRenderer(view: mtkView)
        renderer?.canvas = self
        mtkView.delegate = renderer
        if let layer = mtkView.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        addSubview(mtkView)
        overlay.autoresizingMask = [.width, .height]
        overlay.clipsToBounds = true
        overlay.canvas = self
        addSubview(overlay)
        editor.onNeedsDisplay = { [weak self] in self?.requestDisplay() }
        state.canvasView = self
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }

    private var keyObserver: NSObjectProtocol?
    private var closeGuard: WindowCloseGuard?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        guard let window else { return }
        if closeGuard?.window !== window { closeGuard = WindowCloseGuard(window: window, state: state) }
        // SwiftUI がテキスト欄に自動でフォーカスを移すと単キーのショートカットが効かなくなるため、
        // ウィンドウがアクティブになったらキャンバスにフォーカスを戻す
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func layout() {
        super.layout()
        mtkView.frame = bounds
        overlay.frame = bounds
        if !didInitialFit && bounds.width > 10 {
            didInitialFit = true
            fitToWindow()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    func requestDisplay() {
        mtkView.needsDisplay = true
        overlay.needsDisplay = true
    }

    // MARK: - 表示変換

    func fitToWindow() {
        let doc = editor.doc
        guard bounds.width > 0, bounds.height > 0 else { return }
        let z = min(bounds.width / CGFloat(doc.width), bounds.height / CGFloat(doc.height)) * 0.92
        rotation = 0
        zoom = min(max(z, 0.01), 64)
        offset = CGPoint(x: (bounds.width - CGFloat(doc.width) * zoom) / 2, y: (bounds.height - CGFloat(doc.height) * zoom) / 2)
        viewChanged()
    }

    /// ドキュメントの rect が画面いっぱいに見えるようにする
    func show(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0, rect.width > 0, rect.height > 0 else { return }
        rotation = 0
        zoom = min(max(min(bounds.width / rect.width, bounds.height / rect.height) * 0.92, 0.01), 64)
        offset = CGPoint(x: bounds.midX - rect.midX * zoom, y: bounds.midY - rect.midY * zoom)
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

    func zoomStep(_ inward: Bool) {
        let steps: [CGFloat] = [0.02, 0.03, 0.05, 0.0625, 0.08, 0.1, 0.125, 0.167, 0.2, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]
        let next = inward ? steps.first { $0 > zoom * 1.01 } : steps.last { $0 < zoom / 1.01 }
        let anchor = mouseViewPoint.flatMap { bounds.contains($0) ? $0 : nil } ?? CGPoint(x: bounds.midX, y: bounds.midY)
        zoom(to: next ?? zoom, around: anchor)
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

    // MARK: - 座標

    private func viewPoint(_ e: NSEvent) -> CGPoint {
        convert(e.locationInWindow, from: nil)
    }

    private func canvasPoint(_ e: NSEvent) -> CGPoint {
        viewPoint(e).applying(viewToCanvas)
    }

    private func isTablet(_ e: NSEvent) -> Bool {
        e.subtype == .tabletPoint
    }

    private func strokeInput(_ e: NSEvent) -> StrokeInput {
        let p = canvasPoint(e)
        return StrokeInput(x: Double(p.x), y: Double(p.y), pressure: isTablet(e) ? Double(e.pressure) : 1, time: e.timestamp)
    }

    private func selectionOp(_ flags: NSEvent.ModifierFlags) -> SelectionOp {
        let shift = flags.contains(.shift), opt = flags.contains(.option)
        if shift && opt { return .intersect }
        if shift { return .add }
        if opt { return .subtract }
        return .replace
    }

    /// 修飾キーを考慮した実際のツール
    func effectiveTool(_ flags: NSEvent.ModifierFlags) -> Tool {
        if spaceHeld { return flags.contains(.command) ? .zoom : .hand }
        let t = editor.tool
        if flags.contains(.option) && !flags.contains(.command) && [.brush, .eraser, .fill, .lassoFill].contains(t) { return .eyedropper }
        return t
    }

    // MARK: - マウス / ペン

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        state.timelineFocused = false
        let vp = viewPoint(e)
        let cp = vp.applying(viewToCanvas)
        mouseViewPoint = vp
        let flags = e.modifierFlags
        // Cmd+Option ドラッグでブラシサイズ変更
        if flags.contains(.command) && flags.contains(.option) && [.brush, .eraser].contains(editor.tool) {
            drag = .brushSize(start: vp, startSize: editor.currentBrush.size)
            return
        }
        // 書き出し設定を開いている間は、書き出し枠だけを動かす（手のひら・ズームは使える）
        if let d = state.publishDraft {
            if let h = hitPublishFrame(vp) {
                drag = .publishFrame(handle: h, start: d.resolvedRect(canvas: editor.doc.bounds), startPoint: cp)
                return
            }
            if ![.hand, .zoom].contains(effectiveTool(flags)) { return }
        }
        // デフォーマのハンドル（形を記録するパラメータを選んでいる間）
        if let h = hitDeformerHandle(vp) {
            if case let .pivot(id) = h, flags.contains(.option) {
                // Option を押しながらなら、基本の形の中心を置き直す
                let pivot = editor.rig.deformer(id)?.pivot ?? .zero
                drag = .deformer(.restPivot(id), start: cp, base: baseForm(h), startPivot: pivot)
                return
            }
            // 腕とワープのハンドルは 1 つずつ動かす（選択は変えない）
            if case .arm = h {
                drag = .deformer(h, start: cp, base: baseForm(h), startPivot: .zero)
                return
            }
            if case .tangent = h {
                drag = .deformer(h, start: cp, base: baseForm(h), startPivot: .zero)
                return
            }
            // Shift なら選択に足す・外すだけ
            if flags.contains(.shift) {
                if selectedDeformerHandles.contains(h) { selectedDeformerHandles.remove(h) } else { selectedDeformerHandles.insert(h) }
                overlay.needsDisplay = true
                return
            }
            if !selectedDeformerHandles.contains(h) { selectedDeformerHandles = [h] }
            drag = .deformerGroup(start: cp, bases: baseForms(for: selectedDeformerHandles))
            return
        }
        // リグモードの矩形選択は、ハンドルを囲んで選ぶ（画素の選択範囲は作らない）
        if state.mode == .rig && effectiveTool(flags) == .selectRect {
            let initial = flags.contains(.shift) ? selectedDeformerHandles : []
            selectedDeformerHandles = initial
            if deformerEditing != nil { drag = .handleMarquee(start: cp, initial: initial) }
            overlay.needsDisplay = true
            return
        }
        temporaryTool?.used = true
        let tool = effectiveTool(flags)
        switch tool {
        case .brush, .eraser:
            if editor.beginStroke(strokeInput(e), usePressure: isTablet(e), zoom: Double(zoom)) {
                drag = .stroke
            } else {
                NSSound.beep()
            }
        case .fill:
            editor.fill(atX: Int(floor(cp.x)), y: Int(floor(cp.y)))
        case .wand:
            editor.wandSelect(atX: Int(floor(cp.x)), y: Int(floor(cp.y)), op: selectionOp(flags))
        case .selectRect, .selectEllipse:
            editor.commitTransform()
            drag = .selectShape(start: cp, ellipse: tool == .selectEllipse, op: selectionOp(flags))
        case .lasso:
            editor.commitTransform()
            lassoPoints = [cp]
            drag = .lasso(op: selectionOp(flags))
        case .lassoFill, .lassoErase:
            editor.commitTransform()
            guard editor.canPaintOnActiveLayer else {
                NSSound.beep()
                return
            }
            lassoPoints = [cp]
            drag = .lassoFill(erase: tool == .lassoErase)
        case .move:
            // 既に持ち上げていればそのまま続けて動かす（確定は選択解除・Return・他ツールの使用時）
            if editor.floating != nil || editor.beginTransform(), let f = editor.floating {
                editor.recordTransformStep()
                drag = .move(startCanvas: cp, startParams: f.params)
            } else {
                NSSound.beep()
            }
        case .transform:
            if editor.floating == nil && !editor.beginTransform() {
                NSSound.beep()
                return
            }
            guard let f = editor.floating else { return }
            editor.recordTransformStep()
            drag = .transform(handle: hitHandle(vp, f), startCanvas: cp, startParams: f.params)
        case .eyedropper:
            pick(at: cp, flags: flags)
            drag = .eyedropper
        case .hand:
            drag = .pan(start: vp, startOffset: offset)
            NSCursor.closedHand.set()
        case .zoom:
            drag = .zoomDrag(start: vp, startZoom: zoom, anchor: vp)
        }
        overlay.needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let vp = viewPoint(e)
        let cp = vp.applying(viewToCanvas)
        mouseViewPoint = vp
        switch drag {
        case .stroke:
            editor.continueStroke(strokeInput(e))
        case let .pan(start, startOffset):
            offset = CGPoint(x: startOffset.x + vp.x - start.x, y: startOffset.y + vp.y - start.y)
            viewChanged()
        case let .zoomDrag(start, startZoom, anchor):
            let f = pow(1.01, vp.x - start.x)
            zoom(to: startZoom * f, around: anchor)
        case let .brushSize(start, startSize):
            let d = Float(vp.x - start.x)
            editor.setBrushSize(max(0.5, startSize + d * max(1, startSize / 60)))
        case let .selectShape(start, ellipse, _):
            var r = CGRect(x: min(start.x, cp.x), y: min(start.y, cp.y), width: abs(cp.x - start.x), height: abs(cp.y - start.y))
            // ドラッグ中の Shift は正方形・正円
            if e.modifierFlags.contains(.shift) {
                let s = max(r.width, r.height)
                r = CGRect(x: cp.x < start.x ? start.x - s : start.x, y: cp.y < start.y ? start.y - s : start.y, width: s, height: s)
            }
            shapePreview = (r, ellipse)
        case .lasso, .lassoFill:
            if let last = lassoPoints.last, hypot(last.x - cp.x, last.y - cp.y) * zoom > 1.5 {
                lassoPoints.append(cp)
            }
        case let .move(startCanvas, startParams):
            // 移動は整数ピクセル単位（再サンプリングでぼけないように）
            var p = startParams
            p.tx = (startParams.tx + Double(cp.x - startCanvas.x)).rounded()
            p.ty = (startParams.ty + Double(cp.y - startCanvas.y)).rounded()
            editor.updateTransform(p)
        case let .transform(handle, startCanvas, startParams):
            dragTransform(handle: handle, startCanvas: startCanvas, startParams: startParams, cp: cp, shift: e.modifierFlags.contains(.shift))
        case .eyedropper:
            pick(at: cp, flags: e.modifierFlags)
        case let .deformer(h, start, base, startPivot):
            dragDeformer(h, start: start, base: base, startPivot: startPivot, cp: cp)
        case let .deformerGroup(start, bases):
            dragDeformerGroup(start: start, bases: bases, cp: cp)
        case let .publishFrame(handle, start, startPoint):
            if var d = state.publishDraft {
                let canvas = editor.doc.bounds
                // 比を固定していればその比、Shift を押している間は始めたときの比を保つ
                let ratio = d.aspect?.ratio ?? (e.modifierFlags.contains(.shift) ? Double(start.width) / Double(start.height) : nil)
                d.rect = Publish.dragRect(start, handle: handle, dx: Double(cp.x - startPoint.x), dy: Double(cp.y - startPoint.y),
                                          aspect: ratio, canvas: canvas)
                state.publishDraft = d
            }
        case let .handleMarquee(start, initial):
            let r = CGRect(x: min(start.x, cp.x), y: min(start.y, cp.y), width: abs(cp.x - start.x), height: abs(cp.y - start.y))
            handleMarquee = r
            selectedDeformerHandles = initial.union(deformerHandles(in: r))
        case .none:
            break
        }
        overlay.needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        handleMarquee = nil
        switch drag {
        case .stroke:
            editor.endStroke()
        case .pan:
            cursorUpdate(with: e)
        case let .selectShape(_, ellipse, op):
            if var r = shapePreview?.rect, r.width * zoom > 2 || r.height * zoom > 2 {
                if !ellipse {
                    // 矩形選択はピクセル境界に揃える（境界の半端な選択で縁が残らないように）
                    r = CGRect(x: r.minX.rounded(), y: r.minY.rounded(),
                               width: r.maxX.rounded() - r.minX.rounded(), height: r.maxY.rounded() - r.minY.rounded())
                }
                let path = ellipse ? CGPath(ellipseIn: r, transform: nil) : CGPath(rect: r, transform: nil)
                editor.select(path: path, op: op)
            } else if op == .replace {
                editor.deselect()
            }
            shapePreview = nil
        case let .lasso(op):
            if lassoPoints.count > 2 {
                let path = CGMutablePath()
                path.addLines(between: lassoPoints)
                path.closeSubpath()
                editor.select(path: path, op: op)
            } else if op == .replace {
                editor.deselect()
            }
            lassoPoints = []
        case let .lassoFill(erase):
            if lassoPoints.count > 2 {
                let path = CGMutablePath()
                path.addLines(between: lassoPoints)
                path.closeSubpath()
                editor.lassoFill(path: path, erase: erase)
            }
            lassoPoints = []
        default:
            break
        }
        drag = .none
        endTemporaryToolIfReleased()
        overlay.needsDisplay = true
    }

    override func rightMouseDown(with e: NSEvent) {
        // リグモードでワープの点かハンドルを右クリックしたら、その点のハンドルを自動に戻す
        if state.mode == .rig, let h = hitDeformerHandle(viewPoint(e)) {
            switch h {
            case let .point(id, i), let .tangent(id, i, _): resetWarpTangent(id, i)
            default: break
            }
            overlay.needsDisplay = true
            return
        }
        // 右クリックでスポイト
        pick(at: canvasPoint(e), flags: [])
    }

    private func pick(at cp: CGPoint, flags: NSEvent.ModifierFlags) {
        if let c = editor.pickColor(x: Int(floor(cp.x)), y: Int(floor(cp.y)), currentLayerOnly: flags.contains(.command)) {
            editor.mainColor = c
        }
    }

    override func mouseMoved(with e: NSEvent) {
        mouseViewPoint = viewPoint(e)
        state.cursorCanvasPoint = canvasPoint(e)
        overlay.needsDisplay = true
    }

    override func mouseExited(with e: NSEvent) {
        mouseViewPoint = nil
        overlay.needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(event.modifierFlags)
    }

    func updateCursor(_ flags: NSEvent.ModifierFlags) {
        switch effectiveTool(flags) {
        case .hand: NSCursor.openHand.set()
        case .brush, .eraser, .fill, .lassoFill, .lassoErase, .eyedropper: NSCursor.crosshair.set()
        case .move: NSCursor.openHand.set()
        default: NSCursor.arrow.set()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        updateCursor(event.modifierFlags)
        overlay.needsDisplay = true
    }

    override func tabletProximity(with e: NSEvent) {
        // ペンの消しゴム側を向けたら消しゴムツールに
        if e.isEnteringProximity {
            if e.pointingDeviceType == .eraser {
                if editor.tool != .eraser { toolBeforeEraser = editor.tool }
                editor.tool = .eraser
                eraserInProximity = true
            }
        } else if eraserInProximity {
            eraserInProximity = false
            if let t = toolBeforeEraser { editor.tool = t }
            toolBeforeEraser = nil
        }
    }

    // MARK: - ファイルのドロップ

    /// ドロップ受付中（オーバーレイで枠を表示）
    private(set) var isDropTarget = false

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(AppState.isOpenable)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !droppedURLs(sender).isEmpty else { return [] }
        isDropTarget = true
        overlay.needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
        overlay.needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        overlay.needsDisplay = true
        return state.openDropped(droppedURLs(sender), asLayer: NSEvent.modifierFlags.contains(.option))
    }

    // MARK: - スクロール・ジェスチャー

    override func scrollWheel(with e: NSEvent) {
        let vp = viewPoint(e)
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) || !e.hasPreciseScrollingDeltas {
            // マウスホイールまたは修飾キー付きはズーム
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1
            zoom(to: zoom * pow(2, dy), around: vp)
        } else {
            offset.x += e.scrollingDeltaX
            offset.y += e.scrollingDeltaY
            viewChanged()
        }
    }

    override func magnify(with e: NSEvent) {
        zoom(to: zoom * (1 + e.magnification), around: viewPoint(e))
    }

    override func rotate(with e: NSEvent) {
        rotate(by: -CGFloat(e.rotation) * .pi / 180, around: viewPoint(e))
    }

    override func smartMagnify(with e: NSEvent) {
        fitToWindow()
    }

    // MARK: - キー（AppDelegate のモニタから呼ばれる）

    func setSpaceHeld(_ held: Bool) {
        spaceHeld = held
        updateCursor(NSEvent.modifierFlags)
    }

    func cancelInteraction() {
        switch drag {
        case .stroke: editor.endStroke()
        default: break
        }
        selectedDeformerHandles = []
        handleMarquee = nil
        drag = .none
        lassoPoints = []
        shapePreview = nil
        endTemporaryToolIfReleased()
        overlay.needsDisplay = true
    }

    // MARK: - ツールの一時切り替え

    /// ツールキーを押している間だけ切り替えたツール
    private struct TemporaryTool {
        let keyCode: UInt16
        let previous: Editor.ToolSnapshot
        let start: TimeInterval
        /// キーを押している間にキャンバスを操作したか
        var used = false
        /// 操作中にキーを離した（操作が終わったら戻す）
        var released = false
    }
    private var temporaryTool: TemporaryTool?

    /// ツールキーの keyDown。短く押せばそのまま切り替え、押したまま操作するか長押しすると、離したときに元のツールへ戻る
    func toolKeyDown(_ e: NSEvent, target: ShortcutTarget) {
        let previous = temporaryTool?.previous ?? editor.toolSnapshot
        editor.activate(target)
        temporaryTool = previous == editor.toolSnapshot ? nil : TemporaryTool(keyCode: e.keyCode, previous: previous, start: e.timestamp)
        updateCursor(e.modifierFlags)
        requestDisplay()
    }

    func toolKeyUp(_ e: NSEvent) {
        guard var t = temporaryTool, t.keyCode == e.keyCode else { return }
        guard t.used || e.timestamp - t.start >= 0.4 else {
            temporaryTool = nil
            return
        }
        t.released = true
        temporaryTool = t
        if case .none = drag { endTemporaryToolIfReleased() }
    }

    private func endTemporaryToolIfReleased() {
        guard let t = temporaryTool, t.released else { return }
        temporaryTool = nil
        editor.restore(t.previous)
        updateCursor(NSEvent.modifierFlags)
        requestDisplay()
    }

    // MARK: - 変形ハンドル

    func handlePositions(_ f: FloatingTransform) -> [(TransformHandle, CGPoint)] {
        let c = f.corners.map { $0.applying(canvasToView) }
        var out: [(TransformHandle, CGPoint)] = []
        for i in 0..<4 { out.append((.corner(i), c[i])) }
        for i in 0..<4 {
            let a = c[i], b = c[(i + 1) % 4]
            out.append((.edge(i), CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)))
        }
        return out
    }

    private func hitHandle(_ vp: CGPoint, _ f: FloatingTransform) -> TransformHandle {
        for (h, p) in handlePositions(f) where hypot(p.x - vp.x, p.y - vp.y) < 9 {
            return h
        }
        let poly = CGMutablePath()
        poly.addLines(between: f.corners.map { $0.applying(canvasToView) })
        poly.closeSubpath()
        return poly.contains(vp) ? .inside : .rotate
    }

    private func dragTransform(handle: TransformHandle, startCanvas: CGPoint, startParams: TransformParams, cp: CGPoint, shift: Bool) {
        guard let f = editor.floating else { return }
        var p = startParams
        let c0 = f.center
        let center = CGPoint(x: c0.x + startParams.tx, y: c0.y + startParams.ty)
        switch handle {
        case .inside:
            p.tx += Double(cp.x - startCanvas.x)
            p.ty += Double(cp.y - startCanvas.y)
        case .rotate:
            let a0 = atan2(startCanvas.y - center.y, startCanvas.x - center.x)
            let a1 = atan2(cp.y - center.y, cp.x - center.x)
            var r = startParams.rotation + Double(a1 - a0)
            if shift {
                let step = Double.pi / 12
                r = (r / step).rounded() * step
            }
            p.rotation = r
        case .corner, .edge:
            // 反対側を固定して拡大縮小
            let w = Double(f.sourceRect.width), h = Double(f.sourceRect.height)
            var sgn: (Double, Double)
            var useX = true, useY = true
            switch handle {
            case .corner(0): sgn = (-1, -1)
            case .corner(1): sgn = (1, -1)
            case .corner(2): sgn = (1, 1)
            case .corner(3): sgn = (-1, 1)
            case .edge(0): sgn = (0, -1); useX = false
            case .edge(1): sgn = (1, 0); useY = false
            case .edge(2): sgn = (0, 1); useX = false
            default: sgn = (-1, 0); useY = false
            }
            let rot = startParams.rotation
            let cosR = cos(rot), sinR = sin(rot)
            func toWorld(_ lx: Double, _ ly: Double) -> (Double, Double) {
                (Double(center.x) + lx * cosR - ly * sinR, Double(center.y) + lx * sinR + ly * cosR)
            }
            // 固定点（反対側）の現在位置
            let oppLocal = (-sgn.0 * w / 2 * startParams.sx, -sgn.1 * h / 2 * startParams.sy)
            let anchor = toWorld(oppLocal.0, oppLocal.1)
            let dx = Double(cp.x) - anchor.0, dy = Double(cp.y) - anchor.1
            let lx = dx * cosR + dy * sinR
            let ly = -dx * sinR + dy * cosR
            var sx = useX ? lx / (sgn.0 * w) : startParams.sx
            var sy = useY ? ly / (sgn.1 * h) : startParams.sy
            if shift && useX && useY {
                let s = max(abs(sx), abs(sy))
                sx = s * (sx < 0 ? -1 : 1)
                sy = s * (sy < 0 ? -1 : 1)
            }
            if abs(sx) < 0.001 { sx = 0.001 }
            if abs(sy) < 0.001 { sy = 0.001 }
            p.sx = sx
            p.sy = sy
            // 新しい中心 = 固定点 + R·(S·(sgn·size/2))
            let half = (useX ? sgn.0 * w / 2 * sx : 0, useY ? sgn.1 * h / 2 * sy : 0)
            let fixedLocalNew = (useX ? -half.0 : oppLocal.0, useY ? -half.1 : oppLocal.1)
            // anchor = newCenter + R·fixedLocalNew
            let nc = (anchor.0 - (fixedLocalNew.0 * cosR - fixedLocalNew.1 * sinR),
                      anchor.1 - (fixedLocalNew.0 * sinR + fixedLocalNew.1 * cosR))
            p.tx = nc.0 - Double(c0.x)
            p.ty = nc.1 - Double(c0.y)
        }
        editor.updateTransform(p)
    }
}

// MARK: - 補助表示

final class OverlayView: NSView {
    weak var canvas: CanvasView?
    private var antsPhase: CGFloat = 0
    private var antsTimer: Timer?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        antsTimer?.invalidate()
        guard window != nil else { return }
        antsTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self, let c = self.canvas, c.editor.doc.selection != nil else { return }
            self.antsPhase += 1
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let editor = canvas.editor
        let doc = editor.doc
        let t = canvas.canvasToView
        let canvasRect = CGRect(x: 0, y: 0, width: doc.width, height: doc.height)

        // キャンバス枠
        ctx.saveGState()
        var bt = t
        let border = CGPath(rect: canvasRect, transform: &bt)
        ctx.addPath(border)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()

        // グリッド
        if editor.grid.visible {
            drawGrid(ctx, t: t, canvasRect: canvasRect, grid: editor.grid, zoom: canvas.zoom)
        }

        // 選択範囲
        if let f = editor.floating {
            if let sel = f.originalSelection {
                var tt = f.matrix.concatenating(t)
                if let path = sel.outline.copy(using: &tt) { drawAnts(ctx, path) }
            }
        } else if let sel = doc.selection {
            var tt = t
            if let path = sel.outline.copy(using: &tt) {
                drawAnts(ctx, path)
            }
        }

        // 選択中の図形・投げなわ
        if let (r, ellipse) = canvas.shapePreview {
            var tt = t
            let path = ellipse ? CGPath(ellipseIn: r, transform: &tt) : CGPath(rect: r, transform: &tt)
            drawAnts(ctx, path)
        }
        if canvas.lassoPoints.count > 1 {
            let path = CGMutablePath()
            path.addLines(between: canvas.lassoPoints.map { $0.applying(t) })
            // 投げなわ塗りは塗られる範囲を描画色で予告する
            if editor.tool == .lassoFill {
                let c = editor.mainColor
                ctx.addPath(path)
                ctx.closePath()
                ctx.setFillColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 0.4)
                ctx.fillPath()
            }
            drawAnts(ctx, path)
        }

        // 変形ハンドル
        if let f = editor.floating, editor.tool == .transform {
            let corners = f.corners.map { $0.applying(t) }
            let path = CGMutablePath()
            path.addLines(between: corners)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            for (_, p) in canvas.handlePositions(f) {
                let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(r)
                ctx.setStrokeColor(NSColor.systemBlue.cgColor)
                ctx.stroke(r)
            }
        }

        // デフォーマのハンドル
        drawDeformerHandles(ctx, canvas: canvas, t: t)

        // 書き出し枠（書き出し設定を開いている間）
        drawPublishFrame(ctx, canvas: canvas, t: t)

        // ファイルのドロップ受付
        if canvas.isDropTarget {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(4)
            ctx.stroke(bounds.insetBy(dx: 2, dy: 2))
        }

        // ブラシカーソル
        if let mp = canvas.mouseViewPoint {
            let tool = canvas.effectiveTool(NSEvent.modifierFlags)
            if tool == .brush || tool == .eraser {
                let r = CGFloat(editor.currentBrush.size) / 2 * canvas.zoom
                if r > 2 {
                    let rect = CGRect(x: mp.x - r, y: mp.y - r, width: r * 2, height: r * 2)
                    ctx.setLineWidth(1)
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
                    ctx.strokeEllipse(in: rect.insetBy(dx: -0.5, dy: -0.5))
                    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor)
                    ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
                }
            }
        }
    }

    private func drawAnts(_ ctx: CGContext, _ path: CGPath) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineDash(phase: antsPhase, lengths: [4, 4])
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawGrid(_ ctx: CGContext, t: CGAffineTransform, canvasRect: CGRect, grid: GridSettings, zoom: CGFloat) {
        let spacing = CGFloat(max(grid.spacing, 1))
        let sub = max(grid.subdivisions, 1)
        let subSpacing = spacing / CGFloat(sub)
        ctx.saveGState()
        // 細かい線は画面上で 4px 未満になるなら描かない
        func lines(step: CGFloat) -> CGPath {
            let path = CGMutablePath()
            var x: CGFloat = 0
            while x <= canvasRect.width + 0.001 {
                path.move(to: CGPoint(x: x, y: 0).applying(t))
                path.addLine(to: CGPoint(x: x, y: canvasRect.height).applying(t))
                x += step
            }
            var y: CGFloat = 0
            while y <= canvasRect.height + 0.001 {
                path.move(to: CGPoint(x: 0, y: y).applying(t))
                path.addLine(to: CGPoint(x: canvasRect.width, y: y).applying(t))
                y += step
            }
            return path
        }
        ctx.setLineWidth(1)
        if sub > 1 && subSpacing * zoom >= 4 {
            ctx.addPath(lines(step: subSpacing))
            ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(grid.opacity * 0.4).cgColor)
            ctx.strokePath()
        }
        if spacing * zoom >= 3 {
            ctx.addPath(lines(step: spacing))
            ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(grid.opacity).cgColor)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

// MARK: - SwiftUI ラッパー

struct CanvasRepresentable: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> CanvasView {
        CanvasView(state: state)
    }

    func updateNSView(_ nsView: CanvasView, context: Context) {
        nsView.requestDisplay()
    }
}
