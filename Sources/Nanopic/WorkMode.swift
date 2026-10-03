import AppKit
import NanopicCore

/// 画面のモード。アニメーションモードでは変形を表示し、描けない（描くツールを出さない）
enum WorkMode: String {
    case draw, animate

    var title: String { self == .draw ? "描く" : "アニメーション" }
}

extension AppState {
    /// アニメーションモードで使えるツール
    /// 矩形選択はデフォーマのハンドルを囲んで選ぶのに使う
    static let animationTools: [Tool] = [.selectRect, .hand, .zoom]

    func setMode(_ m: WorkMode) {
        guard m != mode else { return }
        editor.commitTransform()
        if m == .animate {
            if adjustmentKind != nil { closeAdjustment(commit: false) }
            toolBeforeAnimation = editor.tool
            if !Self.animationTools.contains(editor.tool) { editor.selectTool(.selectRect) }
            editor.timelineOpen = true
            editor.setShowsDeformation(true)
        } else {
            stopPlayback()
            canvasView?.selectedDeformerHandles = []
            timelineSelection = []
            editor.timelineOpen = false
            editor.setShowsDeformation(false)
            if let t = toolBeforeAnimation { editor.selectTool(t) }
        }
        mode = m
        canvasView?.requestDisplay()
    }
}
