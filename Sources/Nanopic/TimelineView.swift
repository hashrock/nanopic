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

    func setTimelineOpen(_ open: Bool) {
        if !open { stopPlayback() }
        editor.timelineOpen = open
        timelineOpen = open
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
    @State private var dragging: (layer: UInt32, from: Int)?
    @State private var paramDragging: (id: String, from: Int)?

    private let cell: CGFloat = 18
    private let nameWidth: CGFloat = 230
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
                }
            }
            .frame(height: 20 + CGFloat(max(t.tracks.count + editor.rig.parameters.count, 2)) * rowHeight)
            if t.tracks.isEmpty && editor.rig.parameters.isEmpty {
                Text("レイヤーやスイッチフォルダーを選んで「＋ トラック」で足します。開いている間は、表示を切り替えると今のコマにキーが打たれます。")
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
            Spacer()
            if editor.isPosed {
                Text("ポーズ中（描けません）").font(.caption).foregroundStyle(.orange)
                Button("基本ポーズに戻す") { editor.resetPose() }
            }
            Button {
                let id = editor.addParameter(name: "パラメータ\(editor.rig.parameters.count + 1)")
                state.editingParameter = id
            } label: {
                Label("パラメータ", systemImage: "plus")
            }
            .help("パラメータ（名前つきのつまみ）を足す。デフォーマの形をつまみの値ごとに記録して動かす")
            Button {
                if let id = editor.activeLayerID { editor.addTrack(trackTarget(id)) }
            } label: {
                Label("トラック", systemImage: "plus")
            }
            .help("編集中のレイヤーをトラックに足す（スイッチフォルダーの子なら、そのフォルダー）")
            .disabled(editor.activeLayerID.map { id in
                editor.doc.node(trackTarget(id)).map { editor.timeline.track(for: $0.psdID) != nil && $0.psdID != 0 } ?? true
            } ?? true)
            Button { state.setTimelineOpen(false) } label: { Image(systemName: "xmark") }
                .help("タイムラインを閉じる")
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
        let value = editor.parameterValue(p.id)
        return HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3").font(.caption).foregroundStyle(editing ? Color.accentColor : .secondary).frame(width: 16)
            Text(p.name).font(.caption.weight(editing ? .semibold : .regular)).lineLimit(1).frame(width: 64, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { editor.setParameterValue(p.id, $0) }), in: p.min...max(p.max, p.min + 1e-6))
                .controlSize(.mini)
            Text(String(format: "%.2f", value)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary).frame(width: 30)
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(editing ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { state.editingParameter = editing ? nil : p.id }
        .help("クリックで、このパラメータの形を記録する対象にする（キャンバス上のデフォーマのハンドルで形を決める）")
        .contextMenu {
            Button("名前を変える...") {
                if let name = state.promptText("パラメータの名前", value: p.name), !name.isEmpty {
                    editor.updateParameter(p.id) { $0.name = name }
                }
            }
            Button("範囲と既定値...") {
                if let r = state.promptRange(min: p.min, max: p.max, defaultValue: p.defaultValue) {
                    editor.updateParameter(p.id) { $0.min = r.min; $0.max = r.max; $0.defaultValue = $0.clamp(r.defaultValue) }
                }
            }
            Divider()
            if editor.timeline.parameterTracks.contains(where: { $0.parameter == p.id }) {
                Button("トラックを削除") { editor.removeParameterTrack(p.id) }
            } else {
                Button("トラックに追加") { editor.addParameterTrack(p.id) }
            }
            Divider()
            Button("パラメータを削除") {
                if state.editingParameter == p.id { state.editingParameter = nil }
                editor.removeParameter(p.id)
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
                    if key != nil {
                        Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(Color.orange)
                    } else if track == nil {
                        Rectangle().fill(Color.primary.opacity(0.02))
                    }
                }
                .frame(width: cell, height: rowHeight)
                .overlay(alignment: .bottom) { Divider() }
                .contentShape(Rectangle())
                .onTapGesture { editor.goToFrame(f) }
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { _ in if key != nil, paramDragging == nil { paramDragging = (p.id, f) } }
                    .onEnded { v in
                        if let d = paramDragging {
                            editor.moveParameterKey(d.id, from: d.from, to: d.from + Int((v.translation.width / cell).rounded()))
                        }
                        paramDragging = nil
                    })
                .contextMenu {
                    Button("ここにキーを打つ（今の値）") {
                        let v = editor.parameterValue(p.id)
                        editor.goToFrame(f)
                        editor.setParameterKey(p.id, frame: f, value: v)
                    }
                    if key != nil {
                        Button("キーを削除") { editor.deleteParameterKey(p.id, frame: f) }
                    }
                }
            }
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
                    if f % 6 == 0 {
                        Text("\(f + 1)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary).padding(.leading, 2)
                            .fixedSize()
                    }
                }
                .frame(width: cell, height: 20)
                .contentShape(Rectangle())
                .onTapGesture { editor.goToFrame(f) }
            }
        }
    }

    private func trackRow(_ track: TimelineTrack, _ t: Timeline) -> some View {
        let node = editor.doc.node(psdID: track.layer)
        return HStack(spacing: 0) {
            ForEach(0..<t.frameCount, id: \.self) { f in
                let key = track.keys.first { $0.frame == f }
                ZStack(alignment: .leading) {
                    Rectangle().fill(f == editor.currentFrame ? Color.accentColor.opacity(0.18) : (f % 2 == 0 ? Color.primary.opacity(0.03) : Color.clear))
                    if let key {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(key.visible == false ? Color.secondary : Color.accentColor)
                            .frame(width: cell)
                        if let child = key.child, let name = node?.children.first(where: { $0.psdID == child })?.name {
                            Text(name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                                .offset(x: cell)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(width: cell, height: rowHeight)
                .overlay(alignment: .bottom) { Divider() }
                .contentShape(Rectangle())
                .onTapGesture { editor.goToFrame(f) }
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { _ in if key != nil, dragging == nil { dragging = (track.layer, f) } }
                    .onEnded { v in
                        if let d = dragging {
                            editor.moveKey(layer: d.layer, from: d.from, to: d.from + Int((v.translation.width / cell).rounded()))
                        }
                        dragging = nil
                    })
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
