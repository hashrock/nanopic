import AppKit
import NanopicCore
import UniformTypeIdentifiers

/// エージェント連携（MCP サーバー）の設定と、アプリ側のツール（ファイルの読み書き）
extension AppState {
    var mcpEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "mcp.enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "mcp.enabled")
            applyMCPSetting()
        }
    }

    var mcpPort: UInt16 {
        get {
            let v = UserDefaults.standard.integer(forKey: "mcp.port")
            return v > 0 && v < 65536 ? UInt16(v) : MCPServer.defaultPort
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: "mcp.port")
            applyMCPSetting()
        }
    }

    var mcpEndpoint: String { "http://127.0.0.1:\(mcpPort)/mcp" }

    /// 設定に合わせてサーバーを起動・停止する
    func applyMCPSetting() {
        mcpSettingsVersion += 1
        if mcpEnabled {
            mcp.start(port: mcpPort)
        } else {
            mcp.stop()
            mcpStatus = "停止中"
        }
    }

    func makeAgentToolbox() -> AgentToolbox {
        let tb = AgentToolbox(editor: editor)
        let discard: [String: Any] = ["type": "boolean", "description": "保存していない変更を捨ててよい（既定 false。変更があると失敗する）"]
        tb.extraTools = [
            AgentTool(name: "new_document", description: "新しいキャンバスを作る（用紙と空のレイヤー 1 枚）。",
                      properties: ["width": ["type": "integer"], "height": ["type": "integer"], "discard_changes": discard],
                      required: ["width", "height"]) { [unowned self] a in
                try checkDiscard(a)
                let w = try a.requireInt("width"), h = try a.requireInt("height")
                guard (1...20000).contains(w), (1...20000).contains(h) else { throw AgentError("大きさは 1〜20000 px") }
                newDocument(width: w, height: h)
                canvasView?.window?.title = "Nanopic"
                return [.text("作りました（\(w)×\(h)）")]
            },
            AgentTool(name: "open_file", description: "PSD や画像ファイルを開く（今のキャンバスは閉じる）。",
                      properties: ["path": ["type": "string", "description": "絶対パス"], "discard_changes": discard],
                      required: ["path"]) { [unowned self] a in
                try checkDiscard(a)
                let url = try fileURL(a)
                guard Self.isOpenable(url) else { throw AgentError("開けない種類のファイルです: \(url.lastPathComponent)") }
                try load(url: url)
                return [.text("開きました: \(url.path)（\(editor.doc.width)×\(editor.doc.height)）")]
            },
            AgentTool(name: "import_image", description: "画像ファイルを新しいレイヤーとして読み込む（キャンバスの中央に置く）。",
                      properties: ["path": ["type": "string", "description": "絶対パス"]], required: ["path"]) { [unowned self] a in
                let url = try fileURL(a)
                guard let img = ImageUtil.loadImage(url: url) else { throw AgentError("画像を読み込めませんでした: \(url.path)") }
                editor.addImageLayer(name: url.deletingPathExtension().lastPathComponent, image: img)
                return [.text(tb.json(["layer_id": editor.activeLayerID?.uuidString ?? ""]))]
            },
            AgentTool(name: "save_psd", description: "PSD で保存する。path を省略すると今のファイルに上書きする。",
                      properties: ["path": ["type": "string", "description": "絶対パス（.psd）"]]) { [unowned self] a in
                let url: URL
                if a.has("path") {
                    url = try fileURL(a)
                } else if let u = editor.fileURL, u.pathExtension.lowercased() == "psd" {
                    url = u
                } else {
                    throw AgentError("まだ PSD として保存していないので path を指定してください")
                }
                try writePSD(to: url)
                return [.text("保存しました: \(url.path)")]
            },
            AgentTool(name: "set_view",
                      description: "ユーザーの画面の表示を変える（作業している所を見せる）。region を渡すとそこを画面いっぱいに、fit: true で全体を表示。",
                      properties: ["region": ["type": "object", "properties": ["x": ["type": "integer"], "y": ["type": "integer"],
                                                                                "width": ["type": "integer"], "height": ["type": "integer"]]],
                                   "fit": ["type": "boolean"]]) { [unowned self] a in
                guard let canvas = canvasView else { throw AgentError("キャンバスが開いていません") }
                if let r = try a.rect("region") {
                    canvas.show(CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
                } else {
                    canvas.fitToWindow()
                }
                return [.text(String(format: "表示倍率 %.0f%%", zoom * 100))]
            },
            AgentTool(name: "export_mp4", description: "タイムラインを MP4 動画に書き出す（透明な部分は白。長辺は 3840px まで）。",
                      properties: ["path": ["type": "string", "description": "絶対パス（.mp4）"]], required: ["path"]) { [unowned self] a in
                let url = try fileURL(a)
                editor.commitTransform()
                guard !editor.timeline.isEmpty else { throw AgentError("タイムラインにトラックがありません") }
                try MovieExport.export(editor.doc, to: url)
                let t = editor.timeline
                return [.text("書き出しました: \(url.path)（\(t.frameCount) コマ、\(t.fps) fps）")]
            },
            AgentTool(name: "export_png", description: "見た目を 1 枚の PNG に書き出す。",
                      properties: ["path": ["type": "string", "description": "絶対パス（.png）"]], required: ["path"]) { [unowned self] a in
                let url = try fileURL(a)
                editor.commitTransform()
                guard let img = editor.flattenedImage(), let data = ImageUtil.pngData(img) else { throw AgentError("書き出せませんでした") }
                try data.write(to: url, options: .atomic)
                return [.text("書き出しました: \(url.path)")]
            },
        ]
        return tb
    }

    private func checkDiscard(_ a: AgentArgs) throws {
        let discard = try a.bool("discard_changes") ?? false
        if editor.isDirty && !discard {
            throw AgentError("保存していない変更があります。ユーザーに確かめてから discard_changes: true で呼ぶか、先に save_psd で保存してください")
        }
    }

    private func fileURL(_ a: AgentArgs) throws -> URL {
        let path = (try a.requireString("path") as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw AgentError("path は絶対パスで指定してください") }
        return URL(fileURLWithPath: path)
    }
}
