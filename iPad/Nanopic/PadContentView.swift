import NanopicCore
import NanopicUI
import SwiftUI
import UniformTypeIdentifiers

struct PadContentView: View {
    let state: PadState
    @Bindable var editor: Editor
    @Environment(\.scenePhase) private var scenePhase

    @State private var showBrushes = false
    @State private var showLayers = false
    @State private var showColors = false
    @State private var showNewDocument = false
    @State private var importing: ImportKind?
    @State private var exportFile: ExportFile?
    @State private var exportType: UTType = .png
    @State private var showExporter = false
    @State private var confirmDiscard: PendingAction?

    enum ImportKind: Identifiable {
        case open, layer
        var id: Self { self }
    }

    enum PendingAction: Identifiable {
        case new, open
        var id: Self { self }
    }

    init(state: PadState) {
        self.state = state
        editor = state.editor
    }

    var body: some View {
        ZStack {
            CanvasRepresentable(state: state)
                .ignoresSafeArea()
            HStack {
                SideSliders(editor: editor)
                    .padding(.leading, 10)
                Spacer()
            }
            VStack {
                Spacer()
                if let t = state.toast {
                    Text(t)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity)
                        .padding(.bottom, 24)
                }
            }
            .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .top, spacing: 0) { toolbar }
        .sheet(isPresented: $showNewDocument) {
            NewDocumentSheet { w, h in state.newDocument(width: w, height: h) }
        }
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing == .layer ? [.png, .jpeg, .heic, .tiff, .gif] : PadState.openableTypes) { result in
            let kind = importing
            if case let .success(url) = result {
                if kind == .layer { state.importLayer(url: url) } else { state.open(url: url) }
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportFile, contentType: exportType,
                      defaultFilename: state.documentName) { result in
            if case let .success(url) = result { state.show("「\(url.lastPathComponent)」に書き出しました") }
            exportFile = nil
        }
        .confirmationDialog("変更が保存されていません", isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }),
                            titleVisibility: .visible, presenting: confirmDiscard) { action in
            Button("保存してから続ける") {
                if state.save() { perform(action) }
            }
            Button("変更を破棄", role: .destructive) { perform(action) }
            Button("キャンセル", role: .cancel) {}
        }
        .onOpenURL { url in state.open(url: url) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { state.autosave() }
        }
        .onChange(of: state.showColorPanelRequest) { _, _ in showColors = true }
        .onChange(of: editor.brushes) { _, _ in state.savePreferences() }
        .onChange(of: editor.erasers) { _, _ in state.savePreferences() }
        .onChange(of: editor.palette) { _, _ in state.savePreferences() }
    }

    private func requestDiscard(_ action: PendingAction) {
        if editor.isDirty { confirmDiscard = action } else { perform(action) }
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case .new: showNewDocument = true
        case .open: importing = .open
        }
    }

    private func export(_ type: UTType) {
        do {
            let data: Data
            if type == .psd {
                data = try state.psdData()
            } else {
                guard let d = state.pngData() else { return }
                data = d
            }
            exportType = type
            exportFile = ExportFile(data: data)
            showExporter = true
        } catch {
            state.show("書き出しに失敗しました: \(error.localizedDescription)")
        }
    }

    // MARK: - ツールバー

    private var toolbar: some View {
        HStack(spacing: 6) {
            Menu {
                Button { requestDiscard(.new) } label: { Label("新規…", systemImage: "doc.badge.plus") }
                    .keyboardShortcut("n")
                Button { requestDiscard(.open) } label: { Label("開く…", systemImage: "folder") }
                    .keyboardShortcut("o")
                Divider()
                Button { state.save() } label: { Label("保存", systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s")
                Button { export(.psd) } label: { Label("PSD を書き出し…", systemImage: "square.and.arrow.up") }
                Button { export(.png) } label: { Label("PNG を書き出し…", systemImage: "photo") }
                Divider()
                Button { importing = .layer } label: { Label("画像をレイヤーとして読み込み…", systemImage: "photo.badge.plus") }
                Divider()
                Toggle(isOn: Binding(get: { state.fingerDrawing }, set: { state.fingerDrawing = $0 })) {
                    Label("指で描く", systemImage: "hand.point.up.left")
                }
                Toggle(isOn: Binding(get: { state.perfEnabled }, set: { state.perfEnabled = $0 })) {
                    Label("性能を計測", systemImage: "speedometer")
                }
            } label: {
                Image(systemName: "doc")
                    .frame(width: 40, height: 40)
            }

            barButton("arrow.uturn.backward", disabled: editor.undoLabel == nil) { editor.undo() }
                .keyboardShortcut("z")
            barButton("arrow.uturn.forward", disabled: editor.redoLabel == nil) { editor.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])

            Spacer(minLength: 8)

            Button {
                state.canvas?.fitToView()
            } label: {
                VStack(spacing: 0) {
                    Text(state.documentName + (editor.isDirty ? " •" : ""))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(String(format: "%.0f%%", state.zoom * 100) + (abs(state.rotationDegrees) > 0.5 ? String(format: "  %.0f°", state.rotationDegrees) : ""))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("0")

            Spacer(minLength: 8)

            toolButton(.brush, "b")
            toolButton(.eraser, "e")
            toolButton(.fill, "g")
            toolButton(.eyedropper, "i")

            Divider().frame(height: 24).padding(.horizontal, 4)

            barButton("paintbrush.pointed", selected: showBrushes) { showBrushes.toggle() }
                .popover(isPresented: $showBrushes) {
                    BrushPanel(state: state, editor: editor)
                        .frame(width: 340, height: 560)
                }
            barButton("square.3.layers.3d", selected: showLayers) { showLayers.toggle() }
                .popover(isPresented: $showLayers) {
                    LayerPanel(state: state, editor: editor)
                        .frame(width: 340, height: 600)
                }
            Button { showColors.toggle() } label: {
                Circle()
                    .fill(editor.mainColor.swiftUIColor)
                    .overlay(Circle().stroke(Color.primary.opacity(0.4), lineWidth: 1))
                    .frame(width: 30, height: 30)
                    .frame(width: 40, height: 40)
            }
            .popover(isPresented: $showColors) {
                ColorPanel(editor: editor)
                    .frame(width: 320)
            }
            Button("") { editor.swapColors() }
                .keyboardShortcut("x", modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func barButton(_ symbol: String, selected: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .disabled(disabled)
    }

    private func toolButton(_ tool: Tool, _ key: KeyEquivalent) -> some View {
        Button {
            editor.selectTool(tool)
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .foregroundStyle(editor.tool == tool ? Color.white : Color.primary)
                .background(editor.tool == tool ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .keyboardShortcut(key, modifiers: [])
        .accessibilityLabel(tool.displayName)
    }
}

// MARK: - 左端のスライダー（サイズ・不透明度）

struct SideSliders: View {
    @Bindable var editor: Editor

    var body: some View {
        VStack(spacing: 18) {
            VerticalSlider(value: Binding(get: { log(max(Double(editor.currentBrush.size), 0.5)) },
                                          set: { editor.setBrushSize(Float((exp($0) * 10).rounded() / 10)) }),
                           range: log(0.5)...log(500),
                           label: editor.currentBrush.size < 10 ? String(format: "%.1f", editor.currentBrush.size) : String(format: "%.0f", editor.currentBrush.size))
                .frame(height: 220)
            VerticalSlider(value: Binding(get: { Double(editor.currentBrush.opacity) },
                                          set: { var b = editor.currentBrush; b.opacity = Float($0); editor.currentBrush = b }),
                           range: 0.01...1,
                           label: String(format: "%.0f%%", editor.currentBrush.opacity * 100))
                .frame(height: 160)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .opacity([.brush, .eraser].contains(editor.tool) ? 1 : 0.4)
        .disabled(![.brush, .eraser].contains(editor.tool))
    }
}

/// 縦向きのスライダー（指でもペンでも動かしやすいよう太めにする）
struct VerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var label: String
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let h = geo.size.height
                let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.accentColor.opacity(0.7))
                        .frame(height: max(14, h * t))
                }
                .frame(width: 14)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        // 触った位置に飛ばず、動かした分だけ変える（細かく合わせやすい）
                        let start = dragStart ?? value
                        if dragStart == nil { dragStart = value }
                        let d = -Double(g.translation.height) / Double(h) * (range.upperBound - range.lowerBound)
                        value = min(max(start + d, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStart = nil })
            }
            Text(label)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40)
        }
        .frame(width: 40)
    }
}

// MARK: - 新規作成

struct NewDocumentSheet: View {
    var onCreate: (Int, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var width = 2048
    @State private var height = 2048

    private let presets: [(String, Int, Int)] = [
        ("正方形 2048", 2048, 2048),
        ("フル HD（横）", 1920, 1080),
        ("フル HD（縦）", 1080, 1920),
        ("4K（横）", 3840, 2160),
        ("A4 350dpi", 2894, 4093),
        ("B5 350dpi", 2508, 3541),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("プリセット") {
                    ForEach(presets, id: \.0) { p in
                        Button {
                            width = p.1
                            height = p.2
                        } label: {
                            HStack {
                                Text(p.0).foregroundStyle(Color.primary)
                                Spacer()
                                Text("\(p.1) × \(p.2)").foregroundStyle(.secondary).monospacedDigit()
                                if width == p.1 && height == p.2 { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Section("サイズ（px）") {
                    Stepper(value: $width, in: 16...8000, step: 16) {
                        HStack { Text("幅"); Spacer(); TextField("幅", value: $width, format: .number).multilineTextAlignment(.trailing).keyboardType(.numberPad).frame(width: 100) }
                    }
                    Stepper(value: $height, in: 16...8000, step: 16) {
                        HStack { Text("高さ"); Spacer(); TextField("高さ", value: $height, format: .number).multilineTextAlignment(.trailing).keyboardType(.numberPad).frame(width: 100) }
                    }
                }
            }
            .navigationTitle("新規キャンバス")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作成") {
                        onCreate(min(max(width, 1), 8000), min(max(height, 1), 8000))
                        dismiss()
                    }
                }
            }
        }
    }
}
