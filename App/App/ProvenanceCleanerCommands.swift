import SwiftUI

struct CleanerCommandActions {
    var addFiles: () -> Void
    var createCopy: () -> Void
    var saveCopy: () -> Void
    var showTab: (JobDetailTab) -> Void
    var inspectAll: () -> Void
    var createAllCopies: () -> Void
    var saveAll: () -> Void
    var removeSelected: () -> Void
    var canInspect: Bool
    var canCreateCopy: Bool
    var canSaveCopy: Bool
    var canShowTabs: Bool
    var canCreateAllCopies: Bool
    var canSaveAll: Bool
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

        CommandGroup(replacing: .saveItem) {
            Button("Save Copy…") {
                actions?.saveCopy()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(actions?.canSaveCopy != true)

            Button("Save All Copies…") {
                actions?.saveAll()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(actions?.canSaveAll != true)
        }

        CommandMenu("Process") {
            Button("Create Copy") {
                actions?.createCopy()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(actions?.canCreateCopy != true)

            Button("Create All Copies") {
                actions?.createAllCopies()
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(actions?.canCreateAllCopies != true)

            Divider()

            Button("Check All Files Again") {
                actions?.inspectAll()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(actions?.canInspect != true)

            Divider()

            // Command-Delete, not bare Delete, so typing in a field never
            // removes the selected file.
            Button("Remove from List") {
                actions?.removeSelected()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(actions?.canRemove != true)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(JobDetailTab.allCases.enumerated()), id: \.element) { index, tab in
                Button("Show \(tab.rawValue)") {
                    actions?.showTab(tab)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .disabled(actions?.canShowTabs != true)
            }
        }
    }
}
