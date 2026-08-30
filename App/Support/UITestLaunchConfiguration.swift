#if DEBUG
import Foundation
import SwiftUI

@MainActor
enum UITestLaunchConfiguration {
    private enum EnvironmentKey {
        static let enabled = "PROVENANCE_CLEANER_UI_TESTING"
        static let acceptOwnership = "PROVENANCE_CLEANER_UI_TEST_ACCEPT_OWNERSHIP"
        static let appearance = "PROVENANCE_CLEANER_UI_TEST_APPEARANCE"
        static let importPaths = "PROVENANCE_CLEANER_UI_TEST_IMPORT_PATHS"
    }

    private static var didImportFixtures = false

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[EnvironmentKey.enabled] == "1"
    }

    static var preferredColorScheme: ColorScheme? {
        guard isEnabled else { return nil }
        switch ProcessInfo.processInfo.environment[EnvironmentKey.appearance]?.lowercased() {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    static func prepare(preferences: AppPreferences) {
        guard isEnabled else { return }
        if ProcessInfo.processInfo.environment[EnvironmentKey.acceptOwnership] == "1" {
            preferences.acceptedOwnershipNotice = true
        }
    }

    static func importFixturesIfNeeded(into store: AppStore) async {
        guard isEnabled, !didImportFixtures else { return }
        didImportFixtures = true
        guard let encodedPaths = ProcessInfo.processInfo.environment[EnvironmentKey.importPaths] else {
            return
        }
        let urls = encodedPaths
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)) }
        guard !urls.isEmpty else { return }
        await store.addAndInspect(urls)
    }
}

struct UITestAppearanceProbe: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if UITestLaunchConfiguration.isEnabled {
            Text("UI Test Appearance")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("ui-test.appearance")
                .accessibilityValue(colorScheme == .dark ? "dark" : "light")
                .allowsHitTesting(false)
        }
    }
}

struct UITestWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        if UITestLaunchConfiguration.isEnabled {
            CommandMenu("UI Test") {
                Button("Open Main Window") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}
#endif
