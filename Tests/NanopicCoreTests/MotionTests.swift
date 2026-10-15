import XCTest
@testable import NanopicCore

final class MotionTests: XCTestCase {
    /// 100×100 の真ん中に、縦長の赤い四角（x 30〜70、y 20〜80）を描いたレイヤー
    func editor() -> (Editor, UUID) {
        let ed = Editor(width: 100, height: 100)
        let id = ed.activeLayerID!
        ed.mainColor = SIMD3(1, 0, 0)
        ed.lassoFill(path: CGPath(rect: CGRect(x: 30, y: 20, width: 40, height: 60), transform: nil))
        return (ed, id)
    }

    func testEveryPresetMovesAndLoopsSeamlessly() {
        for preset in MotionPreset.allCases {
            let (ed, id) = editor()
            let pid = ed.addMotion(preset, to: id)
            XCTAssertNotNil(pid, "\(preset)")
            let t = ed.timeline
            XCTAssertEqual(t.fps, 24)
            XCTAssertEqual(t.frameCount, Int((preset.period * 24).rounded()), "\(preset): 空のタイムラインは動き 1 回分")
            let track = t.parameterTracks.first { $0.parameter == pid }!
            XCTAssertEqual(track.value(at: 0)!, track.value(at: t.frameCount)!, accuracy: 1e-9, "\(preset): ループの継ぎ目がつながる")

            let frames = (0..<t.frameCount).map { Editor.renderFrame(ed.doc, frame: $0, values: [:], deformed: true) }
            XCTAssertTrue(frames.contains { $0 != frames[0] }, "\(preset): コマによって見た目が変わる")
            XCTAssertEqual(Editor.renderFrame(ed.doc, frame: 0, values: [:], deformed: false), Compositor.compositeFull(ed.doc),
                           "\(preset): 描いた絵そのものは変えない")
        }
    }

    func testUndoRemovesMotionInOneStep() {
        let (ed, id) = editor()
        ed.addMotion(.sway, to: id)
        XCTAssertFalse(ed.rig.isEmpty)
        ed.undo()
        XCTAssertTrue(ed.rig.isEmpty)
        XCTAssertTrue(ed.timeline.isEmpty)
    }

    func testSecondMotionFitsExistingLength() {
        let (ed, id) = editor()
        ed.addMotion(.sway, to: id)
        XCTAssertEqual(ed.timeline.frameCount, 72)
        let pid = ed.addMotion(.float, to: id)!
        XCTAssertEqual(ed.timeline.frameCount, 72, "あとから付けた動きは今の長さに合わせる")
        let track = ed.timeline.parameterTracks.first { $0.parameter == pid }!
        // ふわふわ（2 秒）は 3 秒の中に 2 回（36 コマずつ）
        XCTAssertEqual(track.keys.map(\.frame), [0, 18, 36, 54, 72])
        XCTAssertEqual(ed.rig.deformers.count, 2)
    }

    func testSwayPivotsAtFeet() {
        let (ed, id) = editor()
        ed.addMotion(.sway, to: id)
        let d = ed.rig.deformers[0]
        XCTAssertEqual(d.pivot, RigPoint(50, 80))
        XCTAssertEqual(d.kind, .rotation)
    }

    func testEmptyLayerHasNothingToMove() {
        let ed = Editor(width: 100, height: 100)
        ed.addLayer()
        let label = ed.undoLabel
        XCTAssertNil(ed.addMotion(.breathe, to: ed.activeLayerID!))
        XCTAssertTrue(ed.rig.isEmpty)
        XCTAssertEqual(ed.undoLabel, label, "履歴に残さない")
    }
}
