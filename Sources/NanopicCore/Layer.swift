import Foundation

public enum BlendMode: String, CaseIterable, Codable, Sendable {
    case passThrough
    case normal
    case darken, multiply, colorBurn, linearBurn, subtract, darkerColor
    case lighten, screen, colorDodge, linearDodge, lighterColor
    case overlay, softLight, hardLight, vividLight, linearLight, pinLight, hardMix
    case difference, exclusion, divide
    case hue, saturation, color, luminosity
    case dissolve

    public var displayName: String {
        switch self {
        case .passThrough: return "通過"
        case .normal: return "通常"
        case .darken: return "比較(暗)"
        case .multiply: return "乗算"
        case .colorBurn: return "焼き込みカラー"
        case .linearBurn: return "焼き込み(リニア)"
        case .subtract: return "減算"
        case .darkerColor: return "カラー比較(暗)"
        case .lighten: return "比較(明)"
        case .screen: return "スクリーン"
        case .colorDodge: return "覆い焼きカラー"
        case .linearDodge: return "加算"
        case .lighterColor: return "カラー比較(明)"
        case .overlay: return "オーバーレイ"
        case .softLight: return "ソフトライト"
        case .hardLight: return "ハードライト"
        case .vividLight: return "ビビッドライト"
        case .linearLight: return "リニアライト"
        case .pinLight: return "ピンライト"
        case .hardMix: return "ハードミックス"
        case .difference: return "差の絶対値"
        case .exclusion: return "除外"
        case .divide: return "除算"
        case .hue: return "色相"
        case .saturation: return "彩度"
        case .color: return "カラー"
        case .luminosity: return "輝度"
        case .dissolve: return "ディザ合成"
        }
    }

    /// PSD のブレンドモードキー（4文字）
    public var psdKey: String {
        switch self {
        case .passThrough: return "pass"
        case .normal: return "norm"
        case .dissolve: return "diss"
        case .darken: return "dark"
        case .multiply: return "mul "
        case .colorBurn: return "idiv"
        case .linearBurn: return "lbrn"
        case .darkerColor: return "dkCl"
        case .lighten: return "lite"
        case .screen: return "scrn"
        case .colorDodge: return "div "
        case .linearDodge: return "lddg"
        case .lighterColor: return "lgCl"
        case .overlay: return "over"
        case .softLight: return "sLit"
        case .hardLight: return "hLit"
        case .vividLight: return "vLit"
        case .linearLight: return "lLit"
        case .pinLight: return "pLit"
        case .hardMix: return "hMix"
        case .difference: return "diff"
        case .exclusion: return "smud"
        case .subtract: return "fsub"
        case .divide: return "fdiv"
        case .hue: return "hue "
        case .saturation: return "sat "
        case .color: return "colr"
        case .luminosity: return "lum "
        }
    }

    public init?(psdKey: String) {
        guard let m = BlendMode.allCases.first(where: { $0.psdKey == psdKey }) else { return nil }
        self = m
    }

    /// UI のメニュー用グループ
    public static let menuGroups: [[BlendMode]] = [
        [.normal],
        [.darken, .multiply, .colorBurn, .linearBurn, .subtract, .darkerColor],
        [.lighten, .screen, .colorDodge, .linearDodge, .lighterColor],
        [.overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix],
        [.difference, .exclusion, .divide],
        [.hue, .saturation, .color, .luminosity],
        [.dissolve],
    ]
}

public enum LayerKind: String, Codable, Sendable {
    case raster
    case folder
}

/// レイヤーツリーのノード（値型。Undo はドキュメント全体のスナップショットで行う）
public struct LayerNode: Identifiable {
    public var id: UUID
    public var name: String
    public var kind: LayerKind
    public var visible: Bool = true
    public var opacity: Float = 1
    public var blendMode: BlendMode
    public var clipping: Bool = false
    public var lockAlpha: Bool = false
    public var isReference: Bool = false
    public var locked: Bool = false
    public var expanded: Bool = true
    public var tiles = TileMap()
    public var children: [LayerNode] = []   // 下から上の順
    /// 内容が変更されるたびに増える（サムネイル更新用）
    public var contentVersion: Int = 0
    /// PSD のレイヤー ID（lyid）。開き直しても変わらないので、サイドカーはこれでレイヤーを指す。0 は未割り当て
    public var psdID: UInt32 = 0
    /// スイッチフォルダー（子を常に 1 つだけ表示する）。フォルダーのときだけ意味がある
    public var isSwitch = false

    public init(id: UUID = UUID(), name: String, kind: LayerKind = .raster) {
        self.id = id
        self.name = name
        self.kind = kind
        self.blendMode = kind == .folder ? .passThrough : .normal
    }

    public var isFolder: Bool { kind == .folder }
}

/// ドキュメントの状態。layers は下から上の順。
public struct DocumentState {
    public var width: Int
    public var height: Int
    public var dpi: Double = 350
    public var layers: [LayerNode] = []
    public var selection: SelectionMask?
    /// タイムライン（取り消しに乗るよう、ドキュメントに持つ）
    public var timeline = Timeline()
    /// デフォーマとパラメータ
    public var rig = Rig()
    /// 書き出しの設定（範囲、大きさ、形式、書き出し先）
    public var publish: PublishSettings?
    public var activeLayerID: UUID?

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var bounds: IntRect { IntRect(x: 0, y: 0, width: width, height: height) }

    // MARK: - ツリー操作

    /// id のノードまでのインデックスパス
    public func indexPath(of id: UUID) -> [Int]? {
        func search(_ nodes: [LayerNode], _ prefix: [Int]) -> [Int]? {
            for (i, n) in nodes.enumerated() {
                if n.id == id { return prefix + [i] }
                if n.isFolder, let p = search(n.children, prefix + [i]) { return p }
            }
            return nil
        }
        return search(layers, [])
    }

    public func node(_ id: UUID?) -> LayerNode? {
        guard let id, let path = indexPath(of: id) else { return nil }
        return node(at: path)
    }

    public func node(at path: [Int]) -> LayerNode? {
        var list = layers
        var result: LayerNode?
        for i in path {
            guard i >= 0, i < list.count else { return nil }
            result = list[i]
            list = list[i].children
        }
        return result
    }

    public var activeLayer: LayerNode? { node(activeLayerID) }

    /// 兄弟リスト（パスの親）を書き換える
    public mutating func modifySiblings(parentPath: [Int], _ body: (inout [LayerNode]) -> Void) {
        func rec(_ list: inout [LayerNode], _ path: ArraySlice<Int>) {
            if path.isEmpty {
                body(&list)
                return
            }
            let i = path.first!
            rec(&list[i].children, path.dropFirst())
        }
        rec(&layers, parentPath[...])
    }

    @discardableResult
    public mutating func modify(_ id: UUID, _ body: (inout LayerNode) -> Void) -> Bool {
        guard let path = indexPath(of: id) else { return false }
        modifySiblings(parentPath: Array(path.dropLast())) { list in
            body(&list[path.last!])
        }
        return true
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> LayerNode? {
        guard let path = indexPath(of: id) else { return nil }
        var removed: LayerNode?
        modifySiblings(parentPath: Array(path.dropLast())) { list in
            removed = list.remove(at: path.last!)
        }
        return removed
    }

    /// parentPath のリストの index へ挿入
    public mutating func insert(_ node: LayerNode, parentPath: [Int], index: Int) {
        modifySiblings(parentPath: parentPath) { list in
            list.insert(node, at: min(max(0, index), list.count))
        }
    }

    /// 上から順（UI 表示順）に、折りたたみを考慮して平坦化
    public func flattenedForDisplay() -> [(node: LayerNode, depth: Int)] {
        var out: [(LayerNode, Int)] = []
        func rec(_ nodes: [LayerNode], _ depth: Int) {
            for n in nodes.reversed() {
                out.append((n, depth))
                if n.isFolder && n.expanded { rec(n.children, depth + 1) }
            }
        }
        rec(layers, 0)
        return out
    }

    /// すべてのノードを走査
    public func forEachNode(_ body: (LayerNode) -> Void) {
        func rec(_ nodes: [LayerNode]) {
            for n in nodes {
                body(n)
                if n.isFolder { rec(n.children) }
            }
        }
        rec(layers)
    }

    /// 祖先を含めて表示されているか
    /// PSD のレイヤー ID がないレイヤーと、複製で重なったレイヤーに新しい ID を振る（下から順に見て、先にあったほうを残す）
    public mutating func assignPSDIDs() {
        var used = Set<UInt32>()
        var next = UInt32(1)
        forEachNode { if $0.psdID != 0 { next = max(next, $0.psdID &+ 1) } }
        func walk(_ nodes: inout [LayerNode]) {
            for i in nodes.indices {
                if nodes[i].psdID == 0 || used.contains(nodes[i].psdID) {
                    nodes[i].psdID = next
                    next &+= 1
                }
                used.insert(nodes[i].psdID)
                walk(&nodes[i].children)
            }
        }
        walk(&layers)
    }

    /// PSD のレイヤー ID からレイヤーを探す
    public func node(psdID: UInt32) -> LayerNode? {
        guard psdID != 0 else { return nil }
        var found: LayerNode?
        forEachNode { if found == nil && $0.psdID == psdID { found = $0 } }
        return found
    }

    public func isEffectivelyVisible(_ id: UUID) -> Bool {
        guard let path = indexPath(of: id) else { return false }
        for k in 1...path.count {
            if let n = node(at: Array(path.prefix(k))), !n.visible { return false }
        }
        return true
    }
}
