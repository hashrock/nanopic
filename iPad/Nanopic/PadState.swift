import NanopicCore
import NanopicUI
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let psd = UTType("com.adobe.photoshop-image") ?? UTType(filenameExtension: "psd")!
}

/// 開いている書類 1 つ（タブ 1 つ）。
///
/// ブラシ・色・パレットのような道具はどの書類でも同じものを使い、書類ごとに持つのは中身・取り消しの履歴・保存先・表示の位置だけ。
/// 道具の状態は Editor に入っているので、切り替えるときに前の書類のエディターから引き継ぐ（Editor.adoptToolState）。Mac 版と同じ作り
@MainActor
@Observable
final class PadDocument: Identifiable {
    let id = UUID()
    let editor: Editor
    /// 開いているファイル名（タイトル表示用）
    var name: String
    /// アプリのフォルダー（書類フォルダー・iCloud container）の外にある書類を開いている。
    /// このときはサイドカー（作品.nanopic）を読まず・書かず、素の PSD として扱う
    fileprivate(set) var isOutsideDocument = false
    /// 開いたファイル（同じファイルをもう一度開こうとしたら、このタブに切り替える）
    @ObservationIgnored fileprivate(set) var openedFrom: URL?
    /// 外の場所（ファイル App で選んだ場所）のファイルを開いている間のアクセス権
    @ObservationIgnored fileprivate var accessedURL: URL?
    /// 起動したときに作った白紙。触らないうちにファイルを開いたら、このタブは閉じる
    @ObservationIgnored var isLaunchPlaceholder = false
    /// ほかのタブに切り替えたときの表示の位置（戻ったときに元に戻す）。nil なら全体を表示する
    @ObservationIgnored var viewport: PadViewport?

    init(editor: Editor, name: String) {
        self.editor = editor
        self.name = name
    }

    /// 起動したときの白紙のまま（何も描いていない）
    var isPristinePlaceholder: Bool {
        isLaunchPlaceholder && !editor.isDirty && !editor.canUndo && !editor.canRedo && editor.fileURL == nil
    }

    fileprivate func releaseAccess() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }
}

/// キャンバスの表示の位置（倍率・回転・ずらし）
struct PadViewport {
    var zoom: CGFloat
    var rotation: CGFloat
    var offset: CGPoint
}

/// iPad 版のアプリの状態（ドキュメント・設定・ファイル操作）
@MainActor
@Observable
final class PadState {
    /// 開いている書類（タブの並び順）
    private(set) var documents: [PadDocument]
    /// いま表示・編集している書類
    private(set) var activeDocument: PadDocument
    var editor: Editor { activeDocument.editor }
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
    /// アプリを離れるとき（ほかのアプリに切り替えた・コントロールセンターを出したなど）に、開いている書類を自動で保存する
    var autosaveEnabled = UserDefaults.standard.object(forKey: "pad.autosave") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autosaveEnabled, forKey: "pad.autosave") }
    }
    /// 選択範囲を作るときの、今の選択範囲との組み合わせ方
    var selectionOp: SelectionOp = .replace
    /// 性能を計測して画面に出す（開発用。画面には出さず、起動の引数 `-perf` を付けたときだけ）
    let perfEnabled = ProcessInfo.processInfo.arguments.contains("-perf")
    /// 画面の下に少しの間だけ出す知らせ
    var toast: String?
    /// 閉じるまで出しておく失敗の知らせ（保存の失敗は、知らせが消えて見逃すと絵を失うので）
    var failure: Failure?
    @ObservationIgnored private var toastToken: UUID?
    /// Apple Pencil のダブルタップで色のパネルを開く（増えたら開く）
    var showColorPanelRequest = 0
    /// 開いているファイル名（タイトル表示用）
    var documentName: String { activeDocument.name }
    /// iCloud container の書類フォルダー（ファイル App の「iCloud Drive › Nanopic」）。iCloud を使っていなければ nil
    private(set) var iCloudDocuments: URL?
    @ObservationIgnored weak var canvas: PadCanvasView?
    @ObservationIgnored private var thumbCache: [UUID: (version: Int, image: CGImage)] = [:]
    /// ブラシ・消しゴム・パレットを iCloud で Mac と iPad の間で同期する
    var syncEnabled = false
    @ObservationIgnored private var sync: PreferenceSync?
    /// 最近開いたファイル（書類のメニュー）。この iPad の中だけに持ち、iCloud では同期しない
    var recentEntries: [RecentFiles.Entry] = []
    @ObservationIgnored let recentFiles = RecentFiles()

    init() {
        let first = PadDocument(editor: Editor(), name: L("無題"))
        first.isLaunchPlaceholder = true
        documents = [first]
        activeDocument = first
        startSync()
        loadPreferences()
        locateICloudContainer()
        refreshRecentFiles()
        #if targetEnvironment(simulator)
        // 検証用（シミュレーターだけ）: `xcrun simctl launch booted com.hashrock.nanopic -open <パス>` で書類を開く
        if let path = UserDefaults.standard.string(forKey: "open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in open(url: URL(fileURLWithPath: path)) }
        }
        #endif
    }

    // MARK: - 知らせ

    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    func showFailure(_ title: String, _ error: Error) {
        failure = Failure(title: title, message: CoordinatedFile.describe(error))
    }

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
        sync?.push()
    }

    // MARK: - 設定の同期（iCloud）

    func setSyncEnabled(_ on: Bool) {
        sync?.setEnabled(on)
        syncEnabled = sync?.isEnabled ?? false
    }

    /// ほかの端末で変わった設定を読み直す
    private func reloadSyncedPreferences() {
        loadPreferences()
        editor.activeBrushIndex = min(editor.activeBrushIndex, max(0, editor.brushes.count - 1))
        editor.activeEraserIndex = min(editor.activeEraserIndex, max(0, editor.erasers.count - 1))
    }

    private func startSync() {
        let s = PreferenceSync { [weak self] in self?.reloadSyncedPreferences() }
        s.pullOnLaunch()
        sync = s
        syncEnabled = s.isEnabled
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
    nonisolated static var documentsDirectory: URL {
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
                // 探している間に開いた書類が iCloud container の中だったら、扱いを直す（開き直してサイドカーを読む）
                for d in self.documents where d.isOutsideDocument && !d.editor.isDirty {
                    guard let u = d.editor.fileURL, self.appFolders.contains(u) else { continue }
                    try? self.load(u, into: d)
                }
            }
        }
    }

    /// サイドカーを読み書きできる場所: アプリの書類フォルダーと iCloud container
    var appFolders: AppFolders {
        AppFolders(roots: [Self.documentsDirectory] + (iCloudDocuments.map { [$0] } ?? []))
    }

    static let openableTypes: [UTType] = [.psd, .png, .jpeg, .heic, .tiff, .bmp, .gif, .webP]

    // MARK: - 書類（タブ）

    /// 新しい書類に付ける名前（「無題」「無題 2」…）
    private func nextUntitledName() -> String {
        let base = L("無題")
        let names = Set(documents.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// 道具（ブラシ・色など）をいまの書類から引き継いだ、空の書類
    private func makeDocument(name: String) -> PadDocument {
        let e = Editor()
        e.adoptToolState(from: editor)
        return PadDocument(editor: e, name: name)
    }

    /// 書類をいまのタブの右に足して表示する。
    /// replacesPlaceholder: 起動したときの白紙のタブ（何も描いていない）を閉じて差し替える（ファイルを開いたときだけ）
    private func addDocument(_ doc: PadDocument, replacesPlaceholder: Bool) {
        let placeholder = replacesPlaceholder && activeDocument.isPristinePlaceholder ? activeDocument : nil
        let index = documents.firstIndex { $0 === activeDocument }.map { $0 + 1 } ?? documents.count
        documents.insert(doc, at: index)
        activate(doc)
        if let placeholder { documents.removeAll { $0 === placeholder } }
    }

    /// 表示・編集する書類を切り替える
    func activate(_ doc: PadDocument) {
        guard doc !== activeDocument, documents.contains(where: { $0 === doc }) else { return }
        let old = activeDocument
        canvas?.cancelInteraction()
        old.editor.commitTransform()
        old.viewport = canvas?.viewport
        old.editor.onNeedsDisplay = nil

        let e = doc.editor
        e.adoptToolState(from: old.editor)
        thumbCache.removeAll()
        activeDocument = doc
        if let canvas {
            e.onNeedsDisplay = { [weak canvas] in canvas?.requestDisplay() }
            if let v = doc.viewport { canvas.viewport = v } else { canvas.fitToView() }
        }
        e.markAllDirty()
    }

    /// タブを閉じる（確かめない。保存していない変更の確認は画面の側でする）。
    /// 最後の 1 つを閉じたら、起動したときと同じ白紙を開く
    func closeDocument(_ doc: PadDocument) {
        guard let i = documents.firstIndex(where: { $0 === doc }) else { return }
        if documents.count == 1 {
            let blank = makeDocument(name: L("無題"))
            blank.isLaunchPlaceholder = true
            documents.append(blank)
            activate(blank)
        } else if doc === activeDocument {
            activate(documents[i + 1 < documents.count ? i + 1 : i - 1])
        }
        documents.removeAll { $0 === doc }
        doc.editor.onNeedsDisplay = nil
        doc.releaseAccess()
    }

    /// 新しい書類をタブで作る
    func newDocument(width: Int, height: Int) {
        let w = min(max(width, 16), 8000), h = min(max(height, 16), 8000)
        // 次にタブバーの＋ですぐ作るときは、このサイズで作る（Mac 版と同じキー）
        UserDefaults.standard.set([w, h], forKey: "newDocumentSize.v1")
        let doc = makeDocument(name: nextUntitledName())
        doc.editor.newDocument(width: w, height: h)
        addDocument(doc, replacesPlaceholder: false)
    }

    /// 最後に新規作成したサイズ（はじめは 2048 × 2048）
    static var lastNewDocumentSize: (width: Int, height: Int) {
        let a = UserDefaults.standard.array(forKey: "newDocumentSize.v1") as? [Int] ?? []
        return a.count == 2 ? (a[0], a[1]) : (2048, 2048)
    }

    /// このファイルを開いているタブ
    private func document(openedFrom url: URL) -> PadDocument? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return documents.first { d in
            [d.editor.fileURL, d.openedFrom].contains { $0?.standardizedFileURL.resolvingSymlinksInPath().path == path }
        }
    }

    /// ファイル App などから渡されたファイルを、新しいタブで開く。もう開いていればそのタブに切り替える
    func open(url: URL) {
        if let d = document(openedFrom: url) {
            activate(d)
            return
        }
        let doc = makeDocument(name: url.deletingPathExtension().lastPathComponent)
        do {
            try load(url, into: doc)
        } catch {
            showFailure(L("開けませんでした"), error)
            return
        }
        addDocument(doc, replacesPlaceholder: true)
    }

    /// ファイルを書類に読み込む
    private func load(_ url: URL, into doc: PadDocument) throws {
        doc.releaseAccess()
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let ext = url.pathExtension.lowercased()
            if ext == "psd" || ext == "psb" {
                // iCloud Drive やほかのアプリのフォルダーの書類もあるので、調停（NSFileCoordinator）を通して読む
                let psd = try PSD.read(try CoordinatedFile.read(url))
                // サイドカー（作品.nanopic）はアプリのフォルダーの中でだけ読む。外の書類は素の PSD として開く
                let inside = appFolders.contains(url)
                let sidecar = inside ? ((try? Sidecar.read(for: url)) ?? nil) : nil
                doc.editor.load(psd, url: url, sidecar: sidecar ?? Sidecar())
                doc.isOutsideDocument = !inside
                noteRecentFile(url)
                // 上書き保存できるよう、閉じるまでアクセス権を持っておく
                if scoped { doc.accessedURL = url }
            } else {
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let img = ImageUtil.loadImage(url: url),
                      let d = Editor.document(from: img, name: url.deletingPathExtension().lastPathComponent) else {
                    throw NSError(domain: "Nanopic", code: 1, userInfo: [NSLocalizedDescriptionKey: L("画像を読み込めませんでした")])
                }
                doc.editor.load(d, url: nil)
                doc.isOutsideDocument = false
                // アクセス権のあるうちに覚える（bookmark を作るのに要る）
                noteRecentFile(url)
            }
            doc.openedFrom = url
            doc.name = url.deletingPathExtension().lastPathComponent
            if doc === activeDocument {
                thumbCache.removeAll()
                canvas?.fitToView()
            }
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    // MARK: - 最近開いたファイル

    /// 一覧と、それぞれ開けるかを読み直す（アプリに戻ってきたときにも呼ぶ。ファイル App で消した・動かしたファイルを反映する）
    func refreshRecentFiles() {
        recentEntries = recentFiles.entries()
    }

    func noteRecentFile(_ url: URL) {
        recentFiles.add(url)
        refreshRecentFiles()
    }

    /// 開く場所（bookmark を解いたもの）。見つからなければ知らせて nil
    func recentFileURL(_ entry: RecentFiles.Entry) -> URL? {
        guard let url = recentFiles.resolve(entry.item) else {
            show(L("「\(entry.item.name)」が見つかりません。移動したか削除された可能性があります"))
            refreshRecentFiles()
            return nil
        }
        return url
    }

    func clearRecentFiles() {
        recentFiles.clear()
        refreshRecentFiles()
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

    /// 受け取りの裏のスレッドから呼ぶ（ファイルの操作だけで、状態には触らない）
    nonisolated private static func copyDropped(_ url: URL) throws -> URL {
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

    var hasFile: Bool {
        editor.fileURL.map { $0.pathExtension.lowercased() == "psd" } ?? false
    }

    /// 上書き保存。まだファイルがなければアプリの書類フォルダーに新しく作る
    @discardableResult
    func save(quiet: Bool = false) -> Bool { save(activeDocument, quiet: quiet) }

    @discardableResult
    func save(_ doc: PadDocument, quiet: Bool = false) -> Bool {
        do {
            let url: URL
            if let u = doc.editor.fileURL, u.pathExtension.lowercased() == "psd" {
                url = u
            } else {
                url = uniqueURL(name: doc.name)
            }
            try writePSD(doc, to: url)
            doc.name = url.deletingPathExtension().lastPathComponent
            noteRecentFile(url)
            if !quiet { show(L("「\(url.lastPathComponent)」に保存しました")) }
            checkUpload(url, doc: doc)
            return true
        } catch {
            // 自動保存（quiet）の失敗も、戻ってきたときに分かるよう閉じるまで出しておく
            showFailure(L("保存に失敗しました"), error)
            return false
        }
    }

    /// 「名前を付けて保存」で書いたファイルを、今の書類として扱う（以後の上書き保存先になる）
    func adoptSavedAs(_ url: URL) {
        let doc = activeDocument
        doc.releaseAccess()
        let scoped = url.startAccessingSecurityScopedResource()
        let inside = appFolders.contains(url)
        var sidecarError: Error?
        // サイドカーはアプリのフォルダーの中でだけ書く（外の場所は素の PSD）
        if inside {
            do { try editor.sidecar.write(for: url) } catch { sidecarError = error }
        }
        editor.markSaved(url: url)
        doc.isOutsideDocument = !inside
        // 上書き保存できるよう、閉じるまでアクセス権を持っておく
        if scoped { doc.accessedURL = url }
        doc.name = url.deletingPathExtension().lastPathComponent
        noteRecentFile(url)
        checkUpload(url, doc: doc)
        if let sidecarError {
            showFailure(L("「\(url.lastPathComponent)」に保存しましたが、追加の情報を書けませんでした"), sidecarError)
        } else {
            show(L("「\(url.lastPathComponent)」に保存しました"))
        }
    }

    /// アプリを離れるとき、開いているどの書類も自動で保存する（ファイル App で選んだ外の場所の書類も、その場で上書きする）
    func autosave() {
        guard autosaveEnabled else { return }
        for doc in documents where doc.editor.isDirty && !doc.editor.isStroking {
            save(doc, quiet: true)
        }
    }

    /// ネットワークドライブやクラウドの場所（ファイルプロバイダー）は、書けたあとに裏で送る。
    /// 送るのに失敗するとファイル App 側にしか出ないので、少しの間ようすを見て、失敗していたら知らせる
    private func checkUpload(_ url: URL, doc: PadDocument) {
        guard !url.path.hasPrefix(Self.documentsDirectory.path) else { return }
        Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, doc.editor.fileURL == url else { return }
                var u = url
                u.removeAllCachedResourceValues()
                guard let v = try? u.resourceValues(forKeys: [.ubiquitousItemUploadingErrorKey, .ubiquitousItemIsUploadedKey]) else { return }
                if let e = v.ubiquitousItemUploadingError {
                    self.showFailure(L("「\(url.lastPathComponent)」を保存先に送れませんでした"), e)
                    return
                }
                // 送り終えた（あるいは、送るという考えのない場所）
                if v.ubiquitousItemIsUploaded != false { return }
            }
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

    private func writePSD(_ doc: PadDocument, to url: URL) throws {
        let data = try psdData(doc.editor)
        try CoordinatedFile.write(data, to: url)
        // サイドカー（作品.nanopic）はアプリのフォルダーの中でだけ書く。外の場所では隣に手を出せないので、素の PSD だけを書く
        if appFolders.contains(url) { try doc.editor.sidecar.write(for: url) }
        doc.editor.markSaved(url: url)
    }

    func psdData() throws -> Data { try psdData(editor) }

    private func psdData(_ e: Editor) throws -> Data {
        e.commitTransform()
        e.prepareForSave()
        return try PSD.write(e.doc)
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
