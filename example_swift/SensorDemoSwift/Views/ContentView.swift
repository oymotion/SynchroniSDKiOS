import SwiftUI

/// iOS: three tabs; macOS: sidebar navigation.
struct ContentView: View {
    @EnvironmentObject var model: AppModel

    #if os(iOS)
    var body: some View {
        TabView {
            DevicePage()
                .tabItem { Label("Device", systemImage: "dot.radiowaves.left.and.right") }
            BioPage()
                .tabItem { Label("Bio", systemImage: "heart.text.square") }
            ImuPage()
                .tabItem { Label("IMU", systemImage: "cube") }
        }
        .environmentObject(model.plotTicker)
    }
    #else
    @State private var page: String? = "Device"

    var body: some View {
        NavigationSplitView {
            List(["Device", "Bio", "IMU"], id: \.self, selection: $page) { name in
                Label(name, systemImage: icon(for: name))
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160)
        } detail: {
            switch page {
            case "Bio": BioPage()
            case "IMU": ImuPage()
            default: DevicePage()
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .environmentObject(model.plotTicker)
    }

    private func icon(for page: String) -> String {
        switch page {
        case "Bio": return "heart.text.square"
        case "IMU": return "cube"
        default: return "dot.radiowaves.left.and.right"
        }
    }
    #endif
}
