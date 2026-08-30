import SwiftUI

@main
struct ProvenanceCleanerApp: App {
    @State private var store: AppStore

    init() {
        let store = AppStore()
#if DEBUG
        UITestLaunchConfiguration.prepare(preferences: store.preferences)
#endif
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            mainWindowContent
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            ProvenanceCleanerCommands()
            NoticesCommands()
#if DEBUG
            UITestWindowCommands()
#endif
        }

        Settings {
            SettingsView(preferences: store.preferences, store: store)
        }

        Window("Third-Party Notices", id: "notices") {
            NoticesView()
        }
        .defaultSize(width: 720, height: 620)
    }

    @ViewBuilder
    private var mainWindowContent: some View {
#if DEBUG
        ContentView(store: store)
            .preferredColorScheme(UITestLaunchConfiguration.preferredColorScheme)
            .overlay(alignment: .topTrailing) {
                UITestAppearanceProbe()
            }
            .task {
                await UITestLaunchConfiguration.importFixturesIfNeeded(into: store)
            }
#else
        ContentView(store: store)
#endif
    }
}

private struct NoticesCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Third-Party Notices…") {
                openWindow(id: "notices")
            }
        }
    }
}
