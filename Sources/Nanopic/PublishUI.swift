import AppKit
import NanopicCore
import SwiftUI
import UniformTypeIdentifiers

/// 書き出し（publish）: ファイルメニューの「書き出し設定」を開いている間だけ、キャンバスに書き出し枠と設定のパネルを出す
extension AppState {
    func openPublishSettings() {
        editor.commitTransform()
        if adjustmentKind != nil { closeAdjustment(commit: false) }
        publishDraft = editor.publishSettings.normalized(canvas: editor.doc.bounds)
        canvasView?.requestDisplay()
    }

    /// 閉じる。commit なら設定を作品に入れる（取り消せる）
    func closePublishSettings(commit: Bool) {
        if commit, let d = publishDraft { editor.setPublishSettings(d) }
        publishDraft = nil
        canvasView?.requestDisplay()
    }

    /// 書き出す（⌥⌘E）。書き出し先がまだなければ聞く。2 回目からは同じ所に上書きする
    func publishNow() {
        if publishDraft != nil { closePublishSettings(commit: true) }
        var s = editor.publishSettings
        var url = editor.publishDestinationURL(s)
        if url == nil {
            guard let chosen = choosePublishDestination(s) else { return }
            s.destination = editor.publishDestinationString(for: chosen)
            editor.setPublishSettings(s, label: "書き出し先")
            url = chosen
        }
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try editor.publish(to: url, settings: s)
            let size = s.resolvedOutputSize(canvas: editor.doc.bounds)
            flashStatus("書き出しました: \(url.lastPathComponent)（\(size.width) × \(size.height)）")
        } catch {
            showError("書き出しに失敗しました: \(error.localizedDescription)")
        }
    }

    /// 書き出し先を選ぶ（形式の拡張子にする）
    func choosePublishDestination(_ s: PublishSettings) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [s.format.utType]
        let current = editor.publishDestinationURL(s)
        let base = current?.deletingPathExtension().lastPathComponent
            ?? editor.fileURL?.deletingPathExtension().lastPathComponent ?? "無題"
        panel.nameFieldStringValue = base + "." + s.format.fileExtension
        panel.directoryURL = current?.deletingLastPathComponent() ?? editor.fileURL?.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 選択範囲を書き出し範囲にする（設定を開いていればその中で）
    func setPublishRectFromSelection() {
        guard let sel = editor.doc.selection, !sel.bounds.isEmpty else { NSSound.beep(); return }
        if var d = publishDraft {
            let canvas = editor.doc.bounds
            d.rect = Publish.expand(sel.bounds.intersection(canvas), aspect: d.aspect(canvas: canvas), canvas: canvas)
            publishDraft = d
            canvasView?.requestDisplay()
        } else {
            editor.setPublishRectFromSelection()
        }
    }

    /// ステータスバーに少しの間だけ出す
    func flashStatus(_ message: String) {
        statusMessage = message
        let token = UUID()
        statusToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.statusToken == token { self?.statusMessage = nil }
        }
    }
}

/// キャンバスの隅に浮かぶ書き出し設定のパネル
struct PublishPanel: View {
    let state: AppState
    @State private var lock = true

    private var canvas: IntRect { state.editor.doc.bounds }

    private var draft: PublishSettings { state.publishDraft ?? PublishSettings() }

    private func update(_ body: (inout PublishSettings) -> Void) {
        guard var d = state.publishDraft else { return }
        body(&d)
        state.publishDraft = d
        state.canvasView?.requestDisplay()
    }

    var body: some View {
        let d = draft
        let r = d.resolvedRect(canvas: canvas)
        let o = d.resolvedOutputSize(canvas: canvas)
        VStack(alignment: .leading, spacing: 10) {
            Text("書き出し設定").font(.headline)

            section("範囲") {
                HStack(spacing: 6) {
                    number("X", r.x) { v in update { $0.setRectOrigin(x: v, canvas: canvas) } }
                    number("Y", r.y) { v in update { $0.setRectOrigin(y: v, canvas: canvas) } }
                }
                HStack(spacing: 6) {
                    number("幅", r.width) { v in update { $0.setRectSize(width: v, canvas: canvas) } }
                    number("高さ", r.height) { v in update { $0.setRectSize(height: v, canvas: canvas) } }
                }
                HStack {
                    Button("キャンバス全体") { update { $0.setWholeCanvas(canvas) } }
                    Button("選択範囲から") { state.setPublishRectFromSelection() }
                        .disabled(state.editor.doc.selection == nil)
                }
                .controlSize(.small)
            }

            section("出力の大きさ") {
                HStack(spacing: 6) {
                    number("幅", o.width) { v in update { $0.setOutputSize(width: v, lock: lock, canvas: canvas) } }
                    Text("×").foregroundStyle(.secondary)
                    number("高さ", o.height) { v in update { $0.setOutputSize(height: v, lock: lock, canvas: canvas) } }
                }
                HStack {
                    Toggle("比率を保つ", isOn: $lock).toggleStyle(.checkbox)
                    Spacer()
                    Button("等倍") { update { $0.setActualSize(canvas: canvas) } }
                        .controlSize(.small)
                        .help("出力を範囲と同じ大きさにする")
                }
                .font(.caption)
            }

            section("形式") {
                Picker("", selection: Binding(get: { d.format }, set: { f in
                    update { s in
                        s.format = f
                        // 書き出し先の拡張子も合わせる
                        if let dest = s.destination, !dest.isEmpty {
                            s.destination = (dest as NSString).deletingPathExtension + "." + f.fileExtension
                        }
                    }
                })) {
                    ForEach(PublishFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if d.format.hasQuality {
                    HStack {
                        Text("品質").font(.caption)
                        Slider(value: Binding(get: { Double(d.quality) }, set: { v in update { $0.quality = Int(v.rounded()) } }), in: 1...100)
                            .controlSize(.small)
                        Text("\(d.quality)").font(.caption.monospacedDigit()).frame(width: 28, alignment: .trailing)
                    }
                }
                Picker("透明な所", selection: Binding(get: { d.effectiveBackground }, set: { b in update { $0.background = b } })) {
                    ForEach(PublishBackground.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .font(.caption)
                .disabled(!d.format.supportsAlpha)
            }

            section("書き出し先") {
                HStack {
                    Text(state.editor.publishDestinationURL(d)?.lastPathComponent ?? "（初回に選びます）")
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(d.destination == nil ? .secondary : .primary)
                        .help(state.editor.publishDestinationURL(d)?.path ?? "")
                    Spacer()
                    Button("変える...") {
                        if let url = state.choosePublishDestination(d) {
                            update { $0.destination = state.editor.publishDestinationString(for: url) }
                        }
                    }
                    .controlSize(.small)
                }
            }

            HStack {
                Button("キャンセル") { state.closePublishSettings(commit: false) }
                Spacer()
                Button("OK") { state.closePublishSettings(commit: true) }
                Button("書き出す") { state.publishNow() }
                    .buttonStyle(.borderedProminent)
                    .help("書き出す（⌥⌘E）")
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func number(_ label: String, _ value: Int, _ set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: Binding(get: { value }, set: { set($0) }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .frame(width: 64)
        }
    }
}

// MARK: キャンバスの書き出し枠

extension CanvasView {
    /// 書き出し枠のつまみの位置（ビューの座標）。Publish.dragRect のつまみの番号の順
    func publishHandlePositions(_ r: IntRect) -> [(Int, CGPoint)] {
        let t = canvasToView
        let x0 = CGFloat(r.minX), y0 = CGFloat(r.minY), x1 = CGFloat(r.maxX), y1 = CGFloat(r.maxY)
        let mx = (x0 + x1) / 2, my = (y0 + y1) / 2
        let pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1), (mx, y0), (x1, my), (mx, y1), (x0, my)]
        return pts.enumerated().map { ($0.offset, CGPoint(x: $0.element.0, y: $0.element.1).applying(t)) }
    }

    /// 書き出し枠のどこを押したか（つまみ、内側。外なら nil）
    func hitPublishFrame(_ vp: CGPoint) -> Int? {
        guard let d = state.publishDraft else { return nil }
        let r = d.resolvedRect(canvas: editor.doc.bounds)
        for (i, p) in publishHandlePositions(r) where hypot(p.x - vp.x, p.y - vp.y) < 8 { return i }
        let cp = vp.applying(viewToCanvas)
        if CGRect(x: r.x, y: r.y, width: r.width, height: r.height).contains(cp) { return Publish.insideHandle }
        return nil
    }
}

extension OverlayView {
    /// 書き出し枠: 外を暗くし、枠とつまみと出力の大きさを描く
    func drawPublishFrame(_ ctx: CGContext, canvas: CanvasView, t: CGAffineTransform) {
        guard let d = canvas.state.publishDraft else { return }
        let r = d.resolvedRect(canvas: canvas.editor.doc.bounds)
        let o = d.resolvedOutputSize(canvas: canvas.editor.doc.bounds)
        var tt = t
        let frame = CGPath(rect: CGRect(x: r.x, y: r.y, width: r.width, height: r.height), transform: &tt)
        ctx.saveGState()
        ctx.addRect(bounds)
        ctx.addPath(frame)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.addPath(frame)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        for (_, p) in canvas.publishHandlePositions(r) {
            let h = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(h)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.stroke(h)
        }
        ctx.restoreGState()
        // 出力の大きさを枠の上に
        let top = canvas.publishHandlePositions(r)[0].1
        let label = "\(o.width) × \(o.height)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let bg = CGRect(x: top.x, y: top.y - size.height - 8, width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 3, yRadius: 3).fill()
        label.draw(at: CGPoint(x: bg.minX + 5, y: bg.minY + 2), withAttributes: attrs)
    }
}
