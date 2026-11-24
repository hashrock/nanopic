import NanopicCore
import SwiftUI

/// 新規作成（⌘N・タブバーの＋）のしかた（設定 ＞ 新規作成）
struct NewDocumentPreferences: Codable, Equatable {
    /// サイズを聞くシートを出す（false ならすぐ作る）
    var asksSize = false
    /// すぐ作るときのサイズ。true なら前回作ったサイズ、false なら下の決まったサイズ
    var usesLastSize = true
    var width = 1920
    var height = 1080

    private static let key = "newDocumentPreferences.v1"

    static func load() -> NewDocumentPreferences {
        guard let d = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(NewDocumentPreferences.self, from: d) else { return NewDocumentPreferences() }
        return p
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

extension AppState {
    /// 新規作成で使うサイズ（シートを出すときは、その最初の値）
    var newDocumentSize: (width: Int, height: Int) {
        newDocumentPreferences.usesLastSize ? Self.lastNewDocumentSize : (newDocumentPreferences.width, newDocumentPreferences.height)
    }

    /// ⌘N・タブバーの＋。設定に従って、サイズを聞くかすぐ作る
    func newDocumentFromCommand() {
        if newDocumentPreferences.asksSize {
            showNewDocumentSheet = true
        } else {
            let s = newDocumentSize
            newDocument(width: s.width, height: s.height)
        }
    }
}

/// 設定ウィンドウの「新規作成」タブ
struct NewDocumentSettingsView: View {
    let state: AppState

    private func binding<T>(_ key: WritableKeyPath<NewDocumentPreferences, T>) -> Binding<T> {
        Binding(get: { state.newDocumentPreferences[keyPath: key] }, set: { state.newDocumentPreferences[keyPath: key] = $0 })
    }

    private var prefs: NewDocumentPreferences { state.newDocumentPreferences }

    var body: some View {
        Form {
            Section {
                Picker("新規作成のとき", selection: binding(\.asksSize)) {
                    Text("サイズを聞かずにすぐ作る").tag(false)
                    Text("サイズを聞く").tag(true)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("⌘N と、タブの並びの＋に効きます。＋を長押しするか、ファイル ＞ サイズを指定して新規… を選ぶと、そのたびにサイズを選べます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker(prefs.asksSize ? L("最初に入れておくサイズ") : L("作るサイズ"), selection: binding(\.usesLastSize)) {
                    Text("前回作ったサイズ").tag(true)
                    Text("決まったサイズ").tag(false)
                }
                .pickerStyle(.radioGroup)
                if !prefs.usesLastSize {
                    Picker("プリセット", selection: Binding(get: { "\(prefs.width)x\(prefs.height)" }, set: { v in
                        if let p = NewDocumentSheet.presets.first(where: { "\($0.1)x\($0.2)" == v }) {
                            state.newDocumentPreferences.width = p.1
                            state.newDocumentPreferences.height = p.2
                        }
                    })) {
                        ForEach(NewDocumentSheet.presets, id: \.0) { p in Text(p.0).tag("\(p.1)x\(p.2)") }
                        if !NewDocumentSheet.presets.contains(where: { $0.1 == prefs.width && $0.2 == prefs.height }) {
                            Text("カスタム").tag("\(prefs.width)x\(prefs.height)")
                        }
                    }
                    LabeledContent("幅 × 高さ") {
                        HStack {
                            TextField("幅", value: Binding(get: { prefs.width }, set: { state.newDocumentPreferences.width = min(max($0, 1), 12000) }),
                                      format: .number)
                                .frame(width: 80)
                            Text("×")
                            TextField("高さ", value: Binding(get: { prefs.height }, set: { state.newDocumentPreferences.height = min(max($0, 1), 12000) }),
                                      format: .number)
                                .frame(width: 80)
                            Text("px")
                        }
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
