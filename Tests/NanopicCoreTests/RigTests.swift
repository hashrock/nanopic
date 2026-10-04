import XCTest
@testable import NanopicCore
@testable import NanopicAgent

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

extension RigTests {
    /// 既定値でも形を記録でき、描くときは変形の表示を切る
    func testFormAtDefaultAndDeformationToggle() {
        let (ed, bar) = editor()
        let d = ed.addDeformer(to: bar, kind: .rotation)!
        let p = ed.addParameter(name: "首")
        XCTAssertEqual(ed.rig.parameter(p)!.min, -1)
        XCTAssertEqual(ed.rig.parameter(p)!.defaultValue, 0)
        ed.setForm(parameter: p, value: 0, deformer: d, DeformerForm(angle: 90))
        XCTAssertTrue(ed.showsDeformation, "形を記録すると変形の表示が入る")
        XCTAssertTrue(ed.isPosed, "既定値でも変形しているので描けない")
        XCTAssertFalse(ed.canPaintOnActiveLayer)
        XCTAssertGreaterThan(alpha(ed.displayDoc, "棒", 50, 35), 200)

        ed.setShowsDeformation(false)
        XCTAssertFalse(ed.isPosed)
        XCTAssertTrue(ed.canPaintOnActiveLayer)
        XCTAssertEqual(alpha(ed.displayDoc, "棒", 50, 35), 0, "切ると描いた絵そのまま")
        ed.setParameterValue(p, 0.5)
        XCTAssertTrue(ed.showsDeformation, "つまみを動かすと入る")
    }
}

extension RigTests {
    /// 格子のマス数を変えても、記録済みの形の見た目は保たれる（一様なずれなら完全に同じ）
    func testWarpGridResampleKeepsForm() {
        let (ed, bar) = editor()
        let d = ed.addDeformer(to: bar, kind: .warp, cols: 2, rows: 2)!
        let p = ed.addParameter(name: "ずらす")
        ed.setForm(parameter: p, value: 1, deformer: d, DeformerForm(offsets: Array(repeating: RigPoint(10, 0), count: 9)))
        let before = ed.doc.posed(values: [p: 1])
        ed.setWarpGrid(d, cols: 4, rows: 3)
        XCTAssertEqual(ed.rig.deformer(d)!.pointCount, 20)
        XCTAssertEqual(ed.rig.parameter(p)!.keys[0].forms[d]!.offsets.count, 20)
        XCTAssertTrue(ed.rig.parameter(p)!.keys[0].forms[d]!.offsets.allSatisfy { abs($0.x - 10) < 1e-9 && abs($0.y) < 1e-9 })
        let after = ed.doc.posed(values: [p: 1])
        XCTAssertEqual(alpha(after, "棒", 75, 50), alpha(before, "棒", 75, 50))
        ed.undo()
        XCTAssertEqual(ed.rig.deformer(d)!.pointCount, 9)
    }
}

extension RigTests {
    func testMoveFormTranslatesAndInterpolates() throws {
        let (ed, bar) = editor()
        let d = ed.addDeformer(to: bar, kind: .rotation)!
        XCTAssertTrue(ed.rig.deformer(d)!.name.hasSuffix("移動・回転"))
        let p = ed.addParameter(name: "上下")
        ed.setForm(parameter: p, value: 1, deformer: d, DeformerForm(move: RigPoint(0, -20)))
        XCTAssertEqual(ed.rig.forms(values: [p: 0.5])[d]?.move, RigPoint(0, -10))
        let posed = ed.doc.posed(values: [p: 1])
        XCTAssertGreaterThan(alpha(posed, "棒", 50, 30), 200, "20px 上に動く")
        XCTAssertEqual(alpha(posed, "棒", 50, 50), 0)
        // 回転と移動を一緒に
        ed.setForm(parameter: p, value: 1, deformer: d, DeformerForm(angle: 90, move: RigPoint(20, 0)))
        XCTAssertGreaterThan(alpha(ed.doc.posed(values: [p: 1]), "棒", 70, 35), 200)

        // 移動量のなかった頃のデータも読める
        let old = try JSONDecoder().decode(DeformerForm.self, from: Data(#"{"angle": 30, "offsets": []}"#.utf8))
        XCTAssertEqual(old, DeformerForm(angle: 30))

        let tb = AgentToolbox(editor: ed)
        _ = try tb.call("set_form", ["parameter": p, "value": -1, "deformer": d, "move": [5, 6]])
        XCTAssertEqual(ed.rig.parameter(p)!.keys.first!.forms[d]!.move, RigPoint(5, 6))
    }
}

extension RigTests {
    /// 親フォルダーの回転をかけた位置にハンドルを出し、画面上の量を子の座標に戻せる
    func testOuterMapAndLocalDeltaThroughParent() {
        let (ed, bar) = editor()
        ed.groupSelectedLayers()
        let folder = ed.doc.node(at: Array(ed.doc.indexPath(of: bar)!.dropLast()))!.id
        let parent = ed.addDeformer(to: folder, kind: .rotation)!
        let child = ed.addDeformer(to: bar, kind: .warp, cols: 1, rows: 1)!
        let p = ed.addParameter(name: "首")
        ed.setForm(parameter: p, value: 1, deformer: parent, DeformerForm(angle: 90))
        let forms = ed.rig.forms(values: [p: 1])
        let d = ed.rig.deformer(child)!
        XCTAssertEqual(ed.doc.outerDeformers(of: d).map(\.id), [parent])
        // 中心 (50, 50) を軸に 90° 回るので、(60, 50) は (50, 60) に見える
        let q = ed.doc.outerMap(RigPoint(60, 50), after: d, forms: forms)
        XCTAssertEqual(q.x, 50, accuracy: 1e-6)
        XCTAssertEqual(q.y, 60, accuracy: 1e-6)
        // 画面上で右へ 10 動かすのは、子の座標では上へ 10
        let l = ed.doc.localDelta(RigPoint(10, 0), at: RigPoint(60, 50), after: d, forms: forms)
        XCTAssertEqual(l.x, 0, accuracy: 1e-6)
        XCTAssertEqual(l.y, -10, accuracy: 1e-6)
    }
}

/// ベジェのワープ（点の間を 3 次の曲線でつなぎ、ハンドルで曲がり方を変える）
final class BezierWarpTests: XCTestCase {
    /// 範囲 (0, 0, 100, 100) の 4×1 のワープ
    func warp(cols: Int = 4, rows: Int = 1) -> Deformer {
        var d = Deformer(id: "w", name: "w", layer: 1, kind: .warp)
        d.rect = RigRect(x: 0, y: 0, width: 100, height: 100)
        d.cols = cols
        d.rows = rows
        return d
    }

    func testBasicProperties() {
        let d = warp()
        let p = RigPoint(33, 71)
        XCTAssertEqual(d.map(p, DeformerForm()), p, "形が 0 なら動かない")
        // 全部同じずれなら平行移動
        let same = DeformerForm(offsets: Array(repeating: RigPoint(5, -3), count: d.pointCount))
        let q = d.map(p, same)
        XCTAssertEqual(q.x, 38, accuracy: 1e-9)
        XCTAssertEqual(q.y, 68, accuracy: 1e-9)
        // ずれが x に比例していれば、そのまま比例（直線は直線のまま）
        let linear = DeformerForm(offsets: (0..<d.pointCount).map { RigPoint(Double($0 % 5) * 2, 0) })
        XCTAssertEqual(d.map(RigPoint(37.5, 50), linear).x, 37.5 + 37.5 / 25 * 2, accuracy: 1e-9)
    }

    func testPassesThroughPointsAndIsSmooth() {
        let d = warp()
        var f = DeformerForm(offsets: Array(repeating: .zero, count: d.pointCount))
        f.offsets[2] = RigPoint(0, 20) // 上の辺のまん中の点を下へ
        // 格子の点の上はちょうどそのずれ
        XCTAssertEqual(d.map(RigPoint(50, 0), f).y, 20, accuracy: 1e-9)
        XCTAssertEqual(d.map(RigPoint(25, 0), f).y, 0, accuracy: 1e-9)
        // マスの境目（x = 25）の左右で傾きが同じ（折れない）
        let e = 0.01
        let y = { (x: Double) in self.warp().map(RigPoint(x, 0), f).y }
        let leftSlope = (y(25) - y(25 - e)) / e, rightSlope = (y(25 + e) - y(25)) / e
        XCTAssertEqual(leftSlope, rightSlope, accuracy: 0.01)
        XCTAssertGreaterThan(rightSlope, 0, "隣の点へなめらかに上がり始める")
    }

    func testHandleChangesCurveNotPoints() {
        let d = warp()
        var f = DeformerForm(offsets: Array(repeating: .zero, count: d.pointCount))
        let before = d.map(RigPoint(12.5, 0), f)
        // 左上の点の横のハンドルを下へ向ける
        f.tangents = Array(repeating: .zero, count: d.pointCount)
        f.tangents[0].u = RigPoint(0, 30)
        let after = d.map(RigPoint(12.5, 0), f)
        XCTAssertGreaterThan(after.y, before.y + 1, "マスの中の曲がり方が変わる")
        XCTAssertEqual(d.map(RigPoint(0, 0), f).y, 0, accuracy: 1e-9, "点の位置は変わらない")
        XCTAssertEqual(d.map(RigPoint(25, 0), f).y, 0, accuracy: 1e-9)
        // ハンドルの先: 自動なら隣の点へ向けて マス / 3、ずれを足すとそのぶん動く
        let h = d.warpHandles(0, f)
        XCTAssertEqual(h.u.x, 25.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(h.u.y, 10, accuracy: 1e-9)
    }

    func testLerpAddAndCoding() throws {
        let a = DeformerForm(offsets: [RigPoint(1, 0)], tangents: [RigTangent(u: RigPoint(4, 0))])
        let b = DeformerForm(offsets: [RigPoint(3, 0)])
        XCTAssertEqual(DeformerForm.lerp(a, b, 0.5).tangents[0].u.x, 2, accuracy: 1e-9)
        XCTAssertEqual((a + a).tangents[0].u.x, 8, accuracy: 1e-9)
        // ハンドルを触っていなければ tangents は書かない
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(b)) as! [String: Any]
        XCTAssertNil(plain["tangents"])
        let back = try JSONDecoder().decode(DeformerForm.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
        XCTAssertFalse(DeformerForm(tangents: [RigTangent(v: RigPoint(0, 1))]).isZero)
    }
}
