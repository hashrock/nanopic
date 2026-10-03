import Foundation

/// デフォーマのハンドルを画面に見えている位置に出し、画面上のドラッグ量をデフォーマの座標に直すための計算
extension DocumentState {
    /// d のあとにかかるデフォーマ（同じレイヤーで後に付けたもの、親フォルダーのもの。内側から外側へ）
    public func outerDeformers(of d: Deformer) -> [Deformer] {
        let all = rig.deformers
        guard let n = node(psdID: d.layer), let path = indexPath(of: n.id),
              let k = all.firstIndex(where: { $0.id == d.id }) else { return [] }
        var out = all[(k + 1)...].filter { $0.layer == d.layer }
        for depth in stride(from: path.count - 1, through: 1, by: -1) {
            guard let parent = node(at: Array(path.prefix(depth))), parent.psdID != 0 else { continue }
            out += all.filter { $0.layer == parent.psdID }
        }
        return out
    }

    /// d の形まで写した点に、外側のデフォーマをかけた位置（画面に見えている位置）
    public func outerMap(_ p: RigPoint, after d: Deformer, forms: [String: DeformerForm]) -> RigPoint {
        var q = p
        for o in outerDeformers(of: d) { q = o.map(q, forms[o.id] ?? DeformerForm()) }
        return q
    }

    /// 画面上で動かした量を、外側の変形をさかのぼって d の座標での量に直す（その点での傾き・伸びの逆をかける）
    public func localDelta(_ delta: RigPoint, at p: RigPoint, after d: Deformer, forms: [String: DeformerForm]) -> RigPoint {
        let o = outerMap(p, after: d, forms: forms)
        let ex = outerMap(RigPoint(p.x + 1, p.y), after: d, forms: forms)
        let ey = outerMap(RigPoint(p.x, p.y + 1), after: d, forms: forms)
        let a = ex.x - o.x, b = ey.x - o.x, c = ex.y - o.y, e = ey.y - o.y
        let det = a * e - b * c
        guard abs(det) > 1e-9 else { return delta }
        return RigPoint((e * delta.x - b * delta.y) / det, (-c * delta.x + a * delta.y) / det)
    }
}
