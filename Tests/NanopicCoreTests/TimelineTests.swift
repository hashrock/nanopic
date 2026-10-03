import XCTest
@testable import NanopicCore

final class TimelineTests: XCTestCase {
    /// 「口」スイッチ（閉じ・あ）と、ふつうのレイヤー「汗」
    func editor() -> (Editor, mouth: UUID, closed: UUID, open: UUID, sweat: UUID) {
        let ed = Editor(width: 32, height: 32)
        ed.addLayer(name: "汗")
        let sweat = ed.activeLayerID!
        ed.addFolder(name: "口")
        let mouth = ed.activeLayerID!
        var kids: [UUID] = []
        for name in ["閉じ", "あ"] {
            ed.addLayer(name: name)
            let id = ed.activeLayerID!
            ed.moveLayer(id, relativeTo: mouth, placement: .into)
            kids.append(id)
        }
        ed.setActiveLayer(kids[0])
        ed.setSwitch(mouth, true)
        return (ed, mouth, kids[0], kids[1], sweat)
    }

    func shown(_ ed: Editor, _ folder: UUID) -> String {
        ed.doc.node(folder)!.children.first(where: \.visible)!.name
    }

    func testKeyHoldsUntilNextAndBeforeFirst() {
        var t = TimelineTrack(layer: 1)
        t.set(TimelineKey(frame: 4, visible: true))
        t.set(TimelineKey(frame: 8, visible: false))
        XCTAssertEqual(t.key(at: 0)?.visible, true, "最初のキーより前は最初のキーの値")
        XCTAssertEqual(t.key(at: 7)?.visible, true)
        XCTAssertEqual(t.key(at: 8)?.visible, false)
        t.set(TimelineKey(frame: 8, visible: true))
        XCTAssertEqual(t.keys.count, 2, "同じコマは置き換える")
    }

    func testAutoKeyAndPlayback() {
        let (ed, mouth, _, open, sweat) = editor()
        ed.addTrack(mouth)
        ed.addTrack(sweat)
        XCTAssertEqual(ed.timeline.tracks.count, 2)
        ed.timelineOpen = true
        // 3 コマ目で口を「あ」、汗を消す
        ed.goToFrame(3)
        ed.toggleVisibility(open)
        ed.toggleVisibility(sweat)
        XCTAssertEqual(ed.timeline.tracks[0].keys.map(\.frame), [0, 3])

        ed.goToFrame(1)
        XCTAssertEqual(shown(ed, mouth), "閉じ")
        XCTAssertTrue(ed.doc.node(sweat)!.visible)
        ed.goToFrame(5)
        XCTAssertEqual(shown(ed, mouth), "あ")
        XCTAssertFalse(ed.doc.node(sweat)!.visible)
    }

    func testNoAutoKeyWhenTimelineClosed() {
        let (ed, mouth, _, open, _) = editor()
        ed.addTrack(mouth)
        ed.goToFrame(3)
        ed.toggleVisibility(open)
        XCTAssertEqual(ed.timeline.tracks[0].keys.map(\.frame), [0])
    }

    func testKeyEditsAreUndoable() {
        let (ed, mouth, _, open, _) = editor()
        ed.addTrack(mouth)
        let layer = ed.doc.node(mouth)!.psdID
        ed.setKey(layer: layer, TimelineKey(frame: 6, child: ed.doc.node(open)!.psdID))
        ed.moveKey(layer: layer, from: 6, to: 9)
        XCTAssertEqual(ed.timeline.tracks[0].keys.map(\.frame), [0, 9])
        ed.undo()
        XCTAssertEqual(ed.timeline.tracks[0].keys.map(\.frame), [0, 6])
        ed.deleteKey(layer: layer, frame: 0)
        ed.deleteKey(layer: layer, frame: 6)
        XCTAssertTrue(ed.timeline.tracks.isEmpty, "キーがなくなったトラックは消える")
    }

    func testSidecarRoundTrip() throws {
        let (ed, mouth, _, open, _) = editor()
        ed.addTrack(mouth)
        ed.setTimeline(fps: 24, frameCount: 48, loop: false)
        ed.setKey(layer: ed.doc.node(mouth)!.psdID, TimelineKey(frame: 10, child: ed.doc.node(open)!.psdID))
        ed.prepareForSave()
        let json = try JSONEncoder().encode(ed.sidecar)
        let psd = try PSD.write(ed.doc)

        let ed2 = Editor(width: 1, height: 1)
        ed2.load(try PSD.read(psd), url: nil, sidecar: try JSONDecoder().decode(Sidecar.self, from: json))
        XCTAssertEqual(ed2.timeline, ed.timeline)
        var m2: LayerNode?
        ed2.doc.forEachNode { if $0.name == "口" { m2 = $0 } }
        ed2.goToFrame(12)
        XCTAssertEqual(shown(ed2, m2!.id), "あ")
    }
}

extension TimelineTests {
    func testParameterEasing() throws {
        var t = ParameterTrack(parameter: "p")
        t.set(frame: 0, value: 0)
        t.set(frame: 10, value: 1)
        XCTAssertEqual(t.value(at: 5)!, 0.5, accuracy: 1e-9)
        t.keys[0].easing = .easeIn
        XCTAssertLessThan(t.value(at: 5)!, 0.5, "ゆっくり始まる")
        t.keys[0].easing = .easeOut
        XCTAssertGreaterThan(t.value(at: 5)!, 0.5, "ゆっくり止まる")
        t.keys[0].easing = .easeInOut
        XCTAssertEqual(t.value(at: 5)!, 0.5, accuracy: 1e-9)
        XCTAssertLessThan(t.value(at: 2)!, 0.2)
        t.keys[0].easing = .hold
        XCTAssertEqual(t.value(at: 9)!, 0)
        XCTAssertEqual(t.value(at: 10)!, 1)
        // 値を打ち直しても動き方は残る
        t.set(frame: 0, value: 0.1)
        XCTAssertEqual(t.keys[0].easing, .hold)
        // 動き方のなかった頃のデータは直線
        let old = try JSONDecoder().decode(ParameterKeyframe.self, from: Data(#"{"frame": 3, "value": 0.5}"#.utf8))
        XCTAssertEqual(old.easing, .linear)
    }
}

extension TimelineTests {
    func testMultiKeyEditing() {
        let (ed, mouth, _, open, sweat) = editor()
        ed.addTrack(mouth)
        ed.addTrack(sweat)
        let m = ed.doc.node(mouth)!.psdID, s = ed.doc.node(sweat)!.psdID
        ed.setKey(layer: m, TimelineKey(frame: 4, child: ed.doc.node(open)!.psdID))
        ed.setKey(layer: s, TimelineKey(frame: 4, visible: false))
        let p = ed.addParameter(name: "首")
        ed.setParameterKey(p, frame: 2, value: 0.5)
        ed.setParameterKeyEasing(p, frame: 2, easing: .easeOut)

        // 3 つをまとめて 3 コマ後ろへ（1 回で戻せる）
        let sel: Set<TimelineKeyRef> = [.layer(m, frame: 4), .layer(s, frame: 4), .parameter(p, frame: 2)]
        let moved = ed.moveKeys(sel, by: 3)
        XCTAssertEqual(moved, [.layer(m, frame: 7), .layer(s, frame: 7), .parameter(p, frame: 5)])
        XCTAssertEqual(ed.timeline.parameterTracks[0].keys.first?.easing, .easeOut, "動き方も一緒に動く")
        ed.undo()
        XCTAssertEqual(ed.timeline.track(for: m)!.keys.map(\.frame), [0, 4])
        // 前へ動かしすぎても 0 で止まる
        XCTAssertEqual(ed.moveKeys([.parameter(p, frame: 2)], by: -10), [.parameter(p, frame: 0)])
        ed.undo()

        // コピーして 10 コマ目に貼り付け
        let clip = ed.copyKeys(sel)
        let pasted = ed.pasteKeys(clip, at: 10)
        XCTAssertEqual(pasted, [.layer(m, frame: 12), .layer(s, frame: 12), .parameter(p, frame: 10)])
        XCTAssertEqual(ed.timeline.track(for: s)!.keys.first { $0.frame == 12 }?.visible, false)

        // まとめて消す（キーがなくなったトラックも消える）
        ed.deleteKeys([.parameter(p, frame: 2), .parameter(p, frame: 10)])
        XCTAssertTrue(ed.timeline.parameterTracks.isEmpty)
    }
}

extension TimelineTests {
    func testOnionSkinShowsOnlyWhatDiffers() {
        let (ed, _, _, _, sweat) = editor()
        // 汗のレイヤーの左半分を黒く塗る
        let tiles = TileMap.filled(width: 16, height: 32, rgba: (0, 0, 0, 255), gen: 1)
        _ = ed.doc.modify(sweat) { $0.tiles = tiles }
        ed.addTrack(sweat)
        let s = ed.doc.node(sweat)!.psdID
        ed.setKey(layer: s, TimelineKey(frame: 0, visible: true))
        ed.setKey(layer: s, TimelineKey(frame: 1, visible: false))
        ed.setKey(layer: s, TimelineKey(frame: 2, visible: false))
        ed.timelineOpen = true
        ed.goToFrame(1)
        XCTAssertNil(ed.onionSkinImage(), "切っていれば出さない")

        ed.onionSkin = OnionSkin(enabled: true, before: 1, after: 1)
        let img = ed.onionSkinImage()!
        func px(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let o = (y * 32 + x) * 4
            return (img[o], img[o + 1], img[o + 2], img[o + 3])
        }
        // 前のコマ（汗が見える）は赤く出る。後ろのコマ（今と同じ）と、もともと白い所は出ない
        XCTAssertGreaterThan(px(4, 4).a, 0)
        XCTAssertGreaterThan(px(4, 4).r, px(4, 4).b)
        XCTAssertEqual(px(24, 4).a, 0)

        // 再計算しなければ同じ版のまま
        let v = ed.onionSkinVersion
        _ = ed.onionSkinImage()
        XCTAssertEqual(ed.onionSkinVersion, v)
    }
}
