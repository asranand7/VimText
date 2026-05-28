import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = NotesViewModel()
    @StateObject private var themeManager = ThemeManager()

    private var theme: AppTheme { themeManager.theme }

    var body: some View {
        NavigationSplitView {
            NoteListView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let noteId = viewModel.selectedNoteId,
               viewModel.notes.contains(where: { $0.id == noteId }) {
                NoteEditorView(viewModel: viewModel, noteId: noteId)
                    .id(noteId)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(theme.secondaryText.opacity(0.6))
                    Text("Select or create a note")
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                    Text("⌘N to create a new note")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    ZStack {
                        VisualEffectView(material: .windowBackground, blendingMode: .behindWindow)
                        theme.editorBackground.opacity(theme.isDark ? 0.35 : 0.6)
                    }
                )
            }
        }
        .environmentObject(themeManager)
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.accent)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { viewModel.createNote() }) {
                    Image(systemName: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Note (⌘N)")
            }
        }
        .navigationTitle("")
        .frame(minWidth: 700, minHeight: 500)
    }
}
