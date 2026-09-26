import Foundation

public enum FillReference: String, CaseIterable, Codable, Sendable {
    case currentLayer
    case allLayers
    case referenceLayers

    public var displayName: String {
        switch self {
        case .currentLayer: return "編集レイヤーのみ参照"
        case .allLayers: return "他レイヤーを参照"
        case .referenceLayers: return "参照レイヤーを参照"
        }
    }
}

public struct FillSettings: Codable, Equatable, Sendable {
    public var reference: FillReference = .allLayers
    /// 色の許容誤差 0...1
    public var tolerance: Float = 0.1
    /// 領域拡縮 (px)
    public var expand: Int = 1
    /// 隙間閉じ (px)
    public var gapClose: Int = 0
    /// 塗りつぶし時にアルファを比較するか（透明部分を境界として扱う）
    public var contiguous = true
    public init() {}
}

public enum FloodFill {
    /// 参照画像（premultiplied RGBA8）から領域マスク (0/255) を作る
    public static func mask(reference ref: UnsafePointer<UInt8>, width w: Int, height h: Int,
                            seedX: Int, seedY: Int, tolerance: Float, contiguous: Bool = true,
                            gapClose: Int = 0) -> (mask: [UInt8], bounds: IntRect) {
        var mask = [UInt8](repeating: 0, count: w * h)
        guard seedX >= 0, seedY >= 0, seedX < w, seedY < h else { return (mask, .zero) }
        let so = (seedY * w + seedX) * 4
        let seed = (Int(ref[so]), Int(ref[so + 1]), Int(ref[so + 2]), Int(ref[so + 3]))
        let thr = Int(tolerance * 255)

        // 領域内判定マップ
        var inside = [UInt8](repeating: 0, count: w * h)
        inside.withUnsafeMutableBufferPointer { ins in
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    let d = max(abs(Int(ref[o]) - seed.0), abs(Int(ref[o + 1]) - seed.1),
                                abs(Int(ref[o + 2]) - seed.2), abs(Int(ref[o + 3]) - seed.3))
                    ins[y * w + x] = d <= thr ? 1 : 0
                }
            }
        }
        // 隙間閉じ: 境界（領域外）を膨張させてから塗り、後で戻す
        var walls: [UInt8]? = nil
        if gapClose > 0 {
            var outside = inside.map { 1 - $0 }
            dilate(&outside, w, h, radius: gapClose, value: 1)
            walls = outside
        }
        var minX = w, minY = h, maxX = -1, maxY = -1
        if !contiguous {
            for i in 0..<(w * h) where inside[i] != 0 {
                mask[i] = 255
                let x = i % w, y = i / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        } else {
            inside.withUnsafeBufferPointer { ins in
                mask.withUnsafeMutableBufferPointer { m in
                    let seedIdx = seedY * w + seedX
                    if ins[seedIdx] == 0 { return }
                    var stack: [(Int, Int)] = [(seedX, seedY)]
                    // 種の位置が壁に埋もれた場合は隙間閉じを使わない
                    let useWalls = walls.map { $0[seedIdx] == 0 } ?? false
                    @inline(__always) func ok2(_ x: Int, _ y: Int) -> Bool {
                        let i = y * w + x
                        if m[i] != 0 || ins[i] == 0 { return false }
                        if useWalls, let walls, walls[i] != 0 { return false }
                        return true
                    }
                    while let (sx, sy) = stack.popLast() {
                        if !ok2(sx, sy) { continue }
                        var x0 = sx
                        while x0 > 0 && ok2(x0 - 1, sy) { x0 -= 1 }
                        var x1 = sx
                        while x1 < w - 1 && ok2(x1 + 1, sy) { x1 += 1 }
                        for x in x0...x1 { m[sy * w + x] = 255 }
                        minX = min(minX, x0); maxX = max(maxX, x1); minY = min(minY, sy); maxY = max(maxY, sy)
                        for ny in [sy - 1, sy + 1] where ny >= 0 && ny < h {
                            var x = x0
                            while x <= x1 {
                                if ok2(x, ny) {
                                    stack.append((x, ny))
                                    while x <= x1 && ok2(x, ny) { x += 1 }
                                } else {
                                    x += 1
                                }
                            }
                        }
                    }
                }
            }
            if let _ = walls, maxX >= 0 {
                // 壁で削られた分を元の領域内で戻す
                var grown = mask
                dilate(&grown, w, h, radius: gapClose, value: 255)
                for i in 0..<(w * h) where grown[i] != 0 && inside[i] != 0 {
                    mask[i] = 255
                }
                minX = max(0, minX - gapClose); minY = max(0, minY - gapClose)
                maxX = min(w - 1, maxX + gapClose); maxY = min(h - 1, maxY + gapClose)
            }
        }
        if maxX < 0 { return (mask, .zero) }
        return (mask, IntRect(minX: minX, minY: minY, maxX: maxX + 1, maxY: maxY + 1))
    }

    /// 正方形の膨張（0 以外を value に広げる）
    public static func dilate(_ m: inout [UInt8], _ w: Int, _ h: Int, radius r: Int, value: UInt8) {
        guard r > 0 else { return }
        var tmp = [UInt8](repeating: 0, count: w * h)
        // 横方向
        m.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    var left = [Int](repeating: 0, count: w)
                    var d = 1 << 30
                    for x in 0..<w {
                        d = src[y * w + x] != 0 ? 0 : d + 1
                        left[x] = d
                    }
                    d = 1 << 30
                    for x in stride(from: w - 1, through: 0, by: -1) {
                        d = src[y * w + x] != 0 ? 0 : d + 1
                        dst[y * w + x] = min(left[x], d) <= r ? value : 0
                    }
                }
            }
        }
        // 縦方向
        m.withUnsafeMutableBufferPointer { dst in
            tmp.withUnsafeBufferPointer { src in
                DispatchQueue.concurrentPerform(iterations: w) { x in
                    var up = [Int](repeating: 0, count: h)
                    var d = 1 << 30
                    for y in 0..<h {
                        d = src[y * w + x] != 0 ? 0 : d + 1
                        up[y] = d
                    }
                    d = 1 << 30
                    for y in stride(from: h - 1, through: 0, by: -1) {
                        d = src[y * w + x] != 0 ? 0 : d + 1
                        dst[y * w + x] = min(up[y], d) <= r ? value : 0
                    }
                }
            }
        }
    }

    /// 収縮
    public static func erode(_ m: inout [UInt8], _ w: Int, _ h: Int, radius r: Int) {
        guard r > 0 else { return }
        var inv = m.map { $0 == 0 ? UInt8(255) : 0 }
        dilate(&inv, w, h, radius: r, value: 255)
        for i in 0..<(w * h) { m[i] = inv[i] != 0 ? 0 : 255 }
    }
}
