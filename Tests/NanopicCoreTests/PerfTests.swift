import XCTest
@testable import NanopicCore

final class PerfTests: XCTestCase {
    func testPerformanceReport() throws {
        guard ProcessInfo.processInfo.environment["NANOPIC_PERF"] != nil else { throw XCTSkip("NANOPIC_PERF 未設定") }
        let w = 4000, h = 3000
        let ed = Editor(width: w, height: h)
        // 塗りつぶしたレイヤーを 10 枚（様々な合成モード）
        var doc = ed.doc
        let modes: [BlendMode] = [.normal, .multiply, .screen, .overlay, .normal, .softLight, .normal, .colorDodge, .normal, .hue]
        for (i, m) in modes.enumerated() {
            var n = LayerNode(name: "L\(i)")
            n.tiles = TileMap.filled(width: w, height: h, rgba: (UInt8(20 * i), 100, 128, 200), gen: 0)
            n.blendMode = m
            doc.layers.append(n)
        }
        doc.activeLayerID = doc.layers.last!.id
        ed.load(doc, url: nil)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        var t0 = Date()
        buf.withUnsafeMutableBufferPointer { p in
            Compositor.composite(ed.doc, rect: ed.doc.bounds, into: p.baseAddress!, bufferWidth: w)
        }
        print(String(format: "PERF full composite 4000x3000 x12 layers: %.1f ms", Date().timeIntervalSince(t0) * 1000))

        // 大きいブラシのストローク（300px, 1 秒分 240 サンプル）
        ed.activeBrushIndex = 0
        var b = ed.currentBrush; b.size = 300; ed.currentBrush = b
        t0 = Date()
        ed.beginStroke(StrokeInput(x: 100, y: 100, pressure: 1, time: 0), usePressure: true, zoom: 1)
        var frameTimes: [Double] = []
        for i in 1...240 {
            ed.continueStroke(StrokeInput(x: 100 + Double(i) * 12, y: 100 + Double(i) * 8, pressure: 1, time: Double(i) / 240))
            // 4 サンプルごとに表示更新（120Hz 相当）
            if i % 4 == 0 {
                let f0 = Date()
                let r = ed.takeDirtyRect()
                buf.withUnsafeMutableBufferPointer { p in
                    Compositor.composite(ed.doc, rect: r, options: ed.compositeOptions(), into: p.baseAddress!, bufferWidth: w)
                }
                frameTimes.append(Date().timeIntervalSince(f0) * 1000)
            }
        }
        ed.endStroke()
        let total = Date().timeIntervalSince(t0) * 1000
        print(String(format: "PERF 300px stroke 240 samples: total %.1f ms, frame composite avg %.2f ms max %.2f ms",
                     total, frameTimes.reduce(0, +) / Double(frameTimes.count), frameTimes.max()!))

        t0 = Date()
        ed.fillSettings.reference = .allLayers
        ed.fill(atX: 2000, y: 1500)
        print(String(format: "PERF fill (all layers ref): %.1f ms", Date().timeIntervalSince(t0) * 1000))

        t0 = Date()
        let data = try PSD.write(ed.doc)
        print(String(format: "PERF PSD write: %.1f ms (%d MB)", Date().timeIntervalSince(t0) * 1000, data.count / 1_000_000))
        t0 = Date()
        _ = try PSD.read(data)
        print(String(format: "PERF PSD read: %.1f ms", Date().timeIntervalSince(t0) * 1000))
    }
}
