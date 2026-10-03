import AppKit
import NanopicCore

/// 画面のモード。リグモード（デフォーマとパラメータで絵を動かす、実験的な機能）では変形を表示し、描けない
/// （描くツールを出さない）。設定の「実験的な機能」で入れたときだけ入れる。
/// 描くモードでもタイムラインは出せる（変形は表示しないので、パラパラを描ける）
enum WorkMode: String {
    case draw, rig

    var title: String { self == .draw ? "描く" : "リグ" }
}

extension AppState {
    /// リグモードで使えるツール
    /// 矩形選択はデフォーマのハンドルを囲んで選ぶのに使う
    static let rigTools: [Tool] = [.selectRect, .hand, .zoom]

    func setMode(_ m: WorkMode) {
        guard m != mode else { return }
        editor.commitTransform()
        if m == .rig {
            if adjustmentKind != nil { closeAdjustment(commit: false) }
            toolBeforeRig = editor.tool
            if !Self.rigTools.contains(editor.tool) { editor.selectTool(.selectRect) }
            editor.timelineOpen = true
            editor.setShowsDeformation(true)
        } else {
            if !showsTimelineInDraw { stopPlayback() }
            canvasView?.selectedDeformerHandles = []
            timelineSelection = []
            editor.setShowsDeformation(false)
            if let t = toolBeforeRig { editor.selectTool(t) }
        }
        mode = m
        editor.timelineOpen = timelineOpen
        canvasView?.requestDisplay()
    }
}
