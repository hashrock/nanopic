import CoreGraphics
import Foundation

public struct TransformParams: Equatable, Sendable {
    public var tx: Double = 0
    public var ty: Double = 0
    public var sx: Double = 1
    public var sy: Double = 1
    /// ラジアン
    public var rotation: Double = 0
    public init() {}
}

/// 選択範囲（またはレイヤー全体）を持ち上げて変形中の状態
public final class FloatingTransform: @unchecked Sendable {
    public let layerID: UUID
    public let sourceRect: IntRect
    /// sourceRect サイズの premultiplied RGBA8
    let pixels: [UInt8]
    /// 持ち上げた部分を取り除いたレイヤーのタイル
    let baseTiles: TileMap
    public let originalSelection: SelectionMask?
    public var params = TransformParams()
    let docWidth: Int
    let docHeight: Int

    public var center: CGPoint {
        CGPoint(x: Double(sourceRect.x) + Double(sourceRect.width) / 2, y: Double(sourceRect.y) + Double(sourceRect.height) / 2)
    }

    public var matrix: CGAffineTransform {
        let c = center
        return CGAffineTransform(translationX: c.x + params.tx, y: c.y + params.ty)
            .rotated(by: params.rotation)
            .scaledBy(x: params.sx, y: params.sy)
            .translatedBy(x: -c.x, y: -c.y)
    }

    /// 変形後の四隅（左上, 右上, 右下, 左下）
    public var corners: [CGPoint] {
        let r = sourceRect.cgRect
        let m = matrix
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { $0.applying(m) }
    }

    public var destBounds: IntRect {
        IntRect.enclosing(sourceRect.cgRect.applying(matrix)).insetBy(-1)
            .intersection(IntRect(x: 0, y: 0, width: docWidth, height: docHeight))
    }

    public init?(layer: LayerNode, selection: SelectionMask?, docWidth: Int, docHeight: Int) {
        guard layer.kind == .raster else { return nil }
        self.layerID = layer.id
        self.docWidth = docWidth
        self.docHeight = docHeight
        self.originalSelection = selection
        let bounds: IntRect
        if let selection {
            guard let cb = layer.tiles.contentBounds() else { return nil }
            bounds = selection.bounds.intersection(cb)
        } else {
            guard let cb = layer.tiles.contentBounds() else { return nil }
            bounds = cb
        }
        if bounds.isEmpty { return nil }
        sourceRect = bounds
        var px = [UInt8](repeating: 0, count: bounds.width * bounds.height * 4)
        var base = layer.tiles
        px.withUnsafeMutableBufferPointer { p in
            for key in bounds.tileKeys {
                guard let t = layer.tiles[key] else { continue }
                let tr = key.rect.intersection(bounds)
                let nt = selection != nil ? Tile(copying: t, gen: -1) : nil
                for y in tr.minY..<tr.maxY {
                    for x in tr.minX..<tr.maxX {
                        let so = ((y - key.y * kTileSize) * kTileSize + (x - key.x * kTileSize)) * 4
                        let dO = ((y - bounds.y) * bounds.width + (x - bounds.x)) * 4
                        let m: Int = selection.map { Int($0.value(x, y)) } ?? 255
                        if m == 0 { continue }
                        for c in 0..<4 {
                            let v = Int(t.data[so + c])
                            p[dO + c] = UInt8((v * m + 127) / 255)
                            if let nt { nt.data[so + c] = UInt8((v * (255 - m) + 127) / 255) }
                        }
                    }
                }
                base.set(key, nt)
            }
        }
        if selection == nil {
            base.removeAll()
        } else {
            base.pruneTransparent(bounds.tileKeys)
        }
        pixels = px
        baseTiles = base
    }

    /// base + 変形後の画像をタイル単位で描画
    public func renderTile(key: TileKey, out: UnsafeMutablePointer<UInt8>) -> Bool {
        let base = baseTiles[key]
        if let base {
            out.update(from: base.data, count: kTilePixelCount * 4)
        } else {
            out.initialize(repeating: 0, count: kTilePixelCount * 4)
        }
        let db = destBounds.intersection(key.rect)
        if db.isEmpty { return base != nil }
        let inv = matrix.inverted()
        let sw = sourceRect.width, sh = sourceRect.height
        let ox = key.x * kTileSize, oy = key.y * kTileSize
        let k: Float = 1.0 / 255.0
        let a = Float(inv.a), b = Float(inv.b), c = Float(inv.c), d = Float(inv.d)
        let tx = Float(inv.tx) - Float(sourceRect.x) - 0.5, ty = Float(inv.ty) - Float(sourceRect.y) - 0.5
        var wrote = base != nil
        pixels.withUnsafeBufferPointer { pp in
            let src = pp.baseAddress!
            @inline(__always) func at(_ x: Int, _ y: Int) -> RGBA {
                if x < 0 || y < 0 || x >= sw || y >= sh { return .zero }
                let o = (y * sw + x) * 4
                return RGBA(Float(src[o]), Float(src[o + 1]), Float(src[o + 2]), Float(src[o + 3]))
            }
            for y in db.minY..<db.maxY {
                let py = Float(y) + 0.5
                for x in db.minX..<db.maxX {
                    let px = Float(x) + 0.5
                    let fx = a * px + c * py + tx
                    let fy = b * px + d * py + ty
                    if fx < -1 || fy < -1 || fx > Float(sw) || fy > Float(sh) { continue }
                    let x0 = Int(floor(fx)), y0 = Int(floor(fy))
                    let wx = fx - Float(x0), wy = fy - Float(y0)
                    let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * wx
                    let bot = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * wx
                    let s = (top + (bot - top) * wy) * k
                    if s.w <= 0.0001 { continue }
                    let o = out + ((y - oy) * kTileSize + (x - ox)) * 4
                    let dd = RGBA(Float(o[0]), Float(o[1]), Float(o[2]), Float(o[3])) * k
                    let r = s + dd * (1 - s.w)
                    o[0] = Compositor.toByte(r.x)
                    o[1] = Compositor.toByte(r.y)
                    o[2] = Compositor.toByte(r.z)
                    o[3] = Compositor.toByte(r.w)
                    wrote = true
                }
            }
        }
        return wrote
    }

    /// 確定後のタイルマップ
    public func resultTiles(gen: Int) -> TileMap {
        var map = baseTiles
        let full = IntRect(x: 0, y: 0, width: docWidth, height: docHeight)
        for key in destBounds.intersection(full).tileKeys {
            let t = Tile(gen: gen)
            if renderTile(key: key, out: t.data), !t.isTransparent {
                map.set(key, t)
            } else {
                map.set(key, nil)
            }
        }
        return map
    }

    public var transformedSelection: SelectionMask? {
        originalSelection?.transformed(matrix)
    }
}
