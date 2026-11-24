import NanopicCore
import NanopicUI
import SwiftUI

/// パネルを置く側
enum PanelSide: String, Codable, CaseIterable, Identifiable {
    case left, right
    var id: Self { self }
    var title: String { self == .left ? L("左") : L("右") }
}

/// 出し入れと左右の配置を選べるパネル
enum PanelKind: String, Codable, CaseIterable, Identifiable {
    case tools, toolOptions, color, palette, layers
    var id: Self { self }

    var title: String {
        switch self {
        case .tools: L("ツール")
        case .toolOptions: L("ツール設定")
        case .color: L("カラー")
        case .palette: L("パレット")
        case .layers: L("レイヤー")
        }
    }
}

struct PanelPlacement: Codable, Equatable {
    var visible = true
    var side: PanelSide
}

/// 画面のパネルの並び（設定 ＞ 画面）
///
/// 各側の列は、外（ウィンドウの端）から内へ「ツール」「ツール設定」「カラー・パレット・レイヤー」の順に並ぶ。
/// 右に置いたときは左右を反転する
struct PanelLayout: Codable, Equatable {
    var placements: [PanelKind: PanelPlacement] = [:]
    var showsStatusBar = true

    static let defaultSides: [PanelKind: PanelSide] = [
        .tools: .left, .toolOptions: .left, .color: .right, .palette: .right, .layers: .right,
    ]

    /// 保存した設定にないパネル（あとから足したもの）は、既定の側に出す
    subscript(kind: PanelKind) -> PanelPlacement {
        get { placements[kind] ?? PanelPlacement(side: Self.defaultSides[kind] ?? .left) }
        set { placements[kind] = newValue }
    }

    /// 保存のしかたの違い（既定と同じ値を明示しているか）は区別しない
    static func == (a: PanelLayout, b: PanelLayout) -> Bool {
        a.showsStatusBar == b.showsStatusBar && PanelKind.allCases.allSatisfy { a[$0] == b[$0] }
    }

    func shows(_ kind: PanelKind, on side: PanelSide) -> Bool {
        let p = self[kind]
        return p.visible && p.side == side
    }
}

extension AppState {
    private static let panelLayoutKey = "panelLayout.v1"

    static func loadPanelLayout() -> PanelLayout {
        guard let d = UserDefaults.standard.data(forKey: panelLayoutKey),
              let l = try? JSONDecoder().decode(PanelLayout.self, from: d) else { return PanelLayout() }
        return l
    }

    func savePanelLayout() {
        if let d = try? JSONEncoder().encode(panelLayout) { UserDefaults.standard.set(d, forKey: Self.panelLayoutKey) }
    }
}

// MARK: - 画面に並べる

/// 片側に並ぶパネルの列（外から内の順）
struct SidePanels: View {
    let state: AppState
    @Bindable var editor: Editor
    let side: PanelSide

    private enum Column: Hashable { case tools, options, stack }

    private var layout: PanelLayout { state.panelLayout }
    private var drawing: Bool { state.mode == .draw }
    /// リグモードではカラーとパレットを出さない（描かないので）
    private var showsColor: Bool { drawing && layout.shows(.color, on: side) }
    private var showsPalette: Bool { drawing && layout.shows(.palette, on: side) }
    private var showsLayers: Bool { layout.shows(.layers, on: side) }

    private var columns: [Column] {
        var c: [Column] = []
        if layout.shows(.tools, on: side) { c.append(.tools) }
        // リグモードのリグパネルは、隠していても出す（リグを組むのに欠かせないので）。置く側は「ツール設定」に従う
        if layout.shows(.toolOptions, on: side) || (!drawing && layout[.toolOptions].side == side) { c.append(.options) }
        if showsColor || showsPalette || showsLayers { c.append(.stack) }
        return side == .left ? c : c.reversed()
    }

    var body: some View {
        ForEach(columns, id: \.self) { col in
            if side == .right { Divider() }
            column(col)
            if side == .left { Divider() }
        }
    }

    @ViewBuilder
    private func column(_ col: Column) -> some View {
        switch col {
        case .tools:
            ToolBarView(state: state, editor: editor)
        case .options:
            Group {
                if drawing {
                    ToolOptionsView(state: state, editor: editor)
                } else {
                    RigPanel(state: state, editor: editor)
                }
            }
            .frame(width: 230)
        case .stack:
            VStack(spacing: 0) {
                if showsColor {
                    ColorPickerView(editor: editor)
                        .padding(10)
                }
                if showsPalette {
                    PaletteView(state: state, editor: editor)
                        .padding(.horizontal, 10)
                        .padding(.top, showsColor ? 0 : 10)
                        .padding(.bottom, 10)
                }
                if showsLayers {
                    if showsColor || showsPalette { Divider() }
                    LayerPanel(state: state, editor: editor)
                        // 名前の変更やドラッグの途中の状態は、書類ごとに捨てる
                        .id(ObjectIdentifier(editor))
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 270)
        }
    }
}

// MARK: - 設定画面

/// 設定ウィンドウの「画面」タブ
struct LayoutSettingsView: View {
    let state: AppState

    private func binding<T>(_ kind: PanelKind, _ key: WritableKeyPath<PanelPlacement, T>) -> Binding<T> {
        Binding(get: { state.panelLayout[kind][keyPath: key] }, set: { state.panelLayout[kind][keyPath: key] = $0 })
    }

    var body: some View {
        Form {
            Section {
                ForEach(PanelKind.allCases) { kind in
                    HStack {
                        Toggle(kind.title, isOn: binding(kind, \.visible))
                        Spacer()
                        Picker(kind.title, selection: binding(kind, \.side)) {
                            ForEach(PanelSide.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!state.panelLayout[kind].visible)
                    }
                }
            } header: {
                Text("パネル")
            } footer: {
                Text("片側に置いたパネルは、ウィンドウの端から「ツール」「ツール設定」「カラー・パレット・レイヤー」の順に並びます。リグモードでは、ツール設定の場所にリグパネルが出ます（隠していても出ます）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("ステータスバー", isOn: Binding(get: { state.panelLayout.showsStatusBar }, set: { state.panelLayout.showsStatusBar = $0 }))
            }
            Section {
                Button("最初の並びに戻す") { state.panelLayout = PanelLayout() }
                    .disabled(state.panelLayout == PanelLayout())
            }
        }
        .formStyle(.grouped)
    }
}
