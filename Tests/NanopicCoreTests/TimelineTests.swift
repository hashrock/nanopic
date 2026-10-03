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
