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

/// 塗り残し（下塗りのレイヤーで塗られていない、線以外の小さなすき間）
public struct Leftover {
    public var bounds: IntRect
    public var area: Int
    public var color: SIMD3<Float>
    public var paint: Editor.MaskPaint
}

extension RegionMap {
    /// flat: 下塗りのレイヤー、line: 線画（どちらも premultiplied RGBA8、キャンバス全体）。
    /// 面積が maxArea 以下のすき間を見つけ、接している塗りの色（なければ線を挟んだ近くの色）で塗るマスクを返す
    public static func leftovers(flat: [UInt8], line ref: [UInt8], width w: Int, height h: Int,
                                 lineThreshold: Float = 0.5, maxArea: Int = 400, expand: Int = 2) -> [Leftover] {
        let n = w * h
        let thr = Int((1 - min(max(lineThreshold, 0.01), 1)) * 255 * 3)
        var line = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let a = 255 - Int(ref[i * 4 + 3])
            line[i] = Int(ref[i * 4]) + Int(ref[i * 4 + 1]) + Int(ref[i * 4 + 2]) + a * 3 <= thr
        }
        @inline(__always) func filled(_ i: Int) -> Bool { flat[i * 4 + 3] >= 128 }
        func color(_ i: Int) -> SIMD3<Float> {
            let a = Float(flat[i * 4 + 3])
            return SIMD3(Float(flat[i * 4]) / a, Float(flat[i * 4 + 1]) / a, Float(flat[i * 4 + 2]) / a)
        }
        func key(_ i: Int) -> Int { Int(flat[i * 4]) << 16 | Int(flat[i * 4 + 1]) << 8 | Int(flat[i * 4 + 2]) }

        var seen = [Bool](repeating: false, count: n)
        var out: [Leftover] = []
        for start in 0..<n where !seen[start] && !line[start] && !filled(start) {
            // すき間を 4 近傍で集める（maxArea を超えたら打ち切って捨てる）
            var comp: [Int] = []
            var stack = [start]
            seen[start] = true
            var tooBig = false, edge = false
            while let i = stack.popLast() {
                comp.append(i)
                if comp.count > maxArea { tooBig = true }
                let x = i % w, y = i / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { edge = true }
                for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1]
                where j >= 0 && !seen[j] && !line[j] && !filled(j) {
                    seen[j] = true
                    stack.append(j)
                }
            }
            if tooBig || edge { continue }
            // 色: 直接接している塗り → なければ線をたどって 12px 以内で最初に届いた塗り（多いもの）
            var votes: [Int: (count: Int, index: Int)] = [:]
            for i in comp {
                let x = i % w, y = i / w
                for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1] where j >= 0 && filled(j) {
                    votes[key(j), default: (0, j)].count += 1
                }
            }
            if votes.isEmpty {
                var dist: [Int: Int] = [:]
                var queue = comp
                for i in comp { dist[i] = 0 }
                var head = 0
                while head < queue.count {
                    let i = queue[head]; head += 1
                    let d = dist[i]!
                    if d >= 12 { continue }
                    let x = i % w, y = i / w
                    for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1] where j >= 0 && dist[j] == nil {
                        dist[j] = d + 1
                        if filled(j) { votes[key(j), default: (0, j)].count += 1 } else if line[j] { queue.append(j) }
                    }
                }
            }
            guard let best = votes.max(by: { $0.value.count < $1.value.count || ($0.value.count == $1.value.count && $0.key > $1.key) }) else { continue }
            // マスク: すき間と、そこから expand px 以内の線の画素
            var minX = w, minY = h, maxX = 0, maxY = 0
            for i in comp { minX = min(minX, i % w); maxX = max(maxX, i % w); minY = min(minY, i / w); maxY = max(maxY, i / w) }
            let b = IntRect(minX: minX, minY: minY, maxX: maxX + 1, maxY: maxY + 1).insetBy(-expand).intersection(IntRect(x: 0, y: 0, width: w, height: h))
            var local = [UInt8](repeating: 0, count: b.width * b.height)
            for i in comp { local[(i / w - b.minY) * b.width + (i % w - b.minX)] = 255 }
            if expand > 0 {
                var grown = local
                FloodFill.dilate(&grown, b.width, b.height, radius: expand, value: 255)
                for y in 0..<b.height {
                    for x in 0..<b.width where grown[y * b.width + x] != 0 && line[(y + b.minY) * w + x + b.minX] { local[y * b.width + x] = 255 }
                }
            }
            let c = color(best.value.index)
            let bw = b.width, ox = b.minX, oy = b.minY
            out.append(Leftover(bounds: IntRect(minX: minX, minY: minY, maxX: maxX + 1, maxY: maxY + 1), area: comp.count, color: c,
                                paint: Editor.MaskPaint(bounds: b, color: c) { x, y in local[(y - oy) * bw + (x - ox)] }))
        }
        return out
    }
}
