import NanopicCore
import SwiftUI

enum AdjustmentKind: String, Identifiable {
    case hueSaturation, brightnessContrast
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hueSaturation: return "色相・彩度・明度"
        case .brightnessContrast: return "明るさ・コントラスト"
        }
    }
}

extension AppState {
    /// 補正パネルを開く（描けないレイヤーなら開かない）
    func openAdjustment(_ kind: AdjustmentKind) {
        guard editor.canPaintOnActiveLayer else {
            NSSound.beep()
            return
        }
        editor.cancelAdjustment()
        adjustmentKind = kind
    }

    func closeAdjustment(commit: Bool) {
        if commit { editor.commitAdjustment() } else { editor.cancelAdjustment() }
        adjustmentKind = nil
    }
}

/// キャンバスの隅に浮かぶ補正パネル。値を変えるとすぐ表示に反映し、OK で確定する
struct AdjustmentPanel: View {
    let state: AppState
    let kind: AdjustmentKind
    @State private var value = ColorAdjustment()
    @State private var preview = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind.title).font(.headline)
            switch kind {
            case .hueSaturation:
                slider("色相", $value.hue, -180...180, suffix: "°")
                slider("彩度", $value.saturation, -100...100)
                slider("明度", $value.lightness, -100...100)
            case .brightnessContrast:
                slider("明るさ", $value.brightness, -100...100)
                slider("コントラスト", $value.contrast, -100...100)
            }
            HStack {
                Toggle("プレビュー", isOn: $preview).toggleStyle(.checkbox)
                Spacer()
                Button("リセット") { value = ColorAdjustment() }
                    .disabled(value.isIdentity)
            }
            .font(.caption)
            HStack {
                Spacer()
                Button("キャンセル") { state.closeAdjustment(commit: false) }
                Button("OK") { state.closeAdjustment(commit: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
        .onChange(of: value) { _, _ in update() }
        .onChange(of: preview) { _, _ in update() }
        .onAppear { update() }
    }

    private func update() {
        // プレビューを切ると補正前の見た目に戻す（値は残る）
        state.editor.previewAdjustment(preview ? value : ColorAdjustment())
    }

    private func slider(_ label: String, _ v: Binding<Float>, _ range: ClosedRange<Float>, suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%+.0f", v.wrappedValue) + suffix)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { v.wrappedValue }, set: { v.wrappedValue = $0.rounded() }), in: range)
                .controlSize(.small)
        }
    }
}
