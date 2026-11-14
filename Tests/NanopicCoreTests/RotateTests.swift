import XCTest
@testable import NanopicCore

final class RotateTests: XCTestCase {
    /// 赤い点 (60, 40) を描いた 200×120 のキャンバス
    func editor() -> Editor {
        let ed = Editor(width: 200, height: 120)
        ed.mainColor = SIMD3(1, 0, 0)
        ed.lassoFill(path: CGPath(rect: CGRect(x: 60, y: 40, width: 1, height: 1), transform: nil))
        return ed
    }

    func testRotateClockwiseMovesPixelsAndSwapsSize() {
        let ed = editor()
        ed.rotateCanvas90(clockwise: true)
        XCTAssertEqual(ed.doc.width, 120)
        XCTAssertEqual(ed.doc.height, 200)
        // (x, y) → (H - 1 - y, x)
        XCTAssertEqual(ed.doc.activeLayer!.tiles.pixel(120 - 1 - 40, 60).0, 255)
        XCTAssertEqual(ed.doc.activeLayer!.tiles.pixel(60, 40).3, 0)
        ed.undo()
        XCTAssertEqual(ed.doc.width, 200)
        XCTAssertEqual(ed.doc.activeLayer!.tiles.pixel(60, 40).0, 255)
    }

    func testRotateCounterClockwiseMovesPixels() {
        let ed = editor()
        ed.rotateCanvas90(clockwise: false)
        XCTAssertEqual(ed.doc.width, 120)
        XCTAssertEqual(ed.doc.height, 200)
        // (x, y) → (y, W - 1 - x)
        XCTAssertEqual(ed.doc.activeLayer!.tiles.pixel(40, 200 - 1 - 60).0, 255)
    }

    func testFourTurnsRestore() {
        let ed = editor()
        let before = ed.doc.activeLayer!.tiles.toBuffer(width: 200, height: 120)
        for _ in 0..<4 { ed.rotateCanvas90(clockwise: true) }
        XCTAssertEqual(ed.doc.width, 200)
        XCTAssertEqual(ed.doc.activeLayer!.tiles.toBuffer(width: 200, height: 120), before)
        ed.rotateCanvas90(clockwise: true)
        ed.rotateCanvas90(clockwise: false)
        XCTAssertEqual(ed.doc.activeLayer!.tiles.toBuffer(width: 200, height: 120), before)
    }

    /// ワープの格子の点は、回したあとも同じ場所（回した先）を指す
    func testWarpPointsFollowRotation() {
        var d = Deformer(id: "w", name: "w", layer: 1, kind: .warp)
        d.rect = RigRect(x: 10, y: 20, width: 80, height: 40)
        d.cols = 4
        d.rows = 2
        var rig = Rig()
        rig.deformers = [d]
        var key = RigParameterKey(value: 1)
        key.forms["w"] = DeformerForm(move: RigPoint(3, 0), offsets: (0..<d.pointCount).map { RigPoint(Double($0), 0) })
        var p = RigParameter(id: "p", name: "p")
        p.keys = [key]
        rig.parameters = [p]
        for cw in [true, false] {
            let rot = Rotate90(clockwise: cw, width: 200, height: 120)
            let r = rot.rig(rig)
            let nd = r.deformers[0]
            XCTAssertEqual(nd.cols, 2)
            XCTAssertEqual(nd.rows, 4)
            let nf = r.parameters[0].keys[0].forms["w"]!
            XCTAssertEqual(nf.move, rot.vector(RigPoint(3, 0)))
            for i in 0..<d.pointCount {
                let j = rot.warpIndex(i, cols: d.cols, rows: d.rows)
                let a = rot.point(d.restPoint(i)), b = nd.restPoint(j)
                XCTAssertEqual(a.x, b.x, accuracy: 1e-9)
                XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
                XCTAssertEqual(nf.offsets[j], rot.vector(RigPoint(Double(i), 0)))
            }
        }
    }

    func testPublishRectAndAspectRotate() {
        let ed = editor()
        var s = PublishSettings()
        s.rect = IntRect(x: 10, y: 20, width: 160, height: 90)
        s.aspect = PublishAspect(16, 9)
        ed.doc.publish = s
        ed.rotateCanvas90(clockwise: true)
        XCTAssertEqual(ed.doc.publish?.rect, IntRect(x: 120 - 20 - 90, y: 10, width: 90, height: 160))
        XCTAssertEqual(ed.doc.publish?.aspect, PublishAspect(9, 16))
    }
}
