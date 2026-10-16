import Foundation

/// パラメータ・デフォーマ・レイヤーのつながり。リグの画面で、どれかを指したときに関係するものを光らせるのに使う
public enum RigLinkTarget: Hashable, Sendable {
    case parameter(String)
    case deformer(String)
    case layer(UUID)
}

/// 指したものと関係するもの一式
public struct RigFocus: Equatable, Sendable {
    public var parameters: Set<String> = []
    public var deformers: Set<String> = []
    /// デフォーマが付いているレイヤー（フォルダー）
    public var layers: Set<UUID> = []
    /// 付いているレイヤーの中にあって、一緒に動くレイヤー（付いているレイヤー自身は含まない）
    public var affectedLayers: Set<UUID> = []

    public init() {}

    public var isEmpty: Bool { parameters.isEmpty && deformers.isEmpty && layers.isEmpty }
}

extension Rig {
    /// パラメータが形を決めているデフォーマ（どれかのキーでずれがあるもの）。付けた順
    public func deformers(drivenBy parameter: String) -> [Deformer] {
        guard let p = self.parameter(parameter) else { return [] }
        let ids = Set(p.keys.flatMap { k in k.forms.filter { !$0.value.isZero }.map(\.key) })
        return deformers.filter { ids.contains($0.id) }
    }

    /// デフォーマの形を決めているパラメータ。並びはパラメータの順
    public func parameters(driving deformer: String) -> [RigParameter] {
        parameters.filter { p in p.keys.contains { !($0.forms[deformer]?.isZero ?? true) } }
    }
}

extension DocumentState {
    /// レイヤーにかかるデフォーマ（自分のものから、親フォルダーのものへ）
    public func deformerChain(of id: UUID) -> [Deformer] {
        guard let path = indexPath(of: id) else { return [] }
        var out: [Deformer] = []
        for depth in stride(from: path.count, through: 1, by: -1) {
            guard let n = node(at: Array(path.prefix(depth))), n.psdID != 0 else { continue }
            out += rig.deformers.filter { $0.layer == n.psdID }
        }
        return out
    }

    /// target と関係するパラメータ・デフォーマ・レイヤー
    public func rigFocus(_ target: RigLinkTarget) -> RigFocus {
        var f = RigFocus()
        let ds: [Deformer]
        switch target {
        case let .parameter(pid):
            guard rig.parameter(pid) != nil else { return f }
            f.parameters = [pid]
            ds = rig.deformers(drivenBy: pid)
        case let .deformer(did):
            guard let d = rig.deformer(did) else { return f }
            ds = [d]
            f.parameters = Set(rig.parameters(driving: did).map(\.id))
        case let .layer(id):
            guard node(id) != nil else { return f }
            ds = deformerChain(of: id)
            f.parameters = Set(ds.flatMap { rig.parameters(driving: $0.id).map(\.id) })
        }
        f.deformers = Set(ds.map(\.id))
        for d in ds {
            guard let n = node(psdID: d.layer) else { continue }
            f.layers.insert(n.id)
            func walk(_ c: LayerNode) {
                f.affectedLayers.insert(c.id)
                c.children.forEach(walk)
            }
            n.children.forEach(walk)
        }
        f.affectedLayers.subtract(f.layers)
        return f
    }
}

extension DocumentState {
    /// レイヤー（フォルダーなら中身全部）の描かれている範囲を、forms の形で写した輪郭（画面に見えている位置）。描かれていなければ nil
    public func posedOutline(of id: UUID, forms: [String: DeformerForm]) -> [RigPoint]? {
        guard let n = node(id), let b = Editor.contentBounds(n) else { return nil }
        let chain = deformerChain(of: id)
        // ワープで辺が曲がるので、辺を細かく区切ってから写す
        let steps = 8
        let x0 = Double(b.minX), y0 = Double(b.minY), x1 = Double(b.minX + b.width), y1 = Double(b.minY + b.height)
        var pts: [RigPoint] = []
        for i in 0..<steps { pts.append(RigPoint(x0 + (x1 - x0) * Double(i) / Double(steps), y0)) }
        for i in 0..<steps { pts.append(RigPoint(x1, y0 + (y1 - y0) * Double(i) / Double(steps))) }
        for i in 0..<steps { pts.append(RigPoint(x1 - (x1 - x0) * Double(i) / Double(steps), y1)) }
        for i in 0..<steps { pts.append(RigPoint(x0, y1 - (y1 - y0) * Double(i) / Double(steps))) }
        return pts.map { p in chain.reduce(p) { q, d in d.map(q, forms[d.id] ?? DeformerForm()) } }
    }
}
