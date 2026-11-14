import NanopicCore
import NanopicUI
import SwiftUI

// MARK: - パネルの枠

/// 画面に出しっぱなしにできるパネル
enum PanelKind: String, CaseIterable, Identifiable {
    case brushes, brushSettings, layers, colors
    var id: Self { self }

    var width: CGFloat {
        switch self {
        case .brushes: return 270
        case .brushSettings: return 330
        case .layers: return 320
        case .colors: return 290
        }
    }

    /// 出しっぱなしのときの高さ（nil なら中身に合わせる）
    var pinnedHeight: CGFloat? {
        switch self {
        case .brushes: return 400
        case .brushSettings, .layers: return 520
        case .colors: return nil
        }
    }

    /// 出しっぱなしにしたときの最初の位置（ブラシは左、レイヤーと色は右に並べる）
    var leading: Bool { self == .brushes || self == .brushSettings }
    var defaultOffset: CGSize {
        switch self {
        case .brushes: return CGSize(width: 64, height: 0)
        case .brushSettings: return CGSize(width: 64 + PanelKind.brushes.width + 10, height: 0)
        case .colors: return .zero
        case .layers: return CGSize(width: -(PanelKind.colors.width + 10), height: 0)
        }
    }
}

/// 見出しとピンのボタンが付いたパネルの枠。出しっぱなしのときは見出しをドラッグして動かせる
struct PanelChrome<Content: View>: View {
    let title: String
    let pinned: Bool
    var accessory: AnyView?
    var onPin: () -> Void
    var onDrag: (CGSize) -> Void = { _ in }
    var onDragEnd: (CGSize) -> Void = { _ in }
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if pinned {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let accessory { accessory }
                Button(action: onPin) {
                    Image(systemName: pinned ? "pin.slash" : "pin")
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel(pinned ? L("出しっぱなしをやめる") : L("出しっぱなしにする"))
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            // 画面全体を基準に測る（パネル自身を基準にすると、動くたびに基準がずれて震える）
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { onDrag($0.translation) }
                .onEnded { onDragEnd($0.translation) },
                including: pinned ? .all : .subviews)
            Divider()
            content
        }
    }
}

// MARK: - ブラシ

/// ブラシ（消しゴム）のプリセットを選ぶ一覧
struct BrushPresetPanel: View {
    let state: PadState
    @Bindable var editor: Editor
    /// 詳細設定を開く
    var openSettings: () -> Void

    private var isEraser: Bool { editor.tool == .eraser }
    private var presets: [BrushSettings] { isEraser ? editor.erasers : editor.brushes }
    private var activeIndex: Int { isEraser ? editor.activeEraserIndex : editor.activeBrushIndex }

    var body: some View {
        Group {
            List {
                Section {
                    ForEach(Array(presets.enumerated()), id: \.element.id) { i, b in
                        Button {
                            if editor.tool != .brush && editor.tool != .eraser { editor.selectTool(.brush) }
                            if isEraser { editor.activeEraserIndex = i } else { editor.activeBrushIndex = i }
                        } label: {
                            HStack(spacing: 10) {
                                if let img = editor.tip(b.tipID).previewImage(size: 24) {
                                    Image(decorative: img, scale: 1)
                                        .renderingMode(.template)
                                        .frame(width: 24, height: 24)
                                }
                                Text(LName(b.name)).foregroundStyle(Color.primary)
                                Spacer()
                                Text(String(format: "%.0f", b.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                if i == activeIndex { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                        .contextMenu {
                            Button { duplicate(i) } label: { Label("複製", systemImage: "plus.square.on.square") }
                            Button(role: .destructive) { delete(i) } label: { Label("削除", systemImage: "trash") }
                                .disabled(presets.count <= 1)
                        }
                    }
                }
                Section {
                    Button { duplicate(activeIndex) } label: { Label("選択中のプリセットを複製", systemImage: "plus.square.on.square") }
                    Button { openSettings() } label: { Label("詳細設定…", systemImage: "slider.horizontal.3") }
                }
            }
        }
    }

    private func duplicate(_ i: Int) {
        var b = presets[i]
        b.id = UUID()
        b.name += " コピー" // l10n:stored
        if isEraser {
            editor.erasers.insert(b, at: i + 1)
            editor.activeEraserIndex = i + 1
        } else {
            editor.brushes.insert(b, at: i + 1)
            editor.activeBrushIndex = i + 1
        }
    }

    private func delete(_ i: Int) {
        guard presets.count > 1 else { return }
        if isEraser {
            editor.erasers.remove(at: i)
            editor.activeEraserIndex = min(editor.activeEraserIndex, editor.erasers.count - 1)
        } else {
            editor.brushes.remove(at: i)
            editor.activeBrushIndex = min(editor.activeBrushIndex, editor.brushes.count - 1)
        }
    }
}

/// 選択中のブラシ（消しゴム）の詳細設定
struct BrushSettingsPanel: View {
    let state: PadState
    @Bindable var editor: Editor

    private var isEraser: Bool { editor.tool == .eraser }

    private var brush: Binding<BrushSettings> {
        Binding(get: { editor.currentBrush }, set: { editor.currentBrush = $0 })
    }

    var body: some View {
        Group {
            List {
                Section("基本") {
                    SizeSlider(size: brush.size)
                    LabeledSlider(label: "不透明度", value: brush.opacity, range: 0...1, scale: 100, suffix: "%")
                    LabeledSlider(label: "硬さ", value: brush.hardness, range: 0...1, scale: 100, suffix: "%")
                    LabeledSlider(label: "濃度（フロー）", value: brush.flow, range: 0.01...1, scale: 100, suffix: "%")
                    LabeledSlider(label: "間隔", value: brush.spacing, range: 0.02...1, scale: 100, suffix: "%")
                    LabeledSlider(label: "手ブレ補正", value: brush.smoothing, range: 0...1, scale: 100)
                }
                Section("筆圧") {
                    Toggle("サイズに影響", isOn: brush.sizePressure)
                    if brush.wrappedValue.sizePressure {
                        LabeledSlider(label: "最小サイズ", value: brush.minSizeRatio, range: 0...1, scale: 100, suffix: "%")
                    }
                    Toggle("不透明度に影響", isOn: brush.opacityPressure)
                    if brush.wrappedValue.opacityPressure {
                        LabeledSlider(label: "最小不透明度", value: brush.minOpacityRatio, range: 0...1, scale: 100, suffix: "%")
                    }
                    LabeledSlider(label: "筆圧カーブ（硬↔軟）", value: Binding(get: { log2(brush.wrappedValue.pressureGamma) },
                                                                          set: { brush.wrappedValue.pressureGamma = pow(2, $0) }),
                                  range: -2...2, format: "%.2f")
                    LabeledSlider(label: "筆圧のならし（入りの遅さ）", value: brush.pressureSmoothing, range: 0...1, scale: 100, suffix: "%")
                    LabeledSlider(label: "抜きの長さ", value: brush.liftTaper, range: 0...1, scale: 100, suffix: "%")
                    LabeledSlider(label: "サイズ変化の滑らかさ", value: Binding(get: { 1 - (brush.wrappedValue.pressureSlope - 0.05) / 1.95 },
                                                                      set: { brush.wrappedValue.pressureSlope = 0.05 + (1 - $0) * 1.95 }),
                                  range: 0...1, scale: 100, suffix: "%")
                }
                Section("ブラシ先端") {
                    tipGrid
                    LabeledSlider(label: "角度", value: brush.angle, range: -180...180, suffix: "°")
                    LabeledSlider(label: "扁平率", value: brush.roundness, range: 0.05...1, scale: 100, suffix: "%")
                    Toggle("進行方向に回転", isOn: brush.followDirection)
                }
                if !isEraser {
                    Section("色混ぜ") {
                        Toggle("色混ぜを有効にする", isOn: brush.mixEnabled)
                        if brush.wrappedValue.mixEnabled {
                            LabeledSlider(label: "絵の具量", value: brush.paintAmount, range: 0...1, scale: 100, suffix: "%")
                            LabeledSlider(label: "色延び", value: brush.colorStretch, range: 0...1, scale: 100, suffix: "%")
                        }
                    }
                }
                Section {
                    TextField("名前", text: brush.name.localizedName)
                    Button("ブラシを初期状態に戻す", role: .destructive) { state.resetBrushPresets() }
                }
            }
        }
    }

    private var tipGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
            ForEach(editor.tips) { tip in
                Group {
                    if let img = tip.previewImage(size: 30) {
                        Image(decorative: img, scale: 1).renderingMode(.template)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 38, height: 38)
                .background(brush.wrappedValue.tipID == tip.id ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { brush.wrappedValue.tipID = tip.id }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - レイヤー

struct LayerPanel: View {
    let state: PadState
    @Bindable var editor: Editor
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var drag = LayerDragState()
    /// 複数選択の途中（行をタップすると選択に足す・外す）
    @State private var selecting = false
    /// 一覧の見えている高さと、中身の上端の位置（スクロールすると負になる）。ドラッグ中に端で送るのに使う
    @State private var viewportHeight: CGFloat = 0
    @State private var contentTop: CGFloat = 0
    /// ドラッグ中の指の位置（一覧の見えている範囲の座標）
    @State private var dragPoint: CGPoint?
    @State private var autoScroll: Task<Void, Never>?

    private static let viewport = "layerViewport"
    /// 端からこの距離に入ったら送る
    private static let edge: CGFloat = 36

    var body: some View {
        let _ = editor.revision
        VStack(spacing: 0) {
            if let layer = editor.doc.activeLayer {
                properties(layer)
                    .padding(12)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(editor.doc.flattenedForDisplay(), id: \.node.id) { item in
                            row(item.node, depth: item.depth)
                                .id(item.node.id)
                        }
                    }
                    .coordinateSpace(name: LayerDragState.space)
                    .onPreferenceChange(LayerRowFramesKey.self) { drag.rowFrames = $0 }
                    .overlay(alignment: .topLeading) { LayerDropIndicator(drag: drag) }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: LayerContentTopKey.self, value: geo.frame(in: .named(Self.viewport)).minY)
                    })
                }
                .coordinateSpace(name: Self.viewport)
                // ドラッグ中は一覧を指で送らない（端に寄せると自動で送る）
                .scrollDisabled(drag.draggingID != nil)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: LayerViewportHeightKey.self, value: geo.size.height)
                })
                .onPreferenceChange(LayerContentTopKey.self) { contentTop = $0 }
                .onPreferenceChange(LayerViewportHeightKey.self) { viewportHeight = $0 }
                .onChange(of: drag.draggingID) { _, id in
                    if id == nil {
                        autoScroll?.cancel()
                        autoScroll = nil
                    } else if autoScroll == nil {
                        autoScroll = Task { await autoScrollLoop(proxy) }
                    }
                }
            }
            Divider()
            HStack {
                iconButton("doc.badge.plus", L("新規レイヤー")) { editor.addLayer() }
                iconButton("folder.badge.plus", L("新規フォルダー")) { editor.addFolder() }
                iconButton("plus.square.on.square", L("レイヤーを複製")) { editor.duplicateActiveLayer() }
                iconButton("arrow.down.to.line", L("下のレイヤーに結合")) { editor.mergeDown() }
                Button { setSelecting(!selecting) } label: {
                    Image(systemName: selecting ? "checkmark.circle.fill" : "checkmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(selecting ? L("複数選択を終える") : L("複数選択"))
                iconButton("trash", L("レイヤーを削除")) {
                    editor.deleteSelectedLayers()
                    setSelecting(false)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .alert("レイヤー名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名前", text: $renameText)
            Button("OK") {
                if let id = renaming, !renameText.isEmpty {
                    editor.setLayerProperty(id, label: L("名前の変更")) { $0.name = renameText }
                }
                renaming = nil
            }
            Button("キャンセル", role: .cancel) { renaming = nil }
        }
    }

    private func properties(_ layer: LayerNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(Array((layer.isFolder ? [[.passThrough]] + BlendMode.menuGroups : BlendMode.menuGroups).enumerated()), id: \.offset) { _, group in
                        Section {
                            ForEach(group, id: \.self) { m in
                                Button {
                                    editor.setLayerProperty(layer.id, label: L("合成モード")) { $0.blendMode = m }
                                } label: {
                                    if m == layer.blendMode { Label(m.displayName, systemImage: "checkmark") } else { Text(m.displayName) }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(layer.blendMode.displayName)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                Spacer()
                Text(String(format: "%.0f%%", layer.opacity * 100)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(layer.opacity) }, set: { v in
                editor.setLayerProperty(layer.id, label: L("不透明度"), coalesce: true) { $0.opacity = Float((v * 100).rounded() / 100) }
            }), in: 0...1)
            HStack(spacing: 8) {
                flag(L("クリッピング"), "paperclip", layer.clipping) { $0.clipping.toggle() }
                if !layer.isFolder {
                    flag(L("透明ロック"), "checkerboard.rectangle", layer.lockAlpha, label: L("透明ピクセルをロック")) { $0.lockAlpha.toggle() }
                }
                flag(L("ロック"), "lock", layer.locked, label: L("レイヤーをロック")) { $0.locked.toggle() }
            }
        }
    }

    private func flag(_ title: String, _ symbol: String, _ on: Bool, label: String? = nil, _ body: @escaping (inout LayerNode) -> Void) -> some View {
        Button {
            if let id = editor.activeLayerID { editor.setLayerProperty(id, label: label ?? title, body) }
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(on ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func row(_ node: LayerNode, depth: Int) -> some View {
        let active = node.id == editor.activeLayerID
        let selected = editor.isLayerSelected(node.id)
        return HStack(spacing: 6) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 44)
            }
            Button {
                editor.toggleVisibility(node.id)
            } label: {
                Image(systemName: node.visible ? "eye" : "eye.slash")
                    .foregroundStyle(node.visible ? .primary : .tertiary)
                    .frame(width: 32, height: 44)
            }
            .buttonStyle(.plain)
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
            if node.isFolder {
                Button {
                    editor.setLayerUIState(node.id) { $0.expanded.toggle() }
                } label: {
                    Image(systemName: node.expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .frame(width: 20, height: 44)
                }
                .buttonStyle(.plain)
                Image(systemName: "folder")
                    .frame(width: 44, height: 36)
            } else {
                thumbnail(node)
            }
            if node.clipping { Image(systemName: "arrow.turn.left.down").font(.caption).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1)
                if node.blendMode != .normal && node.blendMode != .passThrough || node.opacity < 1 {
                    Text("\(node.blendMode.displayName) \(Int((node.opacity * 100).rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if node.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
            // つまみ: ここをドラッグして並べ替える（フォルダーの行の真ん中に落とすと中へ入る）。
            // 一覧のスクロールとぶつからないよう、つまみだけで受ける
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.viewport))
                    .onChanged { v in
                        dragPoint = v.location
                        drag.update(dragging: node.id, location: contentPoint(v.location))
                    }
                    .onEnded { _ in
                        dragPoint = nil
                        drag.finish(editor: editor)
                    })
                .accessibilityLabel("ドラッグして並べ替え")
        }
        .padding(.leading, 8)
        .background(active ? Color.accentColor.opacity(0.22) : selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting {
                if node.id == editor.activeLayerID { return }
                editor.toggleLayerSelection(node.id)
            } else {
                editor.setActiveLayer(node.id)
            }
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: LayerRowFramesKey.self,
                                   value: [LayerRowFrame(id: node.id, isFolder: node.isFolder, name: node.name,
                                                         frame: geo.frame(in: .named(LayerDragState.space)))])
        })
        .contextMenu {
            Button { renameText = node.name; renaming = node.id } label: { Label("名前の変更", systemImage: "pencil") }
            Button { editor.setActiveLayer(node.id); editor.duplicateActiveLayer() } label: { Label("複製", systemImage: "plus.square.on.square") }
            Button { editor.setActiveLayer(node.id); editor.mergeDown() } label: { Label("下のレイヤーに結合", systemImage: "arrow.down.to.line") }
            Button {
                target(node.id)
                editor.groupSelectedLayers()
                setSelecting(false)
            } label: { Label("フォルダーを作成して挿入", systemImage: "rectangle.stack.badge.plus") }
            Divider()
            Button(role: .destructive) {
                target(node.id)
                editor.deleteSelectedLayers()
                setSelecting(false)
            } label: { Label("削除", systemImage: "trash") }
        }
    }

    /// 長押しのメニューの操作の対象: 選択中の行なら選択中のもの全部、そうでなければその行だけ
    private func target(_ id: UUID) {
        if !editor.isLayerSelected(id) { editor.setActiveLayer(id) }
    }

    private func setSelecting(_ on: Bool) {
        selecting = on
        // やめたら、選択は編集レイヤーだけに戻す
        if !on, let id = editor.activeLayerID { editor.setActiveLayer(id) }
    }

    /// 見えている範囲の座標を、一覧の中身の座標にする
    private func contentPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: p.y - contentTop)
    }

    /// ドラッグ中、指が一覧の上下の端にあれば、1 行ずつ送る
    private func autoScrollLoop(_ proxy: ScrollViewProxy) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(110))
            guard !Task.isCancelled, let p = dragPoint, let id = drag.draggingID else { continue }
            let top = -contentTop, bottom = top + viewportHeight
            let rows = drag.rowFrames.sorted { $0.frame.minY < $1.frame.minY }
            if p.y < Self.edge, let r = rows.last(where: { $0.frame.minY < top - 1 }) {
                proxy.scrollTo(r.id, anchor: .top)
            } else if p.y > viewportHeight - Self.edge, let r = rows.first(where: { $0.frame.maxY > bottom + 1 }) {
                proxy.scrollTo(r.id, anchor: .bottom)
            } else {
                continue
            }
            // 送ると指の下の行が変わるので、落とす先を出し直す（送った量は次の描画で contentTop に入る）
            try? await Task.sleep(for: .milliseconds(16))
            drag.update(dragging: id, location: contentPoint(p))
        }
    }

    private func thumbnail(_ node: LayerNode) -> some View {
        ZStack {
            Checkerboard()
            if let img = state.thumbnail(for: node) {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 44, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.4)))
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

private struct LayerContentTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct LayerViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 透明部分を示す市松模様
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 6
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 1 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(white: 0.85)))
                }
            }
        }
    }
}

// MARK: - 色

struct ColorPanel: View {
    @Bindable var editor: Editor
    /// 小さく表示する（出しっぱなしのとき）
    var pinned = false
    /// 色の選択部分を畳んでパレットだけにする
    var collapsed = false
    private let columns = [GridItem(.adaptive(minimum: 30, maximum: 34), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !collapsed {
                ColorPickerView(editor: editor, squareHeight: pinned ? 180 : 220)
            }
            HStack {
                Text("パレット").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    editor.addToPalette(editor.mainColor)
                } label: {
                    Label("登録", systemImage: "plus")
                        .font(.caption)
                }
                .disabled(editor.palette.contains { Editor.sameColor($0, editor.mainColor) })
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(Array(editor.palette.enumerated()), id: \.offset) { i, c in
                        let selected = Editor.sameColor(c, editor.mainColor)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(c.swiftUIColor)
                            .frame(width: 30, height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.6), lineWidth: 1))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: selected ? 2.5 : 0).padding(-3))
                            .contentShape(Rectangle())
                            .onTapGesture { editor.mainColor = c }
                            .contextMenu {
                                Button("サブカラーにする") { editor.subColor = c }
                                Button("描画色で上書き") { editor.replacePaletteColor(at: i, with: editor.mainColor) }
                                Button("削除", role: .destructive) { editor.removeFromPalette(at: i) }
                            }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 120)
        }
        .padding(16)
    }
}
