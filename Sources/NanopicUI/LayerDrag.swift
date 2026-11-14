import NanopicCore
import Observation
import SwiftUI

// MARK: - ドラッグ&ドロップ

public struct LayerRowFrame: Equatable {
    public let id: UUID
    public let isFolder: Bool
    public let name: String
    public let frame: CGRect

    public init(id: UUID, isFolder: Bool, name: String, frame: CGRect) {
        self.id = id
        self.isFolder = isFolder
        self.name = name
        self.frame = frame
    }
}

public struct LayerRowFramesKey: PreferenceKey {
    public static let defaultValue: [LayerRowFrame] = []
    public static func reduce(value: inout [LayerRowFrame], nextValue: () -> [LayerRowFrame]) {
        value.append(contentsOf: nextValue())
    }
}

/// リスト内で完結するドラッグ。NSItemProvider を介さないので軽く、即座に反応する。
@Observable
public final class LayerDragState {
    public static let space = "layerList"

    public struct Target: Equatable {
        public let id: UUID
        public let placement: Editor.DropPlacement
        public let frame: CGRect
    }

    public init() {}

    @ObservationIgnored public var rowFrames: [LayerRowFrame] = []
    public private(set) var draggingID: UUID?
    public private(set) var draggingName = ""
    public private(set) var location: CGPoint = .zero
    public private(set) var target: Target?

    public func update(dragging id: UUID, location p: CGPoint) {
        if draggingID != id {
            draggingID = id
            draggingName = rowFrames.first { $0.id == id }?.name ?? ""
        }
        location = p
        let t = computeTarget(p, dragging: id)
        if t != target { target = t }
    }

    private func computeTarget(_ p: CGPoint, dragging id: UUID) -> Target? {
        let sorted = rowFrames.sorted { $0.frame.minY < $1.frame.minY }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        // リストの上下にはみ出したら先頭の上 / 末尾の下
        let row: LayerRowFrame
        if p.y < first.frame.minY {
            row = first
        } else if p.y >= last.frame.maxY {
            row = last
        } else if let r = sorted.first(where: { p.y >= $0.frame.minY && p.y < $0.frame.maxY }) {
            row = r
        } else {
            return nil
        }
        if row.id == id { return nil }
        let f = row.frame
        let rel = (p.y - f.minY) / max(f.height, 1)
        let placement: Editor.DropPlacement
        if row.isFolder && rel > 0.25 && rel < 0.75 {
            placement = .into
        } else {
            placement = rel < 0.5 ? .above : .below
        }
        return Target(id: row.id, placement: placement, frame: f)
    }

    public func finish(editor: Editor) {
        defer {
            draggingID = nil
            target = nil
        }
        guard let id = draggingID, let t = target else { return }
        // 選択中のレイヤーをつかんだら、選択中のものをまとめて動かす
        if editor.isLayerSelected(id) {
            editor.moveSelectedLayers(relativeTo: t.id, placement: t.placement)
        } else {
            editor.moveLayer(id, relativeTo: t.id, placement: t.placement)
        }
    }
}

public struct LayerDropIndicator: View {
    let drag: LayerDragState

    public init(drag: LayerDragState) {
        self.drag = drag
    }

    public var body: some View {
        if drag.draggingID != nil {
            ZStack(alignment: .topLeading) {
                if let t = drag.target {
                    switch t.placement {
                    case .into:
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .frame(width: t.frame.width, height: t.frame.height)
                            .offset(x: t.frame.minX, y: t.frame.minY)
                    case .above, .below:
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: t.frame.width, height: 2)
                            .offset(x: t.frame.minX, y: (t.placement == .above ? t.frame.minY : t.frame.maxY) - 1)
                    }
                }
                Text(drag.draggingName)
                    .font(.callout)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: drag.location.x + 8, y: drag.location.y - 10)
            }
            .allowsHitTesting(false)
        }
    }
}
