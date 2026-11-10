import NanopicCore
import SwiftUI

public struct LabeledSlider: View {
    let label: LocalizedStringKey
    @Binding var value: Float
    var range: ClosedRange<Float>
    var format: String = "%.0f"
    var scale: Float = 1
    var suffix: String = ""

    public init(label: LocalizedStringKey, value: Binding<Float>, range: ClosedRange<Float>, format: String = "%.0f", scale: Float = 1, suffix: String = "") {
        self.label = label
        _value = value
        self.range = range
        self.format = format
        self.scale = scale
        self.suffix = suffix
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value * scale) + suffix)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

/// 対数スケールのサイズスライダー
public struct SizeSlider: View {
    @Binding var size: Float

    public init(size: Binding<Float>) { _size = size }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("ブラシサイズ").font(.caption)
                Spacer()
                Text(size < 10 ? String(format: "%.1f px", size) : String(format: "%.0f px", size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { log(max(size, 0.5)) }, set: { size = (exp($0) * 10).rounded() / 10 }),
                   in: log(0.5)...log(1000))
                .controlSize(.small)
        }
    }
}

public extension Binding where Value == String {
    /// 保存してある名前（既定のブラシ名など）を訳して出し、打ち替えたときだけ書き戻す
    var localizedName: Binding<String> {
        Binding(get: { LName(wrappedValue) }, set: { wrappedValue = LNameEdited($0, original: wrappedValue) })
    }
}
