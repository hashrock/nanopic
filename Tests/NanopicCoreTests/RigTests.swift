import XCTest
@testable import NanopicCore

final class RigTests: XCTestCase {
    /// 100×100 の真ん中に、横長の赤い棒（x 30〜70、y 48〜52）を描いたレイヤー「棒」
    func editor() -> (Editor, bar: UUID) {
        let ed = Editor(width: 100, height: 100)
        let bar = ed.activeLayerID!
        ed.setLayerProperty(bar, label: "") { $0.name = "棒" }
        ed.mainColor = SIMD3(1, 0, 0)
        ed.lassoFill(path: CGPath(rect: CGRect(x: 30, y: 48, width: 40, height: 4), transform: nil))
        return (ed, bar)
    }

    func alpha(_ doc: DocumentState, _ name: String, _ x: Int, _ y: Int) -> UInt8 {
        var n: LayerNode?
        doc.forEachNode { if $0.name == name { n = $0 } }
        return n!.tiles.pixel(x, y).3
    }

    func testRotationParameterInterpolatesAndPoses() {
        let (ed, bar) = editor()
        let d = ed.addDeformer(to: bar, kind: .rotation)!
        XCTAssertEqual(ed.rig.deformer(d)!.pivot, RigPoint(50, 50))
        let p = ed.addParameter(name: "角度", min: 0, max: 1)
        ed.setForm(parameter: p, value: 0, deformer: d, DeformerForm())
        ed.setForm(parameter: p, value: 1, deformer: d, DeformerForm(angle: 90))
        XCTAssertEqual(ed.rig.forms(values: [p: 0.5])[d]?.angle ?? 0, 45, accuracy: 1e-9)

        XCTAssertFalse(ed.isPosed)
        ed.setParameterValue(p, 1)
        XCTAssertTrue(ed.isPosed)
        let posed = ed.displayDoc
        XCTAssertGreaterThan(alpha(posed, "棒", 50, 35), 200, "90° 回すと縦になる")
        XCTAssertEqual(alpha(posed, "棒", 35, 50), 0)
        XCTAssertGreaterThan(alpha(ed.doc, "棒", 35, 50), 200, "元の絵は変えない")
        // ポーズ中は描けない
        XCTAssertFalse(ed.canPaintOnActiveLayer)
        ed.resetPose()
        XCTAssertTrue(ed.canPaintOnActiveLayer)
    }

    func testWarpShiftsPixels() {
        let (ed, bar) = editor()
        let d = ed.addDeformer(to: bar, kind: .warp, cols: 2, rows: 2)!
        let p = ed.addParameter(name: "ずらす")
        ed.setForm(parameter: p, value: 1, deformer: d, DeformerForm(offsets: Array(repeating: RigPoint(10, 0), count: 9)))
        let posed = ed.doc.posed(values: [p: 1])
        XCTAssertEqual(alpha(posed, "棒", 32, 50), 0)
        XCTAssertGreaterThan(alpha(posed, "棒", 75, 50), 200)
    }

    func testFolderDeformerAndAdditiveParameters() {
        let (ed, bar) = editor()
        ed.groupSelectedLayers()
        let folder = ed.doc.node(ed.doc.indexPath(of: bar).map { Array($0.dropLast()) }.flatMap { ed.doc.node(at: $0) }!.id)!.id
        let d = ed.addDeformer(to: folder, kind: .rotation)!
        let a = ed.addParameter(name: "a"), b = ed.addParameter(name: "b")
        ed.setForm(parameter: a, value: 1, deformer: d, DeformerForm(angle: 45))
        ed.setForm(parameter: b, value: 1, deformer: d, DeformerForm(angle: 45))
        XCTAssertEqual(ed.rig.forms(values: [a: 1, b: 1])[d]?.angle, 90, "ずれは足し合わせる")
        let posed = ed.doc.posed(values: [a: 1, b: 1])
        XCTAssertGreaterThan(alpha(posed, "棒", 50, 35), 200, "フォルダーに付けると中のレイヤーに効く")
    }

    func testParameterTimelineAndSidecar() throws {
        let (ed, bar) = editor()
        let d = ed.addDeformer(to: bar, kind: .rotation)!
        let p = ed.addParameter(name: "角度", min: -1, max: 1, defaultValue: 0)
        ed.setForm(parameter: p, value: 1, deformer: d, DeformerForm(angle: 90))
        ed.setParameterKey(p, frame: 0, value: 0)
        ed.setParameterKey(p, frame: 10, value: 1)
        ed.goToFrame(5)
        XCTAssertEqual(ed.parameterValue(p), 0.5, accuracy: 1e-9, "キーの間は直線で補間")
        ed.undo()
        XCTAssertEqual(ed.timeline.parameterTracks.first?.keys.count, 1)
        ed.redo()

        ed.prepareForSave()
        let json = try JSONEncoder().encode(ed.sidecar)
        let ed2 = Editor(width: 1, height: 1)
        ed2.load(try PSD.read(PSD.write(ed.doc)), url: nil, sidecar: try JSONDecoder().decode(Sidecar.self, from: json))
        XCTAssertEqual(ed2.rig, ed.rig)
        XCTAssertEqual(ed2.timeline.parameterTracks, ed.timeline.parameterTracks)
        XCTAssertFalse(ed2.isPosed, "開いたときは基本ポーズ")
    }

    func testRemovingDeformerClearsForms() {
        let (ed, bar) = editor()
        let d = ed.addDeformer(to: bar, kind: .rotation)!
        let p = ed.addParameter(name: "角度")
        ed.setForm(parameter: p, value: 1, deformer: d, DeformerForm(angle: 30))
        ed.removeDeformer(d)
        XCTAssertTrue(ed.rig.parameter(p)!.keys.allSatisfy { $0.forms.isEmpty })
    }

    func testAgentRigTools() throws {
        let (ed, bar) = editor()
        let tb = AgentToolbox(editor: ed)
        func obj(_ c: [AgentContent]) throws -> [String: Any] {
            guard case let .text(t)? = c.first else { return [:] }
            return try JSONSerialization.jsonObject(with: Data(t.utf8)) as! [String: Any]
        }
        let d = try obj(tb.call("add_deformer", ["layer_id": bar.uuidString, "kind": "warp", "cols": 1, "rows": 1]))["deformer_id"] as! String
        let p = try obj(tb.call("add_parameter", ["name": "ずらす"]))["parameter_id"] as! String
        _ = try tb.call("set_form", ["parameter": p, "value": 1, "deformer": d, "points": ["0": [5, 0], "3": [5, 0]]])
        XCTAssertEqual(ed.rig.parameter(p)!.keys[0].forms[d]!.offsets.count, 4)
        let info = try obj(tb.call("rig", ["values": [p: 1]]))
        XCTAssertEqual(info["posed"] as? Bool, true)
        XCTAssertThrowsError(try tb.call("fill_selection", ["color": "#000000"]), "ポーズ中は描けない")
        _ = try tb.call("rig", ["reset_pose": true])
        XCTAssertFalse(ed.isPosed)
        _ = try tb.call("set_key", ["parameter": p, "frame": 6, "value": 1])
        XCTAssertEqual(ed.timeline.parameterTracks.first?.keys.map(\.frame), [6])
    }
}
