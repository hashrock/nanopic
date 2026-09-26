import NanopicCore
import SwiftUI

// MARK: - ツールバー（左端）

struct ToolBarView: View {
    @Bindable var editor: Editor

    private let groups: [[Tool]] = [
        [.brush, .eraser, .fill, .lassoFill, .lassoErase, .eyedropper],
        [.selectRect, .selectEllipse, .lasso, .wand],
        [.move, .transform],
        [.hand, .zoom],
    ]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(groups.indices, id: \.self) { gi in
                ForEach(groups[gi], id: \.self) { tool in
                    Button {
                        selectTool(tool)
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 15))
                            .frame(width: 32, height: 30)
                            .background(editor.tool == tool ? Color.accentColor.opacity(0.35) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tool.displayName)
                }
                if gi < groups.count - 1 { Divider().frame(width: 28) }
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 44)
    }

    private func selectTool(_ tool: Tool) {
        if tool != .transform && tool != .move { editor.commitTransform() }
        editor.tool = tool
        if tool == .transform { editor.beginTransform() }
    }
}

// MARK: - 共通部品

struct LabeledSlider: View {
    let label: String
    @Binding var value: Float
    var range: ClosedRange<Float>
    var format: String = "%.0f"
    var scale: Float = 1
    var suffix: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value * scale) + suffix)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

/// 対数スケールのサイズスライダー
struct SizeSlider: View {
    @Binding var size: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("ブラシサイズ").font(.caption)
                Spacer()
                Text(size < 10 ? String(format: "%.1f px", size) : String(format: "%.0f px", size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { log(max(size, 0.5)) }, set: { size = (exp($0) * 10).rounded() / 10 }),
                   in: log(0.5)...log(1000))
                .controlSize(.small)
        }
    }
}

// MARK: - ツールプロパティ

struct ToolOptionsView: View {
    let state: AppState
    @Bindable var editor: Editor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(editor.tool.displayName)
                    .font(.headline)
                switch editor.tool {
                case .brush, .eraser:
                    BrushOptionsView(state: state, editor: editor)
                case .fill:
                    FillOptionsView(settings: $editor.fillSettings, showExpand: true)
                case .wand:
                    FillOptionsView(settings: $editor.wandSettings, showExpand: true)
                    selectionHelp
                case .lassoFill, .lassoErase:
                    Toggle("アンチエイリアス", isOn: $editor.lassoFillAntialias).font(.caption)
                    Text(editor.tool == .lassoFill ? "囲んだ範囲を描画色で塗る" : "囲んだ範囲を消す")
                        .font(.caption).foregroundStyle(.secondary)
                case .selectRect, .selectEllipse, .lasso:
                    Toggle("アンチエイリアス", isOn: $editor.selectionAntialias).font(.caption)
                    selectionHelp
                    selectionButtons
                case .move, .transform:
                    TransformOptionsView(editor: editor)
                case .eyedropper:
                    Text("クリックで表示色を取得\n⌘+クリックで編集レイヤーから取得").font(.caption).foregroundStyle(.secondary)
                case .hand:
                    Text("ドラッグでスクロール\nトラックパッド: 2本指でスクロール、ピンチでズーム、回転ジェスチャーで回転").font(.caption).foregroundStyle(.secondary)
                case .zoom:
                    Text("左右にドラッグでズーム").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectionHelp: some View {
        Text("Shift: 追加 / Option: 削除 / Shift+Option: 共通部分").font(.caption2).foregroundStyle(.secondary)
    }

    private var selectionButtons: some View {
        HStack {
            Button("全選択") { editor.selectAll() }
            Button("解除") { editor.deselect() }
            Button("反転") { editor.invertSelection() }
        }
        .controlSize(.small)
    }
}

struct BrushOptionsView: View {
    let state: AppState
    @Bindable var editor: Editor

    private var isEraser: Bool { editor.tool == .eraser }
    private var presets: [BrushSettings] { isEraser ? editor.erasers : editor.brushes }
    private var activeIndex: Int { isEraser ? editor.activeEraserIndex : editor.activeBrushIndex }

    private var brush: Binding<BrushSettings> {
        Binding(get: { editor.currentBrush }, set: { editor.currentBrush = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            presetList
            Divider()
            SizeSlider(size: brush.size)
            LabeledSlider(label: "サイズのランダム", value: brush.sizeJitter, range: 0...1, scale: 100, suffix: "%")
            LabeledSlider(label: "不透明度", value: brush.opacity, range: 0...1, scale: 100, suffix: "%")
            if !isEraser || true {
                LabeledSlider(label: "硬さ", value: brush.hardness, range: 0...1, scale: 100, suffix: "%")
            }
            LabeledSlider(label: "濃度（フロー）", value: brush.flow, range: 0.01...1, scale: 100, suffix: "%")
            LabeledSlider(label: "間隔", value: brush.spacing, range: 0.02...1, scale: 100, suffix: "%")

            GroupBox("筆圧") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("サイズに影響", isOn: brush.sizePressure).font(.caption)
                    if brush.wrappedValue.sizePressure {
                        LabeledSlider(label: "最小サイズ", value: brush.minSizeRatio, range: 0...1, scale: 100, suffix: "%")
                    }
                    Toggle("不透明度に影響", isOn: brush.opacityPressure).font(.caption)
                    if brush.wrappedValue.opacityPressure {
                        LabeledSlider(label: "最小不透明度", value: brush.minOpacityRatio, range: 0...1, scale: 100, suffix: "%")
                    }
                    LabeledSlider(label: "筆圧カーブ（硬↔軟）", value: Binding(get: { log2(brush.wrappedValue.pressureGamma) },
                                                                          set: { brush.wrappedValue.pressureGamma = pow(2, $0) }),
                                  range: -2...2, format: "%.2f")
                    LabeledSlider(label: "サイズ変化の滑らかさ", value: Binding(get: { 1 - (brush.wrappedValue.pressureSlope - 0.05) / 1.95 },
                                                                        set: { brush.wrappedValue.pressureSlope = 0.05 + (1 - $0) * 1.95 }),
                                  range: 0...1, scale: 100, suffix: "%")
                }
                .padding(4)
            }

            LabeledSlider(label: "手ブレ補正", value: brush.smoothing, range: 0...1, scale: 100)

            GroupBox("ブラシ先端") {
                VStack(alignment: .leading, spacing: 6) {
                    tipGrid
                    LabeledSlider(label: "角度", value: brush.angle, range: -180...180, suffix: "°")
                    LabeledSlider(label: "扁平率", value: brush.roundness, range: 0.05...1, scale: 100, suffix: "%")
                    Toggle("進行方向に回転", isOn: brush.followDirection).font(.caption)
                    LabeledSlider(label: "角度のランダム", value: brush.angleJitter, range: 0...1, scale: 100, suffix: "%")
                }
                .padding(4)
            }

            if !isEraser {
                GroupBox("色混ぜ") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("色混ぜを有効にする", isOn: brush.mixEnabled).font(.caption)
                        if brush.wrappedValue.mixEnabled {
                            LabeledSlider(label: "絵の具量", value: brush.paintAmount, range: 0...1, scale: 100, suffix: "%")
                            LabeledSlider(label: "色延び", value: brush.colorStretch, range: 0...1, scale: 100, suffix: "%")
                        }
                    }
                    .padding(4)
                }
                GroupBox("ぼかし") {
                    LabeledSlider(label: "ぼかし強さ", value: brush.blurAmount, range: 0...1, scale: 100, suffix: "%")
                        .padding(4)
                }
                GroupBox("ゆがみ") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledSlider(label: "前方（押し出し）", value: brush.warpPush, range: 0...1, scale: 100, suffix: "%")
                        LabeledSlider(label: "縮小 ↔ 膨張", value: brush.warpRadial, range: -1...1, scale: 100, suffix: "%")
                        LabeledSlider(label: "左回転 ↔ 右回転", value: brush.warpTwist, range: -1...1, scale: 100, suffix: "%")
                    }
                    .padding(4)
                }
            }
        }
        .onChange(of: editor.brushes) { _, _ in state.savePreferences() }
        .onChange(of: editor.erasers) { _, _ in state.savePreferences() }
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(presets.enumerated()), id: \.element.id) { i, b in
                HStack(spacing: 6) {
                    if let img = editor.tip(b.tipID).previewImage(size: 20) {
                        Image(decorative: img, scale: 1)
                            .renderingMode(.template)
                            .frame(width: 20, height: 20)
                    }
                    Text(b.name).font(.callout)
                    Spacer()
                    Text(String(format: "%.0f", b.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(i == activeIndex ? Color.accentColor.opacity(0.3) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture {
                    if isEraser { editor.activeEraserIndex = i } else { editor.activeBrushIndex = i }
                }
                .contextMenu {
                    Button("複製") { duplicate(i) }
                    Button("削除") { delete(i) }.disabled(presets.count <= 1)
                }
            }
            HStack {
                TextField("名前", text: brush.name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Button { duplicate(activeIndex) } label: { Image(systemName: "plus.square.on.square") }
                    .help("ブラシを複製")
                Button { delete(activeIndex) } label: { Image(systemName: "trash") }
                    .disabled(presets.count <= 1)
                    .help("ブラシを削除")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
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

    private var tipGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 5), spacing: 4) {
            ForEach(editor.tips) { tip in
                Group {
                    if let img = tip.previewImage(size: 30) {
                        Image(decorative: img, scale: 1).renderingMode(.template)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 32, height: 32)
                .background(brush.wrappedValue.tipID == tip.id ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onTapGesture { brush.wrappedValue.tipID = tip.id }
                .help(tip.name)
            }
            Button {
                state.importBrushTip()
            } label: {
                Image(systemName: "photo.badge.plus").frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .background(Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .help("画像からブラシ先端を読み込み")
        }
    }
}

struct FillOptionsView: View {
    @Binding var settings: FillSettings
    var showExpand: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("参照", selection: $settings.reference) {
                ForEach(FillReference.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .font(.caption)
            Toggle("隣接ピクセルのみ", isOn: $settings.contiguous).font(.caption)
            LabeledSlider(label: "色の誤差", value: $settings.tolerance, range: 0...1, scale: 100, suffix: "%")
            if showExpand {
                LabeledSlider(label: "領域拡縮",
                              value: Binding(get: { Float(settings.expand) }, set: { settings.expand = Int($0.rounded()) }),
                              range: -10...20, suffix: " px")
                LabeledSlider(label: "隙間閉じ",
                              value: Binding(get: { Float(settings.gapClose) }, set: { settings.gapClose = Int($0.rounded()) }),
                              range: 0...10, suffix: " px")
            }
        }
    }
}

struct TransformOptionsView: View {
    @Bindable var editor: Editor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let f = editor.floating {
                let _ = editor.revision
                let p = f.params
                Group {
                    Text(String(format: "位置: %.0f, %.0f", p.tx, p.ty))
                    Text(String(format: "拡大率: %.1f%% × %.1f%%", p.sx * 100, p.sy * 100))
                    Text(String(format: "回転: %.1f°", p.rotation * 180 / .pi))
                }
                .font(.caption.monospacedDigit())
                HStack {
                    Button("左右反転") {
                        var q = p; q.sx = -q.sx; editor.updateTransform(q)
                    }
                    Button("上下反転") {
                        var q = p; q.sy = -q.sy; editor.updateTransform(q)
                    }
                }
                .controlSize(.small)
                HStack {
                    Button("確定 (Return)") { editor.commitTransform() }
                        .keyboardShortcut(.defaultAction)
                    Button("キャンセル (Esc)") { editor.cancelTransform() }
                }
            } else {
                Text(editor.tool == .move ? "ドラッグでレイヤー（選択範囲）を移動" : "キャンバスをクリックで変形開始")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("ハンドル: 拡大縮小（Shift で縦横比固定）\n枠の外: 回転（Shift で 15° 単位）\n枠の内側: 移動")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
