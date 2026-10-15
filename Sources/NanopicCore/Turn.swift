import Foundation

/// 立体的に振り向く。平らな絵を、楕円体（頭のような丸いもの）の表面に貼ったものとみなして回す。
/// 真ん中ほど手前に出ているので大きく動き、ふち（輪郭）はほとんど動かない。フォルダーなら中のレイヤーの重なり順を奥行きとみなし、
/// いちばん下のレイヤー（後ろ髪など）は奥の面にあるので逆に動き、上のレイヤー（目・鼻など）ほど少し手前に出る
public struct TurnRig: Codable, Equatable, Sendable {
    /// 左右の向きのパラメータ（+1 で右を向く）
    public var yaw: String
    /// 上下の向きのパラメータ（+1 で上を向く）
    public var pitch: String
    /// 回す中心と、横・縦の半径（ドキュメント座標）。カーソルを追うときの基準にも使う
    public var center: RigPoint
    public var radius: RigPoint

    /// 点 p を向かせたいときのパラメータの値（中心から半径の 2 倍離れると向ききる）
    public func values(lookingAt p: RigPoint) -> [String: Double] {
        func v(_ d: Double, _ r: Double) -> Double { Swift.min(Swift.max(d / Swift.max(r * 2, 1), -1), 1) }
        return [yaw: v(p.x - center.x, radius.x), pitch: -v(p.y - center.y, radius.y)]
    }
}

extension Editor {
    /// 左右に向ききったときの角度（度）
    static let turnYaw = 28.0
    /// 上下に向ききったときの角度（度）
    static let turnPitch = 18.0
    /// 手前への出っぱり（横と縦の小さいほうの半径に対する割合）。大きくすると、向こう側の面がつぶれて折り返す
    static let turnBulge = 0.5

    /// レイヤー（フォルダー）に、立体的に振り向くリグを付ける（取り消しは 1 回で戻る）。
    /// 左右・上下の向きのパラメータと、見回すループのタイムラインを作る。描かれていなければ nil
    @discardableResult
    public func addTurn(to id: UUID) -> TurnRig? {
        doc.assignPSDIDs()
        guard let n = doc.node(id), let bounds = Self.contentBounds(n) else { return nil }
        // 奥から手前の順（children は下から上の順）
        let parts = n.isFolder ? n.children.filter { $0.visible && Self.contentBounds($0) != nil } : [n]
        guard !parts.isEmpty else { return nil }
        commitTransform()
        checkpoint("立体的に振り向かせる")

        let rect = RigRect(bounds)
        let center = RigPoint(rect.x + rect.width / 2, rect.y + rect.height / 2)
        let radius = RigPoint(rect.width / 2, rect.height / 2)
        // 向ききったときの形（値 → デフォーマ ID → 形）
        var yawForms: [Double: [String: DeformerForm]] = [:], pitchForms: [Double: [String: DeformerForm]] = [:]
        for (i, part) in parts.enumerated() {
            let depth = Self.turnDepth(rank: i, count: parts.count)
            // 全部のパーツで同じ範囲の格子を使い、同じ立体の上に並べる（格子を細かくしすぎると、なめらかさが減って向こう側が折り返す）
            let d = makeDeformer(part, bounds: bounds, kind: .warp, name: "\(part.name)の向き", cols: 6, rows: 6)
            doc.rig.deformers.append(d)
            func form(yaw a: Double, pitch b: Double) -> DeformerForm {
                DeformerForm(offsets: (0..<d.pointCount).map {
                    Self.turnOffset(d.restPoint($0), center: center, radius: radius, depth: depth,
                                    yaw: a * .pi / 180, pitch: b * .pi / 180)
                })
            }
            for s in [-1.0, 1.0] {
                yawForms[s, default: [:]][d.id] = form(yaw: s * Self.turnYaw, pitch: 0)
                pitchForms[s, default: [:]][d.id] = form(yaw: 0, pitch: s * Self.turnPitch)
            }
        }
        func addParameter(_ name: String, _ forms: [Double: [String: DeformerForm]]) -> String {
            var p = makeParameter(name: "\(n.name)の\(name)", min: -1, max: 1, defaultValue: 0)
            p.keys = forms.keys.sorted().map { RigParameterKey(value: $0, forms: forms[$0]!) }
            doc.rig.parameters.append(p)
            return p.id
        }
        let yaw = addParameter("左右の向き", yawForms), pitch = addParameter("上下の向き", pitchForms)

        // 少し上 → 右 → 少し下 → 左 と、ぐるっと見回す
        addLoopTrack(yaw, cycle: [(0, 0, .easeInOut), (0.25, 1, .easeInOut), (0.5, 0, .easeInOut), (0.75, -1, .easeInOut)], period: 4)
        addLoopTrack(pitch, cycle: [(0, 0.6, .easeInOut), (0.25, 0, .easeInOut), (0.5, -0.4, .easeInOut), (0.75, 0, .easeInOut)], period: 4)
        let turn = TurnRig(yaw: yaw, pitch: pitch, center: center, radius: radius)
        doc.rig.turn = turn
        revision += 1
        applyFrame()
        return turn
    }

    /// 重なり順（0 がいちばん下）での奥行き。いちばん下（後ろ髪など）は奥の面（-1）、ほかは手前の面（1）に置き、
    /// 上のレイヤー（目・鼻など）ほど少し手前に出す。1 枚だけなら手前の面
    static func turnDepth(rank i: Int, count n: Int) -> Double {
        guard n > 1 else { return 1 }
        if i == 0 { return -1 }
        return n > 2 ? 1 + 0.2 * Double(i - 1) / Double(n - 2) : 1
    }

    /// 平らな絵の点 p を、楕円体の表面（depth が 1 なら手前の面、-1 なら奥の面、0 なら回る軸を通る平面）に置いて回したときのずれ
    static func turnOffset(_ p: RigPoint, center c: RigPoint, radius r: RigPoint, depth: Double, yaw: Double, pitch: Double) -> RigPoint {
        let u = (p.x - c.x) / Swift.max(r.x, 1), v = (p.y - c.y) / Swift.max(r.y, 1)
        let z = sqrt(Swift.max(0, 1 - u * u - v * v)) * Swift.min(r.x, r.y) * turnBulge * depth
        let x = p.x - c.x, y = p.y - c.y
        // 横に回してから縦に回す（画面は y が下向きなので、上を向くと手前の点は上へ動く）
        let x1 = x * cos(yaw) + z * sin(yaw), z1 = -x * sin(yaw) + z * cos(yaw)
        let y1 = y * cos(pitch) - z1 * sin(pitch)
        return RigPoint(x1 - x, y1 - y)
    }

    /// 振り向くリグ（向きのパラメータを消していたら nil）
    public var turnRig: TurnRig? {
        guard let t = doc.rig.turn, doc.rig.parameter(t.yaw) != nil, doc.rig.parameter(t.pitch) != nil else { return nil }
        return t
    }

    /// p の方を向く（履歴にもタイムラインにも残さない見た目だけの変更）
    public func lookAt(_ p: RigPoint) {
        guard let turn = turnRig else { return }
        parameterValues.merge(turn.values(lookingAt: p)) { _, new in new }
        showsDeformation = true
        markAllDirty()
    }
}
