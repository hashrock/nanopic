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

extension AppState {
    /// 編集中のレイヤー（フォルダー）におまかせの動きを付け、リグモードで再生して見せる
    func addMotion(_ preset: MotionPreset) {
        guard let id = editor.activeLayerID, editor.addMotion(preset, to: id) != nil else {
            showError("動かす絵がありません。描いてあるレイヤーかフォルダーを選んでください。")
            return
        }
        // 動きを見るにはリグモードがいるので、実験的な機能でも入れる
        rigEnabled = true
        setMode(.rig)
        startPlayback()
        flashStatus("「\(preset.displayName)」の動きを付けました。ファイル ＞ 動画を書き出し で GIF などにできます")
    }

    /// 編集中のフォルダー（レイヤー）を立体的に振り向かせ、リグモードで見回すループを再生する
    func addTurn() {
        guard let id = editor.activeLayerID, editor.addTurn(to: id) != nil else {
            showError("振り向かせる絵がありません。顔などのパーツをまとめたフォルダーか、描いてあるレイヤーを選んでください。")
            return
        }
        rigEnabled = true
        followsCursor = false
        setMode(.rig)
        startPlayback()
        flashStatus("振り向くリグを付けました。リグパネルの「カーソルの方を向く」で、マウスの方を向かせられます")
    }

    /// 振り向くリグをカーソルに追わせるのを入り切りする（追っている間は再生しない）
    func setFollowsCursor(_ on: Bool) {
        followsCursor = on
        if on {
            stopPlayback()
        } else {
            editor.goToFrame(editor.currentFrame)
        }
    }
}
