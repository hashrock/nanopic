import AppKit
import SwiftUI

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
