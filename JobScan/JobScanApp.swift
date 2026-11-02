import SwiftUI

@main
struct JobScanApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(AppModel.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            // Pick up reports added or removed in the Files app, and re-read the settings.
            if phase == .active {
                AppModel.shared.reloadReports()
                AppModel.shared.reloadConfig()
            }
        }
    }
}
