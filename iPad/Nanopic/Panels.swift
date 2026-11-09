import NanopicCore
import NanopicUI
import SwiftUI

// MARK: - ブラシ

struct BrushPanel: View {
    let state: PadState
    @Bindable var editor: Editor

    private var isEraser: Bool { editor.tool == .eraser }
    private var presets: [BrushSettings] { isEraser ? editor.erasers : editor.brushes }
    private var activeIndex: Int { isEraser ? editor.activeEraserIndex : editor.activeBrushIndex }

    private var brush: Binding<BrushSettings> {
        Binding(get: { editor.currentBrush }, set: { editor.currentBrush = $0 })
    }

    var body: some View {
        NavigationStack {
            List {
                Section(isEraser ? "消しゴム" : "ブラシ") {
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
                                Text(b.name).foregroundStyle(Color.primary)
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
                    TextField("名前", text: brush.name)
                    Button("このブラシを複製") { duplicate(activeIndex) }
                    Button("ブラシを初期状態に戻す", role: .destructive) { state.resetBrushPresets() }
                }
            }
            .navigationTitle(isEraser ? "消しゴム" : "ブラシ")
            .navigationBarTitleDisplayMode(.inline)
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

    private func duplicate(_ i: Int) {
        var b = presets[i]
        b.id = UUID()
        b.name += " コピー"
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

// MARK: - レイヤー

struct LayerPanel: View {
    let state: PadState
    @Bindable var editor: Editor
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        let _ = editor.revision
        VStack(spacing: 0) {
            if let layer = editor.doc.activeLayer {
                properties(layer)
                    .padding(12)
                Divider()
            }
            List {
                ForEach(editor.doc.flattenedForDisplay(), id: \.node.id) { item in
                    row(item.node, depth: item.depth)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowBackground(item.node.id == editor.activeLayerID ? Color.accentColor.opacity(0.22) : Color.clear)
                }
            }
            .listStyle(.plain)
            Divider()
            HStack {
                iconButton("doc.badge.plus") { editor.addLayer() }
                iconButton("folder.badge.plus") { editor.addFolder() }
                iconButton("plus.square.on.square") { editor.duplicateActiveLayer() }
                iconButton("arrow.down.to.line") { editor.mergeDown() }
                iconButton("arrow.up") { editor.moveActiveLayer(up: true) }
                iconButton("arrow.down") { editor.moveActiveLayer(up: false) }
                iconButton("trash") { editor.deleteSelectedLayers() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .alert("レイヤー名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名前", text: $renameText)
            Button("OK") {
                if let id = renaming, !renameText.isEmpty {
                    editor.setLayerProperty(id, label: "名前の変更") { $0.name = renameText }
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
                                    editor.setLayerProperty(layer.id, label: "合成モード") { $0.blendMode = m }
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
                editor.setLayerProperty(layer.id, label: "不透明度", coalesce: true) { $0.opacity = Float((v * 100).rounded() / 100) }
            }), in: 0...1)
            HStack(spacing: 8) {
                flag("クリッピング", "paperclip", layer.clipping) { $0.clipping.toggle() }
                if !layer.isFolder {
                    flag("透明ロック", "checkerboard.rectangle", layer.lockAlpha, label: "透明ピクセルをロック") { $0.lockAlpha.toggle() }
                }
                flag("ロック", "lock", layer.locked, label: "レイヤーをロック") { $0.locked.toggle() }
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
        HStack(spacing: 6) {
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
        }
        .contentShape(Rectangle())
        .onTapGesture { editor.setActiveLayer(node.id) }
        .contextMenu {
            Button { renameText = node.name; renaming = node.id } label: { Label("名前の変更", systemImage: "pencil") }
            Button { editor.setActiveLayer(node.id); editor.duplicateActiveLayer() } label: { Label("複製", systemImage: "plus.square.on.square") }
            Button { editor.setActiveLayer(node.id); editor.mergeDown() } label: { Label("下のレイヤーに結合", systemImage: "arrow.down.to.line") }
            Divider()
            Button(role: .destructive) { editor.setActiveLayer(node.id); editor.deleteSelectedLayers() } label: { Label("削除", systemImage: "trash") }
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

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderless)
    }
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
    private let columns = [GridItem(.adaptive(minimum: 30, maximum: 34), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ColorPickerView(editor: editor, squareHeight: 220)
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
