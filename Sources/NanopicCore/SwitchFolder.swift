import Foundation

/// スイッチフォルダー: 子のうち常に 1 つだけを表示するフォルダー（表情の差分、口パク、コマ送りなど）。
/// どの子を出しているかは子の表示状態そのもので持つので、PSD にはふつうのフォルダーとして保存でき、
/// スイッチである印だけをサイドカーに持つ。
extension Editor {
    /// id の親がスイッチフォルダーか
    public func isInSwitch(_ id: UUID) -> Bool {
        guard let path = doc.indexPath(of: id), path.count > 1 else { return false }
        return doc.node(at: Array(path.dropLast()))?.isSwitch ?? false
    }

    public func setSwitch(_ id: UUID, _ on: Bool) {
        guard let n = doc.node(id), n.isFolder, n.isSwitch != on else { return }
        commitTransform()
        checkpoint(on ? "スイッチフォルダーにする" : "スイッチフォルダーを戻す")
        doc.modify(id) { $0.isSwitch = on }
        normalizeSwitches()
        structureChanged()
    }

    /// 目のアイコンの操作。スイッチフォルダーの子なら、その子に切り替える（表示中の子は隠せない）
    public func toggleVisibility(_ id: UUID) {
        if isInSwitch(id) {
            showSwitchChild(id)
        } else {
            guard doc.node(id) != nil else { return }
            checkpoint("表示切替")
            doc.modify(id) { $0.visible.toggle() }
            autoKey(id)
            structureChanged()
        }
    }

    /// スイッチフォルダーで id の子を表示し、ほかの子を隠す
    public func showSwitchChild(_ id: UUID) {
        guard isInSwitch(id), let n = doc.node(id), !n.visible else { return }
        commitTransform()
        checkpoint("表示の切り替え")
        reveal(id)
        if let path = doc.indexPath(of: id), let parent = doc.node(at: Array(path.dropLast())) { autoKey(parent.id) }
        structureChanged()
    }

    /// id が、それを含むスイッチフォルダーで表示されるようにする（履歴は呼び出し側で）
    func reveal(_ id: UUID) {
        guard let path = doc.indexPath(of: id) else { return }
        for depth in 1..<path.count {
            let parentPath = Array(path.prefix(depth))
            guard let parent = doc.node(at: parentPath), parent.isSwitch else { continue }
            let show = path[depth]
            doc.modifySiblings(parentPath: parentPath) { kids in
                for i in kids.indices { kids[i].visible = i == show }
            }
        }
    }

    /// id がスイッチフォルダーの隠れている子（の中）にあるか
    func isHiddenBySwitch(_ id: UUID) -> Bool {
        guard let path = doc.indexPath(of: id) else { return false }
        for depth in 1..<path.count {
            if doc.node(at: Array(path.prefix(depth)))?.isSwitch == true,
               doc.node(at: Array(path.prefix(depth + 1)))?.visible == false { return true }
        }
        return false
    }

    /// どのスイッチフォルダーも、表示する子がちょうど 1 つになるように整える（すでに 1 つなら触らない）。
    /// 残すのは編集中のレイヤーを含む子、なければ一番上の表示中の子、それもなければ一番上の子
    func normalizeSwitches() {
        let activePath = doc.activeLayerID.flatMap { doc.indexPath(of: $0) }
        func walk(_ path: [Int], _ nodes: [LayerNode]) {
            for (i, n) in nodes.enumerated() where n.isFolder {
                let p = path + [i]
                if n.isSwitch && !n.children.isEmpty {
                    let visible = n.children.indices.filter { n.children[$0].visible }
                    var keep: Int?
                    if let a = activePath, a.count > p.count, Array(a.prefix(p.count)) == p { keep = a[p.count] }
                    if visible.count != 1 {
                        let k = keep ?? visible.last ?? n.children.count - 1
                        doc.modifySiblings(parentPath: p) { kids in
                            for j in kids.indices { kids[j].visible = j == k }
                        }
                    }
                }
                if let n2 = doc.node(at: p) { walk(p, n2.children) }
            }
        }
        walk([], doc.layers)
    }

    /// 保存の直前に呼ぶ: レイヤー ID を振り、サイドカーをドキュメントに合わせる
    public func prepareForSave() {
        assignPSDIDs()
        var ids: [UInt32] = []
        doc.forEachNode { if $0.isSwitch { ids.append($0.psdID) } }
        sidecar.switchFolders = ids
        sidecar.timeline = doc.timeline.isEmpty ? nil : doc.timeline
        sidecar.rig = doc.rig.isEmpty ? nil : doc.rig
    }

    /// 開いたときに呼ぶ: サイドカーの印をドキュメントに反映する
    func applySidecar() {
        for id in sidecar.switchFolders {
            guard let n = doc.node(psdID: id), n.isFolder else { continue }
            doc.modify(n.id) { $0.isSwitch = true }
        }
        if let t = sidecar.timeline { doc.timeline = t }
        if let r = sidecar.rig { doc.rig = r }
        normalizeSwitches()
    }
}
