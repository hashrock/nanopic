import Foundation

/// 線画で囲まれた領域の分割（下塗り用）。
///
/// 参照画像を白背景に重ねた明るさで線を判定し、線以外の画素を 4 近傍でつながった領域に分ける。
/// 隙間閉じを指定すると、線を太らせてから分けるので、少し途切れた線でも領域が分かれる。
public struct RegionMap: Sendable {
    public struct Region: Sendable {
        /// 1 から。面積の大きい順
        public var id: Int
        public var area: Int
        public var bounds: IntRect
        /// 領域のいちばん内側の点（境界から最も遠い画素）。塗りつぶしの起点やラベルの位置に使える
        public var point: (x: Int, y: Int)
        /// 画像の端に接している（背景の可能性が高い）
        public var touchesEdge: Bool
    }

    public let width: Int
    public let height: Int
    /// 画素ごとの領域 ID。0 は線（または小さすぎて除いた領域）
    public let labels: [Int32]
    public let regions: [Region]
    public let gapClose: Int

    public func region(_ id: Int) -> Region? {
        id >= 1 && id <= regions.count ? regions[id - 1] : nil
    }

    /// 参照画像（premultiplied RGBA8）から作る
    /// - lineThreshold: 白背景に重ねたときの暗さ（0...1）がこれ以上なら線とみなす
    public static func build(reference ref: [UInt8], width w: Int, height h: Int,
                             lineThreshold: Float = 0.5, gapClose: Int = 0, minArea: Int = 16) -> RegionMap {
        let n = w * h
        // 線の判定
        var line = [UInt8](repeating: 0, count: n)
        let thr = Int((1 - min(max(lineThreshold, 0.01), 1)) * 255 * 3)
        for i in 0..<n {
            let a = 255 - Int(ref[i * 4 + 3])
            let lum = Int(ref[i * 4]) + Int(ref[i * 4 + 1]) + Int(ref[i * 4 + 2]) + a * 3
            if lum <= thr { line[i] = 1 }
        }
        if gapClose > 0 { FloodFill.dilate(&line, w, h, radius: gapClose, value: 1) }

        // 連結成分（4 近傍、横方向のランでまとめて塗る）
        var labels = [Int32](repeating: 0, count: n)
        var areas: [Int] = [0]
        var boxes: [IntRect] = [.zero]
        var edges: [Bool] = [false]
        var next: Int32 = 1
        var stack: [(Int, Int)] = []
        for sy in 0..<h {
            for sx in 0..<w where line[sy * w + sx] == 0 && labels[sy * w + sx] == 0 {
                let id = next
                next += 1
                var area = 0, minX = sx, maxX = sx, minY = sy, maxY = sy
                stack.append((sx, sy))
                while let (x, y) = stack.popLast() {
                    let i = y * w + x
                    if labels[i] != 0 || line[i] != 0 { continue }
                    var x0 = x, x1 = x
                    while x0 > 0 && labels[i - (x - x0) - 1] == 0 && line[i - (x - x0) - 1] == 0 { x0 -= 1 }
                    while x1 < w - 1 && labels[i + (x1 - x) + 1] == 0 && line[i + (x1 - x) + 1] == 0 { x1 += 1 }
                    for xx in x0...x1 { labels[y * w + xx] = id }
                    area += x1 - x0 + 1
                    minX = min(minX, x0); maxX = max(maxX, x1); minY = min(minY, y); maxY = max(maxY, y)
                    for ny in [y - 1, y + 1] where ny >= 0 && ny < h {
                        var xx = x0
                        while xx <= x1 {
                            let j = ny * w + xx
                            if labels[j] == 0 && line[j] == 0 {
                                stack.append((xx, ny))
                                while xx <= x1 && labels[ny * w + xx] == 0 && line[ny * w + xx] == 0 { xx += 1 }
                            } else {
                                xx += 1
                            }
                        }
                    }
                }
                areas.append(area)
                boxes.append(IntRect(minX: minX, minY: minY, maxX: maxX + 1, maxY: maxY + 1))
                edges.append(minX == 0 || minY == 0 || maxX == w - 1 || maxY == h - 1)
            }
        }

        // 小さい領域を除き、面積の大きい順に番号を振り直す
        let kept = (1..<Int(next)).filter { areas[$0] >= max(minArea, 1) }
            .sorted { areas[$0] != areas[$1] ? areas[$0] > areas[$1] : $0 < $1 }
        var remap = [Int32](repeating: 0, count: Int(next))
        for (i, old) in kept.enumerated() { remap[old] = Int32(i + 1) }
        for i in 0..<n where labels[i] != 0 { labels[i] = remap[Int(labels[i])] }

        // 境界からの距離（4 近傍のマンハッタン距離）で、各領域のいちばん内側の点を探す
        var dist = [Int32](repeating: 0, count: n)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let l = labels[i]
                if l == 0 { continue }
                let up: Int32 = y > 0 && labels[i - w] == l ? dist[i - w] : 0
                let left: Int32 = x > 0 && labels[i - 1] == l ? dist[i - 1] : 0
                dist[i] = min(up, left) + 1
            }
        }
        var best = [(d: Int32, x: Int, y: Int)](repeating: (0, 0, 0), count: kept.count + 1)
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                let i = y * w + x
                let l = labels[i]
                if l == 0 { continue }
                let down: Int32 = y < h - 1 && labels[i + w] == l ? dist[i + w] : 0
                let right: Int32 = x < w - 1 && labels[i + 1] == l ? dist[i + 1] : 0
                dist[i] = min(dist[i], min(down, right) + 1)
                if dist[i] >= best[Int(l)].d { best[Int(l)] = (dist[i], x, y) }
            }
        }

        let regions = kept.enumerated().map { i, old in
            Region(id: i + 1, area: areas[old], bounds: boxes[old], point: (best[i + 1].x, best[i + 1].y), touchesEdge: edges[old])
        }
        return RegionMap(width: w, height: h, labels: labels, regions: regions, gapClose: gapClose)
    }

    /// 領域を塗るためのマスク。線の下まで expand（+ 隙間閉じ）だけ広げるが、隣の領域にははみ出さない
    public func paint(_ id: Int, color: SIMD3<Float>, expand: Int) -> Editor.MaskPaint? {
        guard let r = region(id) else { return nil }
        let grow = max(expand, 0) + gapClose
        let b = r.bounds.insetBy(-grow).intersection(IntRect(x: 0, y: 0, width: width, height: height))
        let bw = b.width, bh = b.height
        var local = [UInt8](repeating: 0, count: bw * bh)
        let target = Int32(id)
        for y in 0..<bh {
            for x in 0..<bw where labels[(y + b.minY) * width + x + b.minX] == target { local[y * bw + x] = 255 }
        }
        if grow > 0 {
            var grown = local
            FloodFill.dilate(&grown, bw, bh, radius: grow, value: 255)
            for y in 0..<bh {
                for x in 0..<bw where grown[y * bw + x] != 0 && labels[(y + b.minY) * width + x + b.minX] == 0 {
                    local[y * bw + x] = 255
                }
            }
        }
        let ox = b.minX, oy = b.minY
        return Editor.MaskPaint(bounds: b, color: color) { x, y in local[(y - oy) * bw + (x - ox)] }
    }
}
