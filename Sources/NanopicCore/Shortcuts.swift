import Foundation

/// 単キーのショートカット（⌘ なし。Shift / Option との組み合わせは可）
public struct KeyChord: Codable, Hashable, Sendable {
    /// 修飾キーを除いた文字（小文字）
    public var key: String
    public var shift = false
    public var option = false

    public init(_ key: String, shift: Bool = false, option: Bool = false) {
        self.key = key.lowercased()
        self.shift = shift
        self.option = option
    }

    public var displayName: String {
        (option ? "⌥" : "") + (shift ? "⇧" : "") + key.uppercased()
    }
}

/// ショートカットで切り替える先: ツール（ブラシなら最後に使ったブラシ）か、特定のブラシ・消しゴム
public enum ShortcutTarget: Codable, Hashable, Sendable {
    case tool(Tool)
    case preset(UUID)
}

public struct ShortcutBinding: Codable, Hashable, Sendable {
    public var chord: KeyChord
    public var target: ShortcutTarget

    public init(_ chord: KeyChord, _ target: ShortcutTarget) {
        self.chord = chord
        self.target = target
    }
}

public struct ShortcutMap: Codable, Equatable, Sendable {
    public private(set) var bindings: [ShortcutBinding]

    public init(bindings: [ShortcutBinding]) {
        self.bindings = bindings
    }

    /// ツール以外の機能に使っている単キー（割り当て不可）
    public static let reserved: Set<KeyChord> = [
        KeyChord("x"), KeyChord("["), KeyChord("]"), KeyChord("r", shift: true), KeyChord(" "),
    ]

    public static let defaults = ShortcutMap(bindings: [
        .init(KeyChord("b"), .tool(.brush)),
        .init(KeyChord("p"), .tool(.brush)),
        .init(KeyChord("e"), .tool(.eraser)),
        .init(KeyChord("e", shift: true), .tool(.lassoErase)),
        .init(KeyChord("g"), .tool(.fill)),
        .init(KeyChord("g", shift: true), .tool(.lassoFill)),
        .init(KeyChord("m"), .tool(.selectRect)),
        .init(KeyChord("m", shift: true), .tool(.selectEllipse)),
        .init(KeyChord("l"), .tool(.lasso)),
        .init(KeyChord("w"), .tool(.wand)),
        .init(KeyChord("v"), .tool(.move)),
        .init(KeyChord("i"), .tool(.eyedropper)),
        .init(KeyChord("h"), .tool(.hand)),
        .init(KeyChord("z"), .tool(.zoom)),
    ])

    public func target(for chord: KeyChord) -> ShortcutTarget? {
        bindings.first { $0.chord == chord }?.target
    }

    public func chords(for target: ShortcutTarget) -> [KeyChord] {
        bindings.filter { $0.target == target }.map(\.chord)
    }

    /// chord を target に割り当てる。同じキーの既存の割り当ては外す。chord が nil なら target の割り当てをすべて外す
    public mutating func assign(_ chord: KeyChord?, to target: ShortcutTarget) {
        guard let chord else {
            bindings.removeAll { $0.target == target }
            return
        }
        guard !Self.reserved.contains(chord) else { return }
        bindings.removeAll { $0.chord == chord }
        bindings.append(ShortcutBinding(chord, target))
    }

    /// 存在しないブラシへの割り当てを除く
    public mutating func prune(validPresets: Set<UUID>) {
        bindings.removeAll {
            if case let .preset(id) = $0.target { return !validPresets.contains(id) }
            return false
        }
    }
}

extension Editor {
    /// ショートカットの切り替え先を選ぶ。特定のブラシならそのツール（ブラシか消しゴム）とブラシを選ぶ
    public func activate(_ target: ShortcutTarget) {
        switch target {
        case let .tool(t):
            selectTool(t)
        case let .preset(id):
            if let i = brushes.firstIndex(where: { $0.id == id }) {
                selectTool(.brush)
                activeBrushIndex = i
            } else if let i = erasers.firstIndex(where: { $0.id == id }) {
                selectTool(.eraser)
                activeEraserIndex = i
            }
        }
    }

    /// 一時的に切り替えたあと元に戻すための、ツールと選択中のブラシ
    public struct ToolSnapshot: Equatable, Sendable {
        public var tool: Tool
        public var brushID: UUID?
        public var eraserID: UUID?
    }

    public var toolSnapshot: ToolSnapshot {
        ToolSnapshot(tool: tool, brushID: brushes[safe: activeBrushIndex]?.id, eraserID: erasers[safe: activeEraserIndex]?.id)
    }

    public func restore(_ s: ToolSnapshot) {
        selectTool(s.tool)
        if let i = brushes.firstIndex(where: { $0.id == s.brushID }) { activeBrushIndex = i }
        if let i = erasers.firstIndex(where: { $0.id == s.eraserID }) { activeEraserIndex = i }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
