import SwiftUI

struct CleanerCommandActions {
    var addFiles: () -> Void
    var cleanSelected: () -> Void
    var exportSelected: () -> Void
    var quickLook: () -> Void
    var inspectAll: () -> Void
    var cleanAll: () -> Void
    var exportAll: () -> Void
    var removeSelected: () -> Void
    var canInspect: Bool
    var canCleanSelected: Bool
    var canExportSelected: Bool
    var canQuickLook: Bool
    var canCleanAll: Bool
    var canExportAll: Bool
    var canRemove: Bool
}

private struct CleanerCommandActionsKey: FocusedValueKey {
    typealias Value = CleanerCommandActions
}

extension FocusedValues {
    var cleanerCommandActions: CleanerCommandActions? {
        get { self[CleanerCommandActionsKey.self] }
        set { self[CleanerCommandActionsKey.self] = newValue }
    }
}

struct ProvenanceCleanerCommands: Commands {
    @FocusedValue(\.cleanerCommandActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Files…") {
                actions?.addFiles()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("Process") {
            Button("Clean Selected") {
                actions?.cleanSelected()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(actions?.canCleanSelected != true)

            Button("Export Selected…") {
                actions?.exportSelected()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(actions?.canExportSelected != true)

            Button("Quick Look") {
                actions?.quickLook()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(actions?.canQuickLook != true)

            Divider()

            Button("Inspect All") {
                actions?.inspectAll()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(actions?.canInspect != true)

            Button("Clean All Sequentially") {
                actions?.cleanAll()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(actions?.canCleanAll != true)

            Divider()

            Button("Export Cleaned Files…") {
                actions?.exportAll()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(actions?.canExportAll != true)
        }

        CommandGroup(after: .pasteboard) {
            Button("Remove Selected Item") {
                actions?.removeSelected()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(actions?.canRemove != true)
        }
    }
}
