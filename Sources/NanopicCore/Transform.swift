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
    /// フローティング中の移動・変形の履歴（Undo 用）
    public var history: [TransformParams] = []
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

/// 変形枠の、指で掴める場所
public enum TransformHandle: Equatable, Sendable {
    case corner(Int)   // 0:左上 1:右上 2:右下 3:左下
    case edge(Int)     // 0:上 1:右 2:下 3:左
    case inside
    case rotate
}

extension FloatingTransform {
    /// ハンドルの位置（transform を掛けた座標）
    public func handlePoints(_ transform: CGAffineTransform) -> [(TransformHandle, CGPoint)] {
        let c = corners.map { $0.applying(transform) }
        var out: [(TransformHandle, CGPoint)] = []
        for i in 0..<4 { out.append((.corner(i), c[i])) }
        for i in 0..<4 {
            let a = c[i], b = c[(i + 1) % 4]
            out.append((.edge(i), CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)))
        }
        return out
    }

    /// point（transform を掛けた座標）で掴むハンドル。枠の外なら回転
    public func hitHandle(_ point: CGPoint, transform: CGAffineTransform, radius: CGFloat) -> TransformHandle {
        for (h, p) in handlePoints(transform) where hypot(p.x - point.x, p.y - point.y) < radius {
            return h
        }
        let poly = CGMutablePath()
        poly.addLines(between: corners.map { $0.applying(transform) })
        poly.closeSubpath()
        return poly.contains(point) ? .inside : .rotate
    }

    /// ハンドルを startCanvas から current までドラッグしたときの変形（キャンバス座標）
    public func draggedParams(handle: TransformHandle, startCanvas: CGPoint, startParams: TransformParams,
                              current cp: CGPoint, constrain: Bool) -> TransformParams {
        var p = startParams
        let c0 = center
        let center = CGPoint(x: c0.x + startParams.tx, y: c0.y + startParams.ty)
        switch handle {
        case .inside:
            p.tx += Double(cp.x - startCanvas.x)
            p.ty += Double(cp.y - startCanvas.y)
        case .rotate:
            let a0 = atan2(startCanvas.y - center.y, startCanvas.x - center.x)
            let a1 = atan2(cp.y - center.y, cp.x - center.x)
            var r = startParams.rotation + Double(a1 - a0)
            if constrain {
                let step = Double.pi / 12
                r = (r / step).rounded() * step
            }
            p.rotation = r
        case .corner, .edge:
            // 反対側を固定して拡大縮小
            let w = Double(sourceRect.width), h = Double(sourceRect.height)
            var sgn: (Double, Double)
            var useX = true, useY = true
            switch handle {
            case .corner(0): sgn = (-1, -1)
            case .corner(1): sgn = (1, -1)
            case .corner(2): sgn = (1, 1)
            case .corner(3): sgn = (-1, 1)
            case .edge(0): sgn = (0, -1); useX = false
            case .edge(1): sgn = (1, 0); useY = false
            case .edge(2): sgn = (0, 1); useX = false
            default: sgn = (-1, 0); useY = false
            }
            let rot = startParams.rotation
            let cosR = cos(rot), sinR = sin(rot)
            func toWorld(_ lx: Double, _ ly: Double) -> (Double, Double) {
                (Double(center.x) + lx * cosR - ly * sinR, Double(center.y) + lx * sinR + ly * cosR)
            }
            // 固定点（反対側）の現在位置
            let oppLocal = (-sgn.0 * w / 2 * startParams.sx, -sgn.1 * h / 2 * startParams.sy)
            let anchor = toWorld(oppLocal.0, oppLocal.1)
            let dx = Double(cp.x) - anchor.0, dy = Double(cp.y) - anchor.1
            let lx = dx * cosR + dy * sinR
            let ly = -dx * sinR + dy * cosR
            var sx = useX ? lx / (sgn.0 * w) : startParams.sx
            var sy = useY ? ly / (sgn.1 * h) : startParams.sy
            if constrain && useX && useY {
                let s = max(abs(sx), abs(sy))
                sx = s * (sx < 0 ? -1 : 1)
                sy = s * (sy < 0 ? -1 : 1)
            }
            if abs(sx) < 0.001 { sx = 0.001 }
            if abs(sy) < 0.001 { sy = 0.001 }
            p.sx = sx
            p.sy = sy
            // 新しい中心 = 固定点 + R·(S·(sgn·size/2))
            let half = (useX ? sgn.0 * w / 2 * sx : 0, useY ? sgn.1 * h / 2 * sy : 0)
            let fixedLocalNew = (useX ? -half.0 : oppLocal.0, useY ? -half.1 : oppLocal.1)
            // anchor = newCenter + R·fixedLocalNew
            let nc = (anchor.0 - (fixedLocalNew.0 * cosR - fixedLocalNew.1 * sinR),
                      anchor.1 - (fixedLocalNew.0 * sinR + fixedLocalNew.1 * cosR))
            p.tx = nc.0 - Double(c0.x)
            p.ty = nc.1 - Double(c0.y)
        }
        return p
    }
}
