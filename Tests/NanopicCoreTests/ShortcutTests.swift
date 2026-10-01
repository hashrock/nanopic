import XCTest
@testable import NanopicCore

final class ShortcutTests: XCTestCase {
    func testDefaultsMatchPreviousKeys() {
        let m = ShortcutMap.defaults
        XCTAssertEqual(m.target(for: KeyChord("b")), .tool(.brush))
        XCTAssertEqual(m.target(for: KeyChord("p")), .tool(.brush))
        XCTAssertEqual(m.target(for: KeyChord("g", shift: true)), .tool(.lassoFill))
        XCTAssertNil(m.target(for: KeyChord("x")))
    }

    func testAssignReplacesSameKeyAndKeepsOtherKeys() {
        var m = ShortcutMap.defaults
        let pen = UUID()
        m.assign(KeyChord("p"), to: .preset(pen))
        XCTAssertEqual(m.target(for: KeyChord("p")), .preset(pen))
        // ブラシツールには B が残る
        XCTAssertEqual(m.chords(for: .tool(.brush)), [KeyChord("b")])
        // 外す
        m.assign(nil, to: .preset(pen))
        XCTAssertNil(m.target(for: KeyChord("p")))
    }

    func testReservedKeysCannotBeAssigned() {
        var m = ShortcutMap.defaults
        m.assign(KeyChord("x"), to: .tool(.fill))
        XCTAssertNil(m.target(for: KeyChord("x")))
    }

    func testPruneRemovesDeletedPresets() {
        var m = ShortcutMap.defaults
        let gone = UUID(), kept = UUID()
        m.assign(KeyChord("1"), to: .preset(gone))
        m.assign(KeyChord("2"), to: .preset(kept))
        m.prune(validPresets: [kept])
        XCTAssertNil(m.target(for: KeyChord("1")))
        XCTAssertEqual(m.target(for: KeyChord("2")), .preset(kept))
    }

    func testCodableRoundTrip() throws {
        var m = ShortcutMap.defaults
        m.assign(KeyChord("1", option: true), to: .preset(UUID()))
        let back = try JSONDecoder().decode(ShortcutMap.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
    }

    func testActivatePresetAndRestore() {
        let ed = Editor(width: 10, height: 10)
        ed.activeBrushIndex = 0
        let before = ed.toolSnapshot
        let eraser = ed.erasers[1]
        ed.activate(.preset(eraser.id))
        XCTAssertEqual(ed.tool, .eraser)
        XCTAssertEqual(ed.currentBrush.id, eraser.id)
        let pencil = ed.brushes[2]
        ed.activate(.preset(pencil.id))
        XCTAssertEqual(ed.tool, .brush)
        XCTAssertEqual(ed.activeBrushIndex, 2)
        ed.restore(before)
        XCTAssertEqual(ed.toolSnapshot, before)
        XCTAssertEqual(ed.activeBrushIndex, 0)
    }
}
