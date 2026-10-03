import NanopicCore
import SwiftUI

/// アニメーションモードの左パネル。パラメータ（つまみ）と、編集中のレイヤーのデフォーマを扱う
struct RigPanel: View {
    let state: AppState
    @Bindable var editor: Editor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                parameters
                Divider()
                deformers
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: パラメータ

    private var parameters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("パラメータ").font(.headline)
                Spacer()
                Button {
                    let id = editor.addParameter(name: "パラメータ\(editor.rig.parameters.count + 1)")
                    state.editingParameter = id
                } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("パラメータ（名前つきのつまみ）を足す")
            }
            if editor.rig.parameters.isEmpty {
                Text("つまみを足し、つまみの値ごとにデフォーマの形を記録して動かします。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(editor.rig.parameters, id: \.id) { p in parameterRow(p) }
            if !editor.rig.parameters.isEmpty {
                Button("既定値に戻す") { editor.resetPose() }
                    .controlSize(.small)
                    .disabled(editor.parameterValues.isEmpty)
                    .help("すべてのつまみを既定値に戻す")
                Text("名前を選ぶと、キャンバスのハンドルでそのつまみの今の値の形を記録できます。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func parameterRow(_ p: RigParameter) -> some View {
        let editing = state.editingParameter == p.id
        let hasTrack = editor.timeline.parameterTracks.contains { $0.parameter == p.id }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: editing ? "pencil.circle.fill" : "slider.horizontal.3")
                    .foregroundStyle(editing ? Color.accentColor : .secondary)
                Text(p.name).font(.callout.weight(editing ? .semibold : .regular)).lineLimit(1)
                Spacer()
                Text(String(format: "%.2f", editor.parameterValue(p.id)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Menu {
                    Button("名前を変える...") {
                        if let name = state.promptText("パラメータの名前", value: p.name), !name.isEmpty {
                            editor.updateParameter(p.id) { $0.name = name }
                        }
                    }
                    Button("範囲と既定値...") {
                        if let r = state.promptRange(min: p.min, max: p.max, defaultValue: p.defaultValue) {
                            editor.updateParameter(p.id) { $0.min = r.min; $0.max = r.max; $0.defaultValue = $0.clamp(r.defaultValue) }
                        }
                    }
                    Divider()
                    if hasTrack {
                        Button("タイムラインのトラックを削除") { editor.removeParameterTrack(p.id) }
                    } else {
                        Button("タイムラインにトラックを足す") { editor.addParameterTrack(p.id) }
                    }
                    Divider()
                    Button("パラメータを削除") {
                        if editing { state.editingParameter = nil }
                        editor.removeParameter(p.id)
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture { state.editingParameter = editing ? nil : p.id }
            ParameterSlider(editor: editor, parameter: p, value: editor.parameterValue(p.id))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(editing ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
    }

    // MARK: デフォーマ

    /// 編集中のレイヤーと、その親フォルダーに付いているデフォーマ（内側から）
    private var targetDeformers: [(Deformer, String)] {
        guard let active = editor.activeLayerID, let path = editor.doc.indexPath(of: active) else { return [] }
        var out: [(Deformer, String)] = []
        for depth in stride(from: path.count, through: 1, by: -1) {
            guard let n = editor.doc.node(at: Array(path.prefix(depth))) else { continue }
            out += editor.deformers(on: n.id).map { ($0, n.name) }
        }
        return out
    }

    private var deformers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("デフォーマ").font(.headline)
            if let layer = editor.doc.activeLayer {
                Text("編集中: \(layer.name)").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("回転を付ける") { editor.addDeformer(to: layer.id, kind: .rotation) }
                    Button("ワープを付ける") { editor.addDeformer(to: layer.id, kind: .warp) }
                }
                .controlSize(.small)
            }
            let ds = targetDeformers
            if ds.isEmpty {
                Text("フォルダーに付けると、中のレイヤー全部が一緒に動きます。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ds, id: \.0.id) { d, layerName in deformerRow(d, layerName) }
        }
    }

    private func deformerRow(_ d: Deformer, _ layerName: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: d.kind == .rotation ? "arrow.triangle.2.circlepath" : "squareshape.split.2x2")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(d.name).font(.callout).lineLimit(1)
                    Text(layerName).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("名前を変える...") {
                        if let name = state.promptText("デフォーマの名前", value: d.name), !name.isEmpty {
                            editor.updateDeformer(d.id, label: "デフォーマの名前") { $0.name = name }
                        }
                    }
                    Button(d.kind == .rotation ? "中心を描かれている所に合わせる" : "範囲を描かれている所に合わせる") {
                        editor.fitDeformerToContent(d.id)
                    }
                    Divider()
                    Button("外す") { editor.removeDeformer(d.id) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if d.kind == .warp {
                HStack(spacing: 8) {
                    Text("格子").font(.caption).foregroundStyle(.secondary)
                    Stepper("横 \(d.cols)", value: Binding(get: { d.cols }, set: { editor.setWarpGrid(d.id, cols: $0, rows: d.rows) }), in: 1...16)
                    Stepper("縦 \(d.rows)", value: Binding(get: { d.rows }, set: { editor.setWarpGrid(d.id, cols: d.cols, rows: $0) }), in: 1...16)
                }
                .font(.caption)
                .controlSize(.mini)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }
}
