import SwiftUI

@main
struct NanopicPadApp: App {
    @State private var state = PadState()

    var body: some Scene {
        WindowGroup {
            PadRootView(state: state)
                .preferredColorScheme(.dark)
        }
    }
}

/// タブで書類を切り替えると state.editor が変わる。下の画面は、そのとき表示している書類のエディターで作り直す
struct PadRootView: View {
    let state: PadState

    var body: some View {
        PadContentView(state: state, editor: state.editor)
    }
}
