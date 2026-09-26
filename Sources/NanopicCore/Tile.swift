import Foundation

/// 128x128 の RGBA8 (premultiplied) ピクセルタイル。
/// `gen` は作成された編集世代。Undo スナップショット取得時に世代が進むため、
/// 古い世代のタイルは不変として扱い、書き込み時に複製する（Copy-on-Write）。
public final class Tile: @unchecked Sendable {
    public let data: UnsafeMutablePointer<UInt8>
    public let gen: Int

    public init(gen: Int) {
        data = .allocate(capacity: kTilePixelCount * 4)
        data.initialize(repeating: 0, count: kTilePixelCount * 4)
        self.gen = gen
    }

    public init(copying other: Tile, gen: Int) {
        data = .allocate(capacity: kTilePixelCount * 4)
        data.update(from: other.data, count: kTilePixelCount * 4)
        self.gen = gen
    }

    deinit {
        data.deallocate()
    }

    public var isTransparent: Bool {
        var i = 3
        let n = kTilePixelCount * 4
        while i < n {
            if data[i] != 0 { return false }
            i += 4
        }
        return true
    }
}

public struct TileMap {
    public private(set) var tiles: [TileKey: Tile] = [:]

    public init() {}

    public subscript(key: TileKey) -> Tile? { tiles[key] }
    public var keys: Dictionary<TileKey, Tile>.Keys { tiles.keys }
    public var isEmpty: Bool { tiles.isEmpty }

    /// 書き込み可能なタイルを返す（必要なら複製・新規作成）
    public mutating func mutableTile(_ key: TileKey, gen: Int) -> Tile {
        if let t = tiles[key] {
            if t.gen == gen { return t }
            let c = Tile(copying: t, gen: gen)
            tiles[key] = c
            return c
        }
        let t = Tile(gen: gen)
        tiles[key] = t
        return t
    }

    public mutating func set(_ key: TileKey, _ tile: Tile?) {
        tiles[key] = tile
    }

    public mutating func removeAll() {
        tiles.removeAll()
    }

    public mutating func pruneTransparent(_ keys: [TileKey]) {
        for k in keys {
            if let t = tiles[k], t.isTransparent { tiles[k] = nil }
        }
    }

    public func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard x >= 0, y >= 0 else { return (0, 0, 0, 0) }
        let key = TileKey(x: x / kTileSize, y: y / kTileSize)
        guard let t = tiles[key] else { return (0, 0, 0, 0) }
        let o = ((y % kTileSize) * kTileSize + (x % kTileSize)) * 4
        return (t.data[o], t.data[o + 1], t.data[o + 2], t.data[o + 3])
    }

    /// 不透明ピクセルのバウンディング矩形
    public func contentBounds() -> IntRect? {
        var result = IntRect.zero
        for (key, tile) in tiles {
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            for y in 0..<kTileSize {
                let row = tile.data + y * kTileSize * 4
                for x in 0..<kTileSize where row[x * 4 + 3] != 0 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            if minX <= maxX {
                let r = IntRect(minX: key.x * kTileSize + minX, minY: key.y * kTileSize + minY,
                                maxX: key.x * kTileSize + maxX + 1, maxY: key.y * kTileSize + maxY + 1)
                result = result.union(r)
            }
        }
        return result.isEmpty ? nil : result
    }

    /// キャンバスサイズの RGBA8 premultiplied バッファへ展開
    public func toBuffer(width: Int, height: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        buf.withUnsafeMutableBufferPointer { p in
            copy(into: p.baseAddress!, width: width, height: height, rect: IntRect(x: 0, y: 0, width: width, height: height))
        }
        return buf
    }

    public func copy(into dst: UnsafeMutablePointer<UInt8>, width: Int, height: Int, rect: IntRect) {
        let r = rect.intersection(IntRect(x: 0, y: 0, width: width, height: height))
        for key in r.tileKeys {
            guard let t = tiles[key] else { continue }
            let tr = key.rect.intersection(r)
            for y in tr.minY..<tr.maxY {
                let src = t.data + ((y - key.y * kTileSize) * kTileSize + (tr.minX - key.x * kTileSize)) * 4
                let d = dst + (y * width + tr.minX) * 4
                d.update(from: src, count: tr.width * 4)
            }
        }
    }

    /// キャンバスサイズのバッファからタイルマップを生成
    public static func from(buffer: UnsafePointer<UInt8>, width: Int, height: Int, gen: Int) -> TileMap {
        var map = TileMap()
        let full = IntRect(x: 0, y: 0, width: width, height: height)
        for key in full.tileKeys {
            let tr = key.rect.intersection(full)
            var any = false
            for y in tr.minY..<tr.maxY where !any {
                let row = buffer + (y * width) * 4
                for x in tr.minX..<tr.maxX where row[x * 4 + 3] != 0 {
                    any = true
                    break
                }
            }
            if !any { continue }
            let t = Tile(gen: gen)
            for y in tr.minY..<tr.maxY {
                let src = buffer + (y * width + tr.minX) * 4
                let d = t.data + ((y - key.y * kTileSize) * kTileSize + (tr.minX - key.x * kTileSize)) * 4
                d.update(from: src, count: tr.width * 4)
            }
            map.tiles[key] = t
        }
        return map
    }

    /// 単色で塗りつぶしたタイルマップ
    public static func filled(width: Int, height: Int, rgba: (UInt8, UInt8, UInt8, UInt8), gen: Int) -> TileMap {
        var map = TileMap()
        let full = IntRect(x: 0, y: 0, width: width, height: height)
        for key in full.tileKeys {
            let t = Tile(gen: gen)
            let tr = key.rect.intersection(full)
            for y in tr.minY..<tr.maxY {
                for x in tr.minX..<tr.maxX {
                    let o = ((y - key.y * kTileSize) * kTileSize + (x - key.x * kTileSize)) * 4
                    t.data[o] = rgba.0; t.data[o + 1] = rgba.1; t.data[o + 2] = rgba.2; t.data[o + 3] = rgba.3
                }
            }
            map.tiles[key] = t
        }
        return map
    }
}
