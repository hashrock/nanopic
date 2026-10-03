import CoreGraphics
import Foundation
import Observation

public enum Tool: String, CaseIterable, Codable, Sendable {
    case brush, eraser, fill, lassoFill, lassoErase, selectRect, selectEllipse, lasso, wand, move, transform, eyedropper, hand, zoom

    public var displayName: String {
        switch self {
        case .brush: return "ブラシ"
        case .eraser: return "消しゴム"
        case .fill: return "塗りつぶし"
        case .lassoFill: return "投げなわ塗り"
        case .lassoErase: return "投げなわ消しゴム"
        case .selectRect: return "矩形選択"
        case .selectEllipse: return "楕円選択"
        case .lasso: return "投げなわ選択"
        case .wand: return "自動選択"
        case .move: return "レイヤー移動"
        case .transform: return "拡大・縮小・回転"
        case .eyedropper: return "スポイト"
        case .hand: return "手のひら"
        case .zoom: return "ズーム"
        }
    }

    /// ショートカットを割り当てられるツール（拡大・縮小・回転は ⌘T）
    public static let assignable: [Tool] = allCases.filter { $0 != .transform }

    public var symbol: String {
        switch self {
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .fill: return "drop"
        case .lassoFill: return "lasso.and.sparkles"
        case .lassoErase: return "eraser.line.dashed"
        case .selectRect: return "rectangle.dashed"
        case .selectEllipse: return "circle.dashed"
        case .lasso: return "lasso"
        case .wand: return "wand.and.stars"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .transform: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .eyedropper: return "eyedropper"
        case .hand: return "hand.raised"
        case .zoom: return "magnifyingglass"
        }
    }
}

public struct GridSettings: Codable, Equatable, Sendable {
    public var visible = false
    public var spacing: Int = 100
    public var subdivisions: Int = 4
    public var opacity: Double = 0.5
    public init() {}
}

@Observable
public final class Editor {
    public private(set) var doc: DocumentState
    /// ドキュメントの構造・内容が変わるたびに増加（UI の再描画用）
    public private(set) var revision = 0

    // MARK: ツール状態
    public var tool: Tool = .brush
    public var brushes: [BrushSettings] = BrushSettings.defaultPresets
    public var activeBrushIndex = 0
    public var erasers: [BrushSettings] = BrushSettings.defaultErasers
    public var activeEraserIndex = 0
    public var mainColor = SIMD3<Float>(0.1, 0.1, 0.12)
    public var subColor = SIMD3<Float>(1, 1, 1)
    public var palette: [SIMD3<Float>] = Editor.defaultPalette
    public var fillSettings = FillSettings()
    public var wandSettings = FillSettings()
    public var selectionAntialias = true
    public var lassoFillAntialias = true
    public var grid = GridSettings()
    public private(set) var tips: [BrushTip] = BrushTip.builtins()
    public private(set) var floating: FloatingTransform?
    /// 色調補正のプレビュー中（確定するまでレイヤーの中身は変えず、表示だけに補正をかける）
    public private(set) var adjustment: (layerID: UUID, value: ColorAdjustment)?
    public var fileURL: URL?
    public private(set) var isDirty = false

    // MARK: 履歴
    @ObservationIgnored private var undoStack: [(label: String, state: DocumentState, key: String?, time: Date)] = []
    @ObservationIgnored private var redoStack: [(label: String, state: DocumentState)] = []
    @ObservationIgnored public private(set) var gen = 1
    @ObservationIgnored public var maxUndo = 60
    public private(set) var canUndo = false
    public private(set) var canRedo = false

    // MARK: 描画更新
    @ObservationIgnored private var dirtyRect: IntRect = .zero
    @ObservationIgnored public var onNeedsDisplay: (() -> Void)?

    // MARK: ストローク
    @ObservationIgnored private var engine: StrokeEngine?
    @ObservationIgnored private let strokeBufferLock = NSLock()
    @ObservationIgnored private var strokeBuffer: StrokeBuffer?
    /// 色混ぜブラシのときはこちら（レイヤーに直接混ぜる）
    @ObservationIgnored private var mixBuffer: MixBuffer?
    private var strokeTarget: StrokeTarget? { mixBuffer ?? strokeBuffer }
    @ObservationIgnored private var strokeLayerID: UUID?
    @ObservationIgnored private var strokeMode: StrokeApplyMode = .normal
    @ObservationIgnored private var strokeBrush: BrushSettings?
    @ObservationIgnored private var strokeTip: BrushTip?
    @ObservationIgnored private var strokeDabCount = 0
    public var isStroking: Bool { engine != nil }

    public init(width: Int = 1920, height: Int = 1080) {
        doc = Editor.makeNewDocument(width: width, height: height, gen: 1)
    }

    public static func makeNewDocument(width: Int, height: Int, gen: Int) -> DocumentState {
        var d = DocumentState(width: width, height: height)
        var paper = LayerNode(name: "用紙")
        paper.tiles = TileMap.filled(width: width, height: height, rgba: (255, 255, 255, 255), gen: gen)
        let l1 = LayerNode(name: "レイヤー 1")
        d.layers = [paper, l1]
        d.activeLayerID = l1.id
        return d
    }

    // MARK: - ドキュメント

    public func newDocument(width: Int, height: Int) {
        cancelTransform()
        cancelAdjustment()
        gen += 1
        doc = Editor.makeNewDocument(width: width, height: height, gen: gen)
        selectedLayerIDs = []
        resetHistory()
        fileURL = nil
        isDirty = false
        structureChanged()
    }

    public func load(_ state: DocumentState, url: URL?) {
        cancelTransform()
        cancelAdjustment()
        gen += 1
        doc = state
        func renumber(_ n: inout LayerNode) {
            n.contentVersion = nextVersion()
            for i in n.children.indices { renumber(&n.children[i]) }
        }
        for i in doc.layers.indices { renumber(&doc.layers[i]) }
        if doc.activeLayerID == nil || doc.node(doc.activeLayerID) == nil {
            doc.activeLayerID = firstRasterID(doc.layers.reversed())
        }
        selectedLayerIDs = []
        resetHistory()
        fileURL = url
        isDirty = false
        structureChanged()
    }

    private func firstRasterID<S: Sequence>(_ nodes: S) -> UUID? where S.Element == LayerNode {
        for n in nodes {
            if n.kind == .raster { return n.id }
            if let id = firstRasterID(n.children.reversed()) { return id }
        }
        return nil
    }

    public func markSaved(url: URL?) {
        fileURL = url
        isDirty = false
    }

    // MARK: - 履歴

    private func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateHistoryFlags()
    }

    /// 変更の直前に呼ぶ。coalesceKey が直前と同じなら（1.5 秒以内）1 つの操作にまとめる。
    public func checkpoint(_ label: String, coalesceKey: String? = nil) {
        if let key = coalesceKey, let last = undoStack.last, last.key == key, Date().timeIntervalSince(last.time) < 1.5 {
            undoStack[undoStack.count - 1].time = Date()
            isDirty = true
            return
        }
        undoStack.append((label, doc, coalesceKey, Date()))
        if undoStack.count > maxUndo { undoStack.removeFirst(undoStack.count - maxUndo) }
        redoStack.removeAll()
        gen += 1
        isDirty = true
        updateHistoryFlags()
    }

    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    public func undo() {
        cancelAdjustment()
        if let f = floating {
            // フローティング中は移動・変形を 1 操作ずつ戻し、最初まで戻ったら持ち上げ自体を取り消す
            if let prev = f.history.popLast() {
                updateTransform(prev)
            } else {
                cancelTransform()
            }
            return
        }
        if isStroking { endStroke() }
        guard let entry = undoStack.popLast() else { return }
        redoStack.append((entry.label, doc))
        restore(entry.state)
    }

    public func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append((entry.label, doc, nil, .distantPast))
        restore(entry.state)
    }

    private func restore(_ state: DocumentState) {
        let activeID = doc.activeLayerID
        gen += 1
        doc = state
        // アクティブレイヤーはなるべく維持
        if let activeID, doc.node(activeID) != nil { doc.activeLayerID = activeID }
        selectedLayerIDs = selectedLayerIDs.filter { doc.node($0) != nil && $0 != doc.activeLayerID }
        isDirty = true
        updateHistoryFlags()
        structureChanged()
    }

    private func updateHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - 描画更新

    public func markDirty(_ r: IntRect) {
        if r.isEmpty { return }
        dirtyRect = dirtyRect.union(r)
        onNeedsDisplay?()
    }

    public func markAllDirty() {
        markDirty(doc.bounds)
    }

    /// レンダラーが呼ぶ：更新が必要な領域を取り出す
    public func takeDirtyRect() -> IntRect {
        let r = dirtyRect.intersection(doc.bounds)
        dirtyRect = .zero
        return r
    }

    /// ノード（フォルダーなら子孫すべて）のタイルが占める範囲
    private func tileBounds(_ node: LayerNode) -> IntRect {
        var r = IntRect.zero
        for key in node.tiles.keys { r = r.union(key.rect) }
        for c in node.children { r = r.union(tileBounds(c)) }
        return r
    }

    /// 並べ替え後の再描画。見た目が変わり得るのは、移動したレイヤーの範囲と
    /// クリッピング関係が変わるクリッピングレイヤーの範囲だけなので、全体を再合成しない。
    private func reorderChanged(_ moved: [LayerNode]) {
        revision += 1
        var r = moved.reduce(IntRect.zero) { $0.union(tileBounds($1)) }
        doc.forEachNode { n in
            if n.clipping { r = r.union(tileBounds(n)) }
        }
        markDirty(r.intersection(doc.bounds))
    }

    private func structureChanged() {
        revision += 1
        markAllDirty()
    }

    /// 内容バージョンの採番（Undo 後も重複しないよう単調増加）
    @ObservationIgnored private var versionCounter = 0
    private func nextVersion() -> Int {
        versionCounter += 1
        return versionCounter
    }

    private func contentChanged(_ layerID: UUID, rect: IntRect) {
        let v = nextVersion()
        doc.modify(layerID) { $0.contentVersion = v }
        revision += 1
        markDirty(rect)
    }

    /// 表示用の合成オプション（ストローク中・変形中のプレビューを含む）
    public func compositeOptions() -> CompositeOptions {
        var o = CompositeOptions()
        if let buf = strokeTarget, let lid = strokeLayerID {
            let mode = strokeMode
            let sel = doc.selection
            o.overrideLayerID = lid
            o.overrideTile = { key, src, out in
                buf.apply(key: key, src: src, out: out, mode: mode, selection: sel)
            }
        } else if let f = floating {
            o.overrideLayerID = f.layerID
            o.overrideTile = { key, _, out in
                f.renderTile(key: key, out: out)
            }
        } else if let (lid, adj) = adjustment {
            let sel = doc.selection
            o.overrideLayerID = lid
            o.overrideTile = { key, src, out in
                guard let src else { return false }
                adj.apply(tile: src, out: out, key: key, selection: sel)
                return true
            }
        }
        return o
    }

    // MARK: - ブラシ

    public var currentBrush: BrushSettings {
        get {
            if tool == .eraser { return erasers[min(activeEraserIndex, erasers.count - 1)] }
            return brushes[min(activeBrushIndex, brushes.count - 1)]
        }
        set {
            if tool == .eraser {
                erasers[min(activeEraserIndex, erasers.count - 1)] = newValue
            } else {
                brushes[min(activeBrushIndex, brushes.count - 1)] = newValue
            }
        }
    }

    public func tip(_ id: String) -> BrushTip {
        tips.first { $0.id == id } ?? tips[0]
    }

    public func addTip(_ tip: BrushTip) {
        tips.removeAll { $0.id == tip.id }
        tips.append(tip)
    }

    /// ツールを切り替える。移動・変形以外に切り替えるときは変形を確定する
    public func selectTool(_ t: Tool) {
        if t != .transform && t != .move { commitTransform() }
        tool = t
        if t == .transform { beginTransform() }
    }

    public func setBrushSize(_ size: Float) {
        var b = currentBrush
        b.size = min(max(size, 0.5), 2000)
        currentBrush = b
    }

    public func swapColors() {
        swap(&mainColor, &subColor)
    }

    // MARK: - ストローク

    /// 描画可能なレイヤーか
    public var canPaintOnActiveLayer: Bool {
        guard let l = doc.activeLayer else { return false }
        return l.kind == .raster && !l.locked && doc.isEffectivelyVisible(l.id)
    }

    @discardableResult
    public func beginStroke(_ input: StrokeInput, usePressure: Bool, zoom: Double) -> Bool {
        // 移動・変形中なら確定してから描く
        commitTransform()
        cancelAdjustment()
        guard canPaintOnActiveLayer, let layer = doc.activeLayer else { return false }
        let brush = currentBrush
        strokeBrush = brush
        strokeTip = tip(brush.tipID)
        strokeLayerID = layer.id
        if brush.kind == .eraser {
            strokeMode = .erase
        } else {
            strokeMode = layer.lockAlpha ? .lockAlpha : .normal
        }
        if brush.isDirect {
            mixBuffer = MixBuffer(layer: layer.tiles, width: doc.width, height: doc.height)
        } else {
            strokeBuffer = StrokeBuffer(width: doc.width, height: doc.height)
        }
        strokeDabCount = 0
        let e = StrokeEngine(brush: brush, usePressure: usePressure, zoom: zoom, seed: StrokeEngine.seed(for: input))
        if brush.kind == .brush && (brush.warpRadial != 0 || brush.warpTwist != 0) {
            e.continuousInterval = 1.0 / 60
        }
        e.emit = { [unowned self] dab in self.paintDab(dab) }
        engine = e
        e.begin(input)
        return true
    }

    public func continueStroke(_ input: StrokeInput) {
        engine?.add(input)
    }

    public func endStroke() {
        guard let e = engine else { return }
        e.end()
        engine = nil
        guard let buf = strokeTarget, let lid = strokeLayerID else { return }
        let isMix = mixBuffer != nil
        let touched = buf.touched
        if !touched.isEmpty {
            checkpoint(strokeMode == .erase ? "消しゴム" : "描画")
            let g = gen
            let mode = strokeMode
            let sel = doc.selection
            doc.modify(lid) { layer in
                let keys = buf.tileKeys
                for key in keys {
                    if layer.tiles[key] == nil && mode != .normal { continue }
                    let t = layer.tiles.mutableTile(key, gen: g)
                    _ = buf.apply(key: key, src: t.data, out: t.data, mode: mode, selection: sel)
                }
                // 色混ぜは透明を引きずって消すこともある
                if mode == .erase || isMix { layer.tiles.pruneTransparent(keys) }
            }
            contentChanged(lid, rect: touched)
        }
        strokeBuffer = nil
        mixBuffer = nil
        strokeLayerID = nil
        strokeTip = nil
        strokeBrush = nil
        markDirty(touched)
    }

    private func paintDab(_ dab: Dab) {
        guard let brush = strokeBrush, let tip = strokeTip else { return }
        strokeDabCount += 1
        if let mix = mixBuffer {
            let r = mix.render(dab, brush: brush, brushColor: mainColor, tip: tip)
            markDirty(r)
            return
        }
        guard let buf = strokeBuffer else { return }
        var d = dab
        d.color = mainColor
        let r = buf.render(d, tip: tip, hardness: brush.hardness, roundness: brush.roundness, flow: brush.flow)
        markDirty(r)
    }

    // MARK: - スポイト

    /// 表示中の合成結果から色を取得（透明なら nil）
    public func pickColor(x: Int, y: Int, currentLayerOnly: Bool = false) -> SIMD3<Float>? {
        guard doc.bounds.contains(x, y) else { return nil }
        var px: (UInt8, UInt8, UInt8, UInt8)
        if currentLayerOnly {
            guard let l = doc.activeLayer, l.kind == .raster else { return nil }
            px = l.tiles.pixel(x, y)
        } else {
            let key = TileKey(x: x / kTileSize, y: y / kTileSize)
            let acc = UnsafeMutablePointer<RGBA>.allocate(capacity: kTilePixelCount)
            acc.initialize(repeating: .zero, count: kTilePixelCount)
            defer { acc.deallocate() }
            Compositor.compositeTile(doc.layers, key: key, options: CompositeOptions(), into: acc)
            let v = acc[(y % kTileSize) * kTileSize + (x % kTileSize)]
            let buf = [v.x, v.y, v.z, v.w].map { Compositor.toByte($0) }
            px = (buf[0], buf[1], buf[2], buf[3])
        }
        guard px.3 > 0 else { return nil }
        let a = Float(px.3)
        return SIMD3(Float(px.0) / a, Float(px.1) / a, Float(px.2) / a)
    }

    // MARK: - 塗りつぶし・自動選択

    private func referenceBuffer(_ ref: FillReference) -> [UInt8] {
        switch ref {
        case .currentLayer:
            return doc.activeLayer?.tiles.toBuffer(width: doc.width, height: doc.height)
                ?? [UInt8](repeating: 0, count: doc.width * doc.height * 4)
        case .allLayers:
            return Compositor.compositeFull(doc)
        case .referenceLayers:
            var o = CompositeOptions()
            o.referenceOnly = true
            return Compositor.compositeFull(doc, options: o)
        }
    }

    private func regionMask(at x: Int, _ y: Int, settings: FillSettings) -> (mask: [UInt8], bounds: IntRect) {
        let ref = referenceBuffer(settings.reference)
        var (mask, bounds) = ref.withUnsafeBufferPointer { p in
            FloodFill.mask(reference: p.baseAddress!, width: doc.width, height: doc.height, seedX: x, seedY: y,
                           tolerance: settings.tolerance, contiguous: settings.contiguous, gapClose: settings.gapClose)
        }
        if bounds.isEmpty { return (mask, bounds) }
        if settings.expand > 0 {
            FloodFill.dilate(&mask, doc.width, doc.height, radius: settings.expand, value: 255)
            bounds = bounds.insetBy(-settings.expand).intersection(doc.bounds)
        } else if settings.expand < 0 {
            FloodFill.erode(&mask, doc.width, doc.height, radius: -settings.expand)
        }
        return (mask, bounds)
    }

    public func fill(atX x: Int, y: Int) {
        commitTransform()
        guard canPaintOnActiveLayer, let layer = doc.activeLayer, doc.bounds.contains(x, y) else { return }
        let (mask, bounds) = regionMask(at: x, y, settings: fillSettings)
        if bounds.isEmpty { return }
        paintMask(mask, bounds: bounds, layerID: layer.id, label: "塗りつぶし")
    }

    /// 閉じたパスの内側を描画色で塗る（erase: true なら消す）。選択範囲があればさらに制限。
    public func lassoFill(path: CGPath, erase: Bool = false) {
        commitTransform()
        guard canPaintOnActiveLayer, let layer = doc.activeLayer else { return }
        let m = SelectionMask.fromPath(path, width: doc.width, height: doc.height, antialias: lassoFillAntialias)
        if m.isEmpty { return }
        paintMask(m.data, bounds: m.bounds, layerID: layer.id, label: erase ? "投げなわ消しゴム" : "投げなわ塗り", erase: erase)
    }

    /// マスク（0...255）の範囲を描画色で塗る（erase: true なら消す）。選択範囲があればさらに制限。
    private func paintMask(_ mask: [UInt8], bounds: IntRect, layerID: UUID, label: String, erase: Bool = false) {
        let w = doc.width
        paintMasks([MaskPaint(bounds: bounds, color: mainColor, erase: erase) { x, y in mask[y * w + x] }],
                   layerID: layerID, label: label)
    }

    /// 範囲と、その中の各画素の塗る量（0...255）
    public struct MaskPaint {
        public var bounds: IntRect
        public var color: SIMD3<Float>
        public var erase: Bool
        public var alpha: (Int, Int) -> UInt8

        public init(bounds: IntRect, color: SIMD3<Float>, erase: Bool = false, alpha: @escaping (Int, Int) -> UInt8) {
            self.bounds = bounds
            self.color = color
            self.erase = erase
            self.alpha = alpha
        }
    }

    /// いくつかのマスクを順に塗る（取り消しは 1 回分）。選択範囲があればさらに制限。
    public func paintMasks(_ items: [MaskPaint], layerID: UUID, label: String) {
        guard let layer = doc.node(layerID), layer.kind == .raster else { return }
        let items = items.map { var i = $0; i.bounds = i.bounds.intersection(doc.bounds); return i }.filter { !$0.bounds.isEmpty }
        guard !items.isEmpty else { return }
        checkpoint(label)
        let g = gen
        let sel = doc.selection
        let lockAlpha = layer.lockAlpha
        var all = IntRect.zero
        doc.modify(layerID) { l in
            for item in items {
                let bounds = item.bounds
                let c = item.color
                let erase = item.erase
                all = all.union(bounds)
                for key in bounds.tileKeys {
                    if (lockAlpha || erase) && l.tiles[key] == nil { continue }
                    let t = l.tiles.mutableTile(key, gen: g)
                    let tr = key.rect.intersection(bounds)
                    for y in tr.minY..<tr.maxY {
                        for x in tr.minX..<tr.maxX {
                            var a = Float(item.alpha(x, y)) / 255
                            if let sel { a *= Float(sel.value(x, y)) / 255 }
                            if a <= 0 { continue }
                            let o = t.data + ((y - key.y * kTileSize) * kTileSize + (x - key.x * kTileSize)) * 4
                            if erase {
                                for c in 0..<4 { o[c] = Compositor.toByte(Float(o[c]) / 255 * (1 - a)) }
                                continue
                            }
                            let d = RGBA(Float(o[0]), Float(o[1]), Float(o[2]), Float(o[3])) / 255
                            var r: RGBA
                            if lockAlpha {
                                r = RGBA(c.x, c.y, c.z, 0) * a * d.w + d * (1 - a)
                                r.w = d.w
                            } else {
                                r = RGBA(c.x * a, c.y * a, c.z * a, a) + d * (1 - a)
                            }
                            o[0] = Compositor.toByte(r.x); o[1] = Compositor.toByte(r.y)
                            o[2] = Compositor.toByte(r.z); o[3] = Compositor.toByte(r.w)
                        }
                    }
                }
                l.tiles.pruneTransparent(bounds.tileKeys)
            }
        }
        contentChanged(layerID, rect: all)
    }

    /// 指定した設定で塗りつぶし用の領域マスクを作る（設定は一時的なもので、ツールの設定は変えない）
    public func regionMask(at x: Int, _ y: Int, using settings: FillSettings) -> (mask: [UInt8], bounds: IntRect) {
        regionMask(at: x, y, settings: settings)
    }

    /// 選択範囲（なければ全体）を描画色で塗る
    public func fillSelection() {
        commitTransform()
        guard canPaintOnActiveLayer, let layer = doc.activeLayer else { return }
        let mask = [UInt8](repeating: 255, count: doc.width * doc.height)
        paintMask(mask, bounds: doc.selection?.bounds ?? doc.bounds, layerID: layer.id, label: "塗りつぶし")
    }

    public func wandSelect(atX x: Int, y: Int, op: SelectionOp) {
        guard doc.bounds.contains(x, y) else { return }
        commitTransform()
        let (mask, bounds) = regionMask(at: x, y, settings: wandSettings)
        let new = SelectionMask(width: doc.width, height: doc.height, data: bounds.isEmpty ? [UInt8](repeating: 0, count: doc.width * doc.height) : mask)
        setSelection(SelectionMask.combine(doc.selection, new, op: op), label: "自動選択")
    }

    // MARK: - 選択範囲

    public func setSelection(_ sel: SelectionMask?, label: String) {
        checkpoint(label)
        doc.selection = sel
        revision += 1
        onNeedsDisplay?()
    }

    public func select(path: CGPath, op: SelectionOp) {
        let m = SelectionMask.fromPath(path, width: doc.width, height: doc.height, antialias: selectionAntialias)
        setSelection(SelectionMask.combine(doc.selection, m, op: op), label: "選択範囲")
    }

    public func selectAll() {
        commitTransform()
        setSelection(SelectionMask.all(width: doc.width, height: doc.height), label: "すべてを選択")
    }

    public func deselect() {
        commitTransform()
        guard doc.selection != nil else { return }
        setSelection(nil, label: "選択を解除")
    }

    public func invertSelection() {
        commitTransform()
        if let s = doc.selection {
            setSelection(s.inverted(), label: "選択範囲を反転")
        } else {
            setSelection(SelectionMask.all(width: doc.width, height: doc.height), label: "選択範囲を反転")
        }
    }

    /// 選択範囲（なければレイヤー全体）を消去
    public func clearSelectionContent() {
        if floating != nil {
            deleteFloatingContent()
            return
        }
        guard canPaintOnActiveLayer, let layer = doc.activeLayer else { return }
        checkpoint("消去")
        let g = gen
        let sel = doc.selection
        let rect = sel?.bounds ?? doc.bounds
        doc.modify(layer.id) { l in
            guard let sel else {
                l.tiles.removeAll()
                return
            }
            for key in rect.tileKeys {
                guard l.tiles[key] != nil else { continue }
                let t = l.tiles.mutableTile(key, gen: g)
                let tr = key.rect.intersection(rect)
                for y in tr.minY..<tr.maxY {
                    for x in tr.minX..<tr.maxX {
                        let m = Int(sel.value(x, y))
                        if m == 0 { continue }
                        let o = t.data + ((y - key.y * kTileSize) * kTileSize + (x - key.x * kTileSize)) * 4
                        for c in 0..<4 { o[c] = UInt8((Int(o[c]) * (255 - m) + 127) / 255) }
                    }
                }
            }
            l.tiles.pruneTransparent(rect.tileKeys)
        }
        contentChanged(layer.id, rect: rect)
    }

    // MARK: - 変形

    @discardableResult
    public func beginTransform() -> Bool {
        if floating != nil { return true }
        if isStroking { endStroke() }
        guard canPaintOnActiveLayer, let layer = doc.activeLayer,
              let f = FloatingTransform(layer: layer, selection: doc.selection, docWidth: doc.width, docHeight: doc.height)
        else { return false }
        floating = f
        markDirty(f.sourceRect)
        return true
    }

    /// 移動・変形のドラッグ開始時に呼ぶ（フローティング中の Undo 用に現在の状態を記録）
    public func recordTransformStep() {
        guard let f = floating else { return }
        if f.history.last != f.params { f.history.append(f.params) }
    }

    /// 持ち上げた画素を消去して確定する
    public func deleteFloatingContent() {
        guard let f = floating else { return }
        floating = nil
        checkpoint("消去")
        doc.modify(f.layerID) { $0.tiles = f.baseTiles }
        if f.originalSelection != nil {
            doc.selection = f.transformedSelection
        }
        contentChanged(f.layerID, rect: f.sourceRect.union(f.destBounds))
    }

    public func updateTransform(_ params: TransformParams) {
        guard let f = floating else { return }
        let before = f.destBounds
        f.params = params
        markDirty(before.union(f.destBounds))
        revision += 1
    }

    public func commitTransform() {
        guard let f = floating else { return }
        floating = nil
        if f.params == TransformParams() {
            markDirty(f.sourceRect)
            return
        }
        checkpoint("変形")
        let tiles = f.resultTiles(gen: gen)
        doc.modify(f.layerID) { $0.tiles = tiles }
        if f.originalSelection != nil {
            doc.selection = f.transformedSelection
        }
        contentChanged(f.layerID, rect: f.sourceRect.union(f.destBounds))
    }

    public func cancelTransform() {
        guard let f = floating else { return }
        floating = nil
        markDirty(f.sourceRect.union(f.destBounds))
        revision += 1
    }

    // MARK: - 色調補正

    /// 編集中のレイヤー（選択範囲があればその中）に補正をかけたときの見た目を表示する。描けないレイヤーなら false
    @discardableResult
    public func previewAdjustment(_ value: ColorAdjustment) -> Bool {
        commitTransform()
        guard canPaintOnActiveLayer, let layer = doc.activeLayer else { return false }
        let before = adjustment
        adjustment = (layer.id, value)
        if before?.value != value || before?.layerID != layer.id { markDirty(adjustmentBounds(layer)) }
        return true
    }

    /// プレビュー中の補正をレイヤーに書き込む
    public func commitAdjustment() {
        guard let (lid, adj) = adjustment else { return }
        adjustment = nil
        guard !adj.isIdentity, let layer = doc.node(lid) else {
            doc.node(lid).map { markDirty(adjustmentBounds($0)) }
            return
        }
        let rect = adjustmentBounds(layer)
        checkpoint("色調補正")
        let g = gen
        let sel = doc.selection
        doc.modify(lid) { l in
            for key in Array(l.tiles.keys) where !key.rect.intersection(rect).isEmpty {
                let t = l.tiles.mutableTile(key, gen: g)
                adj.apply(tile: t.data, out: t.data, key: key, selection: sel)
            }
        }
        contentChanged(lid, rect: rect)
    }

    public func cancelAdjustment() {
        guard let (lid, _) = adjustment else { return }
        adjustment = nil
        doc.node(lid).map { markDirty(adjustmentBounds($0)) }
    }

    // MARK: - レイヤー操作

    public var activeLayerID: UUID? { doc.activeLayerID }

    /// 編集レイヤーを切り替える（複数選択は解除）
    public func setActiveLayer(_ id: UUID) {
        guard doc.activeLayerID != id || !selectedLayerIDs.isEmpty else { return }
        commitTransform()
        cancelAdjustment()
        doc.activeLayerID = id
        selectedLayerIDs = []
        revision += 1
    }

    // MARK: - レイヤーの複数選択

    /// 編集レイヤーに加えて選択しているレイヤー（編集レイヤー自身は含まない）
    public private(set) var selectedLayerIDs: Set<UUID> = []

    public func isLayerSelected(_ id: UUID) -> Bool {
        id == doc.activeLayerID || selectedLayerIDs.contains(id)
    }

    /// 選択に追加・除外する（編集レイヤーは外せない）
    public func toggleLayerSelection(_ id: UUID) {
        guard id != doc.activeLayerID, doc.node(id) != nil else { return }
        if selectedLayerIDs.contains(id) {
            selectedLayerIDs.remove(id)
        } else {
            selectedLayerIDs.insert(id)
        }
        revision += 1
    }

    /// 編集レイヤーから id まで（表示順）を選択する
    public func selectLayerRange(to id: UUID) {
        let list = doc.flattenedForDisplay().map(\.node.id)
        guard let a = list.firstIndex(where: { $0 == doc.activeLayerID }), let b = list.firstIndex(of: id) else {
            setActiveLayer(id)
            return
        }
        selectedLayerIDs = Set(list[min(a, b)...max(a, b)])
        selectedLayerIDs.remove(list[a])
        revision += 1
    }

    /// 操作対象のレイヤー（編集レイヤー＋選択中）を下から順に。選択したフォルダーの中身は除く
    public var targetLayerIDs: [UUID] {
        var out: [UUID] = []
        func rec(_ nodes: [LayerNode]) {
            for n in nodes {
                if isLayerSelected(n.id) {
                    out.append(n.id)
                } else if n.isFolder {
                    rec(n.children)
                }
            }
        }
        rec(doc.layers)
        return out
    }

    private func nextLayerName(prefix: String) -> String {
        var maxN = 0
        doc.forEachNode { n in
            if n.name.hasPrefix(prefix + " "), let v = Int(n.name.dropFirst(prefix.count + 1)) { maxN = max(maxN, v) }
        }
        return "\(prefix) \(maxN + 1)"
    }

    /// アクティブレイヤーの上に挿入する位置
    private func insertionPoint() -> (parent: [Int], index: Int) {
        guard let id = doc.activeLayerID, let path = doc.indexPath(of: id) else { return ([], doc.layers.count) }
        return (Array(path.dropLast()), path.last! + 1)
    }

    public func addLayer(name: String? = nil) {
        commitTransform()
        checkpoint("新規レイヤー")
        let node = LayerNode(name: name ?? nextLayerName(prefix: "レイヤー"))
        let (parent, index) = insertionPoint()
        doc.insert(node, parentPath: parent, index: index)
        doc.activeLayerID = node.id
        selectedLayerIDs = []
        structureChanged()
    }

    public func addFolder(name: String? = nil) {
        commitTransform()
        checkpoint("新規フォルダー")
        let node = LayerNode(name: name ?? nextLayerName(prefix: "フォルダー"), kind: .folder)
        let (parent, index) = insertionPoint()
        doc.insert(node, parentPath: parent, index: index)
        doc.activeLayerID = node.id
        selectedLayerIDs = []
        structureChanged()
    }

    /// 選択中のレイヤーを新しいフォルダーに入れる（一番上のレイヤーの位置に作る）
    public func groupSelectedLayers() {
        commitTransform()
        let ids = targetLayerIDs
        guard let top = ids.last, let topPath = doc.indexPath(of: top) else { return }
        checkpoint("フォルダーを作成して挿入")
        var folder = LayerNode(name: nextLayerName(prefix: "フォルダー"), kind: .folder)
        let folderID = folder.id
        doc.insert(folder, parentPath: Array(topPath.dropLast()), index: topPath.last! + 1)
        folder.children = ids.compactMap { doc.remove($0) }
        // フォルダーの一番下はクリッピングできない
        if !folder.children.isEmpty { folder.children[0].clipping = false }
        doc.modify(folderID) { $0.children = folder.children }
        structureChanged()
    }

    /// 選択中のレイヤーを削除
    public func deleteSelectedLayers() {
        commitTransform()
        let ids = targetLayerIDs
        guard !ids.isEmpty else { return }
        var removed = Set<UUID>()
        for id in ids { doc.node(id).map { collectIDs($0, into: &removed) } }
        var count = 0
        doc.forEachNode { _ in count += 1 }
        guard count > removed.count else { return }
        checkpoint("レイヤーを削除")
        // 削除した一番上のレイヤーがあった位置の、表示上すぐ下のレイヤーを選ぶ
        let before = doc.flattenedForDisplay().map(\.node.id)
        let first = before.firstIndex { removed.contains($0) } ?? 0
        for id in ids { doc.remove(id) }
        let after = doc.flattenedForDisplay().map(\.node.id)
        doc.activeLayerID = after.isEmpty ? nil : after[min(first, after.count - 1)]
        selectedLayerIDs = []
        structureChanged()
    }

    private func collectIDs(_ n: LayerNode, into set: inout Set<UUID>) {
        set.insert(n.id)
        for c in n.children { collectIDs(c, into: &set) }
    }

    public func duplicateActiveLayer() {
        commitTransform()
        guard let id = doc.activeLayerID, let path = doc.indexPath(of: id), let node = doc.node(id) else { return }
        checkpoint("レイヤーを複製")
        func dup(_ n: LayerNode) -> LayerNode {
            var c = n
            c.id = UUID()
            c.children = n.children.map(dup)
            return c
        }
        var copy = dup(node)
        copy.name = node.name + " のコピー"
        doc.insert(copy, parentPath: Array(path.dropLast()), index: path.last! + 1)
        doc.activeLayerID = copy.id
        selectedLayerIDs = []
        structureChanged()
    }

    /// 下のレイヤーに結合
    public func mergeDown() {
        commitTransform()
        guard let id = doc.activeLayerID, let path = doc.indexPath(of: id), path.last! > 0,
              let upper = doc.node(id) else { return }
        let lowerPath = Array(path.dropLast()) + [path.last! - 1]
        guard let lower = doc.node(at: lowerPath), lower.kind == .raster else { return }
        checkpoint("下のレイヤーに結合")
        var tmp = DocumentState(width: doc.width, height: doc.height)
        var base = lower
        base.visible = true
        base.opacity = 1
        base.blendMode = .normal
        base.clipping = false
        var top = upper
        if !upper.clipping { top.clipping = false }
        tmp.layers = [base, top]
        let buf = Compositor.compositeFull(tmp)
        let tiles = buf.withUnsafeBufferPointer { TileMap.from(buffer: $0.baseAddress!, width: doc.width, height: doc.height, gen: gen) }
        doc.remove(id)
        let v = nextVersion()
        doc.modify(lower.id) {
            $0.tiles = tiles
            $0.contentVersion = v
        }
        doc.activeLayerID = lower.id
        selectedLayerIDs = []
        structureChanged()
    }

    public func setLayerProperty(_ id: UUID, label: String, coalesce: Bool = false, _ body: (inout LayerNode) -> Void) {
        checkpoint(label, coalesceKey: coalesce ? "prop-\(label)-\(id)" : nil)
        doc.modify(id, body)
        structureChanged()
    }

    /// 開閉などの履歴に残さない変更
    public func setLayerUIState(_ id: UUID, _ body: (inout LayerNode) -> Void) {
        doc.modify(id, body)
        revision += 1
    }

    /// 上下移動（フォルダーへの出入りを含む）
    public func moveActiveLayer(up: Bool) {
        commitTransform()
        guard let id = doc.activeLayerID, let path = doc.indexPath(of: id), let node = doc.node(id) else { return }
        let parent = Array(path.dropLast())
        let idx = path.last!
        let siblings = parent.isEmpty ? doc.layers : (doc.node(at: parent)?.children ?? [])
        checkpoint("レイヤーの移動")
        doc.remove(id)
        if up {
            if idx + 1 < siblings.count {
                let above = siblings[idx + 1]
                if above.isFolder && above.expanded {
                    // 上のフォルダーの一番下へ入る（削除後は idx の位置にある）
                    doc.insert(node, parentPath: parent + [idx], index: 0)
                } else {
                    doc.insert(node, parentPath: parent, index: idx + 1)
                }
            } else if !parent.isEmpty {
                // フォルダーから上に出る
                doc.insert(node, parentPath: Array(parent.dropLast()), index: parent.last! + 1)
            } else {
                doc.insert(node, parentPath: parent, index: idx)
            }
        } else {
            if idx > 0 {
                let below = siblings[idx - 1]
                if below.isFolder && below.expanded {
                    doc.insert(node, parentPath: parent + [idx - 1], index: below.children.count)
                } else {
                    doc.insert(node, parentPath: parent, index: idx - 1)
                }
            } else if !parent.isEmpty {
                doc.insert(node, parentPath: Array(parent.dropLast()), index: parent.last!)
            } else {
                doc.insert(node, parentPath: parent, index: idx)
            }
        }
        reorderChanged([node])
    }

    public enum DropPlacement: Sendable {
        /// 表示上で target の上（同じ親の中）
        case above
        /// 表示上で target の下
        case below
        /// target フォルダーの一番上
        case into
    }

    /// ドラッグ&ドロップ: id を target の上 / 下 / フォルダーの中へ
    public func moveLayer(_ id: UUID, relativeTo target: UUID, placement: DropPlacement) {
        guard doc.node(id) != nil else { return }
        doc.activeLayerID = id
        selectedLayerIDs = []
        moveSelectedLayers(relativeTo: target, placement: placement)
    }

    /// 選択中のレイヤーをまとめて target の上 / 下 / フォルダーの中へ（並び順は保つ）
    public func moveSelectedLayers(relativeTo target: UUID, placement: DropPlacement) {
        commitTransform()
        let ids = targetLayerIDs
        guard !ids.isEmpty, let tp0 = doc.indexPath(of: target), let tnode0 = doc.node(target) else { return }
        // 自分自身やその子孫には移動できない
        for id in ids {
            if let sp = doc.indexPath(of: id), tp0.starts(with: sp) { return }
        }
        if placement == .into && !tnode0.isFolder { return }
        // 移動しても位置が変わらない場合は履歴に残さない
        if ids.count == 1, let sp = doc.indexPath(of: ids[0]), sp.dropLast() == tp0.dropLast() {
            let si = sp.last!, ti = tp0.last!
            if (placement == .above && si == ti + 1) || (placement == .below && si == ti - 1) { return }
        }
        checkpoint("レイヤーの移動")
        let nodes = ids.compactMap { doc.remove($0) }
        guard let tp = doc.indexPath(of: target), let tnode = doc.node(target) else { return }
        let (parent, index): ([Int], Int)
        switch placement {
        case .into: (parent, index) = (tp, tnode.children.count)
        case .above: (parent, index) = (Array(tp.dropLast()), tp.last! + 1)
        case .below: (parent, index) = (Array(tp.dropLast()), tp.last!)
        }
        for (i, n) in nodes.enumerated() { doc.insert(n, parentPath: parent, index: index + i) }
        reorderChanged(nodes)
    }

    public func moveLayer(_ id: UUID, relativeTo target: UUID, intoFolder: Bool) {
        moveLayer(id, relativeTo: target, placement: intoFolder ? .into : .above)
    }

    /// 画像を新規レイヤーとして追加
    public func addImageLayer(name: String, image: CGImage) {
        commitTransform()
        guard let (buf, w, h) = ImageUtil.loadPremultiplied(image) else { return }
        // キャンバス中央に配置
        var canvas = [UInt8](repeating: 0, count: doc.width * doc.height * 4)
        let ox = (doc.width - w) / 2, oy = (doc.height - h) / 2
        for y in 0..<h {
            let cy = y + oy
            if cy < 0 || cy >= doc.height { continue }
            for x in 0..<w {
                let cx = x + ox
                if cx < 0 || cx >= doc.width { continue }
                for c in 0..<4 { canvas[(cy * doc.width + cx) * 4 + c] = buf[(y * w + x) * 4 + c] }
            }
        }
        checkpoint("画像を読み込み")
        var node = LayerNode(name: name)
        node.tiles = canvas.withUnsafeBufferPointer { TileMap.from(buffer: $0.baseAddress!, width: doc.width, height: doc.height, gen: gen) }
        let (parent, index) = insertionPoint()
        doc.insert(node, parentPath: parent, index: index)
        doc.activeLayerID = node.id
        selectedLayerIDs = []
        structureChanged()
    }

    /// 画像からドキュメントを作る
    public static func document(from image: CGImage, name: String) -> DocumentState? {
        guard let (buf, w, h) = ImageUtil.loadPremultiplied(image) else { return nil }
        var d = DocumentState(width: w, height: h)
        var node = LayerNode(name: name)
        node.tiles = buf.withUnsafeBufferPointer { TileMap.from(buffer: $0.baseAddress!, width: w, height: h, gen: 0) }
        d.layers = [node]
        d.activeLayerID = node.id
        return d
    }

    /// 全体を合成した画像
    public func flattenedImage() -> CGImage? {
        let buf = Compositor.compositeFull(doc)
        return ImageUtil.makeImage(premultiplied: buf, width: doc.width, height: doc.height)
    }

    // MARK: - キャンバス操作

    /// キャンバスの大きさを変える。新しいキャンバスの (0, 0) は元の (originX, originY)（左上基準なら 0, 0）
    public func resizeCanvas(width: Int, height: Int, originX: Int = 0, originY: Int = 0, label: String = "キャンバスサイズ変更") {
        commitTransform()
        cancelAdjustment()
        guard width > 0, height > 0 else { return }
        checkpoint(label)
        let oldW = doc.width, oldH = doc.height
        // 元と新しいキャンバスで重なる範囲（元の座標）
        let overlap = IntRect(x: originX, y: originY, width: width, height: height).intersection(doc.bounds)
        func resize(_ n: LayerNode) -> LayerNode {
            var c = n
            if n.kind == .raster {
                let buf = n.tiles.toBuffer(width: oldW, height: oldH)
                var nb = [UInt8](repeating: 0, count: width * height * 4)
                if !overlap.isEmpty {
                    for y in overlap.minY..<overlap.maxY {
                        let src = (y * oldW + overlap.minX) * 4
                        let dst = ((y - originY) * width + overlap.minX - originX) * 4
                        nb.replaceSubrange(dst..<(dst + overlap.width * 4), with: buf[src..<(src + overlap.width * 4)])
                    }
                }
                c.tiles = nb.withUnsafeBufferPointer { TileMap.from(buffer: $0.baseAddress!, width: width, height: height, gen: gen) }
                c.contentVersion = nextVersion()
            }
            c.children = n.children.map(resize)
            return c
        }
        doc.layers = doc.layers.map(resize)
        doc.width = width
        doc.height = height
        doc.selection = nil
        structureChanged()
    }

    /// 選択範囲を囲む矩形にキャンバスを切り詰める（全レイヤー）。選択範囲がなければ何もしない
    @discardableResult
    public func cropToSelection() -> Bool {
        guard let sel = doc.selection, !sel.bounds.isEmpty else { return false }
        let r = sel.bounds
        resizeCanvas(width: r.width, height: r.height, originX: r.x, originY: r.y, label: "トリミング")
        return true
    }
}
