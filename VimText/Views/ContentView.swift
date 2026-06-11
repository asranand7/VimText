import SwiftUI

public struct ContentView: View {
    @StateObject private var viewModel = NotesViewModel()
    @StateObject private var themeManager = ThemeManager()
    @SceneStorage("isSidebarVisible") private var isSidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = SidebarLayout.defaultWidth

    private var theme: AppTheme { themeManager.theme }

    @State private var showCommandPalette = false

    private var clampedSidebarWidth: CGFloat {
        CGFloat(SidebarLayout.clampedWidth(sidebarWidth))
    }

    private var emptyDetail: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(theme.accent.opacity(theme.isDark ? 0.12 : 0.10))
                        .frame(width: 84, height: 84)
                    Image(systemName: "sparkles")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(theme.accent)
                }

                Text("Capture ideas before they disappear.")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(theme.text)
            }

            HStack(alignment: .top, spacing: 40) {
                shortcutColumn(title: "App", shortcuts: [
                    ("⌘N", "New note"),
                    ("⌘K", "Quick open"),
                    ("⌘F", "Find in note"),
                    ("⌘⇧F", "Search all notes"),
                    ("⌘⌥B", "Toggle sidebar")
                ])
                shortcutColumn(title: "Vim", shortcuts: [
                    ("i", "Insert mode"),
                    ("esc", "Normal mode"),
                    ("v", "Visual mode"),
                    ("/", "Search in note"),
                    (":w", "Save")
                ])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .windowBackground, blendingMode: .behindWindow)
        )
    }

    private func shortcutColumn(title: String, shortcuts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(theme.secondaryText.opacity(0.7))
                .padding(.bottom, 2)

            ForEach(shortcuts, id: \.0) { keys, label in
                HStack(spacing: 10) {
                    Text(keys)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .frame(minWidth: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(theme.text.opacity(theme.isDark ? 0.08 : 0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(theme.separator.opacity(0.4), lineWidth: 0.5)
                        )
                    Text(label)
                        .font(.system(.caption))
                        .foregroundStyle(theme.secondaryText.opacity(0.85))
                }
            }
        }
    }

    public init() {}

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if isSidebarVisible {
                    NoteListView(viewModel: viewModel, onToggleSidebar: collapseSidebar)
                        .frame(width: clampedSidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    SidebarResizeHandle(
                        width: $sidebarWidth,
                        isSidebarVisible: $isSidebarVisible
                    )
                    .environmentObject(themeManager)
                    .transition(.opacity)
                }

                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
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
        .onDisappear {
            // Window teardown (closed without quitting): flush any debounced
            // edits before the view model goes away. App quit is covered
            // separately by the willTerminate observer in NotesViewModel.
            viewModel.flushPendingSavesSynchronously()
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewNote)) { _ in
            viewModel.createNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .duplicateCurrentNote)) { _ in
            if let note = viewModel.selectedNote {
                viewModel.duplicateNote(note)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCommandPalette)) { _ in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                showCommandPalette.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            toggleSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusNoteSearch)) { _ in
            guard !isSidebarVisible else { return }
            showSidebarAndReplay(.focusNoteSearch)
        }
        // Note: opening a note from ⌘K must NOT force the sidebar open. When the
        // sidebar is visible, NoteListView's own .revealNoteInSidebar handler
        // scrolls to the note; when it's hidden (e.g. full-screen editor), we
        // leave it hidden so the view stays as the user set it. Re-opening the
        // sidebar later scrolls to the selected note via toggleSidebar.
        .background(
            WindowAccessor { window in
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
            }
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        ZStack {
            if let noteId = viewModel.selectedNoteId,
               viewModel.notes.contains(where: { $0.id == noteId }) {
                NoteEditorView(
                    viewModel: viewModel,
                    noteId: noteId,
                    isSidebarVisible: isSidebarVisible,
                    onToggleSidebar: toggleSidebar
                )
                .id(noteId)
            } else {
                emptyDetail
                    .overlay(alignment: .topLeading) {
                        sidebarToggleButton
                            .padding(.leading, 30)
                            .padding(.top, 20)
                    }
            }
        }
    }

    private var sidebarToggleButton: some View {
        Button(action: toggleSidebar) {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSidebarVisible ? theme.secondaryText.opacity(0.65) : theme.accent)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.separator.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(PressableIconButtonStyle(pressedScale: 0.94))
        .help(isSidebarVisible ? "Hide Sidebar (⌘⌥B)" : "Show Sidebar (⌘⌥B)")
        .accessibilityLabel(isSidebarVisible ? "Hide sidebar" : "Show sidebar")
        .accessibilityHint("Toggles the notes sidebar. Shortcut: Command Option B.")
    }

    private func toggleSidebar() {
        withAnimation(DS.spring) {
            isSidebarVisible.toggle()
        }
        if isSidebarVisible {
            revealSelectedNoteAfterSidebarAppears()
        }
    }

    private func collapseSidebar() {
        withAnimation(DS.spring) {
            isSidebarVisible = false
        }
    }

    private func showSidebarAndReplay(_ name: Notification.Name, object: Any? = nil) {
        withAnimation(DS.spring) {
            isSidebarVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NotificationCenter.default.post(name: name, object: object)
        }
    }

    private func revealSelectedNoteAfterSidebarAppears() {
        guard let selectedNoteId = viewModel.selectedNoteId else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NotificationCenter.default.post(name: .revealNoteInSidebar, object: selectedNoteId)
        }
    }
}

private struct SidebarResizeHandle: View {
    @Binding var width: Double
    @Binding var isSidebarVisible: Bool
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var dragStartWidth: Double?
    @State private var isHovered = false

    private var theme: AppTheme { themeManager.theme }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(theme.separator.opacity(isHovered ? 0.88 : 0.46))
                .frame(width: 1)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(theme.secondaryText.opacity(isHovered ? 0.42 : 0.16))
                .frame(width: 2, height: 34)
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .background {
            ResizeCursorZone()
            theme.surface.opacity(isHovered ? 0.05 : 0.001)
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = SidebarLayout.clampedWidth(width)
                    }
                    let startWidth = dragStartWidth ?? width
                    width = SidebarLayout.clampedWidth(startWidth + value.translation.width)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                    width = SidebarLayout.clampedWidth(width)
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(DS.spring) {
                isSidebarVisible = false
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Drag to resize sidebar. Double-click to hide.")
    }
}

private struct ResizeCursorZone: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ResizeCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ResizeCursorNSView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
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
