import AppKit
import NanopicCore
import SwiftUI

struct LayerPanel: View {
    let state: AppState
    @Bindable var editor: Editor
    @State private var rename = LayerRenameState()
    @State private var drag = LayerDragState()

    var body: some View {
        let _ = editor.revision
        VStack(spacing: 0) {
            propertiesBar
                .padding(8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rowModels(), id: \.id) { model in
                        LayerRowView(model: model,
                                     actions: LayerRowActions(editor: editor, rename: rename, drag: drag))
                            .equatable()
                    }
                }
                .coordinateSpace(name: LayerDragState.space)
                .onPreferenceChange(LayerRowFramesKey.self) { drag.rowFrames = $0 }
                // ドラッグ中の表示はこのオーバーレイだけが更新される（行は再描画しない）
                .overlay(alignment: .topLeading) { LayerDropIndicator(drag: drag) }
            }
            // 編集レイヤーが変わったら名前の編集を確定する
            .onChange(of: editor.doc.activeLayerID) { _, _ in rename.commit(editor) }
            Divider()
            actionBar
                .padding(6)
        }
    }

    // MARK: プロパティ

    @ViewBuilder
    private var propertiesBar: some View {
        if let layer = editor.doc.activeLayer {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Menu {
                        if layer.isFolder {
                            Button(BlendMode.passThrough.displayName) { setBlend(layer, .passThrough) }
                            Divider()
                        }
                        ForEach(BlendMode.menuGroups.indices, id: \.self) { gi in
                            ForEach(BlendMode.menuGroups[gi], id: \.self) { m in
                                Button(m.displayName) { setBlend(layer, m) }
                            }
                            Divider()
                        }
                    } label: {
                        Text(layer.blendMode.displayName)
                    }
                    .frame(width: 130)
                    Spacer()
                    Text("\(Int((layer.opacity * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
                Slider(value: Binding(get: { layer.opacity }, set: { v in
                    editor.setLayerProperty(layer.id, label: "不透明度", coalesce: true) { $0.opacity = (v * 100).rounded() / 100 }
                }), in: 0...1)
                .controlSize(.small)
                HStack(spacing: 4) {
                    toggleButton("paperclip", "下のレイヤーでクリッピング (⌘⌥G)", layer.clipping) {
                        editor.setLayerProperty(layer.id, label: "クリッピング") { $0.clipping.toggle() }
                    }
                    toggleButton("checkerboard.rectangle", "透明ピクセルをロック", layer.lockAlpha) {
                        editor.setLayerProperty(layer.id, label: "透明ピクセルをロック") { $0.lockAlpha.toggle() }
                    }
                    .disabled(layer.isFolder)
                    toggleButton("lock", "レイヤーをロック", layer.locked) {
                        editor.setLayerProperty(layer.id, label: "レイヤーをロック") { $0.locked.toggle() }
                    }
                    toggleButton("scope", "参照レイヤーに設定", layer.isReference) {
                        editor.setLayerProperty(layer.id, label: "参照レイヤー") { $0.isReference.toggle() }
                    }
                    Spacer()
                }
            }
        }
    }

    private func setBlend(_ layer: LayerNode, _ m: NanopicCore.BlendMode) {
        editor.setLayerProperty(layer.id, label: "合成モード") { $0.blendMode = m }
    }

    private func toggleButton(_ symbol: String, _ help: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .background(on ? Color.accentColor.opacity(0.4) : Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 行

    private func rowModels() -> [LayerRowModel] {
        let activeID = editor.doc.activeLayerID
        return editor.doc.flattenedForDisplay().map { node, depth in
            // リグモード（実験的な機能）を切っていれば、デフォーマは出さない
            LayerRowModel(node: node, depth: depth, inSwitch: editor.isInSwitch(node.id), showsRig: state.rigEnabled,
                          timelineOpen: state.timelineOpen, hasTrack: editor.hasTrack(node.id),
                          deformers: state.rigEnabled ? editor.deformers(on: node.id).map(\.name) : [],
                          active: node.id == activeID,
                          selected: editor.selectedLayerIDs.contains(node.id), renaming: node.id == rename.id,
                          thumbnail: node.isFolder ? nil : state.thumbnail(for: node))
        }
    }

    // MARK: アクション

    private var actionBar: some View {
        HStack(spacing: 2) {
            iconButton("doc.badge.plus", "新規ラスターレイヤー (⇧⌘N)") { editor.addLayer() }
            iconButton("folder.badge.plus", "新規レイヤーフォルダー") { editor.addFolder() }
            iconButton("plus.square.on.square", "レイヤーを複製") { editor.duplicateActiveLayer() }
            iconButton("arrow.down.to.line", "下のレイヤーに結合 (⌘E)") { editor.mergeDown() }
            Spacer()
            iconButton("arrow.up", "上へ移動") { editor.moveActiveLayer(up: true) }
            iconButton("arrow.down", "下へ移動") { editor.moveActiveLayer(up: false) }
            iconButton("trash", "レイヤーを削除") { editor.deleteSelectedLayers() }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct CheckerboardView: View {
    /// 10x10 の市松模様（5px マス）を 1 度だけ作ってタイル表示する
    private static let tile: NSImage = {
        let img = NSImage(size: NSSize(width: 10, height: 10))
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        NSRect(x: 5, y: 0, width: 5, height: 5).fill()
        NSRect(x: 0, y: 5, width: 5, height: 5).fill()
        img.unlockFocus()
        return img
    }()

    var body: some View {
        Image(nsImage: Self.tile).resizable(resizingMode: .tile)
    }
}

// MARK: - レイヤー行

/// 行の表示に必要な値だけを持つモデル。等しければ SwiftUI は行を再描画しない。
struct LayerRowModel: Equatable {
    let id: UUID
    let name: String
    let isFolder: Bool
    let isSwitch: Bool
    /// 親がスイッチフォルダー（目のアイコンをラジオボタン風にする）
    let inSwitch: Bool
    /// リグモードを使う（デフォーマのメニューを出す）
    let showsRig: Bool
    /// タイムラインを出している（「タイムラインに足す」を出す）
    let timelineOpen: Bool
    /// タイムラインに行がある（スイッチの子ならそのフォルダーの行）
    let hasTrack: Bool
    /// 付いているデフォーマの名前
    let deformers: [String]
    let expanded: Bool
    let visible: Bool
    let clipping: Bool
    let lockAlpha: Bool
    let locked: Bool
    let isReference: Bool
    let opacity: Float
    let blendMode: NanopicCore.BlendMode
    let depth: Int
    let active: Bool
    let selected: Bool
    let renaming: Bool
    let thumbnail: NSImage?

    init(node: LayerNode, depth: Int, inSwitch: Bool, showsRig: Bool, timelineOpen: Bool, hasTrack: Bool, deformers: [String], active: Bool, selected: Bool, renaming: Bool, thumbnail: NSImage?) {
        id = node.id
        name = node.name
        isFolder = node.isFolder
        isSwitch = node.isFolder && node.isSwitch
        self.inSwitch = inSwitch
        self.showsRig = showsRig
        self.timelineOpen = timelineOpen
        self.hasTrack = hasTrack
        self.deformers = deformers
        expanded = node.expanded
        visible = node.visible
        clipping = node.clipping
        lockAlpha = node.lockAlpha
        locked = node.locked
        isReference = node.isReference
        opacity = node.opacity
        blendMode = node.blendMode
        self.depth = depth
        self.active = active
        self.selected = selected
        self.renaming = renaming
        self.thumbnail = thumbnail
    }

    static func == (a: LayerRowModel, b: LayerRowModel) -> Bool {
        a.id == b.id && a.name == b.name && a.isFolder == b.isFolder && a.isSwitch == b.isSwitch && a.inSwitch == b.inSwitch && a.showsRig == b.showsRig && a.timelineOpen == b.timelineOpen && a.hasTrack == b.hasTrack
            && a.deformers == b.deformers
            && a.expanded == b.expanded
            && a.visible == b.visible && a.clipping == b.clipping && a.lockAlpha == b.lockAlpha
            && a.locked == b.locked && a.isReference == b.isReference && a.opacity == b.opacity
            && a.blendMode == b.blendMode && a.depth == b.depth && a.active == b.active && a.selected == b.selected
            && a.renaming == b.renaming && a.thumbnail === b.thumbnail
    }
}

/// 行から呼ぶ操作（比較対象外）
struct LayerRowActions {
    let editor: Editor
    let rename: LayerRenameState
    let drag: LayerDragState
}

// MARK: - ドラッグ&ドロップ

struct LayerRowFrame: Equatable {
    let id: UUID
    let isFolder: Bool
    let name: String
    let frame: CGRect
}

struct LayerRowFramesKey: PreferenceKey {
    static let defaultValue: [LayerRowFrame] = []
    static func reduce(value: inout [LayerRowFrame], nextValue: () -> [LayerRowFrame]) {
        value.append(contentsOf: nextValue())
    }
}

/// リスト内で完結するドラッグ。NSItemProvider を介さないので軽く、即座に反応する。
@Observable
final class LayerDragState {
    static let space = "layerList"

    struct Target: Equatable {
        let id: UUID
        let placement: Editor.DropPlacement
        let frame: CGRect
    }

    @ObservationIgnored var rowFrames: [LayerRowFrame] = []
    private(set) var draggingID: UUID?
    private(set) var draggingName = ""
    private(set) var location: CGPoint = .zero
    private(set) var target: Target?

    func update(dragging id: UUID, location p: CGPoint) {
        if draggingID != id {
            draggingID = id
            draggingName = rowFrames.first { $0.id == id }?.name ?? ""
        }
        location = p
        let t = computeTarget(p, dragging: id)
        if t != target { target = t }
    }

    private func computeTarget(_ p: CGPoint, dragging id: UUID) -> Target? {
        let sorted = rowFrames.sorted { $0.frame.minY < $1.frame.minY }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        // リストの上下にはみ出したら先頭の上 / 末尾の下
        let row: LayerRowFrame
        if p.y < first.frame.minY {
            row = first
        } else if p.y >= last.frame.maxY {
            row = last
        } else if let r = sorted.first(where: { p.y >= $0.frame.minY && p.y < $0.frame.maxY }) {
            row = r
        } else {
            return nil
        }
        if row.id == id { return nil }
        let f = row.frame
        let rel = (p.y - f.minY) / max(f.height, 1)
        let placement: Editor.DropPlacement
        if row.isFolder && rel > 0.25 && rel < 0.75 {
            placement = .into
        } else {
            placement = rel < 0.5 ? .above : .below
        }
        return Target(id: row.id, placement: placement, frame: f)
    }

    func finish(editor: Editor) {
        defer {
            draggingID = nil
            target = nil
        }
        guard let id = draggingID, let t = target else { return }
        // 選択中のレイヤーをつかんだら、選択中のものをまとめて動かす
        if editor.isLayerSelected(id) {
            editor.moveSelectedLayers(relativeTo: t.id, placement: t.placement)
        } else {
            editor.moveLayer(id, relativeTo: t.id, placement: t.placement)
        }
    }
}

struct LayerDropIndicator: View {
    let drag: LayerDragState

    var body: some View {
        if drag.draggingID != nil {
            ZStack(alignment: .topLeading) {
                if let t = drag.target {
                    switch t.placement {
                    case .into:
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .frame(width: t.frame.width, height: t.frame.height)
                            .offset(x: t.frame.minX, y: t.frame.minY)
                    case .above, .below:
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: t.frame.width, height: 2)
                            .offset(x: t.frame.minX, y: (t.placement == .above ? t.frame.minY : t.frame.maxY) - 1)
                    }
                }
                Text(drag.draggingName)
                    .font(.callout)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: drag.location.x + 8, y: drag.location.y - 10)
            }
            .allowsHitTesting(false)
        }
    }
}

struct LayerRowView: View, Equatable {
    let model: LayerRowModel
    let actions: LayerRowActions
    @FocusState private var renameFocused: Bool

    static func == (a: LayerRowView, b: LayerRowView) -> Bool { a.model == b.model }

    private var editor: Editor { actions.editor }
    private var rename: LayerRenameState { actions.rename }
    static let height: CGFloat = 44

    var body: some View {
        let m = model
        HStack(spacing: 0) {
            // 表示・非表示
            Button {
                rename.commit(editor)
                editor.toggleVisibility(m.id)
            } label: {
                Group {
                    if m.inSwitch {
                        // スイッチフォルダーの子は 1 つだけ表示するので、ラジオボタン風に
                        Image(systemName: m.visible ? "largecircle.fill.circle" : "circle")
                    } else {
                        Image(systemName: m.visible ? "eye" : "eye.slash")
                    }
                }
                .foregroundStyle(m.visible ? .primary : .tertiary)
                .frame(width: 26, height: Self.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(m.inSwitch ? "この子に切り替える" : "表示・非表示")
            Divider()
            // 複数選択（編集レイヤーはペンのマーク）
            Button {
                rename.commit(editor)
                editor.toggleLayerSelection(m.id)
            } label: {
                Group {
                    if m.active {
                        Image(systemName: "pencil")
                    } else if m.selected {
                        Image(systemName: "checkmark")
                    } else {
                        Color.clear
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: Self.height)
                .background(m.selected || m.active ? Color.accentColor.opacity(0.35) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("レイヤーを選択に追加・除外")
            Divider()

            HStack(spacing: 4) {
                if m.depth > 0 {
                    Spacer().frame(width: CGFloat(m.depth) * 14)
                }
                if m.clipping {
                    Rectangle().fill(Color.red.opacity(0.8)).frame(width: 3, height: 34)
                }
                if m.isFolder {
                    Button {
                        editor.setLayerUIState(m.id) { $0.expanded.toggle() }
                    } label: {
                        Image(systemName: m.expanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                    Image(systemName: m.isSwitch ? "switch.2" : m.expanded ? "folder" : "folder.fill")
                        .frame(width: 20)
                        .help(m.isSwitch ? "スイッチフォルダー（子を 1 つだけ表示）" : "")
                } else {
                    ZStack {
                        CheckerboardView()
                        if let img = m.thumbnail {
                            Image(nsImage: img)
                                .resizable()
                                .interpolation(.medium)
                                .aspectRatio(contentMode: .fit)
                        }
                    }
                    .frame(width: 44, height: 36)
                    .overlay(Rectangle().stroke(Color.gray.opacity(0.5), lineWidth: 0.5))
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("\(Int((m.opacity * 100).rounded()))% \(m.blendMode.displayName)")
                        if m.lockAlpha { Image(systemName: "checkerboard.rectangle") }
                        if m.locked { Image(systemName: "lock.fill") }
                        if m.isReference { Image(systemName: "scope") }
                        if !m.deformers.isEmpty {
                            Image(systemName: "skew").help("デフォーマ: " + m.deformers.joined(separator: "、"))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    if m.renaming {
                        TextField("", text: Bindable(rename).text)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .focused($renameFocused)
                            .onSubmit { rename.commit(editor) }
                            .onExitCommand { rename.cancel() }
                            .onAppear { renameFocused = true }
                            .onChange(of: renameFocused) { _, focused in
                                if !focused { rename.commit(editor) }
                            }
                    } else {
                        Text(m.name)
                            .font(.callout)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: Self.height)
            .contentShape(Rectangle())
            // ダブルクリック判定の待ちを避けるため、単一のタップでクリック回数を見る
            .onTapGesture { tap() }
        }
        .background(m.active ? Color.accentColor.opacity(0.28) : m.selected ? Color.accentColor.opacity(0.14) : Color.clear)
        .overlay(alignment: .bottom) { Divider() }
        .background(GeometryReader { geo in
            Color.clear.preference(key: LayerRowFramesKey.self,
                                   value: [LayerRowFrame(id: m.id, isFolder: m.isFolder, name: m.name,
                                                         frame: geo.frame(in: .named(LayerDragState.space)))])
        })
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(LayerDragState.space))
            .onChanged { v in actions.drag.update(dragging: m.id, location: v.location) }
            .onEnded { _ in actions.drag.finish(editor: editor) })
        .contextMenu {
            Button("複製") { editor.setActiveLayer(m.id); editor.duplicateActiveLayer() }
            Button("下のレイヤーに結合") { editor.setActiveLayer(m.id); editor.mergeDown() }
            Button("フォルダーを作成して挿入") { targetThis(); editor.groupSelectedLayers() }
            if m.isFolder {
                Button(m.isSwitch ? "ふつうのフォルダーに戻す" : "スイッチフォルダーにする") { editor.setSwitch(m.id, !m.isSwitch) }
            }
            if m.timelineOpen {
                if m.hasTrack {
                    Button("タイムラインから外す") { editor.removeTrack(of: m.id) }
                } else {
                    Button("タイムラインに足す") { editor.addTrack(editor.timelineTarget(m.id)) }
                }
            }
            if m.showsRig {
                Menu("デフォーマ") {
                    Button("移動・回転デフォーマを付ける") { editor.addDeformer(to: m.id, kind: .rotation) }
                    Button("ワープデフォーマを付ける") { editor.addDeformer(to: m.id, kind: .warp) }
                    let ds = editor.deformers(on: m.id)
                    if !ds.isEmpty {
                        Divider()
                        ForEach(ds, id: \.id) { d in
                            Button("「\(d.name)」を外す") { editor.removeDeformer(d.id) }
                        }
                    }
                }
            }
            Divider()
            Button("削除") { targetThis(); editor.deleteSelectedLayers() }
        }
    }

    private func tap() {
        let event = NSApp.currentEvent
        if event?.clickCount == 2 {
            rename.begin(model.id, name: model.name)
            return
        }
        rename.commit(editor)
        let flags = event?.modifierFlags ?? []
        if flags.contains(.command) {
            editor.toggleLayerSelection(model.id)
        } else if flags.contains(.shift) {
            editor.selectLayerRange(to: model.id)
        } else {
            editor.setActiveLayer(model.id)
        }
    }

    /// 右クリックしたレイヤーが選択外なら、そのレイヤーだけを対象にする
    private func targetThis() {
        if !editor.isLayerSelected(model.id) { editor.setActiveLayer(model.id) }
    }
}

/// レイヤー名のインライン編集。別のレイヤーを選ぶ・フォーカスが外れると確定する
@Observable
final class LayerRenameState {
    private(set) var id: UUID?
    var text = ""

    func begin(_ id: UUID, name: String) {
        text = name
        self.id = id
    }

    func commit(_ editor: Editor) {
        guard let id else { return }
        self.id = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        let name = text
        if !name.isEmpty, let node = editor.doc.node(id), node.name != name {
            editor.setLayerProperty(id, label: "名前の変更") { $0.name = name }
        }
    }

    func cancel() {
        id = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}
