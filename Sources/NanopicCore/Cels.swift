import Foundation

/// パラパラ（コマ送り）: スイッチフォルダーの子を 1 枚ずつのセルとして描く
extension Editor {
    /// id を含む、いちばん内側のスイッチフォルダーの位置（id 自身がスイッチならその位置）
    func switchPath(containing id: UUID) -> [Int]? {
        guard let path = doc.indexPath(of: id) else { return nil }
        for depth in stride(from: path.count, through: 1, by: -1) {
            let p = Array(path.prefix(depth))
            if doc.node(at: p)?.isSwitch == true { return p }
        }
        return nil
    }

    /// 今のコマに新しいセルを作り、キーを打って描く対象にする。
    /// 作る先は編集中のレイヤーを含むスイッチフォルダー。なければ編集中のレイヤーを最初のセルにしてスイッチフォルダーで包む
    @discardableResult
    public func addCel() -> UUID? {
        guard let id = doc.activeLayerID, let activePath = doc.indexPath(of: id) else { return nil }
        commitTransform()
        cancelAdjustment()
        checkpoint("新しいセル")
        doc.assignPSDIDs()
        var swPath = switchPath(containing: id)
        if swPath == nil {
            var folder = LayerNode(name: nextLayerName(prefix: "アニメーション"), kind: .folder)
            folder.isSwitch = true
            let folderID = folder.id
            doc.insert(folder, parentPath: Array(activePath.dropLast()), index: activePath.last! + 1)
            guard var first = doc.remove(id) else { return nil }
            first.visible = true
            first.clipping = false
            doc.modify(folderID) { $0.children = [first] }
            doc.assignPSDIDs()
            swPath = doc.indexPath(of: folderID)
        }
        guard let sp = swPath, let sw = doc.node(at: sp) else { return nil }

        // トラックがなければ、今出ているセルを最初のコマのキーにして作る
        if doc.timeline.track(for: sw.psdID) == nil {
            let shown = sw.children.first(where: \.visible) ?? sw.children.last
            doc.timeline.tracks.append(TimelineTrack(layer: sw.psdID, keys: shown.map { [TimelineKey(frame: 0, child: $0.psdID)] } ?? []))
        }
        // 名前は番号。今出ているセルの上に置く
        let numbers = sw.children.compactMap { Int($0.name) }
        let cel = LayerNode(name: "\(max(numbers.max() ?? 0, sw.children.count) + 1)")
        let index = (sw.children.firstIndex(where: \.visible) ?? sw.children.count - 1) + 1
        doc.insert(cel, parentPath: sp, index: index)
        doc.assignPSDIDs()
        reveal(cel.id)
        doc.activeLayerID = cel.id
        selectedLayerIDs = []
        if let psd = doc.node(cel.id)?.psdID, let ti = doc.timeline.tracks.firstIndex(where: { $0.layer == sw.psdID }) {
            doc.timeline.tracks[ti].set(TimelineKey(frame: currentFrame, child: psd))
        }
        structureChanged()
        return cel.id
    }

    /// コマを移ったとき、編集中のレイヤーがスイッチフォルダーの隠れたセル（の中）にあれば、出ているセルに移す。
    /// セルがフォルダーなら、その中の同じ名前のレイヤー（なければ一番上のレイヤー）
    func followCel() {
        guard timelineOpen, let id = doc.activeLayerID, let path = doc.indexPath(of: id) else { return }
        for depth in stride(from: path.count - 1, through: 1, by: -1) {
            guard let sw = doc.node(at: Array(path.prefix(depth))), sw.isSwitch,
                  let cel = doc.node(at: Array(path.prefix(depth + 1))), !cel.visible,
                  let shown = sw.children.first(where: \.visible) else { continue }
            var target = shown
            if depth + 1 < path.count, shown.isFolder, let name = doc.node(id)?.name {
                target = Self.findLayer(in: shown) { $0.name == name } ?? Self.findLayer(in: shown) { !$0.isFolder } ?? shown
            }
            doc.activeLayerID = target.id
            selectedLayerIDs = []
            revision += 1
            return
        }
    }

    /// 上（後ろの子）から探す
    private static func findLayer(in node: LayerNode, where match: (LayerNode) -> Bool) -> LayerNode? {
        for c in node.children.reversed() {
            if match(c) { return c }
            if c.isFolder, let f = findLayer(in: c, where: match) { return f }
        }
        return nil
    }
}
