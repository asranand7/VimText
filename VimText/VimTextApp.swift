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

            CommandGroup(after: .textEditing) {
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

extension Notification.Name {
    static let createNewNote = Notification.Name("createNewNote")
    static let focusNoteSearch = Notification.Name("focusNoteSearch")
    static let findInNote = Notification.Name("findInNote")
    static let openCommandPalette = Notification.Name("openCommandPalette")
    static let openChangeLocationPanel = Notification.Name("openChangeLocationPanel")
}
