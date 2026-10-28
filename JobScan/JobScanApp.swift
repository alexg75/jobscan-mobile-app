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
            // Pick up changes made in the Files app (reports, config.toml).
            if phase == .active {
                AppModel.shared.reloadReports()
                AppModel.shared.reloadConfig()
            }
        }
    }
}
