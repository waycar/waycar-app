import SwiftUI

struct ConsoleCommands: Commands {
    nonisolated static let helpTitle = "Waycar Help"

    @FocusedValue(\.consoleCommandTarget) private var target

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            buttons(for: [.newAgent])
        }
        CommandGroup(replacing: .appSettings) {
            buttons(for: [.settings])
        }
        // No key equivalent: iPadOS reserves ⌘? for the Help menu's search
        // field, which finds this item.
        CommandGroup(replacing: .help) {
            Button(Self.helpTitle) { target?.perform(.help) }
                .disabled(!(target?.allows(.help) ?? false))
        }
        CommandMenu("Agents") {
            ForEach(
                ConsoleCommandShortcut.all.filter { shortcut in
                    ![ConsoleCommandAction.newAgent, .settings].contains(shortcut.action)
                }
            ) { shortcut in
                commandButton(shortcut)
            }
        }
    }

    private func buttons(for actions: Set<ConsoleCommandAction>) -> some View {
        ForEach(ConsoleCommandShortcut.all.filter { actions.contains($0.action) }) { shortcut in
            commandButton(shortcut)
        }
    }

    private func commandButton(_ shortcut: ConsoleCommandShortcut) -> some View {
        Button(shortcut.title) { target?.perform(shortcut.action) }
            .keyboardShortcut(
                shortcut.key == "\r" ? .return : KeyEquivalent(shortcut.key),
                modifiers: shortcut.modifiers
            )
            .disabled(!(target?.allows(shortcut.action) ?? false))
    }
}

extension ConsoleCommandShortcut {
    var modifiers: EventModifiers {
        requiresShift ? [.command, .shift] : [.command]
    }
}

private struct ConsoleCommandTargetKey: FocusedValueKey {
    typealias Value = ConsoleCommandTarget
}

extension FocusedValues {
    var consoleCommandTarget: ConsoleCommandTarget? {
        get { self[ConsoleCommandTargetKey.self] }
        set { self[ConsoleCommandTargetKey.self] = newValue }
    }
}
