import AppKit
import NanopicCore
import SwiftUI

struct ContentView: View {
    let state: AppState
    @Bindable var editor: Editor

    init(state: AppState) {
        self.state = state
        self.editor = state.editor
    }

    var body: some View {
        HStack(spacing: 0) {
            ToolBarView(state: state, editor: editor)
            Divider()
            ToolOptionsView(state: state, editor: editor)
                .frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                CanvasRepresentable(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if let kind = state.adjustmentKind {
                            AdjustmentPanel(state: state, kind: kind)
                                .id(kind)
                                .padding(12)
                        }
                    }
                Divider()
                StatusBar(state: state, editor: editor)
            }
            Divider()
            VStack(spacing: 0) {
                ColorPickerView(editor: editor)
                    .padding(10)
                PaletteView(state: state, editor: editor)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                Divider()
                LayerPanel(state: state, editor: editor)
            }
            .frame(width: 270)
        }
        // キャンバス以外（パネル）へのドロップでも開けるように
        .dropDestination(for: URL.self) { urls, _ in
            state.openDropped(urls, asLayer: NSEvent.modifierFlags.contains(.option))
        }
        .sheet(isPresented: Binding(get: { state.showNewDocumentSheet }, set: { state.showNewDocumentSheet = $0 })) {
            NewDocumentSheet(state: state)
        }
        .onChange(of: editor.tool) { _, _ in state.canvasView?.requestDisplay() }
        .onChange(of: editor.grid) { _, _ in
            state.canvasView?.requestDisplay()
            state.savePreferences()
        }
        .onChange(of: editor.fillSettings) { _, _ in state.savePreferences() }
    }
}

struct StatusBar: View {
    let state: AppState
    @Bindable var editor: Editor
    @State private var showGrid = false

    var body: some View {
        HStack(spacing: 12) {
            Menu(String(format: "%.1f%%", state.zoom * 100)) {
                ForEach([0.25, 0.5, 1, 2, 4, 8], id: \.self) { z in
                    Button("\(Int(z * 100))%") {
                        if let c = state.canvasView { c.zoom(to: z, around: CGPoint(x: c.bounds.midX, y: c.bounds.midY)) }
                    }
                }
                Divider()
                Button("全体表示") { state.canvasView?.fitToWindow() }
            }
            .frame(width: 90)
            if abs(state.rotationDegrees) > 0.01 {
                Button(String(format: "回転 %.0f°", state.rotationDegrees)) { state.canvasView?.resetRotation() }
                    .help("クリックで回転をリセット")
            }
            Text("\(editor.doc.width) × \(editor.doc.height) px")
                .foregroundStyle(.secondary)
            if let p = state.cursorCanvasPoint {
                Text("\(Int(floor(p.x))), \(Int(floor(p.y)))")
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
            }
            Spacer()
            Toggle("グリッド", isOn: $editor.grid.visible)
                .toggleStyle(.checkbox)
            Button {
                showGrid.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showGrid) {
                GridSettingsView(grid: $editor.grid).padding().frame(width: 240)
            }
            Divider().frame(height: 14)
            Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!editor.canUndo)
                .help("取り消し (⌘Z)")
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!editor.canRedo)
                .help("やり直し (⇧⌘Z)")
        }
        .buttonStyle(.borderless)
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .frame(height: 26)
    }
}

struct GridSettingsView: View {
    @Binding var grid: GridSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("グリッドを表示", isOn: $grid.visible)
            Stepper("間隔: \(grid.spacing) px", value: $grid.spacing, in: 4...2000, step: 10)
            Stepper("分割数: \(grid.subdivisions)", value: $grid.subdivisions, in: 1...16)
            VStack(alignment: .leading) {
                Text("不透明度: \(Int(grid.opacity * 100))%")
                Slider(value: $grid.opacity, in: 0.1...1)
            }
        }
    }
}

struct NewDocumentSheet: View {
    let state: AppState
    @State private var width = 1920
    @State private var height = 1080
    @Environment(\.dismiss) private var dismiss

    private let presets: [(String, Int, Int)] = [
        ("1920 × 1080", 1920, 1080), ("2048 × 2048", 2048, 2048), ("A4 350dpi", 2894, 4093),
        ("B5 350dpi", 2508, 3541), ("1280 × 720", 1280, 720), ("4096 × 4096", 4096, 4096),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新規キャンバス").font(.headline)
            Picker("プリセット", selection: Binding(get: { "\(width)x\(height)" }, set: { v in
                if let p = presets.first(where: { "\($0.1)x\($0.2)" == v }) { width = p.1; height = p.2 }
            })) {
                ForEach(presets, id: \.0) { p in Text(p.0).tag("\(p.1)x\(p.2)") }
                if !presets.contains(where: { $0.1 == width && $0.2 == height }) {
                    Text("カスタム").tag("\(width)x\(height)")
                }
            }
            HStack {
                TextField("幅", value: $width, format: .number).frame(width: 80)
                Text("×")
                TextField("高さ", value: $height, format: .number).frame(width: 80)
                Text("px")
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("作成") {
                    state.newDocument(width: min(max(width, 1), 12000), height: min(max(height, 1), 12000))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

extension AppState {
    func showCanvasSizeDialog() {
        let alert = NSAlert()
        alert.messageText = "キャンバスサイズ"
        alert.informativeText = "左上を基準に変更します"
        let w = NSTextField(string: "\(editor.doc.width)")
        let h = NSTextField(string: "\(editor.doc.height)")
        w.frame = NSRect(x: 0, y: 30, width: 120, height: 24)
        h.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 54))
        box.addSubview(w)
        box.addSubview(h)
        alert.accessoryView = box
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn, let nw = Int(w.stringValue), let nh = Int(h.stringValue) else { return }
        editor.resizeCanvas(width: min(max(nw, 1), 12000), height: min(max(nh, 1), 12000))
        canvasView?.fitToWindow()
    }
}
