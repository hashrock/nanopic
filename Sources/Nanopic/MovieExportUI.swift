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
    /// ファイル ＞ 動画を書き出し（MP4）
    func exportMovie() {
        editor.commitTransform()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = (editor.fileURL?.deletingPathExtension().lastPathComponent ?? "無題") + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let doc = editor.doc
        let values = editor.parameterValues
        let progress = MovieExportProgress()
        progress.total = doc.timeline.frameCount
        movieExport = progress
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try MovieExport.export(doc, to: url, values: values) { done, total in
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
