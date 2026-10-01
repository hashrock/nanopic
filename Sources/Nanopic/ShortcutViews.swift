import AppKit
import NanopicCore
import SwiftUI

/// クリックしてからキーを押すと、そのキーを target に割り当てる（Esc で取り消し、Delete で割り当てを外す）
struct ShortcutRecorder: View {
    let state: AppState
    let target: ShortcutTarget
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "キーを押してください…" : (state.shortcutLabel(target) ?? "なし"))
                    .font(.callout.monospaced())
                    .foregroundStyle(recording ? Color.accentColor : (state.shortcutLabel(target) == nil ? .secondary : .primary))
                    .frame(minWidth: 120)
            }
            if state.shortcutLabel(target) != nil && !recording {
                Button {
                    state.setShortcut(nil, for: target)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("割り当てを外す")
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        message = nil
        recording = true
        state.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch e.keyCode {
            case 53: // Esc
                stop()
            case 51, 117: // Delete
                state.setShortcut(nil, for: target)
                stop()
            default:
                guard let chord = KeyChord(event: e) else {
                    message = "⌘・⌃ との組み合わせや、文字のないキーは使えません"
                    return nil
                }
                if ShortcutMap.reserved.contains(chord) {
                    message = "\(chord.displayName) はほかの機能で使っています"
                    return nil
                }
                state.setShortcut(chord, for: target)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        state.isRecordingShortcut = false
    }
}

/// 割り当て済みのキーを小さく表示する
struct ShortcutBadge: View {
    let state: AppState
    let target: ShortcutTarget

    var body: some View {
        if let label = state.shortcutLabel(target) {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.4)))
        }
    }
}

/// 設定ウィンドウの「ショートカット」タブ
struct ShortcutSettingsView: View {
    let state: AppState
    @Bindable var editor: Editor

    var body: some View {
        Form {
            Section {
                ForEach(Tool.assignable, id: \.self) { tool in
                    row(tool.displayName, symbol: tool.symbol, target: .tool(tool))
                }
            } header: {
                Text("ツール")
            } footer: {
                Text("ブラシと消しゴムは、最後に使ったブラシに切り替わります。キーを押したまま描くと、離したときに元に戻ります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ブラシ") {
                ForEach(editor.brushes) { b in row(b.name, symbol: Tool.brush.symbol, target: .preset(b.id)) }
            }
            Section("消しゴム") {
                ForEach(editor.erasers) { b in row(b.name, symbol: Tool.eraser.symbol, target: .preset(b.id)) }
            }
            Section {
                Button("初期設定に戻す") { state.resetShortcuts() }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ name: String, symbol: String, target: ShortcutTarget) -> some View {
        LabeledContent {
            ShortcutRecorder(state: state, target: target)
        } label: {
            Label(name, systemImage: symbol)
        }
    }
}

/// ツールバーやブラシ一覧から開く、1 つの割り当てだけの小さな設定
struct ShortcutPopover: View {
    let state: AppState
    let title: String
    let target: ShortcutTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) のショートカット").font(.headline)
            ShortcutRecorder(state: state, target: target)
            Text("Esc で取り消し、Delete で割り当てを外す").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

struct SettingsView: View {
    let state: AppState

    var body: some View {
        TabView {
            ShortcutSettingsView(state: state, editor: state.editor)
                .tabItem { Label("ショートカット", systemImage: "keyboard") }
            AgentSettingsView(state: state)
                .tabItem { Label("エージェント連携", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 620)
    }
}

/// 設定ウィンドウの「エージェント連携」タブ
struct AgentSettingsView: View {
    let state: AppState
    @State private var portText = ""

    private var command: String { "claude mcp add --transport http nanopic \(state.mcpEndpoint)" }

    var body: some View {
        let _ = state.mcpSettingsVersion
        Form {
            Section {
                Toggle("MCP サーバーを有効にする", isOn: Binding(get: { state.mcpEnabled }, set: { state.mcpEnabled = $0 }))
                LabeledContent("ポート") {
                    TextField("", text: $portText)
                        .frame(width: 80)
                        .onSubmit {
                            if let p = UInt16(portText), p >= 1024 { state.mcpPort = p } else { portText = String(state.mcpPort) }
                        }
                }
                LabeledContent("状態") { Text(state.mcpStatus).foregroundStyle(.secondary).textSelection(.enabled) }
            } footer: {
                Text("Claude Code などのエージェントが、開いているキャンバスを操作できるようになります（レイヤー、ブラシ、塗りつぶし、線画の領域ごとの下塗りなど）。この Mac の中（127.0.0.1）からだけ接続できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code に登録する") {
                HStack {
                    Text(command).font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("コピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
                Text("登録したら、エージェントに「開いている線画を下塗りして」のように頼めます。操作は ⌘Z で取り消せます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(state.mcpPort) }
    }
}
