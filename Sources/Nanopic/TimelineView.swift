import AppKit
import NanopicCore
import SwiftUI

extension AppState {
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

    private let cell: CGFloat = 18
    private let nameWidth: CGFloat = 150
    private let rowHeight: CGFloat = 26

    var body: some View {
        let t = editor.timeline
        VStack(spacing: 0) {
            header(t)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 20)
                    ForEach(t.tracks, id: \.layer) { track in trackName(track) }
                }
                .frame(width: nameWidth)
                Divider()
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ruler(t)
                        ForEach(t.tracks, id: \.layer) { track in trackRow(track, t) }
                    }
                }
            }
            .frame(height: 20 + CGFloat(max(t.tracks.count, 2)) * rowHeight)
            if t.tracks.isEmpty {
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
