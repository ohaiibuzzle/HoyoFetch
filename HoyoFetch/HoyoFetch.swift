import SwiftUI

@main struct HoyoFetch: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}
