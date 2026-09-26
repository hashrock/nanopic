import CoreGraphics
import Foundation

public enum SelectionOp: Sendable {
    case replace, add, subtract, intersect
}

/// キャンバスサイズの 8bit 選択マスク（不変オブジェクト）
public final class SelectionMask: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let data: [UInt8]
    public let bounds: IntRect
    private var cachedOutline: CGPath?

    public init(width: Int, height: Int, data: [UInt8]) {
        self.width = width
        self.height = height
        self.data = data
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        data.withUnsafeBufferPointer { p in
            for y in 0..<height {
                let row = p.baseAddress! + y * width
                var rowHas = false
                for x in 0..<width where row[x] != 0 {
                    if !rowHas { minX = min(minX, x); rowHas = true }
                    maxX = max(maxX, x)
                }
                if rowHas { minY = min(minY, y); maxY = y }
            }
        }
        bounds = minX <= maxX ? IntRect(minX: minX, minY: minY, maxX: maxX + 1, maxY: maxY + 1) : .zero
    }

    public var isEmpty: Bool { bounds.isEmpty }

    @inline(__always) public func value(_ x: Int, _ y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return data[y * width + x]
    }

    // MARK: 生成

    public static func fromPath(_ path: CGPath, width: Int, height: Int, antialias: Bool = true) -> SelectionMask {
        var data = [UInt8](repeating: 0, count: width * height)
        data.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setShouldAntialias(antialias)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(path)
            ctx.fillPath()
        }
        return SelectionMask(width: width, height: height, data: data)
    }

    public static func all(width: Int, height: Int) -> SelectionMask {
        SelectionMask(width: width, height: height, data: [UInt8](repeating: 255, count: width * height))
    }

    // MARK: 演算

    /// 既存の選択（nil = 全体非選択）と新しいマスクを合成する
    public static func combine(_ current: SelectionMask?, _ new: SelectionMask, op: SelectionOp) -> SelectionMask? {
        let result: SelectionMask
        switch op {
        case .replace:
            result = new
        case .add:
            guard let cur = current else { return new.isEmpty ? nil : new }
            result = SelectionMask(width: new.width, height: new.height,
                                   data: zip(cur.data, new.data).map { max($0, $1) })
        case .subtract:
            guard let cur = current else { return nil }
            result = SelectionMask(width: new.width, height: new.height,
                                   data: zip(cur.data, new.data).map { UInt8((Int($0) * (255 - Int($1)) + 127) / 255) })
        case .intersect:
            guard let cur = current else { return nil }
            result = SelectionMask(width: new.width, height: new.height,
                                   data: zip(cur.data, new.data).map { min($0, $1) })
        }
        return result.isEmpty ? nil : result
    }

    public func inverted() -> SelectionMask? {
        let r = SelectionMask(width: width, height: height, data: data.map { 255 - $0 })
        return r.isEmpty ? nil : r
    }

    /// アフィン変換したマスク（バイリニア）
    public func transformed(_ t: CGAffineTransform) -> SelectionMask? {
        let inv = t.inverted()
        let dstBounds = IntRect.enclosing(bounds.cgRect.applying(t)).intersection(IntRect(x: 0, y: 0, width: width, height: height))
        var out = [UInt8](repeating: 0, count: width * height)
        if !dstBounds.isEmpty {
            data.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for y in dstBounds.minY..<dstBounds.maxY {
                        for x in dstBounds.minX..<dstBounds.maxX {
                            let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(inv)
                            let v = bilinear8(src.baseAddress!, width, height, Float(p.x) - 0.5, Float(p.y) - 0.5)
                            dst[y * width + x] = UInt8(min(255, v + 0.5))
                        }
                    }
                }
            }
        }
        let r = SelectionMask(width: width, height: height, data: out)
        return r.isEmpty ? nil : r
    }

    // MARK: 輪郭（選択範囲の点線表示用）

    public var outline: CGPath {
        if let c = cachedOutline { return c }
        let path = CGMutablePath()
        let b = bounds
        if !b.isEmpty {
            data.withUnsafeBufferPointer { p in
                let d = p.baseAddress!
                @inline(__always) func inside(_ x: Int, _ y: Int) -> Bool {
                    x >= 0 && y >= 0 && x < width && y < height && d[y * width + x] >= 128
                }
                // 水平エッジ
                for y in b.minY...b.maxY {
                    var runStart = -1
                    for x in b.minX...b.maxX {
                        let edge = x < b.maxX && inside(x, y - 1) != inside(x, y)
                        if edge {
                            if runStart < 0 { runStart = x }
                        } else if runStart >= 0 {
                            path.move(to: CGPoint(x: runStart, y: y))
                            path.addLine(to: CGPoint(x: x, y: y))
                            runStart = -1
                        }
                    }
                }
                // 垂直エッジ
                for x in b.minX...b.maxX {
                    var runStart = -1
                    for y in b.minY...b.maxY {
                        let edge = y < b.maxY && inside(x - 1, y) != inside(x, y)
                        if edge {
                            if runStart < 0 { runStart = y }
                        } else if runStart >= 0 {
                            path.move(to: CGPoint(x: x, y: runStart))
                            path.addLine(to: CGPoint(x: x, y: y))
                            runStart = -1
                        }
                    }
                }
            }
        }
        cachedOutline = path
        return path
    }
}

@inline(__always) func bilinear8(_ p: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ fx: Float, _ fy: Float) -> Float {
    // 範囲外（NaN を含む）は 0。Float→Int 変換のトラップを避ける
    guard fx > -2, fy > -2, fx < Float(w) + 1, fy < Float(h) + 1 else { return 0 }
    let x0 = Int(floor(fx)), y0 = Int(floor(fy))
    let tx = fx - Float(x0), ty = fy - Float(y0)
    @inline(__always) func at(_ x: Int, _ y: Int) -> Float {
        (x >= 0 && y >= 0 && x < w && y < h) ? Float(p[y * w + x]) : 0
    }
    let a = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * tx
    let b = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * tx
    return a + (b - a) * ty
}
