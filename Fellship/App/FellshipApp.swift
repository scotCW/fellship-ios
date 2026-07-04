import SwiftUI

@main
struct FellshipApp: App {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.settings)
                .environmentObject(app.engine)
                .environmentObject(app.location)
                .environmentObject(app.notifications)
                .environmentObject(app.offlineMaps)
                .tint(Color("AccentColor"))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                app.notifications.refreshAuthorizationState()
                Task { await app.location.forceTick() }
            }
        }
    }
}
