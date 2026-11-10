import XCTest
@testable import NanopicCore

final class StrokeFilterTests: XCTestCase {
    /// 予測の仮表示は予測点まで届き、実際に描く結果を変えないこと
    func testPreviewDoesNotChangeStroke() {
        func run(preview: Bool) -> ([Dab], [(Double, Double)]?) {
            var brush = BrushSettings(name: "test")
            brush.size = 8
            brush.spacing = 0.1
            brush.smoothing = 0.3
            let engine = StrokeEngine(brush: brush, usePressure: true, zoom: 1)
            var dabs: [Dab] = []
            engine.emit = { dabs.append($0) }
            var last: [(Double, Double)]?
            engine.begin(StrokeInput(x: 0, y: 0, pressure: 0.5, time: 0))
            for i in 1...40 {
                engine.add(StrokeInput(x: Double(i) * 3, y: 0, pressure: 0.5, time: Double(i) / 240))
                if preview {
                    let t = Double(i) / 240
                    last = engine.previewPoints(predicted: [StrokeInput(x: Double(i) * 3 + 30, y: 0, pressure: 0.5, time: t + 0.01)])?.points
                }
            }
            engine.end()
            return (dabs, last)
        }
        let (plain, _) = run(preview: false)
        let (previewed, points) = run(preview: true)
        XCTAssertEqual(plain.map(\.x), previewed.map(\.x))
        XCTAssertEqual(plain.map(\.radius), previewed.map(\.radius))
        let tip = try! XCTUnwrap(points?.last)
        XCTAssertGreaterThan(tip.0, 40 * 3 - 15, "線の先は入力点の近くまで伸びる")
    }

    /// 右下の角をドラッグして 2 倍にすると、左上の角は動かないこと
    func testCornerDragKeepsOppositeCorner() throws {
        let ed = Editor(width: 400, height: 400)
        var doc = ed.doc
        var n = LayerNode(name: "L")
        n.tiles = TileMap.filled(width: 400, height: 400, rgba: (10, 20, 30, 255), gen: 0)
        doc.layers.append(n)
        doc.activeLayerID = n.id
        ed.load(doc, url: nil)
        ed.select(path: CGPath(rect: CGRect(x: 100, y: 100, width: 50, height: 50), transform: nil), op: .replace)
        XCTAssertTrue(ed.beginTransform())
        let f = try XCTUnwrap(ed.floating)
        let before = f.corners[0]
        let p = f.draggedParams(handle: .corner(2), startCanvas: f.corners[2], startParams: f.params,
                                current: CGPoint(x: before.x + 100, y: before.y + 100), constrain: false)
        ed.updateTransform(p)
        XCTAssertEqual(p.sx, 2, accuracy: 0.001)
        XCTAssertEqual(f.corners[0].x, before.x, accuracy: 0.001)
        XCTAssertEqual(f.corners[0].y, before.y, accuracy: 0.001)
    }

    /// 既定の設定なら、一定の筆圧で描いた短い線（0.2 秒）の序盤で太さがほぼ最大になること
    func testEntryReachesPeakEarly() {
        var brush = BrushSettings(name: "test")
        brush.size = 8
        brush.spacing = 0.1
        brush.smoothing = 0
        let engine = StrokeEngine(brush: brush, usePressure: true, zoom: 1)
        var dabs: [Dab] = []
        engine.emit = { dabs.append($0) }
        engine.begin(StrokeInput(x: 0, y: 0, pressure: 0.6, time: 0))
        for i in 1...48 { engine.add(StrokeInput(x: Double(i) * 6, y: 0, pressure: 0.6, time: Double(i) / 240)) }
        engine.end()
        let peak = dabs.map(\.radius).max()!
        let reached = dabs.first { $0.radius >= peak * 0.9 }!
        print("ENTRY 90% at \(reached.x) of 288")
        XCTAssertLessThan(reached.x, 288 * 0.3)
    }

    /// 手ブレ補正をかけても、円は（少し小さくなるだけで）円のままであること
    func testStabilizerKeepsCircleRound() {
        for smoothing: Float in [0.3, 0.6, 1.0] {
            var brush = BrushSettings(name: "test")
            brush.size = 4
            brush.spacing = 0.1
            brush.smoothing = smoothing
            let engine = StrokeEngine(brush: brush, usePressure: false, zoom: 1)
            var dabs: [Dab] = []
            engine.emit = { dabs.append($0) }

            let radius = 300.0, center = 500.0, period = 1.5, rate = 240.0
            let turns = 3.0
            let count = Int(turns * period * rate)
            func sample(_ i: Int) -> StrokeInput {
                let t = Double(i) / rate
                let a = 2 * Double.pi * t / period
                return StrokeInput(x: center + radius * cos(a), y: center + radius * sin(a), pressure: 1, time: t)
            }
            engine.begin(sample(0))
            for i in 1...count { engine.add(sample(i)) }

            // 最初の 2 周はフィルタのなじみ待ちとして捨てる（end() の収束分も入れない）
            let radii = dabs.suffix(dabs.count / 3).map { hypot(Double($0.x) - center, Double($0.y) - center) }
            let mean = radii.reduce(0, +) / Double(radii.count)
            let spread = (radii.max()! - radii.min()!) / mean
            print(String(format: "CIRCLE smoothing=%.1f mean=%.1f spread=%.2f%%", smoothing, mean, spread * 100))
            XCTAssertLessThan(spread, 0.002, "smoothing \(smoothing) で円が歪んだ")
        }
    }
}
