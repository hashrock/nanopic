import AppKit
import NanopicCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // ペンタブレットの全サンプルを受け取る（イベントの間引きを無効化）
        NSEvent.isMouseCoalescingEnabled = false
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            // `self?.handleKey(e) ?? e` だと処理済み（nil）のキーまで流れてビープが鳴る
            guard let self else { return e }
            return self.handleKey(e)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        state.savePreferences()
        return state.confirmDiscardChanges() ? .terminateNow : .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first, let state, state.confirmDiscardChanges() { state.open(url: url) }
    }

    /// 単キーのショートカット（テキスト入力中は無視）
    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard let state, let canvas = state.canvasView, e.window === canvas.window, !state.isRecordingShortcut else { return e }
        if let tv = e.window?.firstResponder as? NSTextView, tv.isEditable { return e }
        let editor = state.editor
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if e.keyCode == 49 { // space
            if e.type == .keyDown {
                if !e.isARepeat { canvas.setSpaceHeld(true) }
            } else {
                canvas.setSpaceHeld(false)
            }
            return nil
        }
        if e.type == .keyUp {
            canvas.toolKeyUp(e)
            return e
        }
        if flags == [.command, .option] && e.keyCode == 5 { // ⌘⌥G: クリッピング
            if let id = editor.activeLayerID { editor.setLayerProperty(id, label: "クリッピング") { $0.clipping.toggle() } }
            return nil
        }
        if flags == [.command] {
            switch e.keyCode {
            case 39: // ⌘'（JIS では ⌘:）: グリッド
                editor.grid.visible.toggle()
                canvas.requestDisplay()
                return nil
            case 24, 41: // ⌘=（JIS では ⌘^）/ ⌘; : ズームイン（JIS 配列でも Shift なしで押せるように）
                canvas.zoomStep(true)
                return nil
            case 27: // ⌘-
                canvas.zoomStep(false)
                return nil
            default:
                break
            }
        }
        if flags.contains(.command) || flags.contains(.control) { return e }
        switch e.keyCode {
        case 36, 76: // return
            if state.adjustmentKind != nil { state.closeAdjustment(commit: true); return nil }
            if editor.floating != nil { editor.commitTransform(); return nil }
            return e
        case 53: // escape
            if state.adjustmentKind != nil { state.closeAdjustment(commit: false); return nil }
            if editor.floating != nil { editor.cancelTransform(); return nil }
            canvas.cancelInteraction()
            return nil
        case 51, 117: // delete
            if state.mode == .animate { return nil }
            editor.clearSelectionContent()
            return nil
        case 123, 124, 125, 126: // 矢印: 変形中なら 1px 移動
            if let f = editor.floating {
                editor.recordTransformStep()
                var p = f.params
                let d: Double = flags.contains(.shift) ? 10 : 1
                switch e.keyCode {
                case 123: p.tx -= d
                case 124: p.tx += d
                case 125: p.ty += d
                default: p.ty -= d
                }
                editor.updateTransform(p)
                return nil
            }
            return e
        default:
            break
        }
        guard let chord = KeyChord(event: e) else { return e }
        // アニメーションモードでは描くツールに切り替えない
        if state.mode == .animate {
            if case let .tool(t)? = state.shortcuts.target(for: chord), AppState.animationTools.contains(t), !e.isARepeat {
                canvas.toolKeyDown(e, target: .tool(t))
                return nil
            }
            return ["x", "[", "]"].contains(chord.key) ? nil : e
        }
        if let target = state.shortcuts.target(for: chord) {
            if !e.isARepeat { canvas.toolKeyDown(e, target: target) }
            canvas.requestDisplay()
            return nil
        }
        switch chord.key {
        case "x": editor.swapColors()
        case "[": editor.setBrushSize(editor.currentBrush.size / 1.15)
        case "]": editor.setBrushSize(editor.currentBrush.size * 1.15)
        case "r" where flags.contains(.shift): canvas.resetRotation()
        default: return e
        }
        canvas.requestDisplay()
        return nil
    }
}

extension KeyChord {
    /// キー入力から作る（⌘・⌃ 付きや文字のないキーは nil）
    init?(event e: NSEvent) {
        let flags = e.modifierFlags
        guard flags.isDisjoint(with: [.command, .control]), let c = e.charactersIgnoringModifiers?.lowercased(), c.count == 1,
              let scalar = c.unicodeScalars.first, scalar.value >= 0x20, scalar.value < 0xF700 else { return nil }
        self.init(c, shift: flags.contains(.shift), option: flags.contains(.option))
    }
}

/// 未保存のままウィンドウを閉じようとしたら、ウィンドウを残したまま終了確認を出す。
/// SwiftUI が設定したウィンドウの delegate に割り込み、それ以外のメッセージは元の delegate に転送する
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    private weak var original: NSWindowDelegate?
    private let state: AppState

    init(window: NSWindow, state: AppState) {
        self.window = window
        self.original = window.delegate
        self.state = state
        super.init()
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard state.editor.isDirty else { return original?.windowShouldClose?(sender) ?? true }
        // ウィンドウを閉じるとアプリも終了するので、確認は applicationShouldTerminate に任せる
        NSApp.terminate(nil)
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : super.forwardingTarget(for: aSelector)
    }
}

@main
struct NanopicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var state = AppState()

    var body: some Scene {
        Window("Nanopic", id: "main") {
            ContentView(state: state)
                .onAppear {
                    delegate.state = state
                    if state.mcpEnabled { state.applyMCPSetting() }
                }
        }
        .defaultSize(width: 1400, height: 900)
        .commands { AppCommands(state: state) }
        Settings {
            SettingsView(state: state)
        }
    }
}

struct AppCommands: Commands {
    let state: AppState
    var editor: Editor { state.editor }

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Toggle("エージェント連携（MCP）", isOn: Binding(get: { _ = state.mcpSettingsVersion; return state.mcpEnabled },
                                                     set: { state.mcpEnabled = $0 }))
        }
        CommandGroup(replacing: .newItem) {
            Button("新規...") {
                if state.confirmDiscardChanges() { state.showNewDocumentSheet = true }
            }
            .keyboardShortcut("n")
            Button("開く...") { state.open() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存") { state.save() }
                .keyboardShortcut("s")
            Button("別名で保存...") { state.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("PNG として書き出し...") { state.exportPNG() }
                .keyboardShortcut("e", modifiers: [.command, .shift, .option])
            Button("動画を書き出し（MP4）...") { state.exportMovie() }
                .disabled(editor.timeline.isEmpty)
            Button("画像をレイヤーとして読み込み...") { state.importImageAsLayer() }
        }
        CommandGroup(replacing: .undoRedo) {
            Button(editor.undoLabel.map { "取り消し: \($0)" } ?? "取り消し") { editor.undo() }
                .keyboardShortcut("z")
                .disabled(!editor.canUndo && editor.floating == nil)
            Button(editor.redoLabel.map { "やり直し: \($0)" } ?? "やり直し") { editor.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!editor.canRedo)
            Button("やり直し") { editor.redo() }
                .keyboardShortcut("y")
                .disabled(!editor.canRedo)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("消去") { editor.clearSelectionContent() }
            Button("塗りつぶし（描画色）") { editor.fillSelection() }
                .keyboardShortcut(.delete, modifiers: [.option])
            Button("拡大・縮小・回転") { editor.selectTool(.transform) }
            .keyboardShortcut("t")
            Button("キャンバスサイズ...") { state.showCanvasSizeDialog() }
            Button("選択範囲でトリミング") {
                editor.cropToSelection()
                state.canvasView?.fitToWindow()
            }
            .disabled(editor.doc.selection == nil)
        }
        CommandMenu("選択範囲") {
            Button("すべてを選択") { editor.selectAll() }
                .keyboardShortcut("a")
            Button("選択を解除") { editor.deselect() }
                .keyboardShortcut("d")
            Button("選択範囲を反転") { editor.invertSelection() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandMenu("フィルター") {
            Button("色相・彩度・明度...") { state.openAdjustment(.hueSaturation) }
                .keyboardShortcut("u")
            Button("明るさ・コントラスト...") { state.openAdjustment(.brightnessContrast) }
        }
        CommandMenu("レイヤー") {
            Button("新規ラスターレイヤー") { editor.addLayer() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("新規レイヤーフォルダー") { editor.addFolder() }
            Button("フォルダーを作成してレイヤーを挿入") { editor.groupSelectedLayers() }
                .keyboardShortcut("g")
            Button("レイヤーを複製") { editor.duplicateActiveLayer() }
                .keyboardShortcut("j")
            Button("下のレイヤーに結合") { editor.mergeDown() }
                .keyboardShortcut("e")
            Button("レイヤーを削除") { editor.deleteSelectedLayers() }
            Divider()
            Button("下のレイヤーでクリッピング") {
                if let id = editor.activeLayerID { editor.setLayerProperty(id, label: "クリッピング") { $0.clipping.toggle() } }
            }
            .keyboardShortcut("g", modifiers: [.command, .option])
            Button("透明ピクセルをロック") {
                if let id = editor.activeLayerID { editor.setLayerProperty(id, label: "透明ピクセルをロック") { $0.lockAlpha.toggle() } }
            }
            Button("参照レイヤーに設定") {
                if let id = editor.activeLayerID { editor.setLayerProperty(id, label: "参照レイヤー") { $0.isReference.toggle() } }
            }
            Divider()
            Button("レイヤーを上へ") { editor.moveActiveLayer(up: true) }
                .keyboardShortcut("]")
            Button("レイヤーを下へ") { editor.moveActiveLayer(up: false) }
                .keyboardShortcut("[")
        }
        CommandGroup(before: .toolbar) {
            Button("ズームイン") { state.canvasView?.zoomStep(true) }
                .keyboardShortcut("+")
            Button("ズームイン") { state.canvasView?.zoomStep(true) }
                .keyboardShortcut("=")
            Button("ズームアウト") { state.canvasView?.zoomStep(false) }
                .keyboardShortcut("-")
            Button("全体表示") { state.canvasView?.fitToWindow() }
                .keyboardShortcut("0")
            Button("100%") { state.canvasView?.setActualSize() }
                .keyboardShortcut("1")
            Button("回転をリセット") { state.canvasView?.resetRotation() }
            Divider()
            Toggle("アニメーションモード", isOn: Binding(get: { state.mode == .animate }, set: { state.setMode($0 ? .animate : .draw) }))
                .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
            Button(editor.grid.visible ? "グリッドを隠す" : "グリッドを表示") {
                editor.grid.visible.toggle()
                state.savePreferences()
                state.canvasView?.requestDisplay()
            }
            .keyboardShortcut("'")
            Divider()
        }
    }
}
