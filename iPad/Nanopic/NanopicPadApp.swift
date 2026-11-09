import SwiftUI

@main
struct NanopicPadApp: App {
    @State private var state = PadState()

    var body: some Scene {
        WindowGroup {
            PadContentView(state: state)
                .preferredColorScheme(.dark)
        }
    }
}
