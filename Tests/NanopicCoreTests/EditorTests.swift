import XCTest
@testable import NanopicCore

final class EditorTests: XCTestCase {
    /// 単色で矩形を塗ったレイヤーを作る
    func layer(_ name: String, w: Int, h: Int, rect: IntRect, rgba: (UInt8, UInt8, UInt8, UInt8)) -> LayerNode {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        for y in rect.minY..<rect.maxY {
            for x in rect.minX..<rect.maxX {
                let o = (y * w + x) * 4
                buf[o] = rgba.0; buf[o + 1] = rgba.1; buf[o + 2] = rgba.2; buf[o + 3] = rgba.3
            }
        }
        var n = LayerNode(name: name)
        n.tiles = buf.withUnsafeBufferPointer { TileMap.from(buffer: $0.baseAddress!, width: w, height: h, gen: 0) }
        return n
    }

    func px(_ buf: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> [Int] {
        let o = (y * w + x) * 4
        return [Int(buf[o]), Int(buf[o + 1]), Int(buf[o + 2]), Int(buf[o + 3])]
    }

    func testNormalAndMultiply() {
        var doc = DocumentState(width: 300, height: 200)
        let bg = layer("bg", w: 300, h: 200, rect: doc.bounds, rgba: (200, 100, 50, 255))
        var top = layer("top", w: 300, h: 200, rect: IntRect(x: 0, y: 0, width: 150, height: 200), rgba: (128, 128, 128, 255))
        top.blendMode = .multiply
        doc.layers = [bg, top]
        let out = Compositor.compositeFull(doc)
        XCTAssertEqual(px(out, 300, 200, 10), [200, 100, 50, 255])
        let m = px(out, 300, 10, 10)
        XCTAssertEqual(m[0], 100, accuracy: 1)
        XCTAssertEqual(m[1], 50, accuracy: 1)
        XCTAssertEqual(m[2], 25, accuracy: 1)
    }

    func testClippingAndHiddenBase() {
        var doc = DocumentState(width: 300, height: 200)
        let base = layer("base", w: 300, h: 200, rect: IntRect(x: 0, y: 0, width: 100, height: 200), rgba: (255, 0, 0, 255))
        var clip = layer("clip", w: 300, h: 200, rect: doc.bounds, rgba: (0, 0, 255, 255))
        clip.clipping = true
        doc.layers = [base, clip]
        var out = Compositor.compositeFull(doc)
        XCTAssertEqual(px(out, 300, 50, 50), [0, 0, 255, 255])   // ベースの内側は青
        XCTAssertEqual(px(out, 300, 200, 50), [0, 0, 0, 0])      // 外側は透明
        doc.layers[0].visible = false
        out = Compositor.compositeFull(doc)
        XCTAssertEqual(px(out, 300, 50, 50), [0, 0, 0, 0])       // ベース非表示ならクリップも非表示
    }

    func testFolderPassThroughVsNormal() {
        var doc = DocumentState(width: 200, height: 200)
        let bg = layer("bg", w: 200, h: 200, rect: doc.bounds, rgba: (200, 200, 200, 255))
        var mul = layer("mul", w: 200, h: 200, rect: doc.bounds, rgba: (128, 128, 128, 255))
        mul.blendMode = .multiply
        var folder = LayerNode(name: "f", kind: .folder)
        folder.children = [mul]
        doc.layers = [bg, folder]
        // 通過: 乗算が背景に効く
        XCTAssertEqual(px(Compositor.compositeFull(doc), 200, 5, 5)[0], 100, accuracy: 1)
        // 通常（分離）: フォルダー内で透明に乗算 → そのまま灰色が乗る
        doc.layers[1].blendMode = .normal
        XCTAssertEqual(px(Compositor.compositeFull(doc), 200, 5, 5)[0], 128, accuracy: 1)
        // フォルダー不透明度 50%
        doc.layers[1].opacity = 0.5
        XCTAssertEqual(px(Compositor.compositeFull(doc), 200, 5, 5)[0], 164, accuracy: 1)
    }

    func testStrokeUndoRedo() {
        let ed = Editor(width: 300, height: 300)
        let lid = ed.doc.activeLayerID!
        XCTAssertTrue(ed.doc.node(lid)!.tiles.isEmpty)
        ed.beginStroke(StrokeInput(x: 20, y: 20, pressure: 1, time: 0), usePressure: false, zoom: 1)
        for i in 1...30 { ed.continueStroke(StrokeInput(x: 20 + Double(i) * 8, y: 20 + Double(i) * 8, pressure: 1, time: Double(i) / 120)) }
        ed.endStroke()
        let afterStroke = ed.doc.node(lid)!.tiles.pixel(100, 100)
        XCTAssertGreaterThan(afterStroke.3, 200)
        XCTAssertTrue(ed.canUndo)
        ed.undo()
        XCTAssertEqual(ed.doc.node(lid)!.tiles.pixel(100, 100).3, 0)
        ed.redo()
        XCTAssertEqual(ed.doc.node(lid)!.tiles.pixel(100, 100).3, afterStroke.3)
        // 2 回目のストロークで 1 回目のスナップショットが壊れていないこと（Copy-on-Write）
        ed.tool = .eraser
        ed.beginStroke(StrokeInput(x: 100, y: 100, pressure: 1, time: 0), usePressure: false, zoom: 1)
        ed.continueStroke(StrokeInput(x: 101, y: 101, pressure: 1, time: 0.01))
        ed.endStroke()
        XCTAssertEqual(ed.doc.node(lid)!.tiles.pixel(100, 100).3, 0)
        ed.undo()
        XCTAssertEqual(ed.doc.node(lid)!.tiles.pixel(100, 100).3, afterStroke.3)
    }

    func testStrokeRespectsSelectionAndLockAlpha() {
        let ed = Editor(width: 200, height: 200)
        let lid = ed.doc.activeLayerID!
        ed.select(path: CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 200), transform: nil), op: .replace)
        ed.beginStroke(StrokeInput(x: 10, y: 50, pressure: 1, time: 0), usePressure: false, zoom: 1)
        ed.continueStroke(StrokeInput(x: 190, y: 50, pressure: 1, time: 0.1))
        ed.endStroke()
        XCTAssertGreaterThan(ed.doc.node(lid)!.tiles.pixel(50, 50).3, 200)
        XCTAssertEqual(ed.doc.node(lid)!.tiles.pixel(150, 50).3, 0)
    }

    func testFillReferenceModes() {
        let ed = Editor(width: 200, height: 200)
        // 線画レイヤー: 中央に縦線
        var lines = layer("line", w: 200, h: 200, rect: IntRect(x: 100, y: 0, width: 3, height: 200), rgba: (0, 0, 0, 255))
        lines.isReference = true
        var fillLayer = LayerNode(name: "fill")
        fillLayer.id = UUID()
        var doc = ed.doc
        doc.layers = [doc.layers[0], lines, fillLayer]
        doc.activeLayerID = fillLayer.id
        ed.load(doc, url: nil)
        ed.mainColor = SIMD3(1, 0, 0)
        ed.fillSettings.expand = 0
        ed.fillSettings.reference = .referenceLayers
        ed.fill(atX: 10, y: 10)
        let n = ed.doc.node(fillLayer.id)!
        XCTAssertEqual(n.tiles.pixel(50, 50).3, 255)
        XCTAssertEqual(n.tiles.pixel(150, 50).3, 0)   // 線の向こう側は塗られない
        // 編集レイヤーのみ参照だと全面
        ed.undo()
        ed.fillSettings.reference = .currentLayer
        ed.fill(atX: 10, y: 10)
        XCTAssertEqual(ed.doc.node(fillLayer.id)!.tiles.pixel(150, 50).3, 255)
    }

    func testGapClose() {
        let w = 120, h = 120
        // 隙間 2px のある四角形の枠
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        func set(_ x: Int, _ y: Int) { buf[(y * w + x) * 4 + 3] = 255 }
        for i in 20..<100 {
            set(i, 20); set(i, 99); set(20, i)
            if i < 58 || i > 60 { set(99, i) }
        }
        let (mask, _) = buf.withUnsafeBufferPointer {
            FloodFill.mask(reference: $0.baseAddress!, width: w, height: h, seedX: 50, seedY: 50, tolerance: 0.1, gapClose: 3)
        }
        XCTAssertEqual(mask[50 * w + 50], 255)
        XCTAssertEqual(mask[5 * w + 5], 0, "隙間から外に漏れていない")
        let (leak, _) = buf.withUnsafeBufferPointer {
            FloodFill.mask(reference: $0.baseAddress!, width: w, height: h, seedX: 50, seedY: 50, tolerance: 0.1, gapClose: 0)
        }
        XCTAssertEqual(leak[5 * w + 5], 255, "隙間閉じなしでは漏れる")
    }

    func testTransformMoveAndScale() {
        let ed = Editor(width: 300, height: 300)
        var doc = ed.doc
        let l = layer("sq", w: 300, h: 300, rect: IntRect(x: 10, y: 10, width: 20, height: 20), rgba: (0, 255, 0, 255))
        doc.layers = [l]
        doc.activeLayerID = l.id
        ed.load(doc, url: nil)
        XCTAssertTrue(ed.beginTransform())
        var p = TransformParams()
        p.tx = 100
        p.ty = 50
        p.sx = 2
        p.sy = 2
        ed.updateTransform(p)
        ed.commitTransform()
        let t = ed.doc.node(l.id)!.tiles
        XCTAssertEqual(t.pixel(15, 15).3, 0)               // 元の位置は空
        XCTAssertEqual(t.pixel(120, 70).3, 255)            // 中心 (20,20)+(100,50)
        XCTAssertEqual(t.pixel(120 - 18, 70 - 18).3, 255)  // 2 倍で ±20
        XCTAssertEqual(t.pixel(120 - 22, 70).3, 0)
        ed.undo()
        XCTAssertEqual(ed.doc.node(l.id)!.tiles.pixel(15, 15).3, 255)
    }

    func testTransformSelectionOnlyLiftsSelected() {
        let ed = Editor(width: 200, height: 200)
        var doc = ed.doc
        let l = layer("sq", w: 200, h: 200, rect: IntRect(x: 0, y: 0, width: 100, height: 100), rgba: (0, 0, 255, 255))
        doc.layers = [l]
        doc.activeLayerID = l.id
        ed.load(doc, url: nil)
        ed.select(path: CGPath(rect: CGRect(x: 0, y: 0, width: 50, height: 100), transform: nil), op: .replace)
        ed.beginTransform()
        var p = TransformParams()
        p.tx = 120
        ed.updateTransform(p)
        ed.commitTransform()
        let t = ed.doc.node(l.id)!.tiles
        XCTAssertEqual(t.pixel(25, 50).3, 0)      // 持ち上げた部分は空
        XCTAssertEqual(t.pixel(75, 50).3, 255)    // 選択外は残る
        XCTAssertEqual(t.pixel(145, 50).3, 255)   // 移動先
        XCTAssertEqual(ed.doc.selection?.value(145, 50), 255)  // 選択範囲も移動
    }

    func testSelectionOps() {
        let w = 100, h = 100
        let a = SelectionMask.fromPath(CGPath(rect: CGRect(x: 0, y: 0, width: 60, height: 100), transform: nil), width: w, height: h)
        let b = SelectionMask.fromPath(CGPath(rect: CGRect(x: 40, y: 0, width: 60, height: 100), transform: nil), width: w, height: h)
        XCTAssertEqual(SelectionMask.combine(a, b, op: .add)!.bounds, IntRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(SelectionMask.combine(a, b, op: .subtract)!.bounds, IntRect(x: 0, y: 0, width: 40, height: 100))
        XCTAssertEqual(SelectionMask.combine(a, b, op: .intersect)!.bounds, IntRect(x: 40, y: 0, width: 20, height: 100))
        XCTAssertEqual(a.inverted()!.bounds, IntRect(x: 60, y: 0, width: 40, height: 100))
        XCTAssertFalse(a.outline.isEmpty)
    }

    func testLayerTreeOps() {
        let ed = Editor(width: 100, height: 100)
        let l1 = ed.doc.activeLayerID!
        ed.addFolder()
        let folder = ed.doc.activeLayerID!
        ed.setActiveLayer(l1)
        ed.moveActiveLayer(up: true)   // 展開中のフォルダーに入る
        XCTAssertEqual(ed.doc.indexPath(of: l1)!.count, 2)
        ed.moveActiveLayer(up: true)   // フォルダーから出る
        XCTAssertEqual(ed.doc.indexPath(of: l1)!.count, 1)
        ed.moveLayer(l1, relativeTo: folder, intoFolder: true)
        XCTAssertEqual(ed.doc.node(folder)!.children.first?.id, l1)
        // フォルダーを自分の子孫へは移動できない
        ed.moveLayer(folder, relativeTo: l1, intoFolder: false)
        XCTAssertEqual(ed.doc.indexPath(of: folder)!.count, 1)
        ed.undo(); ed.undo(); ed.undo()
        XCTAssertEqual(ed.doc.indexPath(of: l1)!.count, 1)
    }

    func testMergeDownKeepsBlend() {
        let ed = Editor(width: 100, height: 100)
        var doc = ed.doc
        let lower = layer("lower", w: 100, h: 100, rect: doc.bounds, rgba: (200, 200, 200, 255))
        var upper = layer("upper", w: 100, h: 100, rect: doc.bounds, rgba: (128, 128, 128, 255))
        upper.blendMode = .multiply
        doc.layers = [lower, upper]
        doc.activeLayerID = upper.id
        ed.load(doc, url: nil)
        let before = Compositor.compositeFull(ed.doc)
        ed.mergeDown()
        XCTAssertEqual(ed.doc.layers.count, 1)
        let after = Compositor.compositeFull(ed.doc)
        XCTAssertEqual(px(before, 100, 5, 5), px(after, 100, 5, 5))
    }

    func testPressureRampHasNoJump() {
        // 強い筆圧でいきなり描き始めても、隣接ダブの半径の変化が小さいこと
        var b = BrushSettings(name: "t")
        b.size = 40
        b.spacing = 0.05
        let e = StrokeEngine(brush: b, usePressure: true, zoom: 1)
        var radii: [Float] = []
        var alphas: [Float] = []
        e.emit = { radii.append($0.radius); alphas.append($0.alpha) }
        e.begin(StrokeInput(x: 0, y: 0, pressure: 1, time: 0))
        for i in 1...100 {
            e.add(StrokeInput(x: Double(i) * 4, y: 0, pressure: i > 90 ? 0 : 1, time: Double(i) / 200))
        }
        e.end()
        XCTAssertGreaterThan(radii.count, 10)
        XCTAssertLessThan(radii.first!, 3)
        for i in 1..<radii.count {
            // 相対変化が大きくないこと（ダブ間隔 = 半径の 10% 程度なので変化量もそれに比例）
            XCTAssertLessThan(abs(radii[i] - radii[i - 1]), max(1.5, radii[i - 1] * 0.2), "dab \(i)")
        }
        XCTAssertGreaterThan(radii.max()!, 18)
    }
}
