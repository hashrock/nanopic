import XCTest
@testable import NanopicCore

final class TurnTests: XCTestCase {
    /// 200×200 に「顔」フォルダー（下から 後ろ髪・顔・目）を作る
    func editor() -> (Editor, folder: UUID, parts: [UUID]) {
        let ed = Editor(width: 200, height: 200)
        ed.addFolder(name: "顔")
        let folder = ed.activeLayerID!
        var parts: [UUID] = []
        for (name, rect) in [("後ろ髪", CGRect(x: 40, y: 30, width: 120, height: 140)),
                             ("顔", CGRect(x: 55, y: 50, width: 90, height: 110)),
                             ("目", CGRect(x: 90, y: 95, width: 20, height: 10))] {
            ed.addLayer(name: name)
            let id = ed.activeLayerID!
            ed.moveLayer(id, relativeTo: folder, placement: .into)
            ed.lassoFill(path: CGPath(ellipseIn: rect, transform: nil))
            parts.append(id)
        }
        return (ed, folder, parts)
    }

    func testTurnMovesFrontWithAndBackAgainst() throws {
        let (ed, folder, parts) = editor()
        let turn = try XCTUnwrap(ed.addTurn(to: folder))
        XCTAssertEqual(ed.rig.deformers.count, 3)
        XCTAssertEqual(ed.rig.parameters.count, 2)
        XCTAssertEqual(Set(ed.timeline.parameterTracks.map(\.parameter)), [turn.yaw, turn.pitch])

        func centerShift(_ part: UUID, _ values: [String: Double]) -> RigPoint {
            let d = ed.rig.deformers.first { $0.layer == ed.doc.node(part)!.psdID }!
            let c = turn.center
            return d.map(c, ed.rig.forms(values: values)[d.id] ?? DeformerForm()) - c
        }
        XCTAssertGreaterThan(centerShift(parts[2], [turn.yaw: 1]).x, 5, "手前（目）は右を向くと右へ動く")
        XCTAssertGreaterThan(centerShift(parts[2], [turn.yaw: 1]).x, centerShift(parts[1], [turn.yaw: 1]).x, "上のレイヤーほど大きく動く")
        XCTAssertLessThan(centerShift(parts[0], [turn.yaw: 1]).x, -5, "奥（後ろ髪）は逆に動く")
        XCTAssertLessThan(centerShift(parts[2], [turn.pitch: 1]).y, -3, "上を向くと手前は上へ動く")

        // 向きを変えると見た目が変わり、描いた絵そのものは変えない
        let before = Compositor.compositeFull(ed.doc)
        XCTAssertNotEqual(Compositor.compositeFull(ed.doc.posed(values: [turn.yaw: 1, turn.pitch: -1])), before)
        XCTAssertEqual(Compositor.compositeFull(ed.doc), before)
    }

    /// 向ききっても、どこも折り返さない（画素が重なって汚れない）
    func testTurnNeverFolds() throws {
        let (ed, folder, _) = editor()
        let turn = try XCTUnwrap(ed.addTurn(to: folder))
        for (y, p) in [(-1.0, -1.0), (-1, 0), (-1, 1), (1, -1), (1, 0), (1, 1)] {
            let forms = ed.rig.forms(values: [turn.yaw: y, turn.pitch: p])
            for d in ed.rig.deformers {
                let f = forms[d.id] ?? DeformerForm()
                for j in stride(from: d.rect.y, through: d.rect.y + d.rect.height, by: 4) {
                    for x in stride(from: d.rect.x, to: d.rect.x + d.rect.width, by: 1) {
                        let a = d.map(RigPoint(x, j), f), b = d.map(RigPoint(x + 1, j), f)
                        XCTAssertGreaterThan(b.x - a.x, 0.1, "yaw \(y) pitch \(p) の \(x), \(j)")
                    }
                }
                for i in stride(from: d.rect.x, through: d.rect.x + d.rect.width, by: 4) {
                    for y0 in stride(from: d.rect.y, to: d.rect.y + d.rect.height, by: 1) {
                        let a = d.map(RigPoint(i, y0), f), b = d.map(RigPoint(i, y0 + 1), f)
                        XCTAssertGreaterThan(b.y - a.y, 0.1, "yaw \(y) pitch \(p) の \(i), \(y0)")
                    }
                }
            }
        }
    }

    func testUndoRemovesTurnInOneStep() {
        let (ed, folder, _) = editor()
        ed.addTurn(to: folder)
        ed.undo()
        XCTAssertTrue(ed.rig.isEmpty)
        XCTAssertNil(ed.rig.turn)
        XCTAssertTrue(ed.timeline.isEmpty)
    }

    func testLookAtFollowsPointWithoutHistory() throws {
        let (ed, folder, _) = editor()
        let turn = try XCTUnwrap(ed.addTurn(to: folder))
        let label = ed.undoLabel, timeline = ed.timeline
        ed.lookAt(RigPoint(turn.center.x + 1000, turn.center.y - 1000))
        XCTAssertEqual(ed.parameterValue(turn.yaw), 1, "右上の遠くを見ると右に向ききる")
        XCTAssertEqual(ed.parameterValue(turn.pitch), 1)
        XCTAssertTrue(ed.isPosed)
        XCTAssertEqual(ed.undoLabel, label, "履歴に残さない")
        XCTAssertEqual(ed.timeline, timeline, "キーを打たない")
        ed.removeParameter(turn.yaw)
        XCTAssertNil(ed.turnRig, "向きのパラメータを消したら追わない")
    }

    func testSingleLayerTurnsAsFrontSurface() throws {
        let ed = Editor(width: 100, height: 100)
        let id = ed.activeLayerID!
        ed.lassoFill(path: CGPath(ellipseIn: CGRect(x: 20, y: 20, width: 60, height: 60), transform: nil))
        let turn = try XCTUnwrap(ed.addTurn(to: id))
        let d = ed.rig.deformers[0]
        XCTAssertGreaterThan((d.map(turn.center, ed.rig.forms(values: [turn.yaw: 1])[d.id]!) - turn.center).x, 3)
    }

    func testTurnIsSavedInSidecarRig() throws {
        let (ed, folder, _) = editor()
        let turn = try XCTUnwrap(ed.addTurn(to: folder))
        let data = try JSONEncoder().encode(ed.rig)
        XCTAssertEqual(try JSONDecoder().decode(Rig.self, from: data).turn, turn)
        // 振り向きのなかった頃のデータも読める
        let old = try JSONDecoder().decode(Rig.self, from: Data(#"{"deformers":[],"parameters":[]}"#.utf8))
        XCTAssertNil(old.turn)
    }
}
