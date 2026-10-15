import Foundation

/// おまかせの動き。選んだレイヤー（フォルダー）にデフォーマとパラメータを付け、タイムラインでくり返し動かす。
/// リグを組まなくても、描いた絵をすぐ少し動かせるようにする
public enum MotionPreset: String, CaseIterable, Sendable {
    /// 下を止めて、上の方を伸び縮みさせる
    case breathe
    /// 下の真ん中を軸に、左右に傾く
    case sway
    /// 上下に浮き沈みする
    case float
    /// 縮んでから伸びて跳ねる
    case bounce
    /// 下を止めて、上の方を左右になびかせる
    case flutter

    public var displayName: String {
        switch self {
        case .breathe: return "呼吸"
        case .sway: return "ゆらゆら"
        case .float: return "ふわふわ"
        case .bounce: return "ぴょこぴょこ"
        case .flutter: return "なびく"
        }
    }

    /// 1 回の動きの秒数
    var period: Double {
        switch self {
        case .breathe, .sway: return 3
        case .float, .flutter: return 2
        case .bounce: return 1
        }
    }

    var deformerKind: DeformerKind {
        switch self {
        case .sway, .float: return .rotation
        case .breathe, .bounce, .flutter: return .warp
        }
    }

    /// パラメータの範囲（既定値は 0）
    var range: (min: Double, max: Double) {
        switch self {
        case .breathe, .float: return (0, 1)
        case .sway, .bounce, .flutter: return (-1, 1)
        }
    }

    /// 1 回の動きのキー（0..<1 の位置、値、次のキーまでの動き方）。最後のキーから次の回の最初のキーへつながる
    var cycle: [(phase: Double, value: Double, easing: Easing)] {
        switch self {
        case .breathe, .float: return [(0, 0, .easeInOut), (0.5, 1, .easeInOut)]
        case .sway, .flutter: return [(0, -1, .easeInOut), (0.5, 1, .easeInOut)]
        // 止まった所から縮み、跳んで（上で遅く）、落ちて縮み、戻る
        case .bounce: return [(0, 0, .easeIn), (0.15, -1, .easeOut), (0.5, 1, .easeIn), (0.85, -1, .easeOut)]
        }
    }

    /// パラメータの値ごとの形（b は描かれている範囲）。ワープは 2×2 マスの格子
    func forms(_ b: RigRect) -> [(value: Double, form: DeformerForm)] {
        let w = b.width, h = b.height
        // 格子の点ごとのずれ（u は左 0〜右 1、v は上 0〜下 1）
        func warp(_ f: (_ u: Double, _ v: Double) -> RigPoint) -> [RigPoint] {
            (0..<9).map { f(Double($0 % 3) / 2, Double($0 / 3) / 2) }
        }
        switch self {
        case .breathe:
            return [(1, DeformerForm(offsets: warp { _, v in RigPoint(0, -(1 - v) * h * 0.025) }))]
        case .sway:
            return [(-1, DeformerForm(angle: -2.5)), (1, DeformerForm(angle: 2.5))]
        case .float:
            return [(1, DeformerForm(move: RigPoint(0, -max(h * 0.04, 2))))]
        case .bounce:
            let squash = warp { u, v in RigPoint((u - 0.5) * w * 0.08, (1 - v) * h * 0.08) }
            let stretch = warp { u, v in RigPoint(-(u - 0.5) * w * 0.05, -(1 - v) * h * 0.05) }
            return [(-1, DeformerForm(offsets: squash)), (1, DeformerForm(move: RigPoint(0, -h * 0.1), offsets: stretch))]
        case .flutter:
            func lean(_ k: Double) -> [RigPoint] { warp { _, v in RigPoint(k * (1 - v) * (1 - v) * w * 0.05, 0) } }
            return [(-1, DeformerForm(offsets: lean(-1))), (1, DeformerForm(offsets: lean(1)))]
        }
    }
}

extension Editor {
    /// レイヤー（フォルダー）におまかせの動きを付け、タイムラインでくり返す（取り消しは 1 回で戻る）。
    /// タイムラインが空なら 24fps で動き 1 回分の長さにし、そうでなければ今の長さにちょうど収まる回数でくり返す。
    /// 描かれていなければ nil。作ったパラメータの ID を返す
    @discardableResult
    public func addMotion(_ preset: MotionPreset, to id: UUID) -> String? {
        guard let n = doc.node(id), let bounds = Self.contentBounds(n) else { return nil }
        commitTransform()
        checkpoint("\(preset.displayName)の動きを付ける")
        doc.assignPSDIDs()
        let psdID = doc.node(id)!.psdID
        let b = RigRect(x: Double(bounds.x), y: Double(bounds.y), width: Double(bounds.width), height: Double(bounds.height))

        var d = Deformer(id: Self.newID("d", existing: doc.rig.deformers.map(\.id)),
                         name: "\(n.name)の\(preset.displayName)", layer: psdID, kind: preset.deformerKind)
        d.rect = b
        d.cols = 2
        d.rows = 2
        // 傾きは足元を軸にする
        d.pivot = RigPoint(b.x + b.width / 2, preset == .sway ? b.y + b.height : b.y + b.height / 2)
        var p = RigParameter(id: Self.newID("p", existing: doc.rig.parameters.map(\.id)), name: d.name,
                             min: preset.range.min, max: preset.range.max)
        p.keys = preset.forms(b).map { RigParameterKey(value: $0.value, forms: [d.id: $0.form]) }
        doc.rig.deformers.append(d)
        doc.rig.parameters.append(p)

        if doc.timeline.isEmpty {
            doc.timeline.fps = 24
            doc.timeline.frameCount = Int((preset.period * 24).rounded())
            doc.timeline.loop = true
        }
        let t = doc.timeline
        let cycles = max(1, Int((Double(t.frameCount) / (preset.period * Double(t.fps))).rounded()))
        var track = ParameterTrack(parameter: p.id)
        for c in 0..<cycles {
            for k in preset.cycle {
                let f = Int(((Double(c) + k.phase) * Double(t.frameCount) / Double(cycles)).rounded())
                track.set(frame: f, value: k.value, easing: k.easing)
            }
        }
        // 最後のコマの次（= 次の回の 0 コマ目）に最初のキーを置いて、ループの継ぎ目をなめらかにする
        track.set(frame: t.frameCount, value: preset.cycle[0].value)
        doc.timeline.parameterTracks.append(track)
        revision += 1
        applyFrame()
        markAllDirty()
        return p.id
    }
}
