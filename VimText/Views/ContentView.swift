import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = NotesViewModel()
    @StateObject private var themeManager = ThemeManager()

    private var theme: AppTheme { themeManager.theme }

    @State private var showCommandPalette = false

    var body: some View {
        ZStack {
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
                        VisualEffectView(material: .windowBackground, blendingMode: .behindWindow)
                    )
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .toolbar(.hidden, for: .windowToolbar)
            .disabled(showCommandPalette)

            if showCommandPalette {
                CommandPaletteView(viewModel: viewModel, isPresented: $showCommandPalette)
                    .zIndex(10)
            }
        }
        .environmentObject(themeManager)
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.accent)
        .navigationTitle("")
        .frame(minWidth: 700, minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: .createNewNote)) { _ in
            viewModel.createNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCommandPalette)) { _ in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                showCommandPalette.toggle()
            }
        }
        .background(
            WindowAccessor { window in
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
            }
        )
    }
}

struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
