import CoreGraphics
import Foundation

/// エージェント（MCP）から呼ぶ操作。入出力は JSON 互換の値（[String: Any] など）
public struct AgentError: Error, CustomStringConvertible {
    public var description: String
    public init(_ message: String) { description = message }
}

public enum AgentContent {
    case text(String)
    case png(Data)
}

public struct AgentTool {
    public var name: String
    public var description: String
    public var inputSchema: [String: Any]
    public var handler: (AgentArgs) throws -> [AgentContent]

    public init(name: String, description: String, properties: [String: Any] = [:], required: [String] = [],
                handler: @escaping (AgentArgs) throws -> [AgentContent]) {
        self.name = name
        self.description = description
        self.inputSchema = ["type": "object", "properties": properties, "required": required]
        self.handler = handler
    }
}

/// 引数の取り出し（型が違えばエラーにする）
public struct AgentArgs {
    public let raw: [String: Any]
    public init(_ raw: [String: Any]) { self.raw = raw }

    public func has(_ k: String) -> Bool { raw[k] != nil && !(raw[k] is NSNull) }

    public func double(_ k: String) throws -> Double? {
        guard has(k) else { return nil }
        if let v = raw[k] as? NSNumber { return v.doubleValue }
        if let s = raw[k] as? String, let v = Double(s) { return v }
        throw AgentError("\(k) は数値で指定してください")
    }
    public func double(_ k: String, default d: Double) throws -> Double { try double(k) ?? d }
    public func int(_ k: String) throws -> Int? { try double(k).map { Int($0.rounded()) } }
    public func int(_ k: String, default d: Int) throws -> Int { try int(k) ?? d }
    public func requireInt(_ k: String) throws -> Int {
        guard let v = try int(k) else { throw AgentError("\(k) を指定してください") }
        return v
    }
    public func bool(_ k: String) throws -> Bool? {
        guard has(k) else { return nil }
        if let v = raw[k] as? Bool { return v }
        if let v = raw[k] as? NSNumber { return v.boolValue }
        throw AgentError("\(k) は true / false で指定してください")
    }
    public func string(_ k: String) throws -> String? {
        guard has(k) else { return nil }
        if let v = raw[k] as? String { return v }
        throw AgentError("\(k) は文字列で指定してください")
    }
    public func requireString(_ k: String) throws -> String {
        guard let v = try string(k) else { throw AgentError("\(k) を指定してください") }
        return v
    }
    public func color(_ k: String) throws -> SIMD3<Float>? {
        guard let s = try string(k) else { return nil }
        guard let c = AgentToolbox.parseColor(s) else { throw AgentError("\(k) は \"#RRGGBB\" の形で指定してください: \(s)") }
        return c
    }
    public func uuid(_ k: String) throws -> UUID? {
        guard let s = try string(k) else { return nil }
        guard let id = UUID(uuidString: s) else { throw AgentError("\(k) が ID の形になっていません: \(s)") }
        return id
    }
    /// [[x, y], ...] または [[x, y, 筆圧], ...] / [{"x":, "y":, "pressure":}, ...]
    public func points(_ k: String) throws -> [(x: Double, y: Double, p: Double?)] {
        guard let arr = raw[k] as? [Any] else { throw AgentError("\(k) を点の配列で指定してください") }
        return try arr.map { v in
            if let a = v as? [NSNumber], a.count >= 2 {
                return (a[0].doubleValue, a[1].doubleValue, a.count >= 3 ? a[2].doubleValue : nil)
            }
            if let o = v as? [String: Any], let x = o["x"] as? NSNumber, let y = o["y"] as? NSNumber {
                return (x.doubleValue, y.doubleValue, (o["pressure"] as? NSNumber)?.doubleValue)
            }
            throw AgentError("\(k) の点は [x, y] か [x, y, 筆圧] で指定してください")
        }
    }
    public func rect(_ k: String) throws -> IntRect? {
        guard has(k) else { return nil }
        guard let o = raw[k] as? [String: Any] else { throw AgentError("\(k) は {x, y, width, height} で指定してください") }
        let a = AgentArgs(o)
        return IntRect(x: try a.requireInt("x"), y: try a.requireInt("y"), width: try a.requireInt("width"), height: try a.requireInt("height"))
    }
}

/// エディターを操作するツールの一式
public final class AgentToolbox {
    public let editor: Editor
    /// アプリ側で足すツール（ファイルの読み書きなど）
    public var extraTools: [AgentTool] = []
    /// 直前の find_regions の結果
    public private(set) var regionMap: RegionMap?
    /// 直前の find_regions で線として見たもの（fill_leftovers の既定）
    private var lastReference: [String]?

    public init(editor: Editor) {
        self.editor = editor
    }

    public var tools: [AgentTool] { coreTools + moreTools + extraTools }

    public func call(_ name: String, _ args: [String: Any]) throws -> [AgentContent] {
        guard let tool = tools.first(where: { $0.name == name }) else { throw AgentError("知らないツールです: \(name)") }
        return try tool.handler(AgentArgs(args))
    }

    public static let instructions = """
    nanopic はラスターのペイントアプリです。ユーザーが開いているキャンバスを直接操作します（画面に反映され、ユーザーは ⌘Z で取り消せます）。

    座標はドキュメントの画素（左上が原点、x は右、y は下）。色は "#RRGGBB"。レイヤーは ID（UUID）で指定し、get_document で一覧できます。
    一覧は表示と同じ上から下の順です。

    よい進め方:
    1. get_document で大きさとレイヤー構成を、get_image（grid: true で座標の目盛り）で見た目を確かめる。
    2. 描く・塗る前に、どのレイヤーに入れるか決める。線画の下に色を置くなら add_layer で塗り用のレイヤーを作り、move_layer で線画の下へ。
    3. 操作のあとは get_image で結果を見て確かめ、直す。
    4. 線を何本も描く、いくつもの点を塗るなど、操作が続くときは batch でまとめて送ると早い。

    下塗り（線画で囲まれた範囲を色で塗り分ける）:
    1. find_regions を線画のレイヤー（reference: 線画のレイヤー ID）で呼ぶ。線で閉じた範囲が番号つきで返り、番号を描き込んだ画像も返る。
       線が少し途切れて隣とつながっている場合は gap_close を 2〜4 にする。背景は touches_edge が true で面積が大きい。
       線が大きく開いていて、塗り分けたい範囲が隣や背景とつながっているときは、新しいレイヤー（例: 閉じ線）に stroke で
       開いた所を閉じる線を描き（curve: true で点を通る滑らかな線になる。非表示のレイヤーにも layer_id を指定すれば描ける）、
       そのレイヤーを非表示にして、reference に [線画の ID, 閉じ線の ID] を渡して find_regions をやり直す。
       多角形を手で合わせるより正確で早い。
    2. 画像と元の絵を見比べ、各番号が何（肌、髪、服…）かを判断して、色を決める。
    3. fill_regions で番号と色をまとめて渡す（線の下まで少し広げて塗るので隙間が残らない）。
       パーツ（髪・肌・服…）ごとにレイヤーを分けるなら、各 fill に name をつけて separate_layers: true にする（線画の下のフォルダーにパーツごとのレイヤーができる）。
    4. 最後に fill_leftovers で細かい塗り残しをまとめて埋める。
       get_image で確かめ、色違いは同じ番号を塗り直して直す。
       fill の起点は線の上ではなく、塗りたい範囲の内側にする（線の上から塗ると、つながった線全体が塗られる）。
    """

    // MARK: - ツールの定義

    private var coreTools: [AgentTool] {
        let layerID: [String: Any] = ["type": "string", "description": "対象のレイヤー ID。省略すると編集中のレイヤー"]
        let color: [String: Any] = ["type": "string", "description": "\"#RRGGBB\"。省略すると現在の描画色"]
        let points: [String: Any] = ["type": "array", "items": ["type": "array", "items": ["type": "number"]]]
        let rect: [String: Any] = ["type": "object", "properties": ["x": ["type": "integer"], "y": ["type": "integer"],
                                                                    "width": ["type": "integer"], "height": ["type": "integer"]]]
        return [
            AgentTool(name: "get_document",
                      description: "ドキュメントの大きさ、レイヤーの一覧（上から順、ID・名前・合成モード・不透明度・描かれている範囲など）、編集中のレイヤー、選択範囲、描画色、選択中のブラシを返す。") { [unowned self] _ in
                [.text(json(documentInfo()))]
            },
            AgentTool(name: "get_image",
                      description: "キャンバスの見た目を PNG で返す。layer_id を渡すとそのレイヤーだけ（白背景）。region で一部を拡大して見られる。grid: true で座標の目盛りを重ねる。",
                      properties: ["layer_id": ["type": "string", "description": "このレイヤーだけを描く"],
                                   "region": rect.merging(["description": "見る範囲（ドキュメント座標）。省略すると全体"]) { a, _ in a },
                                   "max_size": ["type": "integer", "description": "画像の長辺の最大 px（既定 1024）"],
                                   "grid": ["type": "boolean", "description": "座標の目盛りを重ねる"]]) { [unowned self] a in
                try getImage(a)
            },
            AgentTool(name: "find_regions",
                      description: "線画で囲まれた範囲を探して番号をつける（下塗り用）。番号・面積・範囲・内側の点・今の色を一覧で、番号を描き込んだ画像と一緒に返す。結果は fill_regions と select で使える。",
                      properties: ["reference": ["description": "線として見るもの: 線画のレイヤー ID か ID の配列（線画＋閉じ線のレイヤーなど。非表示でもよい）、\"all\"（見えている全体、既定）、\"reference_layers\"（参照レイヤー）"],
                                   "line_threshold": ["type": "number", "description": "白背景に重ねた暗さがこれ以上を線とみなす 0〜1（既定 0.5）"],
                                   "gap_close": ["type": "integer", "description": "この px までの線の途切れを閉じて扱う（既定 0）"],
                                   "min_area": ["type": "integer", "description": "これより小さい範囲は除く（px、既定 30）"],
                                   "max_regions": ["type": "integer", "description": "一覧に載せる最大数（大きい順、既定 300）"],
                                   "list_min_area": ["type": "integer", "description": "これより小さい範囲は一覧に載せず数だけ返す（px、既定 150）"],
                                   "max_size": ["type": "integer", "description": "画像の長辺の最大 px（既定 1024）"]]) { [unowned self] a in
                try findRegions(a)
            },
            AgentTool(name: "fill_regions",
                      description: "find_regions の番号の範囲を色で塗る。複数をまとめて渡せる（取り消しは 1 回分）。線の下まで expand px 広げて塗るが、隣の範囲にははみ出さない。",
                      properties: ["fills": ["type": "array", "description": "[{\"region\": 番号, \"color\": \"#RRGGBB\", \"name\": \"髪\"}, ...]。name はパーツ名（separate_layers のときのレイヤー名）",
                                             "items": ["type": "object", "properties": ["region": ["type": "integer"], "color": ["type": "string"], "name": ["type": "string"]],
                                                       "required": ["region", "color"]]],
                                   "layer_id": layerID,
                                   "separate_layers": ["type": "boolean", "description": "name（なければ色）ごとにレイヤーを分けて塗る。レイヤーはフォルダーにまとめ、線画の下に作る（同じ name のレイヤーがあればそこに足す）"],
                                   "folder": ["type": "string", "description": "separate_layers のフォルダー名（既定「下塗り」）"],
                                   "below": ["type": "string", "description": "separate_layers のフォルダーをこのレイヤーの下に作る（既定は find_regions の線画）"],
                                   "expand": ["type": "integer", "description": "線の下へ広げる px（既定 2）"]],
                      required: ["fills"]) { [unowned self] a in
                try fillRegions(a)
            },
            AgentTool(name: "fill_leftovers",
                      description: "下塗りの塗り残し（線画で囲まれた、まだ塗っていない小さなすき間）を探し、接している色で塗る。fill_regions や lasso_fill のあとの仕上げに。dry_run: true なら塗らずに場所だけ返す。",
                      properties: ["layer_id": ["type": "string", "description": "下塗りのレイヤー、またはパーツごとのレイヤーを入れたフォルダー。省略すると編集中のレイヤー"],
                                   "reference": ["description": "線画のレイヤー ID か ID の配列。省略すると直前の find_regions と同じ"],
                                   "max_area": ["type": "integer", "description": "これより大きいすき間は塗らない（px、既定 400）"],
                                   "expand": ["type": "integer", "description": "線の下へ広げる px（既定 2）"],
                                   "line_threshold": ["type": "number"], "dry_run": ["type": "boolean"]]) { [unowned self] a in
                try fillLeftovers(a)
            },
            AgentTool(name: "fill",
                      description: "塗りつぶし（バケツ）。点 (x, y) から色の近い範囲を塗る。",
                      properties: ["x": ["type": "number"], "y": ["type": "number"], "color": color, "layer_id": layerID,
                                   "reference": ["type": "string", "description": "\"all\"（既定）、\"layer\"（塗るレイヤーだけ）、\"reference_layers\""],
                                   "tolerance": ["type": "number", "description": "色の許容誤差 0〜1（既定はアプリの設定）"],
                                   "gap_close": ["type": "integer"], "expand": ["type": "integer"]],
                      required: ["x", "y"]) { [unowned self] a in
                try fill(a)
            },
            AgentTool(name: "lasso_fill",
                      description: "点を結んだ多角形の内側を塗る（erase: true なら消す）。",
                      properties: ["points": points.merging(["description": "[[x, y], ...]"]) { a, _ in a },
                                   "color": color, "erase": ["type": "boolean"], "layer_id": layerID,
                                   "antialias": ["type": "boolean", "description": "既定 true"]],
                      required: ["points"]) { [unowned self] a in
                try lassoFill(a)
            },
            AgentTool(name: "stroke",
                      description: "ブラシで線を描く。点は [x, y] か [x, y, 筆圧 0〜1]。点の間は滑らかにつなぐ。筆圧を渡すとブラシの筆圧設定が効く。",
                      properties: ["points": points, "brush": ["type": "string", "description": "ブラシの名前か ID（list_brushes）。省略すると選択中のブラシ"],
                                   "size": ["type": "number", "description": "直径 px（このストロークだけ）"],
                                   "opacity": ["type": "number", "description": "不透明度 0〜1（このストロークだけ）"],
                                   "curve": ["type": "boolean", "description": "点を滑らかな曲線（点を通る曲線）でつなぐ。少ない点で自然な線が引ける"],
                                   "settings": ["type": "object", "description": "ブラシ設定の上書き（このストロークだけ）。項目は list_brushes の detail: true で見られる（hardness, flow, spacing, smoothing など）"],
                                   "color": ["type": "string", "description": "\"#RRGGBB\"（このストロークだけ）。省略すると現在の描画色"], "erase": ["type": "boolean", "description": "消しゴムで描く"], "layer_id": layerID],
                      required: ["points"]) { [unowned self] a in
                try stroke(a)
            },
            AgentTool(name: "list_brushes", description: "ブラシと消しゴムの一覧（ID・名前・大きさ）。detail: true ですべての設定項目も返す。",
                      properties: ["detail": ["type": "boolean"]]) { [unowned self] a in
                let detail = try a.bool("detail") ?? false
                func info(_ b: BrushSettings) -> [String: Any] {
                    detail ? Self.settingsJSON(b) : ["id": b.id.uuidString, "name": b.name, "size": Double(b.size), "opacity": Double(b.opacity)]
                }
                return [.text(json(["brushes": editor.brushes.map(info), "erasers": editor.erasers.map(info)]))]
            },
            AgentTool(name: "select",
                      description: "選択範囲を作る。選択範囲があると、塗る・描く・消す操作はその中だけに効く。",
                      properties: ["shape": ["type": "string", "enum": ["rect", "ellipse", "polygon", "regions", "wand", "layer", "all", "none", "invert"],
                                             "description": "wand: 点 (x, y) から色の近い範囲（自動選択）。layer: layer_id のレイヤーの描かれている部分"],
                                   "x": ["type": "integer"], "y": ["type": "integer"],
                                   "tolerance": ["type": "number", "description": "wand の色の許容誤差 0〜1"],
                                   "reference": ["type": "string", "description": "wand が見るもの: \"all\"（既定）、\"layer\"（編集中のレイヤー）、\"reference_layers\""],
                                   "layer_id": ["type": "string", "description": "layer で使うレイヤー"],
                                   "rect": rect.merging(["description": "rect / ellipse の範囲"]) { a, _ in a },
                                   "points": points.merging(["description": "polygon の頂点"]) { a, _ in a },
                                   "regions": ["type": "array", "items": ["type": "integer"], "description": "find_regions の番号"],
                                   "op": ["type": "string", "enum": ["replace", "add", "subtract", "intersect"], "description": "既定 replace"]],
                      required: ["shape"]) { [unowned self] a in
                try select(a)
            },
            AgentTool(name: "clear", description: "選択範囲の中（なければレイヤー全体）を消去する。",
                      properties: ["layer_id": layerID]) { [unowned self] a in
                try useLayer(a, paint: true)
                editor.clearSelectionContent()
                return [.text("消去しました")]
            },
            AgentTool(name: "pick_color", description: "点の色を返す（layer_only: true なら編集中のレイヤーだけを見る）。",
                      properties: ["x": ["type": "integer"], "y": ["type": "integer"], "layer_only": ["type": "boolean"]],
                      required: ["x", "y"]) { [unowned self] a in
                let c = editor.pickColor(x: try a.requireInt("x"), y: try a.requireInt("y"), currentLayerOnly: try a.bool("layer_only") ?? false)
                return [.text(json(["color": c.map(Self.hex) as Any? ?? NSNull()]))]
            },
            AgentTool(name: "add_layer",
                      description: "新しいレイヤー（folder: true ならフォルダー）を編集中のレイヤーの上に作り、編集中にする。below / above に ID を渡すとそのレイヤーの下・上に置く。",
                      properties: ["name": ["type": "string"], "folder": ["type": "boolean"],
                                   "below": ["type": "string", "description": "このレイヤーのすぐ下に置く"],
                                   "above": ["type": "string", "description": "このレイヤーのすぐ上に置く"]]) { [unowned self] a in
                try addLayer(a)
            },
            AgentTool(name: "update_layer",
                      description: "レイヤーの設定を変える（指定した項目だけ）。",
                      properties: ["layer_id": ["type": "string"], "name": ["type": "string"], "visible": ["type": "boolean"],
                                   "opacity": ["type": "number", "description": "0〜1"],
                                   "blend_mode": ["type": "string", "enum": BlendMode.allCases.map(\.rawValue)],
                                   "clipping": ["type": "boolean"], "lock_alpha": ["type": "boolean", "description": "透明ピクセルをロック"],
                                   "locked": ["type": "boolean"], "reference": ["type": "boolean", "description": "参照レイヤー"]],
                      required: ["layer_id"]) { [unowned self] a in
                try updateLayer(a)
            },
            AgentTool(name: "set_active_layer", description: "編集するレイヤーを選ぶ。",
                      properties: ["layer_id": ["type": "string"]], required: ["layer_id"]) { [unowned self] a in
                try useLayer(a, paint: false)
                return [.text("編集レイヤー: \(editor.doc.activeLayer?.name ?? "")")]
            },
            AgentTool(name: "move_layer", description: "レイヤーを target の上（above）・下（below）・フォルダーの中（into）へ動かす。",
                      properties: ["layer_id": ["type": "string"], "target": ["type": "string"],
                                   "placement": ["type": "string", "enum": ["above", "below", "into"]]],
                      required: ["layer_id", "target", "placement"]) { [unowned self] a in
                let id = try layer(a, "layer_id"), target = try layer(a, "target")
                let placement: Editor.DropPlacement
                switch try a.requireString("placement") {
                case "above": placement = .above
                case "below": placement = .below
                case "into": placement = .into
                default: throw AgentError("placement は above / below / into のどれか")
                }
                editor.moveLayer(id, relativeTo: target, placement: placement)
                return [.text("動かしました")]
            },
            AgentTool(name: "duplicate_layer", description: "レイヤーを複製する。", properties: ["layer_id": layerID]) { [unowned self] a in
                try useLayer(a, paint: false)
                editor.duplicateActiveLayer()
                return [.text(json(["layer_id": editor.activeLayerID?.uuidString ?? ""]))]
            },
            AgentTool(name: "merge_down", description: "レイヤーを下のレイヤーに結合する。", properties: ["layer_id": layerID]) { [unowned self] a in
                try useLayer(a, paint: false)
                editor.mergeDown()
                return [.text("結合しました")]
            },
            AgentTool(name: "delete_layer", description: "レイヤーを削除する。", properties: ["layer_id": ["type": "string"]],
                      required: ["layer_id"]) { [unowned self] a in
                try useLayer(a, paint: false)
                editor.deleteSelectedLayers()
                return [.text("削除しました")]
            },
            AgentTool(name: "undo", description: "取り消す。", properties: ["steps": ["type": "integer", "description": "既定 1"]]) { [unowned self] a in
                for _ in 0..<max(1, try a.int("steps", default: 1)) { editor.undo() }
                return [.text("取り消しました")]
            },
            AgentTool(name: "redo", description: "やり直す。", properties: ["steps": ["type": "integer"]]) { [unowned self] a in
                for _ in 0..<max(1, try a.int("steps", default: 1)) { editor.redo() }
                return [.text("やり直しました")]
            },
        ]
    }

    // MARK: - 情報

    func documentInfo() -> [String: Any] {
        let doc = editor.doc
        func node(_ n: LayerNode) -> [String: Any] {
            var o: [String: Any] = [
                "id": n.id.uuidString, "name": n.name, "kind": n.kind.rawValue, "visible": n.visible,
                "opacity": (Double(n.opacity) * 100).rounded() / 100, "blend_mode": n.blendMode.rawValue,
            ]
            if n.clipping { o["clipping"] = true }
            if n.lockAlpha { o["lock_alpha"] = true }
            if n.locked { o["locked"] = true }
            if n.isReference { o["reference"] = true }
            if n.isFolder {
                o["children"] = n.children.reversed().map(node)
            } else {
                o["content_bounds"] = n.tiles.contentBounds().map(Self.rectJSON) as Any? ?? NSNull()
            }
            return o
        }
        var info: [String: Any] = [
            "width": doc.width, "height": doc.height,
            "layers": doc.layers.reversed().map(node),
            "active_layer_id": doc.activeLayerID?.uuidString as Any? ?? NSNull(),
            "selection": doc.selection.map { Self.rectJSON($0.bounds) } as Any? ?? NSNull(),
            "main_color": Self.hex(editor.mainColor),
            "tool": editor.tool.rawValue,
            "brush": ["id": editor.currentBrush.id.uuidString, "name": editor.currentBrush.name, "size": Double(editor.currentBrush.size)],
            "unsaved_changes": editor.isDirty,
        ]
        if let url = editor.fileURL { info["file"] = url.path }
        return info
    }

    private func getImage(_ a: AgentArgs) throws -> [AgentContent] {
        let doc = editor.doc
        let rect = (try a.rect("region") ?? doc.bounds).intersection(doc.bounds)
        guard !rect.isEmpty else { throw AgentError("region がキャンバスの外です") }
        let buf: [UInt8]
        var what = "キャンバス全体の見た目"
        if let id = try a.uuid("layer_id") {
            guard var n = doc.node(id) else { throw AgentError("レイヤーが見つかりません: \(id)") }
            n.visible = true
            n.opacity = 1
            n.blendMode = .normal
            n.clipping = false
            var tmp = DocumentState(width: doc.width, height: doc.height)
            tmp.layers = [n]
            buf = Compositor.compositeFull(tmp)
            what = "レイヤー「\(n.name)」だけ（白背景）"
        } else {
            buf = Compositor.compositeFull(doc)
        }
        guard let out = AgentRender.render(buf, width: doc.width, height: doc.height, rect: rect,
                                           maxSize: try a.int("max_size", default: 1024), grid: try a.bool("grid") ?? false) else {
            throw AgentError("画像を作れませんでした")
        }
        let note = "\(what)。範囲 x=\(rect.x) y=\(rect.y) \(rect.width)×\(rect.height)、画像 \(out.width)×\(out.height)px（\(out.scale < 1 ? "ドキュメントの 1px を \(Int((1 / out.scale).rounded())) 倍に拡大" : "画像の 1px = ドキュメントの " + String(format: "%.2f", out.scale) + "px")）"
        return [.png(out.png), .text(note)]
    }

    // MARK: - 下塗り

    private func findRegions(_ a: AgentArgs) throws -> [AgentContent] {
        let doc = editor.doc
        let (ref, refName) = try referenceImage(try referenceKeys(a) ?? ["all"])
        let map = RegionMap.build(reference: ref, width: doc.width, height: doc.height,
                                  lineThreshold: Float(try a.double("line_threshold", default: 0.5)),
                                  gapClose: max(0, try a.int("gap_close", default: 0)),
                                  minArea: max(1, try a.int("min_area", default: 30)))
        regionMap = map
        lastReference = try referenceKeys(a) ?? ["all"]
        let composite = Compositor.compositeFull(doc)
        let limit = max(1, try a.int("max_regions", default: 300))
        let listMin = max(0, try a.int("list_min_area", default: 150))
        let listed = map.regions.prefix(limit).filter { $0.area >= listMin }
        let small = map.regions.filter { $0.area < listMin }
        let list: [[String: Any]] = listed.map { r in
            let i = (r.point.y * doc.width + r.point.x) * 4
            var o: [String: Any] = ["region": r.id, "area": r.area, "bounds": [r.bounds.x, r.bounds.y, r.bounds.width, r.bounds.height],
                                    "point": [r.point.x, r.point.y]]
            if composite[i + 3] > 0 {
                let al = Float(composite[i + 3])
                o["color"] = Self.hex(SIMD3(Float(composite[i]) / al, Float(composite[i + 1]) / al, Float(composite[i + 2]) / al))
            }
            if r.touchesEdge { o["touches_edge"] = true }
            return o
        }
        var contents: [AgentContent] = []
        if let img = AgentRender.regions(map, base: composite, maxSize: try a.int("max_size", default: 1024), maxLabels: listed.count) {
            contents.append(.png(img.png))
        }
        let summary: [String: Any] = [
            "reference": refName, "region_count": map.regions.count, "regions": list,
            "small_regions": ["count": small.count, "total_area": small.reduce(0) { $0 + $1.area }],
            "note": "bounds は [x, y, 幅, 高さ]。画像は範囲ごとに色をのせ、番号を内側の点に描いたもの。color は今の見た目の色。"
                + "list_min_area px 未満の小さな範囲は一覧から省いた（番号は振ってあり、最後に fill_leftovers でまとめて塗れる）。",
        ]
        contents.append(.text(json(summary)))
        return contents
    }

    private func findNode(named name: String, folder: Bool, in nodes: [LayerNode]) -> UUID? {
        for n in nodes.reversed() {
            if n.name == name && n.isFolder == folder { return n.id }
            if let id = findNode(named: name, folder: folder, in: n.children) { return id }
        }
        return nil
    }

    /// 点を通る滑らかな曲線（centripetal Catmull-Rom）に細かく分ける
    static func catmullRom(_ p: [(x: Double, y: Double, p: Double?)]) -> [(x: Double, y: Double, p: Double?)] {
        guard p.count >= 3 else { return p }
        var out: [(x: Double, y: Double, p: Double?)] = [p[0]]
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            func d(_ a: (x: Double, y: Double, p: Double?), _ b: (x: Double, y: Double, p: Double?)) -> Double {
                max(pow(hypot(b.x - a.x, b.y - a.y), 0.5), 1e-4)
            }
            let t1 = d(p0, p1), t2 = t1 + d(p1, p2), t3 = t2 + d(p2, p3)
            let n = max(2, Int(hypot(p2.x - p1.x, p2.y - p1.y) / 4))
            for k in 1...n {
                let t = t1 + (t2 - t1) * Double(k) / Double(n)
                func lerp(_ a: Double, _ b: Double, _ ta: Double, _ tb: Double) -> Double { tb == ta ? a : (a * (tb - t) + b * (t - ta)) / (tb - ta) }
                func c(_ v0: Double, _ v1: Double, _ v2: Double, _ v3: Double) -> Double {
                    let a1 = lerp(v0, v1, 0, t1), a2 = lerp(v1, v2, t1, t2), a3 = lerp(v2, v3, t2, t3)
                    let b1 = lerp(a1, a2, 0, t2), b2 = lerp(a2, a3, t1, t3)
                    return lerp(b1, b2, t1, t2)
                }
                let pr: Double? = p1.p.map { $0 + ((p2.p ?? $0) - $0) * Double(k) / Double(n) }
                out.append((c(p0.x, p1.x, p2.x, p3.x), c(p0.y, p1.y, p2.y, p3.y), pr))
            }
        }
        return out
    }

    /// reference は文字列か、レイヤー ID の配列
    private func referenceKeys(_ a: AgentArgs) throws -> [String]? {
        if let arr = a.raw["reference"] as? [String] { return arr.isEmpty ? nil : arr }
        return try a.string("reference").map { [$0] }
    }

    /// 線として見る画像（"all"、"reference_layers"、レイヤー ID の並び。非表示のレイヤーも見る）
    private func referenceImage(_ keys: [String]) throws -> ([UInt8], String) {
        let doc = editor.doc
        if keys == ["all"] { return (Compositor.compositeFull(doc), "見えている全体") }
        if keys == ["reference_layers"] {
            var o = CompositeOptions()
            o.referenceOnly = true
            return (Compositor.compositeFull(doc, options: o), "参照レイヤー")
        }
        var tmp = DocumentState(width: doc.width, height: doc.height)
        for key in keys {
            guard let id = UUID(uuidString: key), var n = doc.node(id) else { throw AgentError("reference のレイヤーが見つかりません: \(key)") }
            n.visible = true
            n.clipping = false
            tmp.layers.append(n)
        }
        return (Compositor.compositeFull(tmp), tmp.layers.map { "レイヤー「\($0.name)」" }.joined(separator: "と"))
    }

    private func fillLeftovers(_ a: AgentArgs) throws -> [AgentContent] {
        // 下塗りのフォルダー（パーツごとのレイヤー）なら、まとめて見て、色をとったレイヤーに塗る
        if let id = try a.uuid("layer_id"), let n = editor.doc.node(id), n.isFolder {
            return try fillLeftovers(a, folder: n)
        }
        let lid = try useLayer(a, paint: true)
        guard let keys = try referenceKeys(a) ?? lastReference else {
            throw AgentError("reference（線画のレイヤー ID）を指定してください")
        }
        guard keys != ["all"] else { throw AgentError("reference には線画のレイヤー ID を指定してください（\"all\" だと塗った色も線に見えてしまう）") }
        let doc = editor.doc
        let (ref, _) = try referenceImage(keys)
        let flat = doc.node(lid)!.tiles.toBuffer(width: doc.width, height: doc.height)
        let found = RegionMap.leftovers(flat: flat, line: ref, width: doc.width, height: doc.height,
                                        lineThreshold: Float(try a.double("line_threshold", default: 0.5)),
                                        maxArea: max(1, try a.int("max_area", default: 400)), expand: max(0, try a.int("expand", default: 2)))
        let dry = try a.bool("dry_run") ?? false
        if !dry && !found.isEmpty { editor.paintMasks(found.map(\.paint), layerID: lid, label: "塗り残しを塗る") }
        let list: [[String: Any]] = found.prefix(100).map { ["bounds": Self.rectJSON($0.bounds), "area": $0.area, "color": Self.hex($0.color)] }
        return [.text(json(["count": found.count, "filled": !dry, "leftovers": list]))]
    }

    private func fillLeftovers(_ a: AgentArgs, folder: LayerNode) throws -> [AgentContent] {
        guard let keys = try referenceKeys(a) ?? lastReference, keys != ["all"] else {
            throw AgentError("reference（線画のレイヤー ID）を指定してください")
        }
        let doc = editor.doc
        let (ref, _) = try referenceImage(keys)
        var f = folder
        f.visible = true
        f.opacity = 1
        var tmp = DocumentState(width: doc.width, height: doc.height)
        tmp.layers = [f]
        let flat = Compositor.compositeFull(tmp)
        let found = RegionMap.leftovers(flat: flat, line: ref, width: doc.width, height: doc.height,
                                        lineThreshold: Float(try a.double("line_threshold", default: 0.5)),
                                        maxArea: max(1, try a.int("max_area", default: 400)), expand: max(0, try a.int("expand", default: 2)))
        let dry = try a.bool("dry_run") ?? false
        let children = folder.children.filter { $0.kind == .raster }.reversed()
        var byLayer: [UUID: [Editor.MaskPaint]] = [:]
        for l in found {
            let x = l.source % doc.width, y = l.source / doc.width
            guard let target = children.first(where: { $0.tiles.pixel(x, y).3 >= 128 }) ?? children.first else { continue }
            byLayer[target.id, default: []].append(l.paint)
        }
        if !dry { for (id, items) in byLayer { editor.paintMasks(items, layerID: id, label: "塗り残しを塗る") } }
        let list: [[String: Any]] = found.prefix(100).map { ["bounds": [$0.bounds.x, $0.bounds.y, $0.bounds.width, $0.bounds.height], "area": $0.area, "color": Self.hex($0.color)] }
        return [.text(json(["count": found.count, "filled": !dry, "leftovers": list]))]
    }

    private func fillRegions(_ a: AgentArgs) throws -> [AgentContent] {
        guard let map = regionMap, map.width == editor.doc.width, map.height == editor.doc.height else {
            throw AgentError("先に find_regions を呼んでください")
        }
        guard let fills = a.raw["fills"] as? [[String: Any]], !fills.isEmpty else { throw AgentError("fills を指定してください") }
        let expand = max(0, try a.int("expand", default: 2))
        // 先に全部確かめる（途中で失敗して半端に塗らないように）
        var groups: [(name: String, items: [Editor.MaskPaint])] = []
        for f in fills {
            let fa = AgentArgs(f)
            let id = try fa.requireInt("region")
            guard let c = try fa.color("color") else { throw AgentError("region \(id) の color を指定してください") }
            guard let p = map.paint(id, color: c, expand: expand) else { throw AgentError("region \(id) はありません（1〜\(map.regions.count)）") }
            let name = try fa.string("name") ?? Self.hex(c)
            if let i = groups.firstIndex(where: { $0.name == name }) { groups[i].items.append(p) } else { groups.append((name, [p])) }
        }
        guard try a.bool("separate_layers") ?? false else {
            let lid = try useLayer(a, paint: true)
            editor.paintMasks(groups.flatMap(\.items), layerID: lid, label: "領域の塗り")
            return [.text("\(fills.count) 個の範囲を「\(editor.doc.node(lid)?.name ?? "")」に塗りました")]
        }
        // 色（name）ごとのレイヤーに塗る。フォルダーにまとめ、線画の下に置く
        let anchor = try a.uuid("below") ?? lastReference?.compactMap(UUID.init(uuidString:)).first ?? editor.activeLayerID
        guard let anchor, editor.doc.node(anchor) != nil else { throw AgentError("below（置く位置の上にあるレイヤー）を指定してください") }
        let folderName = try a.string("folder") ?? "下塗り"
        var folderID = findNode(named: folderName, folder: true, in: editor.doc.layers)
        if folderID == nil {
            editor.addFolder(name: folderName)
            folderID = editor.activeLayerID
            editor.moveLayer(folderID!, relativeTo: anchor, placement: .below)
        }
        let folder = folderID!
        var made: [String: String] = [:]
        for g in groups {
            var lid = editor.doc.node(folder).flatMap { findNode(named: g.name, folder: false, in: $0.children) }
            if lid == nil {
                editor.addLayer(name: g.name)
                lid = editor.activeLayerID
                editor.moveLayer(lid!, relativeTo: folder, placement: .into)
            }
            editor.paintMasks(g.items, layerID: lid!, label: "領域の塗り")
            made[g.name] = lid!.uuidString
        }
        return [.text(json(["folder_id": folder.uuidString, "layers": made,
                            "note": "\(fills.count) 個の範囲を \(groups.count) 枚のレイヤーに塗りました。同じ name で呼ぶと同じレイヤーに足して塗る"]))]
    }

    // MARK: - 描く・塗る

    private func fill(_ a: AgentArgs) throws -> [AgentContent] {
        let lid = try useLayer(a, paint: true)
        let x = try a.requireInt("x"), y = try a.requireInt("y")
        guard editor.doc.bounds.contains(x, y) else { throw AgentError("(\(x), \(y)) はキャンバスの外です") }
        var s = editor.fillSettings
        switch try a.string("reference") {
        case nil: break
        case "all": s.reference = .allLayers
        case "layer": s.reference = .currentLayer
        case "reference_layers": s.reference = .referenceLayers
        case let r?: throw AgentError("reference は all / layer / reference_layers のどれか: \(r)")
        }
        if let t = try a.double("tolerance") { s.tolerance = Float(t) }
        if let g = try a.int("gap_close") { s.gapClose = g }
        if let e = try a.int("expand") { s.expand = e }
        let seed = editor.pickColor(x: x, y: y)
        let (mask, bounds) = editor.regionMask(at: x, y, using: s)
        guard !bounds.isEmpty else { return [.text("塗る範囲がありませんでした")] }
        let w = editor.doc.width
        editor.paintMasks([Editor.MaskPaint(bounds: bounds, color: try a.color("color") ?? editor.mainColor) { x, y in mask[y * w + x] }],
                          layerID: lid, label: "塗りつぶし")
        var area = 0
        for yy in bounds.minY..<bounds.maxY {
            for xx in bounds.minX..<bounds.maxX where mask[yy * w + xx] != 0 { area += 1 }
        }
        var out: [String: Any] = ["area": area, "bounds": Self.rectJSON(bounds), "seed_color": seed.map(Self.hex) as Any? ?? NSNull()]
        // 線の上から塗ると、つながった線全体を塗ってしまう
        if let c = seed, (c.x + c.y + c.z) / 3 < 0.5 {
            out["warning"] = "起点 (\(x), \(y)) は暗い色（線の上の可能性）です。つながった線全体を塗ったかもしれません。意図と違えば undo して、線の内側の点で塗り直してください"
        }
        return [.text(json(out))]
    }

    private func lassoFill(_ a: AgentArgs) throws -> [AgentContent] {
        let lid = try useLayer(a, paint: true)
        let pts = try a.points("points")
        guard pts.count >= 3 else { throw AgentError("points は 3 点以上") }
        let path = CGMutablePath()
        path.addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y) })
        path.closeSubpath()
        let m = SelectionMask.fromPath(path, width: editor.doc.width, height: editor.doc.height, antialias: try a.bool("antialias") ?? true)
        guard !m.isEmpty else { return [.text("範囲がキャンバスの外です")] }
        let erase = try a.bool("erase") ?? false
        editor.paintMasks([Editor.MaskPaint(bounds: m.bounds, color: try a.color("color") ?? editor.mainColor, erase: erase) { x, y in m.value(x, y) }],
                          layerID: lid, label: erase ? "投げなわ消しゴム" : "投げなわ塗り")
        return [.text(erase ? "消しました" : "塗りました")]
    }

    private func stroke(_ a: AgentArgs) throws -> [AgentContent] {
        let lid = try useLayer(a, paint: true)
        var pts = try a.points("points")
        guard !pts.isEmpty else { throw AgentError("points を指定してください") }
        if try a.bool("curve") ?? false { pts = Self.catmullRom(pts) }
        // 非表示のレイヤー（明示したとき）は描くあいだだけ表示扱いにする
        let hidden = editor.doc.node(lid).map { !$0.visible } ?? false
        if hidden { editor.setLayerUIState(lid) { $0.visible = true } }
        defer { if hidden { editor.setLayerUIState(lid) { $0.visible = false } } }
        let erase = try a.bool("erase") ?? false
        let before = editor.toolSnapshot
        let presets = erase ? editor.erasers : editor.brushes
        var index = erase ? editor.activeEraserIndex : editor.activeBrushIndex
        if let key = try a.string("brush") {
            guard let i = presets.firstIndex(where: { $0.id.uuidString == key || $0.name == key }) else {
                throw AgentError("ブラシが見つかりません: \(key)（list_brushes で確かめてください）")
            }
            index = i
        }
        editor.activate(.preset(presets[index].id))
        let original = editor.currentBrush
        let originalColor = editor.mainColor
        if let o = a.raw["settings"] as? [String: Any] { editor.currentBrush = try Self.applying(o, to: editor.currentBrush) }
        if let size = try a.double("size") { editor.setBrushSize(Float(size)) }
        if let op = try a.double("opacity") { editor.currentBrush.opacity = Float(min(max(op, 0), 1)) }
        if let c = try a.color("color") { editor.mainColor = c }
        defer {
            editor.currentBrush = original
            editor.mainColor = originalColor
            editor.restore(before)
        }
        // 点の間を 2px 以下の間隔に分け、一定の速さで動かしたことにする（同じ入力なら必ず同じ結果）
        let usePressure = pts.contains { $0.p != nil }
        var samples: [StrokeInput] = []
        var t = 0.0
        for (i, p) in pts.enumerated() {
            if i == 0 {
                samples.append(StrokeInput(x: p.x, y: p.y, pressure: p.p ?? 1, time: 0))
                continue
            }
            let q = pts[i - 1]
            let d = hypot(p.x - q.x, p.y - q.y)
            let n = max(1, Int((d / 2).rounded(.up)))
            for k in 1...n {
                let u = Double(k) / Double(n)
                t += d / Double(n) / 800
                samples.append(StrokeInput(x: q.x + (p.x - q.x) * u, y: q.y + (p.y - q.y) * u,
                                           pressure: (q.p ?? 1) + ((p.p ?? 1) - (q.p ?? 1)) * u, time: t))
            }
        }
        guard editor.beginStroke(samples[0], usePressure: usePressure, zoom: 1) else {
            throw AgentError("このレイヤーには描けません（フォルダー・ロック・非表示）")
        }
        for s in samples.dropFirst() { editor.continueStroke(s) }
        editor.endStroke()
        return [.text("描きました（\(editor.currentBrush.name)、\(samples.count) 点）")]
    }

    // MARK: - 選択範囲

    private func select(_ a: AgentArgs) throws -> [AgentContent] {
        let doc = editor.doc
        let op: SelectionOp
        switch try a.string("op") ?? "replace" {
        case "replace": op = .replace
        case "add": op = .add
        case "subtract": op = .subtract
        case "intersect": op = .intersect
        case let s: throw AgentError("op は replace / add / subtract / intersect のどれか: \(s)")
        }
        switch try a.requireString("shape") {
        case "all": editor.selectAll()
        case "none": editor.deselect()
        case "invert": editor.invertSelection()
        case "rect", "ellipse":
            guard let r = try a.rect("rect") else { throw AgentError("rect を指定してください") }
            let cg = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
            editor.select(path: try a.requireString("shape") == "rect" ? CGPath(rect: cg, transform: nil) : CGPath(ellipseIn: cg, transform: nil), op: op)
        case "polygon":
            let pts = try a.points("points")
            guard pts.count >= 3 else { throw AgentError("points は 3 点以上") }
            let path = CGMutablePath()
            path.addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y) })
            path.closeSubpath()
            editor.select(path: path, op: op)
        case "regions":
            guard let map = regionMap, map.width == doc.width, map.height == doc.height else { throw AgentError("先に find_regions を呼んでください") }
            guard let ids = a.raw["regions"] as? [NSNumber], !ids.isEmpty else { throw AgentError("regions に番号を並べてください") }
            var data = [UInt8](repeating: 0, count: doc.width * doc.height)
            for n in ids {
                guard let p = map.paint(n.intValue, color: .zero, expand: 1) else { throw AgentError("region \(n) はありません") }
                for y in p.bounds.minY..<p.bounds.maxY {
                    for x in p.bounds.minX..<p.bounds.maxX { data[y * doc.width + x] = max(data[y * doc.width + x], p.alpha(x, y)) }
                }
            }
            editor.setSelection(SelectionMask.combine(doc.selection, SelectionMask(width: doc.width, height: doc.height, data: data), op: op),
                                label: "選択範囲")
        case "wand":
            let x = try a.requireInt("x"), y = try a.requireInt("y")
            guard doc.bounds.contains(x, y) else { throw AgentError("(\(x), \(y)) はキャンバスの外です") }
            var st = editor.wandSettings
            switch try a.string("reference") {
            case nil, "all": st.reference = .allLayers
            case "layer": st.reference = .currentLayer
            case "reference_layers": st.reference = .referenceLayers
            case let r?: throw AgentError("reference は all / layer / reference_layers のどれか: \(r)")
            }
            if let t = try a.double("tolerance") { st.tolerance = Float(t) }
            let saved = editor.wandSettings
            editor.wandSettings = st
            editor.wandSelect(atX: x, y: y, op: op)
            editor.wandSettings = saved
        case "layer":
            let id = try layer(a, "layer_id")
            guard let n = doc.node(id), n.kind == .raster else { throw AgentError("ラスターレイヤーを指定してください") }
            let buf = n.tiles.toBuffer(width: doc.width, height: doc.height)
            let data = (0..<(doc.width * doc.height)).map { buf[$0 * 4 + 3] }
            editor.setSelection(SelectionMask.combine(doc.selection, SelectionMask(width: doc.width, height: doc.height, data: data), op: op),
                                label: "選択範囲")
        case let s:
            throw AgentError("shape が不明です: \(s)")
        }
        return [.text(json(["selection": editor.doc.selection.map { Self.rectJSON($0.bounds) } as Any? ?? NSNull()]))]
    }

    // MARK: - レイヤー

    private func layer(_ a: AgentArgs, _ key: String) throws -> UUID {
        guard let id = try a.uuid(key) else { throw AgentError("\(key) を指定してください") }
        guard editor.doc.node(id) != nil else { throw AgentError("レイヤーが見つかりません: \(id)") }
        return id
    }

    /// layer_id があれば編集レイヤーにする。paint: true なら描けるレイヤーかも確かめる
    @discardableResult
    private func useLayer(_ a: AgentArgs, paint: Bool) throws -> UUID {
        if a.has("layer_id") {
            let id = try layer(a, "layer_id")
            if editor.activeLayerID != id || !editor.selectedLayerIDs.isEmpty { editor.setActiveLayer(id) }
        }
        guard let l = editor.doc.activeLayer else { throw AgentError("編集レイヤーがありません") }
        if paint {
            if l.kind != .raster { throw AgentError("「\(l.name)」はフォルダーなので描けません") }
            if l.locked { throw AgentError("「\(l.name)」はロックされています") }
            // 非表示のレイヤーは、layer_id で明示したときだけ描ける（閉じ線など）
            if !editor.doc.isEffectivelyVisible(l.id) && !a.has("layer_id") {
                throw AgentError("「\(l.name)」は非表示です。非表示のまま描くなら layer_id で指定してください")
            }
        }
        return l.id
    }

    private func addLayer(_ a: AgentArgs) throws -> [AgentContent] {
        let below = try a.uuid("below"), above = try a.uuid("above")
        for id in [below, above].compactMap({ $0 }) where editor.doc.node(id) == nil {
            throw AgentError("レイヤーが見つかりません: \(id)")
        }
        if try a.bool("folder") ?? false {
            editor.addFolder(name: try a.string("name"))
        } else {
            editor.addLayer(name: try a.string("name"))
        }
        guard let id = editor.activeLayerID else { throw AgentError("作れませんでした") }
        if let below { editor.moveLayer(id, relativeTo: below, placement: .below) }
        if let above { editor.moveLayer(id, relativeTo: above, placement: .above) }
        return [.text(json(["layer_id": id.uuidString, "name": editor.doc.node(id)?.name ?? ""]))]
    }

    private func updateLayer(_ a: AgentArgs) throws -> [AgentContent] {
        let id = try layer(a, "layer_id")
        var blend: BlendMode?
        if let s = try a.string("blend_mode") {
            guard let b = BlendMode(rawValue: s) else { throw AgentError("blend_mode が不明です: \(s)") }
            blend = b
        }
        let name = try a.string("name"), visible = try a.bool("visible"), opacity = try a.double("opacity")
        let clipping = try a.bool("clipping"), lockAlpha = try a.bool("lock_alpha"), locked = try a.bool("locked"), ref = try a.bool("reference")
        editor.setLayerProperty(id, label: "レイヤーの設定") { n in
            if let name { n.name = name }
            if let visible { n.visible = visible }
            if let opacity { n.opacity = Float(min(max(opacity, 0), 1)) }
            if let blend { n.blendMode = blend }
            if let clipping { n.clipping = clipping }
            if let lockAlpha { n.lockAlpha = lockAlpha }
            if let locked { n.locked = locked }
            if let ref { n.isReference = ref }
        }
        return [.text("変更しました")]
    }

    // MARK: - 補助

    public static func parseColor(_ s: String) -> SIMD3<Float>? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return SIMD3(Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255)
    }

    public static func hex(_ c: SIMD3<Float>) -> String {
        func b(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.x), b(c.y), b(c.z))
    }

    static func rectJSON(_ r: IntRect) -> [String: Int] {
        ["x": r.x, "y": r.y, "width": r.width, "height": r.height]
    }

    public func json(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "\(v)" }
        return s
    }
}

// MARK: - 変形・選択・ブラシ・まとめて実行

extension AgentToolbox {
    var moreTools: [AgentTool] {
        let layerID: [String: Any] = ["type": "string", "description": "対象のレイヤー ID。省略すると編集中のレイヤー"]
        return [
            AgentTool(name: "batch",
                      description: "複数のツールを順に呼ぶ（1 回のやりとりで済む）。たとえば線をたくさん描く、いくつかの点を塗りつぶすなど。画像を返すツールの画像もそのまま返す。",
                      properties: ["calls": ["type": "array", "description": "[{\"tool\": 名前, \"arguments\": {...}}, ...]",
                                             "items": ["type": "object", "properties": ["tool": ["type": "string"], "arguments": ["type": "object"]],
                                                       "required": ["tool"]]],
                                   "stop_on_error": ["type": "boolean", "description": "失敗したらそこで止める（既定 true）"]],
                      required: ["calls"]) { [unowned self] a in
                try batch(a)
            },
            AgentTool(name: "transform",
                      description: "選択範囲の中（なければレイヤー全体）を動かす・拡大縮小する・回転する・反転する。中心は対象の範囲の中心。",
                      properties: ["layer_id": layerID,
                                   "dx": ["type": "number", "description": "右へ動かす px"], "dy": ["type": "number", "description": "下へ動かす px"],
                                   "scale": ["type": "number", "description": "縦横同じ倍率"],
                                   "scale_x": ["type": "number"], "scale_y": ["type": "number"],
                                   "rotation": ["type": "number", "description": "度。正の値で時計回り"],
                                   "flip_horizontal": ["type": "boolean"], "flip_vertical": ["type": "boolean"]]) { [unowned self] a in
                try transform(a)
            },
            AgentTool(name: "fill_selection", description: "選択範囲（なければレイヤー全体）を色で塗る。select で楕円や多角形を選んでから塗る、などに。",
                      properties: ["color": ["type": "string", "description": "\"#RRGGBB\"。省略すると現在の描画色"], "layer_id": layerID]) { [unowned self] a in
                let lid = try useLayer(a, paint: true)
                let doc = editor.doc
                let sel = doc.selection
                editor.paintMasks([Editor.MaskPaint(bounds: sel?.bounds ?? doc.bounds, color: try a.color("color") ?? editor.mainColor) { _, _ in 255 }],
                                  layerID: lid, label: "塗りつぶし")
                return [.text("塗りました")]
            },
            AgentTool(name: "set_color", description: "描画色（main）とサブカラー（sub）を設定する。",
                      properties: ["main": ["type": "string", "description": "\"#RRGGBB\""], "sub": ["type": "string"]]) { [unowned self] a in
                if let c = try a.color("main") { editor.mainColor = c }
                if let c = try a.color("sub") { editor.subColor = c }
                return [.text(json(["main": Self.hex(editor.mainColor), "sub": Self.hex(editor.subColor)]))]
            },
            AgentTool(name: "select_brush", description: "ブラシ（または消しゴム）を名前か ID で選ぶ。以後ユーザーが描くときもそのブラシになる。",
                      properties: ["brush": ["type": "string"]], required: ["brush"]) { [unowned self] a in
                let b = try brush(try a.requireString("brush"))
                editor.activate(.preset(b.id))
                return [.text("選びました: \(b.name)")]
            },
            AgentTool(name: "update_brush",
                      description: "ブラシの設定を変えて保存する（ユーザーのブラシも変わる）。一時的に変えたいだけなら stroke の settings を使う。",
                      properties: ["brush": ["type": "string", "description": "名前か ID"],
                                   "settings": ["type": "object", "description": "変える項目（list_brushes の detail: true で見られる名前）"]],
                      required: ["brush", "settings"]) { [unowned self] a in
                let b = try brush(try a.requireString("brush"))
                guard let o = a.raw["settings"] as? [String: Any] else { throw AgentError("settings を指定してください") }
                let nb = try Self.applying(o, to: b)
                if let i = editor.brushes.firstIndex(where: { $0.id == b.id }) { editor.brushes[i] = nb }
                if let i = editor.erasers.firstIndex(where: { $0.id == b.id }) { editor.erasers[i] = nb }
                return [.text(json(Self.settingsJSON(nb)))]
            },
            AgentTool(name: "create_brush",
                      description: "既存のブラシを元に新しいブラシを作る（ユーザーのブラシ一覧に加わる）。",
                      properties: ["from": ["type": "string", "description": "元にするブラシの名前か ID"], "name": ["type": "string"],
                                   "settings": ["type": "object", "description": "変える項目"]],
                      required: ["from", "name"]) { [unowned self] a in
                let base = try brush(try a.requireString("from"))
                var nb = try Self.applying(a.raw["settings"] as? [String: Any] ?? [:], to: base)
                nb.id = UUID()
                nb.name = try a.requireString("name")
                if editor.erasers.contains(where: { $0.id == base.id }) { editor.erasers.append(nb) } else { editor.brushes.append(nb) }
                return [.text(json(["id": nb.id.uuidString, "name": nb.name]))]
            },
            AgentTool(name: "group_layers", description: "いくつかのレイヤーを新しいフォルダーにまとめる。",
                      properties: ["layer_ids": ["type": "array", "items": ["type": "string"]], "name": ["type": "string"]],
                      required: ["layer_ids"]) { [unowned self] a in
                guard let ids = (a.raw["layer_ids"] as? [String])?.compactMap(UUID.init(uuidString:)), !ids.isEmpty else {
                    throw AgentError("layer_ids に ID を並べてください")
                }
                for id in ids where editor.doc.node(id) == nil { throw AgentError("レイヤーが見つかりません: \(id)") }
                editor.setActiveLayer(ids[0])
                for id in ids.dropFirst() where !editor.isLayerSelected(id) { editor.toggleLayerSelection(id) }
                editor.groupSelectedLayers()
                guard let path = editor.doc.indexPath(of: ids[0]), let folder = editor.doc.node(at: Array(path.dropLast())), folder.isFolder else {
                    throw AgentError("まとめられませんでした")
                }
                if let name = try a.string("name") { editor.setLayerProperty(folder.id, label: "レイヤーの名前") { $0.name = name } }
                return [.text(json(["folder_id": folder.id.uuidString]))]
            },
            AgentTool(name: "resize_canvas", description: "キャンバスの大きさを変える（左上を基準に、絵は拡大縮小しない）。",
                      properties: ["width": ["type": "integer"], "height": ["type": "integer"]], required: ["width", "height"]) { [unowned self] a in
                let w = try a.requireInt("width"), h = try a.requireInt("height")
                guard (1...20000).contains(w), (1...20000).contains(h) else { throw AgentError("大きさは 1〜20000 px") }
                editor.resizeCanvas(width: w, height: h)
                return [.text("\(w)×\(h) にしました")]
            },
        ]
    }

    private func brush(_ key: String) throws -> BrushSettings {
        guard let b = (editor.brushes + editor.erasers).first(where: { $0.id.uuidString == key || $0.name == key }) else {
            throw AgentError("ブラシが見つかりません: \(key)（list_brushes で確かめてください）")
        }
        return b
    }

    private func batch(_ a: AgentArgs) throws -> [AgentContent] {
        guard let calls = a.raw["calls"] as? [[String: Any]], !calls.isEmpty else { throw AgentError("calls を指定してください") }
        let stop = try a.bool("stop_on_error") ?? true
        var out: [AgentContent] = []
        var failed = 0
        for (i, c) in calls.enumerated() {
            guard let name = c["tool"] as? String else { throw AgentError("calls[\(i)] に tool がありません") }
            guard name != "batch" else { throw AgentError("batch の中で batch は使えません") }
            do {
                let r = try call(name, c["arguments"] as? [String: Any] ?? [:])
                for item in r {
                    if case let .text(t) = item { out.append(.text("[\(i)] \(name): \(t)")) } else { out.append(item) }
                }
            } catch {
                failed += 1
                out.append(.text("[\(i)] \(name): 失敗: \(error)"))
                if stop { throw AgentError(out.compactMap { if case let .text(t) = $0 { return t } else { return nil } }.joined(separator: "\n") + "\n（ここで止めました。前の操作は実行済み）") }
            }
        }
        out.append(.text("\(calls.count) 件中 \(calls.count - failed) 件成功"))
        return out
    }

    private func transform(_ a: AgentArgs) throws -> [AgentContent] {
        try useLayer(a, paint: true)
        var p = TransformParams()
        p.tx = try a.double("dx", default: 0)
        p.ty = try a.double("dy", default: 0)
        let s = try a.double("scale", default: 1)
        p.sx = try a.double("scale_x", default: s)
        p.sy = try a.double("scale_y", default: s)
        if try a.bool("flip_horizontal") ?? false { p.sx = -p.sx }
        if try a.bool("flip_vertical") ?? false { p.sy = -p.sy }
        p.rotation = try a.double("rotation", default: 0) * .pi / 180
        guard p.sx != 0, p.sy != 0 else { throw AgentError("倍率に 0 は使えません") }
        guard editor.beginTransform() else { throw AgentError("変形できませんでした（空のレイヤーか、選択範囲の中が空）") }
        editor.updateTransform(p)
        let dest = editor.floating?.destBounds
        editor.commitTransform()
        return [.text(json(["bounds": dest.map(Self.rectJSON) as Any? ?? NSNull()]))]
    }

    /// ブラシ設定の一部を JSON で上書きする
    static func applying(_ o: [String: Any], to b: BrushSettings) throws -> BrushSettings {
        var d = settingsJSON(b)
        for (k, v) in o {
            guard d[k] != nil, k != "id", k != "kind" else {
                throw AgentError("ブラシの設定に \(k) はありません。使える項目: \(d.keys.filter { $0 != "id" && $0 != "kind" }.sorted().joined(separator: ", "))")
            }
            d[k] = v
        }
        do {
            return try JSONDecoder().decode(BrushSettings.self, from: JSONSerialization.data(withJSONObject: d))
        } catch {
            throw AgentError("ブラシの設定の値の型が違います: \(error)")
        }
    }

    static func settingsJSON(_ b: BrushSettings) -> [String: Any] {
        guard let d = try? JSONEncoder().encode(b), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
}
