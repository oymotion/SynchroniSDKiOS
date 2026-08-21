import SwiftUI

@main
struct SensorDemoSwiftApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        // Background: flush the SDK capture and log files.
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                SensorController.getInstance().onSuspend()
            }
        }
    }
}
