import NanopicCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let psd = UTType("com.adobe.photoshop-image") ?? UTType(filenameExtension: "psd")!
}

/// iPad 版のアプリの状態（ドキュメント・設定・ファイル操作）
@Observable
final class PadState {
    let editor = Editor()
    /// 表示倍率と回転（表示用。実体は PadCanvasView）
    var zoom: Double = 1
    var rotationDegrees: Double = 0
    /// 指でも描く（オフなら指は表示の移動・拡大・回転だけ）
    var fingerDrawing = UserDefaults.standard.bool(forKey: "pad.fingerDrawing") {
        didSet {
            UserDefaults.standard.set(fingerDrawing, forKey: "pad.fingerDrawing")
            canvas?.updateGestureConfiguration()
        }
    }
    /// 選択範囲を作るときの、今の選択範囲との組み合わせ方
    var selectionOp: SelectionOp = .replace
    /// 性能を計測して画面に出す
    var perfEnabled = UserDefaults.standard.bool(forKey: "pad.perfEnabled") {
        didSet {
            UserDefaults.standard.set(perfEnabled, forKey: "pad.perfEnabled")
            canvas?.updatePerfConfiguration()
        }
    }
    /// 画面の下に少しの間だけ出す知らせ
    var toast: String?
    @ObservationIgnored private var toastToken: UUID?
    /// Apple Pencil のダブルタップで色のパネルを開く（増えたら開く）
    var showColorPanelRequest = 0
    /// 開いているファイル名（タイトル表示用）
    var documentName = L("無題")
    /// アプリのフォルダー（書類フォルダー・iCloud container）の外にある書類を開いている。
    /// このときはサイドカー（作品.nanopic）を読まず・書かず、素の PSD として扱う
    private(set) var isOutsideDocument = false
    /// iCloud container の書類フォルダー（ファイル App の「iCloud Drive › Nanopic」）。iCloud を使っていなければ nil
    private(set) var iCloudDocuments: URL?
    @ObservationIgnored weak var canvas: PadCanvasView?
    /// 外の場所（ファイル App で選んだ場所）のファイルを開いている間のアクセス権
    @ObservationIgnored private var accessedURL: URL?
    @ObservationIgnored private var thumbCache: [UUID: (version: Int, image: CGImage)] = [:]

    init() {
        loadPreferences()
        locateICloudContainer()
        #if targetEnvironment(simulator)
        // 検証用（シミュレーターだけ）: `xcrun simctl launch booted com.hashrock.nanopic -open <パス>` で書類を開く
        if let path = UserDefaults.standard.string(forKey: "open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in open(url: URL(fileURLWithPath: path)) }
        }
        #endif
    }

    // MARK: - 知らせ

    func show(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.toastToken == token else { return }
            withAnimation { self.toast = nil }
        }
    }

    // MARK: - サムネイル

    func thumbnail(for node: LayerNode) -> CGImage? {
        guard node.kind == .raster else { return nil }
        if let c = thumbCache[node.id], c.version == node.contentVersion { return c.image }
        let doc = editor.doc
        guard let img = ImageUtil.thumbnail(tiles: node.tiles, docWidth: doc.width, docHeight: doc.height, maxSize: 64) else { return nil }
        thumbCache[node.id] = (node.contentVersion, img)
        return img
    }

    // MARK: - 設定の保存（Mac 版と同じキー）

    func savePreferences() {
        let enc = JSONEncoder()
        let d = UserDefaults.standard
        if let v = try? enc.encode(editor.brushes) { d.set(v, forKey: "brushes.v1") }
        if let v = try? enc.encode(editor.erasers) { d.set(v, forKey: "erasers.v1") }
        if let v = try? enc.encode(editor.fillSettings) { d.set(v, forKey: "fill.v1") }
        d.set(editor.palette.map(HexColor.format), forKey: "palette.v1")
    }

    private func loadPreferences() {
        let dec = JSONDecoder()
        let d = UserDefaults.standard
        if let v = d.data(forKey: "brushes.v1"), let b = try? dec.decode([BrushSettings].self, from: v), !b.isEmpty {
            editor.brushes = b
        }
        if let v = d.data(forKey: "erasers.v1"), let b = try? dec.decode([BrushSettings].self, from: v), !b.isEmpty {
            editor.erasers = b
        }
        if let v = d.data(forKey: "fill.v1"), let f = try? dec.decode(FillSettings.self, from: v) {
            editor.fillSettings = f
        }
        if let p = d.stringArray(forKey: "palette.v1") {
            editor.palette = p.compactMap(HexColor.parse)
        }
    }

    func resetBrushPresets() {
        editor.brushes = BrushSettings.defaultPresets
        editor.erasers = BrushSettings.defaultErasers
        editor.activeBrushIndex = 0
        editor.activeEraserIndex = 0
        savePreferences()
    }

    // MARK: - ファイル

    /// アプリの書類フォルダー（ファイル App の「このiPad内 › Nanopic」）
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// iCloud container を探す（時間がかかることがあるので裏で）。書類フォルダーを作っておくと、ファイル App の iCloud Drive に出る
    private func locateICloudContainer() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return }
            let docs = container.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                guard let self else { return }
                self.iCloudDocuments = docs
                // 探している間に開いた書類が iCloud container の中だったら、扱いを直す
                if self.isOutsideDocument, let u = self.editor.fileURL, self.appFolders.contains(u), !self.editor.isDirty {
                    self.open(url: u)
                }
            }
        }
    }

    /// サイドカーを読み書きできる場所: アプリの書類フォルダーと iCloud container
    var appFolders: AppFolders {
        AppFolders(roots: [Self.documentsDirectory] + (iCloudDocuments.map { [$0] } ?? []))
    }

    static let openableTypes: [UTType] = [.psd, .png, .jpeg, .heic, .tiff, .bmp, .gif, .webP]

    func newDocument(width: Int, height: Int) {
        releaseAccess()
        isOutsideDocument = false
        editor.newDocument(width: width, height: height)
        thumbCache.removeAll()
        documentName = L("無題")
        canvas?.fitToView()
    }

    /// 今の書類を閉じて、起動したときと同じ白紙に戻す
    func closeDocument() {
        let blank = Editor().doc
        newDocument(width: blank.width, height: blank.height)
    }

    /// ファイル App などから渡されたファイルを開く
    func open(url: URL) {
        releaseAccess()
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let ext = url.pathExtension.lowercased()
            if ext == "psd" || ext == "psb" {
                // iCloud Drive やほかのアプリのフォルダーの書類もあるので、調停（NSFileCoordinator）を通して読む
                let doc = try PSD.read(try CoordinatedFile.read(url))
                // サイドカー（作品.nanopic）はアプリのフォルダーの中でだけ読む。外の書類は素の PSD として開く
                let inside = appFolders.contains(url)
                let sidecar = inside ? ((try? Sidecar.read(for: url)) ?? nil) : nil
                editor.load(doc, url: url, sidecar: sidecar ?? Sidecar())
                isOutsideDocument = !inside
                // 上書き保存できるよう、閉じるまでアクセス権を持っておく
                if scoped { accessedURL = url }
            } else {
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let img = ImageUtil.loadImage(url: url),
                      let doc = Editor.document(from: img, name: url.deletingPathExtension().lastPathComponent) else {
                    throw NSError(domain: "Nanopic", code: 1, userInfo: [NSLocalizedDescriptionKey: L("画像を読み込めませんでした")])
                }
                editor.load(doc, url: nil)
                isOutsideDocument = false
            }
            thumbCache.removeAll()
            documentName = url.deletingPathExtension().lastPathComponent
            canvas?.fitToView()
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            show(L("開けませんでした: \(error.localizedDescription)"))
        }
    }

    /// ドロップされたファイルを受け取る。元の場所のまま開ければそのまま（scoped = true で受け取り側がアクセス権を手放す）、
    /// 開けなければコピーを渡す。PSD のコピーは上書き保存できるよう書類フォルダーに置く
    func receiveDropped(_ providers: [NSItemProvider], completion: @escaping (URL, Bool) -> Void) -> Bool {
        for provider in providers {
            guard let type = Self.openableTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { continue }
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: type.identifier) { [self] url, inPlace, _ in
                guard let url else {
                    DispatchQueue.main.async { self.show(L("ファイルを受け取れませんでした")) }
                    return
                }
                if inPlace && url.startAccessingSecurityScopedResource() {
                    DispatchQueue.main.async { completion(url, true) }
                    return
                }
                do {
                    let copy = try Self.copyDropped(url)
                    DispatchQueue.main.async { completion(copy, false) }
                } catch {
                    DispatchQueue.main.async { self.show(L("ファイルを受け取れませんでした: \(error.localizedDescription)")) }
                }
            }
            return true
        }
        return false
    }

    private static func copyDropped(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let ext = url.pathExtension
        let name = url.deletingPathExtension().lastPathComponent
        var dst: URL
        if ["psd", "psb"].contains(ext.lowercased()) {
            dst = documentsDirectory.appendingPathComponent(url.lastPathComponent)
            var i = 2
            while fm.fileExists(atPath: dst.path) {
                dst = documentsDirectory.appendingPathComponent("\(name) \(i).\(ext)")
                i += 1
            }
        } else {
            let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            dst = dir.appendingPathComponent(url.lastPathComponent)
        }
        try fm.copyItem(at: url, to: dst)
        return dst
    }

    /// 画像を新しいレイヤーとして読み込む
    func importLayer(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let img = ImageUtil.loadImage(url: url) else {
            show(L("画像を読み込めませんでした"))
            return
        }
        editor.addImageLayer(name: url.deletingPathExtension().lastPathComponent, image: img)
    }

    private func releaseAccess() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    var hasFile: Bool {
        editor.fileURL.map { $0.pathExtension.lowercased() == "psd" } ?? false
    }

    /// 上書き保存。まだファイルがなければアプリの書類フォルダーに新しく作る
    @discardableResult
    func save(quiet: Bool = false) -> Bool {
        do {
            let url: URL
            if let u = editor.fileURL, u.pathExtension.lowercased() == "psd" {
                url = u
            } else {
                url = uniqueURL(name: documentName)
            }
            try writePSD(to: url)
            documentName = url.deletingPathExtension().lastPathComponent
            if !quiet { show(L("「\(url.lastPathComponent)」に保存しました")) }
            return true
        } catch {
            show(L("保存に失敗しました: \(error.localizedDescription)"))
            return false
        }
    }

    /// アプリを離れるとき、アプリのフォルダーの書類だけ自動で保存する（外の場所のファイルは勝手に上書きしない）
    func autosave() {
        guard editor.isDirty, !editor.isStroking else { return }
        if let u = editor.fileURL, !appFolders.contains(u) { return }
        save(quiet: true)
    }

    /// 外の場所の書類を、アプリの書類フォルダーに複製して、そちらを開いた状態にする（いまの絵を新しい PSD として書く）。
    /// 元の書類には触らない。元の隣にサイドカーがあっても、それは読めないので付いてこない
    @discardableResult
    func duplicateIntoAppFolder() -> Bool {
        do {
            let url = uniqueURL(name: documentName)
            try writePSD(to: url)
            releaseAccess()
            isOutsideDocument = false
            documentName = url.deletingPathExtension().lastPathComponent
            show(L("「このiPad内 › Nanopic」に「\(url.lastPathComponent)」を作りました"))
            return true
        } catch {
            show(L("複製に失敗しました: \(error.localizedDescription)"))
            return false
        }
    }

    private func uniqueURL(name: String) -> URL {
        let dir = Self.documentsDirectory
        var url = dir.appendingPathComponent(name + ".psd")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) \(i).psd")
            i += 1
        }
        return url
    }

    private func writePSD(to url: URL) throws {
        let data = try psdData()
        try CoordinatedFile.write(data, to: url)
        // サイドカー（作品.nanopic）はアプリのフォルダーの中でだけ書く。外の場所では隣に手を出せないので、素の PSD だけを書く
        if appFolders.contains(url) { try editor.sidecar.write(for: url) }
        editor.markSaved(url: url)
    }

    func psdData() throws -> Data {
        editor.commitTransform()
        editor.prepareForSave()
        return try PSD.write(editor.doc)
    }

    func pngData() -> Data? {
        editor.commitTransform()
        guard let img = editor.flattenedImage() else { return nil }
        return ImageUtil.pngData(img)
    }
}

/// 書き出し（ファイル App の保存先を選ぶ）用のファイル
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.psd, .png] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
