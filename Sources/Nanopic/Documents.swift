import AppKit
import NanopicCore
import Observation
import SwiftUI

// 複数の書類をタブで開く。
//
// ウィンドウは 1 つのまま、ウィンドウの中のタブバーで書類を切り替える（macOS のウィンドウタブは使わない）。
// ブラシ・色・パレット・ショートカットのような道具はどの書類でも同じものを使い、
// 書類ごとに持つのは中身・取り消しの履歴・保存先・表示の位置だけ。
// 道具の状態は Editor に入っているので、切り替えるときに前の書類のエディターから引き継ぐ（Editor.adoptToolState）。

/// 開いている書類 1 つ（タブ 1 つ）
@MainActor
@Observable
final class DocumentSession: Identifiable {
    let id = UUID()
    let editor: Editor
    /// 保存していない書類の名前（「無題」「無題 2」や、開いた画像のファイル名）
    var name: String
    /// 開いたファイル（同じファイルをもう一度開こうとしたら、このタブに切り替える）
    @ObservationIgnored var openedFrom: URL?
    /// 起動したときに作った白紙。触らないうちにほかの書類を開いたら、このタブは閉じる
    @ObservationIgnored var isLaunchPlaceholder = false
    /// ほかのタブに切り替えたときの表示の位置（戻ったときに元に戻す）。nil なら全体を表示する
    @ObservationIgnored var viewport: CanvasViewport?

    init(editor: Editor, name: String) {
        self.editor = editor
        self.name = name
    }

    /// タブとウィンドウに出す名前
    var title: String { editor.fileURL?.lastPathComponent ?? name }

    /// 起動したときの白紙のまま（何も描いていない）
    var isPristinePlaceholder: Bool {
        isLaunchPlaceholder && !editor.isDirty && !editor.canUndo && !editor.canRedo && editor.fileURL == nil
    }
}

extension AppState {
    /// 保存していない書類がある
    var hasUnsavedDocuments: Bool { documents.contains { $0.editor.isDirty } }

    /// このファイルを開いているタブ
    func document(openedFrom url: URL) -> DocumentSession? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return documents.first { s in
            [s.editor.fileURL, s.openedFrom].contains { $0?.standardizedFileURL.resolvingSymlinksInPath().path == path }
        }
    }

    /// 新しい書類に付ける名前（「無題」「無題 2」…）
    func nextUntitledName() -> String {
        let base = L("無題")
        let names = Set(documents.map(\.title))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// 書類をタブに足して表示する。起動したときの白紙をまだ触っていなければ、そのタブは閉じる
    func addDocument(_ session: DocumentSession) {
        let placeholder = activeDocument.isPristinePlaceholder ? activeDocument : nil
        let index = documents.firstIndex { $0 === activeDocument }.map { $0 + 1 } ?? documents.count
        documents.insert(session, at: index)
        activate(session)
        if let placeholder { documents.removeAll { $0 === placeholder } }
    }

    /// 表示・編集する書類を切り替える
    func activate(_ session: DocumentSession) {
        guard session !== activeDocument, documents.contains(where: { $0 === session }) else { return }
        let old = activeDocument
        // 書類ごとの一時的なもの（補正のプレビュー・書き出し範囲の調整・再生・タイムラインの選択）は閉じる
        if adjustmentKind != nil { closeAdjustment(commit: false) }
        if publishDraft != nil { closePublishSettings(commit: false) }
        stopPlayback()
        canvasView?.cancelInteraction()
        old.editor.commitTransform()
        old.viewport = canvasView?.viewport
        old.editor.onNeedsDisplay = nil

        let editor = session.editor
        editor.adoptToolState(from: old.editor)
        editor.timelineOpen = timelineOpen
        if editor.showsDeformation != (mode == .rig) { editor.setShowsDeformation(mode == .rig) }
        timelineSelection = []
        timelineFocused = false
        editingParameter = nil
        selectedDeformer = nil
        rigHover = nil
        thumbCache.removeAll()
        activeDocument = session
        agent.editor = editor
        if let canvas = canvasView {
            editor.onNeedsDisplay = { [weak canvas] in canvas?.requestDisplay() }
            if let v = session.viewport { canvas.viewport = v } else { canvas.fitToWindow() }
        }
        editor.markAllDirty()
    }

    /// タブを順に切り替える（⌃⇥・⌃⇧⇥）
    func activateAdjacentDocument(forward: Bool) {
        guard documents.count > 1, let i = documents.firstIndex(where: { $0 === activeDocument }) else { return }
        let n = documents.count
        activate(documents[(i + (forward ? 1 : n - 1)) % n])
    }

    /// タブを閉じる（保存していなければ聞く）。最後の 1 つなら、ウィンドウを閉じる（アプリも終わる）
    func closeDocument(_ session: DocumentSession) {
        guard documents.count > 1 else {
            canvasView?.window?.performClose(nil)
            return
        }
        guard confirmClose(session) else { return }
        removeDocument(session)
    }

    /// タブを閉じる（確認しない）。最後の 1 つは閉じない
    func removeDocument(_ session: DocumentSession) {
        guard documents.count > 1, let i = documents.firstIndex(where: { $0 === session }) else { return }
        if session === activeDocument {
            activate(documents[i + 1 < documents.count ? i + 1 : i - 1])
        }
        documents.removeAll { $0 === session }
        session.editor.onNeedsDisplay = nil
    }

    /// 保存していない書類を閉じてよいか聞く。保存しない・保存できたときは true
    func confirmClose(_ session: DocumentSession) -> Bool {
        guard session.editor.isDirty else { return true }
        activate(session)
        let alert = NSAlert()
        alert.messageText = L("「\(session.title)」の変更を保存しますか？")
        alert.informativeText = L("保存しないと、変更は失われます。")
        alert.addButton(withTitle: L("保存"))
        alert.addButton(withTitle: L("キャンセル"))
        alert.addButton(withTitle: L("保存しない"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    /// 終わる前に、保存していない書類を 1 つずつ聞く。どれかでキャンセルしたら false
    func confirmCloseAll() -> Bool {
        for s in documents where s.editor.isDirty {
            guard confirmClose(s) else { return false }
        }
        return true
    }
}

/// キャンバスの表示の位置（倍率・回転・ずらし）
struct CanvasViewport: Equatable {
    var zoom: CGFloat
    var rotation: CGFloat
    var offset: CGPoint
}

/// キャンバスの上のタブバー
struct DocumentTabBar: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(state.documents) { doc in
                        DocumentTab(document: doc, isActive: doc === state.activeDocument, canClose: state.documents.count > 1,
                                    select: { state.activate(doc) }, close: { state.closeDocument(doc) })
                        Divider().frame(height: 16)
                    }
                    NewDocumentTabButton(state: state)
                }
            }
            // 「描く｜リグ」の切り替え。ウィンドウのツールバーに置くと、それだけのために一段使ってしまうので、タブの並びの右端に置く
            Picker("モード", selection: Binding(get: { state.mode }, set: { state.setMode($0) })) {
                Text(WorkMode.draw.title).tag(WorkMode.draw)
                Text(WorkMode.rig.title).tag(WorkMode.rig)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .padding(.horizontal, 8)
            .help("描くモードとリグモードを切り替える（⌥⌘T）")
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// タブの並びの後ろの＋。押すと設定（設定 ＞ 新規作成）に従って作る。長押しでサイズを選ぶ
private struct NewDocumentTabButton: View {
    let state: AppState

    var body: some View {
        Menu {
            ForEach(NewDocumentSheet.presets, id: \.0) { p in
                Button(p.0) { state.newDocument(width: p.1, height: p.2) }
            }
            Divider()
            Button("サイズを指定…") { state.showNewDocumentSheet = true }
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            state.newDocumentFromCommand()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 28)
        .help(L("新規キャンバス。長押しでサイズを選ぶ"))
    }
}

private struct DocumentTab: View {
    let document: DocumentSession
    let isActive: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            // 閉じるボタン（カーソルを乗せたときと選んでいるとき）。保存していなければ丸を出す
            ZStack {
                if canClose && (hovering || isActive) {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("タブを閉じる")
                } else if document.editor.isDirty {
                    Circle().frame(width: 6, height: 6).foregroundStyle(.secondary)
                }
            }
            .frame(width: 14)
            Text(document.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if document.editor.isDirty && canClose && (hovering || isActive) {
                Circle().frame(width: 6, height: 6).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .foregroundStyle(isActive ? .primary : .secondary)
        .padding(.horizontal, 8)
        .frame(minWidth: 90, maxWidth: 220, minHeight: 28)
        .background(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if isActive { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(document.editor.fileURL?.path ?? document.title)
        .contextMenu {
            Button("閉じる", action: close)
                .disabled(!canClose)
            if let url = document.editor.fileURL {
                Button("Finder に表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}
