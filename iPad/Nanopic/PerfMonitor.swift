import Foundation
import NanopicUI
import QuartzCore
import UIKit

/// ストロークごとの性能とペン入力の記録。メニューの「性能を計測」でオンにする。
/// 画面左上に要約を出し、詳しい CSV を Library/Caches/nanopic-perf/ に書く。
final class PadPerfMonitor {
    private struct Sample {
        var t: Double, x: Double, y: Double, force: Double, altitude: Double
        var estimated: Int, expecting: Int, updateIndex: Int
        var group: Int
    }

    private var active = false
    private var meta = ""
    private var samples: [Sample] = []
    private var finalForce: [Int: Double] = [:]
    private var frames: [RenderTiming] = []
    private var handlerMs: [Double] = []
    private var group = 0
    private var beginMs = 0.0
    private var strokeNumber = 0
    private let runID = Int(Date().timeIntervalSince1970)
    var onSummary: ((String) -> Void)?

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("nanopic-perf")
    }

    func begin(meta: String, beginMs: Double) {
        active = true
        self.meta = meta
        self.beginMs = beginMs
        samples.removeAll(keepingCapacity: true)
        finalForce.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true)
        handlerMs.removeAll(keepingCapacity: true)
        group = 0
    }

    func record(_ t: UITouch, in view: UIView) {
        guard active else { return }
        let p = t.preciseLocation(in: view)
        samples.append(Sample(t: t.timestamp, x: Double(p.x), y: Double(p.y), force: Double(t.force),
                              altitude: Double(t.altitudeAngle),
                              estimated: t.estimatedProperties.rawValue,
                              expecting: t.estimatedPropertiesExpectingUpdates.rawValue,
                              updateIndex: t.estimationUpdateIndex?.intValue ?? -1, group: group))
    }

    func handler(ms: Double) {
        guard active else { return }
        handlerMs.append(ms)
        group += 1
    }

    func estimatedUpdate(_ t: UITouch) {
        guard let i = t.estimationUpdateIndex?.intValue else { return }
        finalForce[i] = Double(t.force)
    }

    func frame(_ f: RenderTiming) {
        guard active else { return }
        frames.append(f)
        if frames.count % 30 == 0, frames.count >= 2 {
            let span = frames[frames.count - 1].start - frames[frames.count - 30].start
            if span > 0 { onSummary?(String(format: "描画中 %.0f fps", 29 / span)) }
        }
    }

    func cancel() { active = false }

    func end(endMs: Double, dabs: Int) {
        guard active else { return }
        // 筆圧の確定値は少し遅れて届くので、待ってから書き出す
        let begun = (meta: meta, beginMs: beginMs, samples: samples, handlerMs: handlerMs)
        let captured = frames
        active = false
        strokeNumber += 1
        let number = strokeNumber
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            let text = summary(meta: begun.meta, samples: begun.samples, frames: captured, handlerMs: begun.handlerMs,
                               beginMs: begun.beginMs, endMs: endMs, dabs: dabs)
            onSummary?(text)
            let forces = finalForce
            let dir = Self.directory
            let base = "\(runID)-\(number)"
            DispatchQueue.global(qos: .utility).async {
                Self.write(base: base, dir: dir, summary: text, samples: begun.samples, finalForce: forces, frames: captured)
            }
        }
    }

    private func stats(_ v: [Double]) -> (avg: Double, p95: Double, max: Double) {
        guard !v.isEmpty else { return (0, 0, 0) }
        let s = v.sorted()
        return (s.reduce(0, +) / Double(s.count), s[min(s.count - 1, Int(Double(s.count) * 0.95))], s[s.count - 1])
    }

    private func line(_ name: String, _ v: [Double]) -> String {
        let s = stats(v)
        return String(format: "%@ avg %.1f p95 %.1f max %.1f ms", name, s.avg, s.p95, s.max)
    }

    private func summary(meta: String, samples: [Sample], frames: [RenderTiming], handlerMs: [Double],
                         beginMs: Double, endMs: Double, dabs: Int) -> String {
        var out = [meta]
        if let a = samples.first, let b = samples.last, b.t > a.t {
            let forceBit = UITouch.Properties.force.rawValue
            let est = samples.filter { $0.estimated & forceBit != 0 }.count
            out.append(String(format: "入力 %d点 %.0fHz 推定筆圧 %.0f%% ダブ %d", samples.count, Double(samples.count - 1) / (b.t - a.t),
                              Double(est) * 100 / Double(samples.count), dabs))
        }
        if frames.count >= 2 {
            let intervals = zip(frames.dropFirst(), frames).map { ($0.start - $1.start) * 1000 }
            out.append(String(format: "表示 %.0f fps", Double(frames.count - 1) / (frames[frames.count - 1].start - frames[0].start)))
            out.append(line("間隔", intervals))
            let dirty = frames.map { Double($0.dirtyWidth * $0.dirtyHeight) / 1_000_000 }
            out.append(String(format: "更新領域 avg %.2f max %.2f Mpx", stats(dirty).avg, stats(dirty).max))
        }
        out.append(line("入力処理", handlerMs))
        out.append(line("合成", frames.map(\.compositeMs)))
        out.append(line("GPU待ち", frames.map(\.waitMs)))
        out.append(line("転送", frames.map(\.uploadMs)))
        out.append(line("drawable", frames.map(\.drawableMs)))
        out.append(line("draw全体", frames.map(\.totalMs)))
        out.append(line("GPU", frames.map(\.gpuMs)))
        out.append(String(format: "開始 %.1f ms / 確定 %.1f ms", beginMs, endMs))
        return out.joined(separator: "\n")
    }

    private static func write(base: String, dir: URL, summary: String, samples: [Sample], finalForce: [Int: Double], frames: [RenderTiming]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = "t,x,y,force,finalForce,altitude,estimated,expecting,updateIndex,group\n"
        for v in samples {
            let f = finalForce[v.updateIndex].map { String($0) } ?? ""
            s += "\(v.t),\(v.x),\(v.y),\(v.force),\(f),\(v.altitude),\(v.estimated),\(v.expecting),\(v.updateIndex),\(v.group)\n"
        }
        try? s.write(to: dir.appendingPathComponent("\(base)-samples.csv"), atomically: true, encoding: .utf8)
        var fr = "start,dirtyW,dirtyH,compositeMs,waitMs,uploadMs,drawableMs,totalMs,gpuMs\n"
        for f in frames {
            fr += "\(f.start),\(f.dirtyWidth),\(f.dirtyHeight),\(f.compositeMs),\(f.waitMs),\(f.uploadMs),\(f.drawableMs),\(f.totalMs),\(f.gpuMs)\n"
        }
        try? fr.write(to: dir.appendingPathComponent("\(base)-frames.csv"), atomically: true, encoding: .utf8)
        try? summary.write(to: dir.appendingPathComponent("\(base)-summary.txt"), atomically: true, encoding: .utf8)
    }
}
