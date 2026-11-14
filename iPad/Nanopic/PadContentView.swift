import NanopicCore
import NanopicUI
import SwiftUI
import UniformTypeIdentifiers

struct PadContentView: View {
    let state: PadState
    @Bindable var editor: Editor
    @Environment(\.scenePhase) private var scenePhase

    @State private var showBrushes = false
    @State private var showBrushSettings = false
    /// 画面に出しっぱなしにしているパネル（カンマ区切り）
    @AppStorage("pad.pinnedPanels") private var pinnedRaw = ""
    /// 出しっぱなしのパネルをドラッグで動かした量
    @State private var panelOffsets: [PanelKind: CGSize] = [:]
    @State private var panelDrag: (kind: PanelKind, translation: CGSize)?
    @AppStorage("pad.colorPickerCollapsed") private var colorsCollapsed = false
    /// サイズ・不透明度のスライダーを右端に置く（持ち手をドラッグして左右の端に寄せる）
    @AppStorage("pad.slidersRight") private var slidersRight = false
    /// スライダーの上下の位置（画面の真ん中からのずれ）
    @AppStorage("pad.slidersY") private var slidersY: Double = 0
    @State private var slidersDrag: CGSize?
    /// ツールを切り替えたときに出す説明
    @State private var toolHint: Tool?
    @State private var toolHintToken: UUID?
    @State private var dropTargeted = false
    @State private var showLayers = false
    @State private var showColors = false
    @State private var showNewDocument = false
    @State private var importing: ImportKind?
    @State private var exportFile: ExportFile?
    @State private var exportType: UTType = .png
    @State private var showExporter = false
    /// 書き出しではなく「名前を付けて保存」として保存先を選んでいる
    @State private var savingAs = false
    @State private var confirmDiscard: PendingAction?
    @State private var showOutsideInfo = false

    enum ImportKind: Identifiable {
        case open, layer
        var id: Self { self }
    }

    enum PendingAction: Hashable, Identifiable {
        /// ドロップされたファイル。scoped なら開いたあとアクセス権を手放す
        case openFile(URL, scoped: Bool)
        case new, open, close
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
            floatingSliders
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
            if let tool = toolHint {
                VStack {
                    toolHintView(tool)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            ForEach(PanelKind.allCases.filter { isPinned($0) }) { kind in
                pinnedPanel(kind)
            }
            if editor.floating != nil {
                VStack {
                    Spacer()
                    transformBar.padding(.bottom, 70)
                }
            } else if editor.doc.selection != nil {
                // 選択範囲があるあいだは、移動・変形と解除のバーを出す
                VStack {
                    Spacer()
                    selectionBar.padding(.bottom, 70)
                }
                .transition(.opacity)
            }
            if dropTargeted {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: PadState.openableTypes, isTargeted: $dropTargeted) { providers in
            state.receiveDropped(providers) { url, scoped in
                requestDiscard(.openFile(url, scoped: scoped))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { toolbar }
        .sheet(isPresented: $showNewDocument) {
            NewDocumentSheet { w, h in state.newDocument(width: w, height: h) }
        }
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing == .layer ? [.png, .jpeg, .heic, .tiff, .gif] : PadState.openableTypes) { result in
            let kind = importing
            switch result {
            case let .success(url):
                if kind == .layer { state.importLayer(url: url) } else { state.open(url: url) }
            case let .failure(error):
                state.showFailure(L("開けませんでした"), error)
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportFile, contentType: exportType,
                      defaultFilename: state.documentName) { result in
            switch result {
            case let .success(url):
                if savingAs { state.adoptSavedAs(url) } else { state.show(L("「\(url.lastPathComponent)」に書き出しました")) }
            case let .failure(error):
                // 保存先を選ばずに閉じたときは失敗ではない
                if (error as? CocoaError)?.code != .userCancelled {
                    state.showFailure(savingAs ? L("保存に失敗しました") : L("書き出しに失敗しました"), error)
                }
            }
            exportFile = nil
        }
        .confirmationDialog("変更が保存されていません", isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }),
                            titleVisibility: .visible, presenting: confirmDiscard) { action in
            Button("保存してから続ける") {
                if state.save() { perform(action) }
            }
            Button("変更を破棄", role: .destructive) { perform(action) }
            Button("キャンセル", role: .cancel) {
                if case let .openFile(url, scoped: true) = action { url.stopAccessingSecurityScopedResource() }
            }
        }
        .alert(state.failure?.title ?? "", isPresented: Binding(get: { state.failure != nil }, set: { if !$0 { state.failure = nil } }),
               presenting: state.failure) { _ in
            Button("OK") { state.failure = nil }
        } message: { f in
            Text(f.message)
        }
        .onOpenURL { url in state.open(url: url) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { state.autosave() }
        }
        .onChange(of: state.showColorPanelRequest) { _, _ in
            if !isPinned(.colors) { showColors = true }
        }
        .onChange(of: state.isOutsideDocument) { _, outside in
            // 名前を付けて保存で外に置いたときは、保存の知らせのほうで伝える
            if outside && !savingAs { state.show(L("アプリのフォルダーの外の書類です。素の PSD として開きました")) }
        }
        .onChange(of: editor.tool) { _, tool in showToolHint(tool) }
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
        case .close: state.closeDocument()
        case let .openFile(url, scoped):
            state.open(url: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    private func export(_ type: UTType, saveAs: Bool = false) {
        savingAs = saveAs
        do {
            let data: Data
            if type == .psd {
                data = try state.psdData()
            } else {
                guard let d = state.pngData() else {
                    state.showFailure(L("書き出しに失敗しました"), CocoaError(.fileWriteUnknown))
                    return
                }
                data = d
            }
            exportType = type
            exportFile = ExportFile(data: data)
            showExporter = true
        } catch {
            state.showFailure(L("書き出しに失敗しました"), error)
        }
    }

    /// キャンバスごと 90 度回す（用紙の向きを直す）。表示も回したあとの大きさに合わせる
    private func rotate(clockwise: Bool) {
        editor.rotateCanvas90(clockwise: clockwise)
        state.canvas?.fitToView()
    }

    /// 外の場所の書類を開いているときの案内
    private var outsideInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("アプリのフォルダーの外にある書類です").font(.headline)
            Text("素の PSD として開いています。スイッチフォルダー・タイムライン・リグ・書き出し設定（隣の「\(state.documentName).nanopic」の情報）は読まず、保存しても書きません。")
            Text("Nanopic のフォルダー（ファイル App の「このiPad内 › Nanopic」か「iCloud Drive › Nanopic」）に移すと全部使えます。「\(state.documentName).nanopic」があるときは、ファイル App で PSD と一緒に移してください。")
            Button {
                showOutsideInfo = false
                state.duplicateIntoAppFolder()
            } label: {
                Label("Nanopic のフォルダーに複製して開く", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            Text("複製は、いまの絵を新しい PSD として作ります。元の書類はそのまま残ります。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 360)
    }

    // MARK: - ツールバー

    private var toolbar: some View {
        HStack(spacing: 6) {
            Menu {
                Button { requestDiscard(.new) } label: { Label("新規…", systemImage: "doc.badge.plus") }
                    .keyboardShortcut("n")
                Button { requestDiscard(.open) } label: { Label("開く…", systemImage: "folder") }
                    .keyboardShortcut("o")
                Button { requestDiscard(.close) } label: { Label("閉じる", systemImage: "xmark.circle") }
                    .disabled(editor.fileURL == nil && !editor.isDirty)
                    .keyboardShortcut("w")
                Divider()
                Button { state.save() } label: { Label("保存", systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s")
                Button { export(.psd, saveAs: true) } label: { Label("名前を付けて保存…", systemImage: "square.and.arrow.down.on.square") }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button { export(.psd) } label: { Label("PSD を書き出し…", systemImage: "square.and.arrow.up") }
                Button { export(.png) } label: { Label("PNG を書き出し…", systemImage: "photo") }
                Divider()
                Menu {
                    Button { rotate(clockwise: true) } label: { Label("右に 90° 回転", systemImage: "rotate.right") }
                    Button { rotate(clockwise: false) } label: { Label("左に 90° 回転", systemImage: "rotate.left") }
                } label: {
                    Label("画像を回転", systemImage: "rotate.right")
                }
                Button { importing = .layer } label: { Label("画像をレイヤーとして読み込み…", systemImage: "photo.badge.plus") }
                Divider()
                Toggle(isOn: Binding(get: { state.fingerDrawing }, set: { state.fingerDrawing = $0 })) {
                    Label("指で描く", systemImage: "hand.point.up.left")
                }
                Toggle(isOn: Binding(get: { state.syncEnabled }, set: { state.setSyncEnabled($0) })) {
                    Label("ブラシとパレットを iCloud で同期", systemImage: "icloud")
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

            if state.isOutsideDocument {
                Button { showOutsideInfo = true } label: {
                    // ツールバーは縦向きだと狭いので、印だけ出す（説明は押すと出る）
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .frame(width: 36, height: 30)
                        .background(Color.yellow.opacity(0.2), in: Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("アプリのフォルダーの外にある書類です")
                .popover(isPresented: $showOutsideInfo) { outsideInfo }
            }

            Spacer(minLength: 8)

            toolButton(.brush, "b")
            toolButton(.eraser, "e")
            toolButton(.fill, "g")
            toolButton(.lassoFill, "l")
            toolButton(.lassoErase, "k")
            selectionMenu
            toolButton(.eyedropper, "i")

            Divider().frame(height: 24).padding(.horizontal, 4)

            barButton("square.grid.2x2", selected: showBrushes || isPinned(.brushes)) { toggle(.brushes, $showBrushes) }
                .accessibilityLabel("ブラシの種類")
                .popover(isPresented: $showBrushes) { popoverPanel(.brushes, $showBrushes) }
            barButton("slider.horizontal.3", selected: showBrushSettings || isPinned(.brushSettings)) { toggle(.brushSettings, $showBrushSettings) }
                .accessibilityLabel("ブラシの詳細設定")
                .popover(isPresented: $showBrushSettings) { popoverPanel(.brushSettings, $showBrushSettings) }
            barButton("square.3.layers.3d", selected: showLayers || isPinned(.layers)) { toggle(.layers, $showLayers) }
                .accessibilityLabel("レイヤー")
                .popover(isPresented: $showLayers) { popoverPanel(.layers, $showLayers) }
            Button { toggle(.colors, $showColors) } label: {
                Circle()
                    .fill(editor.mainColor.swiftUIColor)
                    .overlay(Circle().stroke(Color.primary.opacity(0.4), lineWidth: 1))
                    .frame(width: 30, height: 30)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("色")
            .popover(isPresented: $showColors) { popoverPanel(.colors, $showColors) }
            Button("") { editor.swapColors() }
                .keyboardShortcut("x", modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
            // 移動・変形はツールバーから外し、選択範囲のバーに置いた。キーボードではいつでも選べる
            Button("") { editor.selectTool(.move) }
                .keyboardShortcut("v", modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
            Button("") { editor.selectTool(.transform) }
                .keyboardShortcut("t", modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - サイズ・不透明度のスライダー（浮かせて、左右の端に寄せる）

    private var floatingSliders: some View {
        GeometryReader { geo in
            let drag = slidersDrag ?? .zero
            // 上下ははみ出さないよう、真ん中から (高さ - スライダーの高さ) / 2 までに抑える
            let limit = max(0, (geo.size.height - SideSliders.height) / 2 - 8)
            let y = min(max(slidersY + drag.height, -limit), limit)
            SideSliders(editor: editor,
                        onDrag: { slidersDrag = $0 },
                        onDragEnd: { t, location in
                            slidersRight = location.x > geo.frame(in: .global).midX
                            slidersY = min(max(slidersY + t.height, -limit), limit)
                            slidersDrag = nil
                        })
                .offset(x: drag.width, y: y)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: slidersRight ? .trailing : .leading)
                .animation(.easeOut(duration: 0.2), value: slidersRight)
        }
    }

    // MARK: - ツールの説明

    private static func hint(for tool: Tool) -> String {
        switch tool {
        case .brush: return L("描く")
        case .eraser: return L("消す")
        case .fill: return L("タップした所と同じ色の範囲を塗る")
        case .lassoFill: return L("囲んだ範囲を描画色で塗る")
        case .lassoErase: return L("囲んだ範囲を消す")
        case .selectRect: return L("四角く選ぶ")
        case .selectEllipse: return L("丸く選ぶ")
        case .lasso: return L("囲んで選ぶ")
        case .wand: return L("タップした所と同じ色の範囲を選ぶ")
        case .move: return L("レイヤーや選択範囲を動かす")
        case .transform: return L("角で拡大・縮小、枠の外で回転")
        case .eyedropper: return L("タップした所の色を取る")
        case .hand: return L("表示を動かす")
        case .zoom: return L("表示を拡大・縮小する")
        }
    }

    private func toolHintView(_ tool: Tool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tool.symbol)
                .font(.system(size: 17))
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.displayName).font(.subheadline.weight(.semibold))
                Text(Self.hint(for: tool)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private func showToolHint(_ tool: Tool) {
        let token = UUID()
        toolHintToken = token
        withAnimation(.easeOut(duration: 0.2)) { toolHint = tool }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard toolHintToken == token else { return }
            withAnimation(.easeIn(duration: 0.25)) { toolHint = nil }
        }
    }

    // MARK: - パネル（ポップオーバーと出しっぱなし）

    private func isPinned(_ kind: PanelKind) -> Bool {
        pinnedRaw.split(separator: ",").contains { $0 == kind.rawValue }
    }

    private func setPinned(_ kind: PanelKind, _ on: Bool) {
        var set = pinnedRaw.split(separator: ",").map(String.init).filter { $0 != kind.rawValue }
        if on { set.append(kind.rawValue) }
        withAnimation(.easeOut(duration: 0.2)) { pinnedRaw = set.joined(separator: ",") }
    }

    /// ツールバーのボタン: 出しっぱなしならしまう、そうでなければポップオーバーを開け閉めする
    private func toggle(_ kind: PanelKind, _ shown: Binding<Bool>) {
        if isPinned(kind) { setPinned(kind, false) } else { shown.wrappedValue.toggle() }
    }

    private func title(_ kind: PanelKind) -> String {
        switch kind {
        case .brushes: return editor.tool == .eraser ? L("消しゴム") : L("ブラシ")
        case .brushSettings: return LName(editor.currentBrush.name)
        case .layers: return L("レイヤー")
        case .colors: return L("色")
        }
    }

    @ViewBuilder
    private func panelContent(_ kind: PanelKind, pinned: Bool) -> some View {
        switch kind {
        case .brushes:
            BrushPresetPanel(state: state, editor: editor) {
                showBrushes = false
                guard !isPinned(.brushSettings) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showBrushSettings = true }
            }
        case .brushSettings:
            BrushSettingsPanel(state: state, editor: editor)
        case .layers:
            LayerPanel(state: state, editor: editor)
        case .colors:
            ColorPanel(editor: editor, pinned: pinned, collapsed: pinned && colorsCollapsed)
        }
    }

    private func accessory(_ kind: PanelKind, pinned: Bool) -> AnyView? {
        guard kind == .colors, pinned else { return nil }
        return AnyView(Button {
            withAnimation { colorsCollapsed.toggle() }
        } label: {
            Image(systemName: colorsCollapsed ? "chevron.down" : "chevron.up")
                .frame(width: 30, height: 30)
        }
        .accessibilityLabel(colorsCollapsed ? L("色の選択を開く") : L("パレットだけにする")))
    }

    private func popoverPanel(_ kind: PanelKind, _ shown: Binding<Bool>) -> some View {
        PanelChrome(title: title(kind), pinned: false, onPin: {
            shown.wrappedValue = false
            setPinned(kind, true)
        }) {
            panelContent(kind, pinned: false)
        }
        .frame(width: kind.width, height: kind == .colors ? nil : (kind == .brushes ? 480 : 580))
    }

    private func pinnedPanel(_ kind: PanelKind) -> some View {
        let base = panelOffsets[kind] ?? kind.defaultOffset
        let drag = panelDrag?.kind == kind ? panelDrag!.translation : .zero
        return PanelChrome(title: title(kind), pinned: true, accessory: accessory(kind, pinned: true),
                           onPin: { setPinned(kind, false) },
                           onDrag: { panelDrag = (kind, $0) },
                           onDragEnd: { t in
                               panelOffsets[kind] = CGSize(width: base.width + t.width, height: base.height + t.height)
                               panelDrag = nil
                           }) {
            panelContent(kind, pinned: true)
        }
        .frame(width: kind.width, height: kind.pinnedHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .offset(x: base.width + drag.width, y: base.height + drag.height)
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: kind.leading ? .topLeading : .topTrailing)
        .transition(.opacity)
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

    private static let selectionTools: [Tool] = [.lasso, .selectRect, .selectEllipse, .wand]

    private var selectionMenu: some View {
        let active = Self.selectionTools.contains(editor.tool)
        return Menu {
            ForEach(Self.selectionTools, id: \.self) { tool in
                Button { editor.selectTool(tool) } label: { Label(tool.displayName, systemImage: tool.symbol) }
            }
            Divider()
            Picker("組み合わせ", selection: Binding(get: { state.selectionOp }, set: { state.selectionOp = $0 })) {
                Text("新しく選ぶ").tag(SelectionOp.replace)
                Text("追加").tag(SelectionOp.add)
                Text("削除").tag(SelectionOp.subtract)
                Text("共通部分").tag(SelectionOp.intersect)
            }
            Divider()
            Button("すべて選択") { editor.selectAll() }
            Button("選択を解除") { editor.deselect() }
                .disabled(editor.doc.selection == nil)
            Button("選択範囲を反転") { editor.invertSelection() }
                .disabled(editor.doc.selection == nil)
            Button("選択範囲の中を消す", role: .destructive) { editor.clearSelectionContent() }
                .disabled(editor.doc.selection == nil)
        } label: {
            Image(systemName: active ? editor.tool.symbol : Tool.lasso.symbol)
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(active ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel("選択範囲")
    }

    /// 選択範囲があるあいだに出すバー: 移動・変形ツールと選択の解除
    private var selectionBar: some View {
        HStack(spacing: 4) {
            selectionBarTool(.move)
            selectionBarTool(.transform)
            Divider().frame(height: 22).padding(.horizontal, 6)
            Button { editor.deselect() } label: {
                Label("選択を解除", systemImage: "xmark.circle")
                    .padding(.horizontal, 8)
                    .frame(height: 40)
            }
            .keyboardShortcut("d")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    private func selectionBarTool(_ tool: Tool) -> some View {
        Button { editor.selectTool(tool) } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .foregroundStyle(editor.tool == tool ? Color.white : Color.primary)
                .background(editor.tool == tool ? Color.accentColor : .clear, in: Circle())
        }
        .accessibilityLabel(tool.displayName)
    }

    /// 移動・変形の途中に出す、確定・取り消しのバー
    private var transformBar: some View {
        HStack(spacing: 18) {
            Button { flipFloating(x: true) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .accessibilityLabel("左右反転")
            Button { flipFloating(x: false) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                .accessibilityLabel("上下反転")
            Divider().frame(height: 22)
            Button("キャンセル") { editor.cancelTransform() }
            Button("確定") { editor.commitTransform() }
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }

    private func flipFloating(x: Bool) {
        guard let f = editor.floating else { return }
        editor.recordTransformStep()
        var p = f.params
        if x { p.sx = -p.sx } else { p.sy = -p.sy }
        editor.updateTransform(p)
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

// MARK: - 端のスライダー（サイズ・不透明度。左右どちらの端にも寄せられる）

struct SideSliders: View {
    @Bindable var editor: Editor
    /// 持ち手のドラッグ（動かした量）
    var onDrag: (CGSize) -> Void = { _ in }
    /// 離したとき（動かした量と、画面での指の位置）
    var onDragEnd: (CGSize, CGPoint) -> Void = { _, _ in }

    /// 全体のおおよその高さ（上下の位置をはみ出さないよう抑えるのに使う）
    static let height: CGFloat = 520

    var body: some View {
        VStack(spacing: 18) {
            // 持ち手: ドラッグして動かす。左右は離したときに近いほうの端へ寄せる
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 22)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation) }
                    .onEnded { onDragEnd($0.translation, $0.location) })
                .accessibilityLabel("ドラッグして動かす")
                .padding(.bottom, -10)
            sliders
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// ブラシ・消しゴムのときだけ使える（持ち手はいつでも動かせる）
    private var sliders: some View {
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
        (L("正方形 2048"), 2048, 2048),
        (L("フル HD（横）"), 1920, 1080),
        (L("フル HD（縦）"), 1080, 1920),
        (L("4K（横）"), 3840, 2160),
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
