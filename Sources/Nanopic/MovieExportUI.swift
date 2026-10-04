import AppKit
import NanopicCore
import SwiftUI
import UniformTypeIdentifiers

/// 書き出しの進み具合（シートに出す）
@Observable
final class MovieExportProgress {
    var done = 0
    var total = 1
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

extension AppState {
    /// ファイル ＞ 動画を書き出し
    func exportMovie(_ format: MovieFormat) {
        editor.commitTransform()
        let options = editor.movieOptions(format: format)
        let panel = NSSavePanel()
        let base = editor.fileURL?.deletingPathExtension().lastPathComponent ?? "無題"
        switch format {
        case .mp4: panel.allowedContentTypes = [.mpeg4Movie]
        case .prores: panel.allowedContentTypes = [.quickTimeMovie]
        case .apng: panel.allowedContentTypes = [.png]
        case .pngSequence: break
        }
        panel.nameFieldStringValue = format == .pngSequence ? base + "_frames" : base + "." + format.fileExtension
        var notes: [String] = []
        if format == .pngSequence { notes.append("この名前のフォルダーを作り、中にコマごとの PNG を書きます。") }
        if format.supportsAlpha && options.effectiveBackground == .transparent {
            notes.append("透明にするには、用紙のレイヤーを隠してください。")
        }
        if !notes.isEmpty { panel.message = notes.joined(separator: " ") }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let doc = editor.doc
        let values = editor.parameterValues
        let progress = MovieExportProgress()
        progress.total = doc.timeline.frameCount
        movieExport = progress
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try MovieExport.export(doc, to: url, values: values, options: options) { done, total in
                    DispatchQueue.main.async { progress.done = done; progress.total = total }
                    return !progress.isCancelled
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.movieExport = nil
                switch result {
                case .success:
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failure(let e) where e is MovieExport.Cancelled:
                    break
                case .failure(let e):
                    self.showError("動画を書き出せませんでした: \(e)")
                }
            }
        }
    }
}

struct MovieExportSheet: View {
    let progress: MovieExportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("動画を書き出しています").font(.headline)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            HStack {
                Text("\(progress.done) / \(progress.total) コマ").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル") { progress.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
