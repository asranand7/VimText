import SwiftUI

@main
struct VimTextApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    NotificationCenter.default.post(name: .createNewNote, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Duplicate Note") {
                    NotificationCenter.default.post(name: .duplicateCurrentNote, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
            }

            CommandGroup(replacing: .textEditing) {
                Button("Find in Note") {
                    NotificationCenter.default.post(name: .findInNote, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find in Notes") {
                    NotificationCenter.default.post(name: .focusNoteSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
            }

            CommandGroup(after: .textEditing) {
                Button("Increase Text Size") {
                    EditorPreferences.increaseFontSize()
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Decrease Text Size") {
                    EditorPreferences.decreaseFontSize()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Text Size") {
                    EditorPreferences.resetFontSize()
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button("Quick Open Note…") {
                    NotificationCenter.default.post(name: .openCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            CommandMenu("Vim") {
                Text("Vim Keybindings Active")
                Divider()
                Text("Normal: Esc")
                Text("Insert: i, a, o, O, I, A")
                Text("Visual: v, V")
                Text("Command: :")
                Divider()
                Text("Save: :w or ⌘S")
                Text("Motions: h j k l w b e 0 $ gg G")
                Text("Operations: d y c p")
            }
        }
    }
}
