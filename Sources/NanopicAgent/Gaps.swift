import Foundation
import NanopicCore

/// 線画の開いた所（線の端が近くの線に届いていない所）を探す
public struct LineGap: Sendable {
    public var id: Int
    public var from: (x: Int, y: Int)
    public var to: (x: Int, y: Int)
    public var length: Double {
        hypot(Double(to.x - from.x), Double(to.y - from.y))
    }
}

public enum GapFinder {
    /// 参照画像（premultiplied RGBA8）の線を細線化し、端点から maxDistance px 以内で進む向きにある線への線分を返す（短い順）
    public static func find(reference ref: [UInt8], width w: Int, height h: Int,
                            lineThreshold: Float = 0.5, maxDistance: Int = 40) -> [LineGap] {
        let n = w * h
        let thr = Int((1 - min(max(lineThreshold, 0.01), 1)) * 255 * 3)
        var line = [UInt8](repeating: 0, count: n)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for i in 0..<n {
            let a = 255 - Int(ref[i * 4 + 3])
            if Int(ref[i * 4]) + Int(ref[i * 4 + 1]) + Int(ref[i * 4 + 2]) + a * 3 <= thr {
                line[i] = 1
                let x = i % w, y = i / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return [] }
        let skel = thin(line, w, h, IntRect(minX: max(minX - 1, 0), minY: max(minY - 1, 0), maxX: min(maxX + 2, w), maxY: min(maxY + 2, h)))

        @inline(__always) func at(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && skel[y * w + x] != 0 }
        let dirs = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)]

        var gaps: [LineGap] = []
        for y in minY...maxY {
            for x in minX...maxX where at(x, y) {
                let nb = dirs.filter { at(x + $0.0, y + $0.1) }
                guard nb.count == 1 else { continue }
                // 端点から線をたどって、向きと、自分の線の近くの画素を集める
                var path = [(x, y)]
                var prev = (x, y), cur = (x + nb[0].0, y + nb[0].1)
                for _ in 0..<(maxDistance * 2) {
                    path.append(cur)
                    let next = dirs.map { (cur.0 + $0.0, cur.1 + $0.1) }
                        .filter { c in at(c.0, c.1) && c != prev && !path.suffix(4).contains(where: { $0 == c }) }
                    guard let nx = next.first else { break }
                    prev = cur
                    cur = nx
                }
                guard path.count >= 12 else { continue } // まつげやそばかすのような短い線は無視
                let back = path[min(path.count - 1, 10)]
                var dx = Double(x - back.0), dy = Double(y - back.1)
                let len = hypot(dx, dy)
                guard len > 0 else { continue }
                dx /= len; dy /= len
                // 自分の線（たどった部分の近く）を除いて、進む向きの前方にある線で一番近い点
                var best: (d: Double, x: Int, y: Int)?
                let r = maxDistance
                for ty in max(0, y - r)...min(h - 1, y + r) {
                    for tx in max(0, x - r)...min(w - 1, x + r) where line[ty * w + tx] != 0 {
                        let vx = Double(tx - x), vy = Double(ty - y)
                        let d = hypot(vx, vy)
                        if d < 3 || d > Double(r) { continue }
                        // 前方 ±60° 以内
                        if (vx * dx + vy * dy) / d < 0.5 { continue }
                        if path.contains(where: { abs($0.0 - tx) <= 4 && abs($0.1 - ty) <= 4 }) { continue }
                        // 向きからずれるほど遠いとみなす
                        let score = d * (2 - (vx * dx + vy * dy) / d)
                        if best == nil || score < best!.d { best = (score, tx, ty) }
                    }
                }
                guard let b = best else { continue }
                // 線分の途中がほぼ線の上なら、すでに閉じている
                let steps = Int(hypot(Double(b.x - x), Double(b.y - y)))
                var open = 0
                for k in 1..<max(steps, 2) {
                    let px = x + (b.x - x) * k / max(steps, 1), py = y + (b.y - y) * k / max(steps, 1)
                    if line[py * w + px] == 0 { open += 1 }
                }
                if open < 2 { continue }
                gaps.append(LineGap(id: 0, from: (x, y), to: (b.x, b.y)))
            }
        }
        // 向かい合う端点どうしの重複を除く
        var out: [LineGap] = []
        for g in gaps.sorted(by: { $0.length < $1.length }) {
            let dup = out.contains { o in
                (abs(o.from.x - g.to.x) <= 6 && abs(o.from.y - g.to.y) <= 6 && abs(o.to.x - g.from.x) <= 6 && abs(o.to.y - g.from.y) <= 6)
                    || (abs(o.from.x - g.from.x) <= 2 && abs(o.from.y - g.from.y) <= 2)
            }
            if !dup { out.append(g) }
        }
        for i in out.indices { out[i].id = i + 1 }
        return out
    }

    /// Zhang-Suen の細線化（rect の中だけ）
    static func thin(_ src: [UInt8], _ w: Int, _ h: Int, _ rect: IntRect) -> [UInt8] {
        var m = src
        var changed = true
        var remove: [Int] = []
        while changed {
            changed = false
            for pass in 0..<2 {
                remove.removeAll(keepingCapacity: true)
                for y in max(rect.minY, 1)..<min(rect.maxY, h - 1) {
                    for x in max(rect.minX, 1)..<min(rect.maxX, w - 1) {
                        let i = y * w + x
                        if m[i] == 0 { continue }
                        let p2 = m[i - w], p3 = m[i - w + 1], p4 = m[i + 1], p5 = m[i + w + 1]
                        let p6 = m[i + w], p7 = m[i + w - 1], p8 = m[i - 1], p9 = m[i - w - 1]
                        let b = Int(p2) + Int(p3) + Int(p4) + Int(p5) + Int(p6) + Int(p7) + Int(p8) + Int(p9)
                        if b < 2 || b > 6 { continue }
                        let seq = [p2, p3, p4, p5, p6, p7, p8, p9, p2]
                        var a = 0
                        for k in 0..<8 where seq[k] == 0 && seq[k + 1] == 1 { a += 1 }
                        if a != 1 { continue }
                        if pass == 0 {
                            if p2 * p4 * p6 != 0 || p4 * p6 * p8 != 0 { continue }
                        } else {
                            if p2 * p4 * p8 != 0 || p2 * p6 * p8 != 0 { continue }
                        }
                        remove.append(i)
                    }
                }
                if !remove.isEmpty {
                    changed = true
                    for i in remove { m[i] = 0 }
                }
            }
        }
        return m
    }
}
