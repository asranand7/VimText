import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = NotesViewModel()
    @StateObject private var themeManager = ThemeManager()

    private var theme: AppTheme { themeManager.theme }

    @State private var showCommandPalette = false

    private var emptyDetail: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(theme.accent.opacity(theme.isDark ? 0.12 : 0.10))
                    .frame(width: 84, height: 84)
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(theme.accent)
            }

            VStack(spacing: 6) {
                Text("Capture ideas before they disappear.")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("Press ⌘N to start a new note, or ⌘K to search.")
                    .font(.system(.subheadline))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .windowBackground, blendingMode: .behindWindow)
        )
    }

    var body: some View {
        ZStack {
            NavigationSplitView {
                NoteListView(viewModel: viewModel)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } detail: {
                ZStack {
                    if let noteId = viewModel.selectedNoteId,
                       viewModel.notes.contains(where: { $0.id == noteId }) {
                        NoteEditorView(viewModel: viewModel, noteId: noteId)
                            .id(noteId)
                            .transition(.smoothContent)
                    } else {
                        emptyDetail
                            .transition(.smoothContent)
                    }
                }
                .animation(.spring(response: 0.12, dampingFraction: 0.88), value: viewModel.selectedNoteId)
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

struct ContentTransitionModifier: ViewModifier {
    var offset: CGFloat
    var opacity: Double
    
    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(y: offset)
    }
}

extension AnyTransition {
    static var smoothContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: ContentTransitionModifier(offset: 6, opacity: 0),
                identity: ContentTransitionModifier(offset: 0, opacity: 1)
            ),
            removal: .opacity
        )
    }
}
