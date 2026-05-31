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

    public init() {}

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if isSidebarVisible {
                    NoteListView(viewModel: viewModel)
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
        .onReceive(NotificationCenter.default.publisher(for: .revealNoteInSidebar)) { notification in
            guard !isSidebarVisible else { return }
            showSidebarAndReplay(.revealNoteInSidebar, object: notification.object)
        }
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
                .frame(width: 28, height: 24)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.separator.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(PressableIconButtonStyle(pressedScale: 0.94))
        .help(isSidebarVisible ? "Hide Sidebar (⌘⌥S)" : "Show Sidebar (⌘⌥S)")
    }

    private func toggleSidebar() {
        withAnimation(DS.spring) {
            isSidebarVisible.toggle()
        }
        if isSidebarVisible {
            revealSelectedNoteAfterSidebarAppears()
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
                .fill(theme.separator.opacity(isHovered ? 0.72 : 0.46))
                .frame(width: 1)
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .background(theme.surface.opacity(0.001))
        .gesture(
            DragGesture(minimumDistance: 0)
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
