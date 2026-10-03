import AppKit
import NanopicCore
import SwiftUI

extension AppState {
    /// 1 行の文字を入れてもらう（キャンセルなら nil）
    func promptText(_ title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let f = NSTextField(string: value)
        f.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = f
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = f
        return alert.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }

    /// パラメータの範囲と既定値を入れてもらう
    func promptRange(min: Double, max: Double, defaultValue: Double) -> (min: Double, max: Double, defaultValue: Double)? {
        let alert = NSAlert()
        alert.messageText = "範囲と既定値"
        alert.informativeText = "最小・最大・既定値（既定値が基本ポーズ）"
        let fields = [min, max, defaultValue].enumerated().map { i, v -> NSTextField in
            let f = NSTextField(string: String(v))
            f.frame = NSRect(x: 0, y: CGFloat(2 - i) * 30, width: 120, height: 24)
            return f
        }
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 84))
        fields.forEach(box.addSubview)
        alert.accessoryView = box
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn,
              let a = Double(fields[0].stringValue), let b = Double(fields[1].stringValue), let d = Double(fields[2].stringValue), a < b
        else { return nil }
        return (a, b, d)
    }

    func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    func startPlayback() {
        stopPlayback()
        let t = editor.timeline
        if !t.loop && editor.currentFrame >= t.frameCount - 1 { editor.goToFrame(0) }
        isPlaying = true
        playTimer = Timer.scheduledTimer(withTimeInterval: 1 / Double(max(t.fps, 1)), repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = self.editor.timeline
            let next = self.editor.currentFrame + 1
            if next >= t.frameCount {
                if t.loop { self.editor.goToFrame(0) } else { self.stopPlayback() }
            } else {
                self.editor.goToFrame(next)
            }
        }
    }

    func stopPlayback() {
        playTimer?.invalidate()
        playTimer = nil
        isPlaying = false
    }
}

/// キャンバスの下に出すタイムライン。レイヤーの表示とスイッチフォルダーの子をコマごとに切り替える
struct TimelineView: View {
    let state: AppState
    @Bindable var editor: Editor
    /// マスの上のドラッグ
    private enum GridDrag {
        case scrub
        case toggled
        case moving(offset: Int)
        case marquee(start: CGPoint, current: CGPoint, initial: Set<TimelineKeyRef>)
    }
    @State private var gridDrag: GridDrag?
    /// コマ 1 つの幅（拡大縮小できる）
    @State private var cell: CGFloat = 18

    private let rulerHeight: CGFloat = 20
    private let nameWidth: CGFloat = 170
    private let rowHeight: CGFloat = 26

    var body: some View {
        let t = editor.timeline
        VStack(spacing: 0) {
            header(t)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 20)
                    ForEach(editor.rig.parameters, id: \.id) { p in parameterName(p) }
                    ForEach(t.tracks, id: \.layer) { track in trackName(track) }
                }
                .frame(width: nameWidth)
                Divider()
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ruler(t)
                        ForEach(editor.rig.parameters, id: \.id) { p in parameterRow(p, t) }
                        ForEach(t.tracks, id: \.layer) { track in trackRow(track, t) }
                    }
                    .overlay(alignment: .topLeading) { gridOverlay(t) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged(gridChanged).onEnded(gridEnded))
                }
            }
            .frame(height: 20 + CGFloat(max(t.tracks.count + editor.rig.parameters.count, 2)) * rowHeight)
            if t.tracks.isEmpty && editor.rig.parameters.isEmpty {
                Text("レイヤーやスイッチフォルダーを選んで「＋ トラック」で足します。表示を切り替えると今のコマにキーが打たれます。パラメータは左のリグパネルで足します。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 上段

    private func header(_ t: Timeline) -> some View {
        HStack(spacing: 10) {
            Button { state.togglePlayback() } label: { Image(systemName: state.isPlaying ? "stop.fill" : "play.fill") }
                .help(state.isPlaying ? "停止" : "再生")
            Button { editor.goToFrame(0) } label: { Image(systemName: "backward.end.fill") }
                .help("最初のコマへ")
            Text("\(editor.currentFrame + 1) / \(t.frameCount)")
                .font(.caption.monospacedDigit())
                .frame(width: 70, alignment: .leading)
            Divider().frame(height: 16)
            Stepper(value: Binding(get: { t.fps }, set: { editor.setTimeline(fps: $0); restartIfPlaying() }), in: 1...60) {
                Text("\(t.fps) fps").font(.caption.monospacedDigit())
            }
            Stepper(value: Binding(get: { t.frameCount }, set: { editor.setTimeline(frameCount: $0) }), in: 1...10_000) {
                Text("\(t.frameCount) コマ").font(.caption.monospacedDigit())
            }
            Toggle("ループ", isOn: Binding(get: { t.loop }, set: { editor.setTimeline(loop: $0) }))
                .toggleStyle(.checkbox).font(.caption)
            Divider().frame(height: 16)
            Button { cell = max(6, cell / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("タイムラインを縮める")
            Button { cell = min(48, cell * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("タイムラインを広げる")
            Spacer()
            Button {
                if let id = editor.activeLayerID { editor.addTrack(trackTarget(id)) }
            } label: {
                Label("トラック", systemImage: "plus")
            }
            .help("編集中のレイヤーをトラックに足す（スイッチフォルダーの子なら、そのフォルダー）")
            .disabled(editor.activeLayerID.map { id in
                editor.doc.node(trackTarget(id)).map { editor.timeline.track(for: $0.psdID) != nil && $0.psdID != 0 } ?? true
            } ?? true)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func restartIfPlaying() {
        if state.isPlaying { state.startPlayback() }
    }

    /// スイッチフォルダーの子を選んでいるときは、フォルダーのトラックにする
    private func trackTarget(_ id: UUID) -> UUID {
        guard editor.isInSwitch(id), let path = editor.doc.indexPath(of: id),
              let parent = editor.doc.node(at: Array(path.dropLast())) else { return id }
        return parent.id
    }

    // MARK: パラメータ

    private func parameterName(_ p: RigParameter) -> some View {
        let editing = state.editingParameter == p.id
        let hasTrack = editor.timeline.parameterTracks.contains { $0.parameter == p.id }
        return HStack(spacing: 4) {
            Image(systemName: "slider.horizontal.3").font(.caption).foregroundStyle(editing ? Color.accentColor : .secondary).frame(width: 16)
            Text(p.name).font(.caption.weight(editing ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(hasTrack ? .primary : .secondary)
            Spacer(minLength: 0)
            Text(String(format: "%.2f", editor.parameterValue(p.id))).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(editing ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { state.editingParameter = editing ? nil : p.id }
        .contextMenu {
            if hasTrack {
                Button("トラックを削除") { editor.removeParameterTrack(p.id) }
            } else {
                Button("トラックに追加") { editor.addParameterTrack(p.id) }
            }
        }
    }

    private func parameterRow(_ p: RigParameter, _ t: Timeline) -> some View {
        let track = t.parameterTracks.first { $0.parameter == p.id }
        return HStack(spacing: 0) {
            ForEach(0..<t.frameCount, id: \.self) { f in
                let key = track?.keys.first { $0.frame == f }
                ZStack {
                    Rectangle().fill(f == editor.currentFrame ? Color.accentColor.opacity(0.18) : (f % 2 == 0 ? Color.primary.opacity(0.03) : Color.clear))
                    if let key {
                        selectionMark(.parameter(p.id, frame: f))
                        Image(systemName: Self.easingSymbol(key.easing)).font(.system(size: 9)).foregroundStyle(Color.orange)
                            .help("動き方: \(key.easing.displayName)")
                    } else if track == nil {
                        Rectangle().fill(Color.primary.opacity(0.02))
                    }
                }
                .frame(width: cell, height: rowHeight)
                .overlay(alignment: .bottom) { Divider() }
                .contextMenu {
                    Button("ここにキーを打つ（今の値）") {
                        let v = editor.parameterValue(p.id)
                        editor.goToFrame(f)
                        editor.setParameterKey(p.id, frame: f, value: v)
                    }
                    if let key {
                        Menu("動き方（次のキーまで）") {
                            ForEach(Easing.allCases, id: \.self) { e in
                                Button {
                                    editor.setParameterKeyEasing(p.id, frame: f, easing: e)
                                } label: {
                                    if e == key.easing { Label(e.displayName, systemImage: "checkmark") } else { Text(e.displayName) }
                                }
                            }
                        }
                        Button("キーを削除") { editor.deleteParameterKey(p.id, frame: f) }
                    }
                }
            }
        }
    }

    // MARK: マスの操作（キーの選択・移動・範囲選択・再生位置）

    /// 行の並び（パラメータ、レイヤーのトラックの順）
    private var rowIDs: [TimelineKeyRef] {
        editor.rig.parameters.map { .parameter($0.id, frame: 0) } + editor.timeline.tracks.map { .layer($0.layer, frame: 0) }
    }

    /// 行 row のコマ frame にキーがあれば、その参照
    private func keyRef(row: Int, frame: Int) -> TimelineKeyRef? {
        let rows = rowIDs
        guard rows.indices.contains(row), frame >= 0 else { return nil }
        let ref: TimelineKeyRef
        switch rows[row] {
        case let .parameter(p, _): ref = .parameter(p, frame: frame)
        case let .layer(l, _): ref = .layer(l, frame: frame)
        }
        return editor.existingKeys([ref]).isEmpty ? nil : ref
    }

    private func rowIndex(_ ref: TimelineKeyRef) -> Int? {
        rowIDs.firstIndex { r in
            switch (r, ref) {
            case let (.parameter(a, _), .parameter(b, _)): return a == b
            case let (.layer(a, _), .layer(b, _)): return a == b
            default: return false
            }
        }
    }

    private func frame(at x: CGFloat) -> Int { max(0, Int(x / cell)) }

    private func gridChanged(_ v: DragGesture.Value) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        if gridDrag == nil {
            let loc = v.startLocation
            if loc.y < rulerHeight {
                gridDrag = .scrub
            } else if let ref = keyRef(row: Int((loc.y - rulerHeight) / rowHeight), frame: frame(at: loc.x)) {
                if shift {
                    if state.timelineSelection.contains(ref) { state.timelineSelection.remove(ref) } else { state.timelineSelection.insert(ref) }
                    gridDrag = .toggled
                } else {
                    if !state.timelineSelection.contains(ref) { state.timelineSelection = [ref] }
                    gridDrag = .moving(offset: 0)
                }
            } else {
                let initial = shift ? state.timelineSelection : []
                state.timelineSelection = initial
                gridDrag = .marquee(start: loc, current: loc, initial: initial)
            }
        }
        switch gridDrag {
        case .scrub:
            editor.goToFrame(frame(at: v.location.x))
        case .moving:
            gridDrag = .moving(offset: Int((v.translation.width / cell).rounded()))
        case let .marquee(start, _, initial):
            gridDrag = .marquee(start: start, current: v.location, initial: initial)
            let r = CGRect(x: min(start.x, v.location.x), y: min(start.y, v.location.y),
                           width: abs(v.location.x - start.x), height: abs(v.location.y - start.y))
            var sel = initial
            for (i, row) in rowIDs.enumerated() {
                let cy = rulerHeight + CGFloat(i) * rowHeight + rowHeight / 2
                guard cy >= r.minY && cy <= r.maxY else { continue }
                let f0 = max(0, Int(ceil(r.minX / cell - 0.5))), f1 = Int(floor(r.maxX / cell - 0.5))
                guard f0 <= f1 else { continue }
                for f in f0...f1 {
                    let ref: TimelineKeyRef
                    switch row {
                    case let .parameter(p, _): ref = .parameter(p, frame: f)
                    case let .layer(l, _): ref = .layer(l, frame: f)
                    }
                    sel.insert(ref)
                }
            }
            state.timelineSelection = editor.existingKeys(sel)
        default:
            break
        }
    }

    private func gridEnded(_ v: DragGesture.Value) {
        switch gridDrag {
        case let .moving(offset):
            if offset != 0 {
                state.timelineSelection = editor.moveKeys(state.timelineSelection, by: offset)
            } else {
                editor.goToFrame(frame(at: v.startLocation.x))
            }
        case let .marquee(start, current, _):
            // ほとんど動かさなければクリック: 選択を外して再生位置を動かす
            if hypot(current.x - start.x, current.y - start.y) < 3 { editor.goToFrame(frame(at: start.x)) }
        default:
            break
        }
        gridDrag = nil
    }

    /// 選んだキーの下地
    private func selectionMark(_ ref: TimelineKeyRef) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(state.timelineSelection.contains(ref) ? Color.accentColor.opacity(0.45) : Color.clear)
            .frame(width: min(cell, 16), height: 16)
            .frame(width: cell)
    }

    /// 範囲選択の枠と、動かしている間の行き先
    @ViewBuilder
    private func gridOverlay(_ t: Timeline) -> some View {
        ZStack(alignment: .topLeading) {
            if case let .marquee(start, current, _) = gridDrag {
                Rectangle()
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .background(Color.accentColor.opacity(0.08))
                    .frame(width: abs(current.x - start.x), height: abs(current.y - start.y))
                    .offset(x: min(start.x, current.x), y: min(start.y, current.y))
            }
            if case let .moving(offset) = gridDrag, offset != 0 {
                ForEach(Array(state.timelineSelection), id: \.self) { ref in
                    if let row = rowIndex(ref) {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                            .frame(width: min(cell, 16), height: 16)
                            .offset(x: CGFloat(ref.frame + offset) * cell + (cell - min(cell, 16)) / 2,
                                    y: rulerHeight + CGFloat(row) * rowHeight + (rowHeight - 16) / 2)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// キーの印: 直線は ◆、緩急ありは ●、止めるは ■
    static func easingSymbol(_ e: Easing) -> String {
        switch e {
        case .linear: return "diamond.fill"
        case .hold: return "square.fill"
        default: return "circle.fill"
        }
    }

    // MARK: トラック

    private func trackName(_ track: TimelineTrack) -> some View {
        let node = editor.doc.node(psdID: track.layer)
        return HStack(spacing: 4) {
            Image(systemName: node?.isSwitch == true ? "switch.2" : node?.isFolder == true ? "folder" : "photo")
                .font(.caption).foregroundStyle(.secondary).frame(width: 16)
            Text(node?.name ?? "（削除されたレイヤー）").font(.caption).lineLimit(1)
                .foregroundStyle(node == nil ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .contextMenu {
            Button("トラックを削除") { editor.removeTrack(layer: track.layer) }
        }
    }

    private func ruler(_ t: Timeline) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<t.frameCount, id: \.self) { f in
                ZStack(alignment: .leading) {
                    Rectangle().fill(f == editor.currentFrame ? Color.accentColor.opacity(0.5) : Color.clear)
                    if f % labelEvery == 0 {
                        Text("\(f + 1)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary).padding(.leading, 2)
                            .fixedSize()
                    }
                }
                .frame(width: cell, height: rulerHeight)
            }
        }
    }

    /// 目盛りの数字の間隔（狭いほど間引く）
    private var labelEvery: Int { cell >= 14 ? 6 : cell >= 9 ? 12 : 24 }

    private func trackRow(_ track: TimelineTrack, _ t: Timeline) -> some View {
        let node = editor.doc.node(psdID: track.layer)
        return HStack(spacing: 0) {
            ForEach(0..<t.frameCount, id: \.self) { f in
                let key = track.keys.first { $0.frame == f }
                ZStack(alignment: .leading) {
                    Rectangle().fill(f == editor.currentFrame ? Color.accentColor.opacity(0.18) : (f % 2 == 0 ? Color.primary.opacity(0.03) : Color.clear))
                    if let key {
                        selectionMark(.layer(track.layer, frame: f))
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(key.visible == false ? Color.secondary : Color.accentColor)
                            .frame(width: cell)
                        // コマが狭いときは重なるので名前を出さない
                        if cell >= 14, let child = key.child, let name = node?.children.first(where: { $0.psdID == child })?.name {
                            Text(name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                                .offset(x: cell)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(width: cell, height: rowHeight)
                .overlay(alignment: .bottom) { Divider() }
                .contextMenu {
                    Button("ここにキーを打つ（今の表示）") {
                        editor.goToFrame(f)
                        editor.setKeyFromCurrentState(layer: track.layer, frame: f)
                    }
                    if key != nil {
                        Button("キーを削除") { editor.deleteKey(layer: track.layer, frame: f) }
                    }
                }
            }
        }
    }
}

/// パラメータのつまみ。既定値に縦線、形を記録した値に ◆ を出す。
/// ドラッグで値を変え（◆ の近くでは吸い付く）、◆ をクリックするとその値に、右クリックで形を消せる
struct ParameterSlider: View {
    let editor: Editor
    let parameter: RigParameter
    let value: Double

    /// 上の段に ◆、下の段につまみ
    private let height: CGFloat = 24
    private let inset: CGFloat = 6
    private let trackY: CGFloat = 16

    private func x(_ v: Double, _ w: CGFloat) -> CGFloat {
        inset + CGFloat((v - parameter.min) / max(parameter.max - parameter.min, 1e-9)) * w
    }

    /// 位置から値。◆ と既定値の近く（4px 以内）では吸い付く
    private func value(at px: CGFloat, _ w: CGFloat) -> Double {
        let p = parameter
        let v = p.min + Double(min(max((px - inset) / max(w, 1), 0), 1)) * (p.max - p.min)
        let snaps = p.keys.map(\.value) + [p.defaultValue]
        if let s = snaps.min(by: { abs(x($0, w) - px) < abs(x($1, w) - px) }), abs(x(s, w) - px) < 4 { return s }
        return v
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - inset * 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.primary.opacity(0.15)).frame(width: w, height: 3).offset(x: inset, y: trackY - 1.5)
                // 既定値
                Rectangle().fill(Color.secondary).frame(width: 1, height: 10)
                    .offset(x: x(parameter.defaultValue, w) - 0.5, y: trackY - 5)
                // つまみ
                Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                    .offset(x: x(value, w) - 5, y: trackY - 5)
                    .allowsHitTesting(false)
                // 形を記録した値
                ForEach(parameter.keys, id: \.value) { k in
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.orange)
                        .frame(width: 10, height: 10)
                        .offset(x: x(k.value, w) - 5, y: 0)
                        .onTapGesture { editor.setParameterValue(parameter.id, k.value) }
                        .help(String(format: "%.2f に形を記録済み（クリックで移動、右クリックで消す）", k.value))
                        .contextMenu {
                            Button(String(format: "%.2f の形を消す", k.value)) {
                                editor.removeParameterKey(parameter: parameter.id, value: k.value)
                            }
                        }
                }
            }
            .frame(width: geo.size.width, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                editor.setParameterValue(parameter.id, value(at: g.location.x, w))
            })
        }
        .frame(height: height)
    }
}
