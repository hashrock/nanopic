import AppKit
import NanopicCore
import Observation
import UniformTypeIdentifiers

@Observable
final class AppState {
    let editor = Editor()
    /// 表示倍率（ステータスバー表示用。実体は CanvasView）
    var zoom: Double = 1
    var rotationDegrees: Double = 0
    var cursorCanvasPoint: CGPoint?
    var showNewDocumentSheet = false
    @ObservationIgnored weak var canvasView: CanvasView?
    @ObservationIgnored private var thumbCache: [UUID: (version: Int, image: NSImage)] = [:]

    init() {
        loadPreferences()
        loadUserTips()
    }

    // MARK: - サムネイル

    func thumbnail(for node: LayerNode) -> NSImage? {
        guard node.kind == .raster else { return nil }
        if let c = thumbCache[node.id], c.version == node.contentVersion { return c.image }
        let doc = editor.doc
        guard let cg = ImageUtil.thumbnail(tiles: node.tiles, docWidth: doc.width, docHeight: doc.height, maxSize: 48) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbCache[node.id] = (node.contentVersion, img)
        return img
    }

    // MARK: - 設定の保存

    private let brushesKey = "brushes.v1"
    private let erasersKey = "erasers.v1"

    func savePreferences() {
        let enc = JSONEncoder()
        if let d = try? enc.encode(editor.brushes) { UserDefaults.standard.set(d, forKey: brushesKey) }
        if let d = try? enc.encode(editor.erasers) { UserDefaults.standard.set(d, forKey: erasersKey) }
        if let d = try? enc.encode(editor.grid) { UserDefaults.standard.set(d, forKey: "grid.v1") }
        if let d = try? enc.encode(editor.fillSettings) { UserDefaults.standard.set(d, forKey: "fill.v1") }
    }

    private func loadPreferences() {
        let dec = JSONDecoder()
        if let d = UserDefaults.standard.data(forKey: brushesKey), let b = try? dec.decode([BrushSettings].self, from: d), !b.isEmpty {
            editor.brushes = b
        }
        if let d = UserDefaults.standard.data(forKey: erasersKey), let b = try? dec.decode([BrushSettings].self, from: d), !b.isEmpty {
            editor.erasers = b
        }
        if let d = UserDefaults.standard.data(forKey: "grid.v1"), let g = try? dec.decode(GridSettings.self, from: d) {
            editor.grid = g
        }
        if let d = UserDefaults.standard.data(forKey: "fill.v1"), let f = try? dec.decode(FillSettings.self, from: d) {
            editor.fillSettings = f
        }
    }

    func resetBrushPresets() {
        editor.brushes = BrushSettings.defaultPresets
        editor.erasers = BrushSettings.defaultErasers
        editor.activeBrushIndex = 0
        editor.activeEraserIndex = 0
        savePreferences()
    }

    // MARK: - ブラシ先端画像

    private var tipsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Nanopic/tips", isDirectory: true)
    }

    private func loadUserTips() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: tipsDirectory, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension.lowercased() == "png" {
            let name = url.deletingPathExtension().lastPathComponent
            if let tip = BrushTip(id: "user:" + name, name: name, url: url) {
                editor.addTip(tip)
            }
        }
    }

    /// 画像を選んでブラシ先端として登録し、現在のブラシに設定する
    func importBrushTip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif]
        panel.message = "ブラシ先端にする画像を選択（透明部分があればアルファ、なければ黒い部分が濃く塗られます）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        guard let tip = BrushTip(id: "user:" + name, name: name, url: url) else {
            showError("画像を読み込めませんでした")
            return
        }
        try? FileManager.default.createDirectory(at: tipsDirectory, withIntermediateDirectories: true)
        let dest = tipsDirectory.appendingPathComponent(name + ".png")
        if let img = ImageUtil.loadImage(url: url), let data = ImageUtil.pngData(img) {
            try? data.write(to: dest)
        }
        editor.addTip(tip)
        var b = editor.currentBrush
        b.tipID = tip.id
        editor.currentBrush = b
    }

    // MARK: - ファイル

    func confirmDiscardChanges() -> Bool {
        guard editor.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "変更が保存されていません"
        alert.informativeText = "現在のドキュメントの変更を破棄しますか？"
        alert.addButton(withTitle: "破棄")
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func newDocument(width: Int, height: Int) {
        editor.newDocument(width: width, height: height)
        canvasView?.fitToWindow()
    }

    func open() {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "psd")!, UTType(filenameExtension: "psb") ?? .data, .png, .jpeg, .tiff, .bmp, .gif]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        let ext = url.pathExtension.lowercased()
        do {
            if ext == "psd" || ext == "psb" {
                let data = try Data(contentsOf: url)
                let doc = try PSD.read(data)
                editor.load(doc, url: url)
            } else {
                guard let img = ImageUtil.loadImage(url: url),
                      let doc = Editor.document(from: img, name: url.deletingPathExtension().lastPathComponent) else {
                    throw NSError(domain: "Nanopic", code: 1, userInfo: [NSLocalizedDescriptionKey: "画像を読み込めませんでした"])
                }
                editor.load(doc, url: nil)
            }
            thumbCache.removeAll()
            canvasView?.fitToWindow()
            NSApp.keyWindow?.title = url.lastPathComponent
        } catch {
            showError("ファイルを開けませんでした: \(error)")
        }
    }

    func save() {
        if let url = editor.fileURL, url.pathExtension.lowercased() == "psd" {
            write(to: url)
        } else {
            saveAs()
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "psd")!]
        panel.nameFieldStringValue = editor.fileURL?.deletingPathExtension().lastPathComponent ?? "無題"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    private func write(to url: URL) {
        editor.commitTransform()
        do {
            let data = try PSD.write(editor.doc)
            try data.write(to: url, options: .atomic)
            editor.markSaved(url: url)
            NSApp.keyWindow?.title = url.lastPathComponent
        } catch {
            showError("保存に失敗しました: \(error)")
        }
    }

    func exportPNG() {
        editor.commitTransform()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = editor.fileURL?.deletingPathExtension().lastPathComponent ?? "無題"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let img = editor.flattenedImage(), let data = ImageUtil.pngData(img) else { return }
        do {
            try data.write(to: url)
        } catch {
            showError("書き出しに失敗しました: \(error)")
        }
    }

    func importImageAsLayer() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif]
        guard panel.runModal() == .OK, let url = panel.url, let img = ImageUtil.loadImage(url: url) else { return }
        editor.addImageLayer(name: url.deletingPathExtension().lastPathComponent, image: img)
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
