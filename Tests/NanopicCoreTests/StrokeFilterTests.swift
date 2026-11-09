import XCTest
@testable import NanopicCore

final class StrokeFilterTests: XCTestCase {
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
