import SwiftUI

@main
struct OfflineResearchApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Enforce offline mode before any view or dependency can attempt a load.
        OfflineGuard.install()
    }

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(model)
                .task { model.bootstrap() }
        }
    }
}
