import AppKit
import NanopicCore
import SwiftUI
import UniformTypeIdentifiers

struct LayerPanel: View {
    let state: AppState
    @Bindable var editor: Editor
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var dropTarget: (id: UUID, into: Bool)?

    var body: some View {
        let _ = editor.revision
        VStack(spacing: 0) {
            propertiesBar
                .padding(8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(editor.doc.flattenedForDisplay(), id: \.node.id) { item in
                        row(item.node, depth: item.depth)
                    }
                }
            }
            Divider()
            actionBar
                .padding(6)
        }
    }

    // MARK: プロパティ

    @ViewBuilder
    private var propertiesBar: some View {
        if let layer = editor.doc.activeLayer {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Menu {
                        if layer.isFolder {
                            Button(BlendMode.passThrough.displayName) { setBlend(layer, .passThrough) }
                            Divider()
                        }
                        ForEach(BlendMode.menuGroups.indices, id: \.self) { gi in
                            ForEach(BlendMode.menuGroups[gi], id: \.self) { m in
                                Button(m.displayName) { setBlend(layer, m) }
                            }
                            Divider()
                        }
                    } label: {
                        Text(layer.blendMode.displayName)
                    }
                    .frame(width: 130)
                    Spacer()
                    Text("\(Int((layer.opacity * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
                Slider(value: Binding(get: { layer.opacity }, set: { v in
                    editor.setLayerProperty(layer.id, label: "不透明度", coalesce: true) { $0.opacity = (v * 100).rounded() / 100 }
                }), in: 0...1)
                .controlSize(.small)
                HStack(spacing: 4) {
                    toggleButton("paperclip", "下のレイヤーでクリッピング (⌘⌥G)", layer.clipping) {
                        editor.setLayerProperty(layer.id, label: "クリッピング") { $0.clipping.toggle() }
                    }
                    toggleButton("checkerboard.rectangle", "透明ピクセルをロック", layer.lockAlpha) {
                        editor.setLayerProperty(layer.id, label: "透明ピクセルをロック") { $0.lockAlpha.toggle() }
                    }
                    .disabled(layer.isFolder)
                    toggleButton("lock", "レイヤーをロック", layer.locked) {
                        editor.setLayerProperty(layer.id, label: "レイヤーをロック") { $0.locked.toggle() }
                    }
                    toggleButton("scope", "参照レイヤーに設定", layer.isReference) {
                        editor.setLayerProperty(layer.id, label: "参照レイヤー") { $0.isReference.toggle() }
                    }
                    Spacer()
                }
            }
        }
    }

    private func setBlend(_ layer: LayerNode, _ m: NanopicCore.BlendMode) {
        editor.setLayerProperty(layer.id, label: "合成モード") { $0.blendMode = m }
    }

    private func toggleButton(_ symbol: String, _ help: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .background(on ? Color.accentColor.opacity(0.4) : Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 行

    private func row(_ node: LayerNode, depth: Int) -> some View {
        let active = node.id == editor.doc.activeLayerID
        return HStack(spacing: 4) {
            Button {
                editor.setLayerProperty(node.id, label: "表示切替") { $0.visible.toggle() }
            } label: {
                Image(systemName: node.visible ? "eye" : "eye.slash")
                    .foregroundStyle(node.visible ? .primary : .tertiary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            if depth > 0 {
                Spacer().frame(width: CGFloat(depth) * 14)
            }
            if node.clipping {
                Rectangle().fill(Color.red.opacity(0.8)).frame(width: 3, height: 30)
            }
            if node.isFolder {
                Button {
                    editor.setLayerUIState(node.id) { $0.expanded.toggle() }
                } label: {
                    Image(systemName: node.expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                Image(systemName: node.expanded ? "folder" : "folder.fill")
                    .frame(width: 40, height: 32)
            } else {
                thumbnail(node)
            }
            VStack(alignment: .leading, spacing: 1) {
                if renamingID == node.id {
                    TextField("", text: $renameText, onCommit: {
                        let name = renameText
                        renamingID = nil
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        if !name.isEmpty && name != node.name {
                            editor.setLayerProperty(node.id, label: "名前の変更") { $0.name = name }
                        }
                    })
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                } else {
                    Text(node.name)
                        .font(.callout)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text("\(Int((node.opacity * 100).rounded()))% \(node.blendMode.displayName)")
                    if node.lockAlpha { Image(systemName: "checkerboard.rectangle") }
                    if node.locked { Image(systemName: "lock.fill") }
                    if node.isReference { Image(systemName: "scope") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(active ? Color.accentColor.opacity(0.28) : Color.clear)
        .overlay(alignment: .top) {
            if dropTarget?.id == node.id && dropTarget?.into == false {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .overlay {
            if dropTarget?.id == node.id && dropTarget?.into == true {
                RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            renameText = node.name
            renamingID = node.id
        }
        .simultaneousGesture(TapGesture().onEnded { editor.setActiveLayer(node.id) })
        .draggable(node.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            defer { dropTarget = nil }
            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
            editor.moveLayer(id, relativeTo: node.id, intoFolder: node.isFolder)
            return true
        } isTargeted: { t in
            if t { dropTarget = (node.id, node.isFolder) } else if dropTarget?.id == node.id { dropTarget = nil }
        }
        .contextMenu {
            Button("複製") { editor.setActiveLayer(node.id); editor.duplicateActiveLayer() }
            Button("下のレイヤーに結合") { editor.setActiveLayer(node.id); editor.mergeDown() }
            Button("フォルダーを作成して挿入") { editor.setActiveLayer(node.id); editor.groupActiveLayer() }
            Divider()
            Button("削除") { editor.setActiveLayer(node.id); editor.deleteActiveLayer() }
        }
    }

    private func thumbnail(_ node: LayerNode) -> some View {
        ZStack {
            CheckerboardView()
            if let img = state.thumbnail(for: node) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 40, height: 32)
        .overlay(Rectangle().stroke(Color.gray.opacity(0.5), lineWidth: 0.5))
    }

    // MARK: アクション

    private var actionBar: some View {
        HStack(spacing: 2) {
            iconButton("doc.badge.plus", "新規ラスターレイヤー (⇧⌘N)") { editor.addLayer() }
            iconButton("folder.badge.plus", "新規レイヤーフォルダー") { editor.addFolder() }
            iconButton("plus.square.on.square", "レイヤーを複製") { editor.duplicateActiveLayer() }
            iconButton("arrow.down.to.line", "下のレイヤーに結合 (⌘E)") { editor.mergeDown() }
            Spacer()
            iconButton("arrow.up", "上へ移動") { editor.moveActiveLayer(up: true) }
            iconButton("arrow.down", "下へ移動") { editor.moveActiveLayer(up: false) }
            iconButton("trash", "レイヤーを削除") { editor.deleteActiveLayer() }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct CheckerboardView: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 5
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) {
                    let even = (Int(x / s) + Int(y / s)) % 2 == 0
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(even ? .white : Color(white: 0.85)))
                }
            }
        }
    }
}
