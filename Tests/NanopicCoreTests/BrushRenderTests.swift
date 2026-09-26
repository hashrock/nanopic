import XCTest
@testable import NanopicCore

/// 合成入力でストロークを描いて PNG に出力する（目視確認用）
final class BrushRenderTests: XCTestCase {
    let outDir = ProcessInfo.processInfo.environment["NANOPIC_TEST_OUT"] ?? NSTemporaryDirectory()

    func stroke(_ ed: Editor, from: (Double, Double), to: (Double, Double), curve: Double = 60,
                duration: Double = 0.4, rate: Double = 200, pressure: (Double) -> Double, jitter: Double = 0) {
        let n = Int(duration * rate)
        var t = 0.0
        for i in 0...n {
            let u = Double(i) / Double(n)
            let x = from.0 + (to.0 - from.0) * u
            let y = from.1 + (to.1 - from.1) * u + sin(u * .pi) * curve
            let jx = jitter * (Double((i * 7919) % 13) / 6.5 - 1)
            let jy = jitter * (Double((i * 104729) % 11) / 5.5 - 1)
            let s = StrokeInput(x: x + jx, y: y + jy, pressure: pressure(u), time: t)
            if i == 0 { ed.beginStroke(s, usePressure: true, zoom: 1) } else { ed.continueStroke(s) }
            t += 1 / rate
        }
        ed.endStroke()
    }

    func save(_ ed: Editor, _ name: String) {
        let img = ed.flattenedImage()!
        let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
        try! ImageUtil.pngData(img)!.write(to: url)
        print("wrote", url.path)
    }

    func testStrokes() {
        let ed = Editor(width: 900, height: 700)
        // 1. 自然な入り抜き
        ed.activeBrushIndex = 0
        var b = ed.currentBrush; b.size = 16; ed.currentBrush = b
        stroke(ed, from: (40, 40), to: (400, 60), pressure: { u in sin(u * .pi) })
        // 2. いきなり強い筆圧で開始・終了（急変を抑えられているか）
        stroke(ed, from: (40, 140), to: (400, 160), pressure: { _ in 0.9 })
        // 3. 筆圧ノイズ + 速い
        stroke(ed, from: (40, 240), to: (400, 260), duration: 0.12, pressure: { u in 0.6 + 0.3 * sin(u * 40) })
        // 4. 細いペン、ゆっくり、ジッター（手ブレ補正）
        b = ed.currentBrush; b.size = 4; b.smoothing = 0.6; ed.currentBrush = b
        stroke(ed, from: (40, 340), to: (400, 330), duration: 1.5, pressure: { u in sin(u * .pi) }, jitter: 1.5)
        b.smoothing = 0; ed.currentBrush = b
        stroke(ed, from: (40, 400), to: (400, 390), duration: 1.5, pressure: { u in sin(u * .pi) }, jitter: 1.5)
        // 5. 鉛筆（濃度筆圧）
        ed.activeBrushIndex = 2
        stroke(ed, from: (460, 40), to: (860, 60), pressure: { u in sin(u * .pi) })
        // 6. エアブラシ
        ed.activeBrushIndex = 3
        stroke(ed, from: (460, 150), to: (860, 170), curve: 20, pressure: { u in sin(u * .pi) })
        // 7. 水彩 (色混ぜ) 色を変えて重ねる
        ed.activeBrushIndex = 4
        ed.mainColor = SIMD3(0.9, 0.2, 0.2)
        stroke(ed, from: (460, 280), to: (860, 290), curve: 10, pressure: { _ in 0.8 })
        ed.mainColor = SIMD3(0.2, 0.3, 0.9)
        stroke(ed, from: (460, 320), to: (860, 280), curve: 10, pressure: { _ in 0.8 })
        // 8. 色混ぜ（ぼかし）
        ed.activeBrushIndex = 6
        stroke(ed, from: (650, 250), to: (650, 360), curve: 0, pressure: { _ in 0.9 })
        // 9. チョーク・油彩
        ed.activeBrushIndex = 7
        ed.mainColor = SIMD3(0.1, 0.5, 0.2)
        stroke(ed, from: (460, 420), to: (860, 430), pressure: { u in sin(u * .pi) })
        ed.activeBrushIndex = 5
        ed.mainColor = SIMD3(0.8, 0.6, 0.1)
        stroke(ed, from: (460, 500), to: (860, 520), pressure: { u in sin(u * .pi) })
        ed.mainColor = SIMD3(0.2, 0.2, 0.7)
        stroke(ed, from: (460, 540), to: (860, 490), pressure: { u in sin(u * .pi) })
        // 10. 太いペンの入り抜き
        ed.activeBrushIndex = 0
        b = ed.currentBrush; b.size = 60; b.smoothing = 0.3; ed.currentBrush = b
        ed.mainColor = SIMD3(0.1, 0.1, 0.1)
        stroke(ed, from: (40, 520), to: (400, 560), duration: 0.35, pressure: { u in min(1, u * 5) * min(1, (1 - u) * 5) })
        stroke(ed, from: (40, 620), to: (400, 640), duration: 0.3, pressure: { _ in 1 })
        save(ed, "strokes.png")
    }
}
