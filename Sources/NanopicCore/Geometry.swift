import CoreGraphics
import Foundation

public let kTileSize = 128
public let kTilePixelCount = kTileSize * kTileSize

/// 整数矩形（maxX / maxY は排他的）
public struct IntRect: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static let zero = IntRect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Int { x }
    public var minY: Int { y }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var area: Int { isEmpty ? 0 : width * height }

    public func union(_ o: IntRect) -> IntRect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        return IntRect(minX: min(minX, o.minX), minY: min(minY, o.minY),
                       maxX: max(maxX, o.maxX), maxY: max(maxY, o.maxY))
    }

    public func intersection(_ o: IntRect) -> IntRect {
        let r = IntRect(minX: max(minX, o.minX), minY: max(minY, o.minY),
                        maxX: min(maxX, o.maxX), maxY: min(maxY, o.maxY))
        return r.isEmpty ? .zero : r
    }

    public func insetBy(_ d: Int) -> IntRect {
        IntRect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d)
    }

    public func contains(_ px: Int, _ py: Int) -> Bool {
        px >= minX && px < maxX && py >= minY && py < maxY
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public static func enclosing(_ r: CGRect) -> IntRect {
        if r.isNull || r.isInfinite { return .zero }
        return IntRect(minX: Int(floor(r.minX)), minY: Int(floor(r.minY)),
                       maxX: Int(ceil(r.maxX)), maxY: Int(ceil(r.maxY)))
    }

    /// 矩形に重なるタイルキー（負の座標は含めない）
    public var tileKeys: [TileKey] {
        if isEmpty { return [] }
        let x0 = max(0, minX) / kTileSize
        let y0 = max(0, minY) / kTileSize
        let x1 = (maxX - 1) / kTileSize
        let y1 = (maxY - 1) / kTileSize
        if x1 < x0 || y1 < y0 || maxX <= 0 || maxY <= 0 { return [] }
        var keys: [TileKey] = []
        keys.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for ty in y0...y1 {
            for tx in x0...x1 {
                keys.append(TileKey(x: tx, y: ty))
            }
        }
        return keys
    }

    public var description: String { "(\(x),\(y) \(width)x\(height))" }
}

public struct TileKey: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public var rect: IntRect {
        IntRect(x: x * kTileSize, y: y * kTileSize, width: kTileSize, height: kTileSize)
    }
}

@inline(__always) func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }

@inline(__always) func pixelHash(_ x: Int, _ y: Int) -> Float {
    var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h ^= h >> 16
    return Float(h & 0xFFFF) / 65536.0
}
