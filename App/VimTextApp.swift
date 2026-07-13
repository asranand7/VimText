import SwiftUI
import VimTextCore

/// The global Quick Capture hotkey must be registered once at launch,
/// whether or not a window ever opens — hence an app delegate rather than a
/// view's onAppear.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        QuickCaptureHotKey.shared.start()
    }
}

@main
struct VimTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

                // The real trigger is the global hotkey (default ⌃⌥Space,
                // rebindable from the sidebar ⋯ menu); this item is for
                // discoverability.
                Button("Quick Capture") {
                    QuickCapturePanelController.shared.show()
                }
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

                Button("Command Palette…") {
                    NotificationCenter.default.post(name: .openCommandList, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("Focus Note List") {
                    NotificationCenter.default.post(name: .focusNoteList, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
            }

            CommandMenu("Vim") {
                Text("Vim Keybindings Active")
                Divider()
                Text("Normal: Esc")
                Text("Insert: i, a, o, O, I, A")
                Text("Visual: v, V · gv reselect")
                Text("Command: :")
                Divider()
                Text("Save: :w or ⌘S")
                Text("Motions: h j k l w b e W B E 0 $ gg G")
                Text("Operations: d y c p")
                Text("Undo/redo: u · ⌃R")
                Text("Jump list: ⌃O back · ⌃I forward")
                Divider()
                Text("Note list (⌘L): j k gg G to move")
                Text("Enter/o open · dd delete · / search · esc back")
            }
        }
    }
}
