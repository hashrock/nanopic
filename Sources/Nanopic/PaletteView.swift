import AppKit
import NanopicCore
import SwiftUI

/// 登録した色。クリックで描画色、Option＋クリックでサブカラーにする
struct PaletteView: View {
    let state: AppState
    @Bindable var editor: Editor

    private let columns = [GridItem(.adaptive(minimum: 20, maximum: 24), spacing: 4)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("パレット").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    editor.addToPalette(editor.mainColor)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(editor.palette.contains { Editor.sameColor($0, editor.mainColor) })
                .help("描画色をパレットに登録")
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(Array(editor.palette.enumerated()), id: \.offset) { i, c in
                        swatch(i, c)
                    }
                }
            }
            .frame(maxHeight: 76)
        }
        .onChange(of: editor.palette) { _, _ in state.savePreferences() }
    }

    private func swatch(_ i: Int, _ c: SIMD3<Float>) -> some View {
        let selected = Editor.sameColor(c, editor.mainColor)
        return RoundedRectangle(cornerRadius: 3)
            .fill(c.swiftUIColor)
            .frame(width: 20, height: 20)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.6), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: selected ? 2 : 0).padding(-2))
            .contentShape(Rectangle())
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.option) { editor.subColor = c } else { editor.mainColor = c }
            }
            .contextMenu {
                Button("描画色で上書き") { editor.replacePaletteColor(at: i, with: editor.mainColor) }
                Button("削除") { editor.removeFromPalette(at: i) }
            }
            .help("#\(c.hex)（Option＋クリックでサブカラー）")
    }
}
