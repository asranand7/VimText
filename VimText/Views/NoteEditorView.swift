import SwiftUI

struct NoteEditorView: View {
    @ObservedObject var viewModel: NotesViewModel
    let noteId: UUID
    var isSidebarVisible = true
    var onToggleSidebar: (() -> Void)? = nil

    @StateObject private var vimEngine = VimEngine()
    @StateObject private var findController = FindController()
    @State private var content: String = ""
    @State private var rtfData: Data = Data()
    @State private var wordCount: Int = 0
    @State private var wordCountTask: Task<Void, Never>? = nil
    @State private var updateViewModelTask: Task<Void, Never>? = nil
    @State private var hasLoaded = false
    @State private var startInInsertMode = false
    @State private var showDeleteConfirm = false
    @FocusState private var isFindFieldFocused: Bool
    @AppStorage(EditorPreferences.fontSizeKey) private var fontSize: Double = EditorPreferences.defaultFontSize
    @AppStorage("showLineNumbers") private var showLineNumbers: Bool = false
    @AppStorage("useMonospacedFont") private var useMonospacedFont: Bool = false
    @AppStorage("editorPaperStyle") private var paperStyle: String = "plain"
    @AppStorage("smartLists") private var smartLists: Bool = true
    @EnvironmentObject private var themeManager: ThemeManager

    private var theme: AppTheme { themeManager.theme }

    private var editorFont: NSFont {
        if useMonospacedFont {
            return NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        }

        return NSFont(name: "Inter-Regular", size: CGFloat(fontSize))
            ?? NSFont(name: "Inter", size: CGFloat(fontSize))
            ?? NSFont.systemFont(ofSize: CGFloat(fontSize))
    }

    private var note: Note? {
        viewModel.notes.first { $0.id == noteId }
    }

    private var editorHeader: some View {
        HStack(spacing: 8) {

            // Left: sidebar toggle + timestamp
            HStack(spacing: 4) {
                if let onToggleSidebar {
                    Button(action: onToggleSidebar) {
                        HStack(spacing: 4) {
                            Image(systemName: "sidebar.leading")
                                .font(.system(size: 11, weight: .semibold))
                            Text("⌘⌥B")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(theme.secondaryText.opacity(0.76))
                        }
                        .foregroundStyle(isSidebarVisible ? theme.secondaryText.opacity(0.62) : theme.accent)
                    }
                    .buttonStyle(PressableIconButtonStyle(pressedScale: 0.94))
                    .help(isSidebarVisible ? "Hide Sidebar (⌘⌥B)" : "Show Sidebar (⌘⌥B)")
                    .accessibilityLabel(isSidebarVisible ? "Hide sidebar" : "Show sidebar")
                    .accessibilityHint("Toggles the notes sidebar. Shortcut: Command Option B.")
                }

                if let note = note {
                    Text(relativeTimeString(for: note.modifiedAt))
                        .font(.system(size: 11, weight: .regular))
                }
            }
            .foregroundStyle(theme.text.opacity(0.65))

            Spacer()

            // Right pill 1: pin · trash · theme
            HStack(spacing: 2) {
                Button(action: {
                    if let note = note {
                        withAnimation(DS.snappy) { viewModel.togglePin(note) }
                    }
                }) {
                    Image(systemName: note?.isPinned == true ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(note?.isPinned == true ? theme.accent : theme.secondaryText.opacity(0.6))
                }
                .buttonStyle(PlainButtonStyle())
                .help(note?.isPinned == true ? "Unpin Note" : "Pin Note")

                Button(action: { showDeleteConfirm = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText.opacity(0.6))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Delete Note")

                Menu {
                    ForEach(AppTheme.all) { item in
                        Button { themeManager.themeID = item.id } label: {
                            if themeManager.themeID == item.id {
                                Label(item.name, systemImage: "checkmark")
                            } else { Text(item.name) }
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText.opacity(0.6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Theme")
            }
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(theme.separator.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)

            // Right pill 2: Aa
            Menu {
                fontSizeMenu
                Divider()
                Toggle("Monospaced Font", isOn: $useMonospacedFont)
                Toggle("Line Numbers", isOn: $showLineNumbers)
                Toggle("Smart Lists", isOn: $smartLists)
                Divider()
                Menu("Paper Style") {
                    Picker("Paper Style", selection: $paperStyle) {
                        Text("Plain").tag("plain")
                        Text("Dotted Grid").tag("dotted")
                        Text("Lined Paper").tag("lined")
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(theme.separator.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            .help("Font Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)

        .background(editorPaperFill)
    }




    var body: some View {
        ZStack {
            VisualEffectView(material: .windowBackground, blendingMode: .behindWindow)
                .opacity(theme.isDark ? 0.76 : 0.90)
            
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        editorHeader
                        
                        Divider()
                            .foregroundStyle(theme.separator.opacity(0.4))
                        
                        editorArea
                        
                        if vimEngine.showCommandLine {
                            Divider()
                                .foregroundStyle(theme.separator.opacity(0.4))
                            commandLine
                        }
                        
                        Divider()
                            .foregroundStyle(theme.separator.opacity(0.4))
                        statusBar
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(editorPanelFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(editorPanelStroke, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(theme.isDark ? 0.30 : 0.07), radius: 22, x: 0, y: 8)
                    .padding(.leading, 4)
                    .padding(.trailing, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                    
                    if findController.isVisible {
                        findBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(1)
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .animation(.easeInOut(duration: 0.28), value: theme.id)
        .confirmationDialog(
            "Delete Note?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let note = note {
                    viewModel.deleteNote(note)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to permanently delete this note?")
        }
        .onAppear {
            loadNote()
            findController.installKeyMonitor()
            // A note opened from a ⌘K search arrives with the query already
            // pending; onChange won't fire for a freshly-created editor, so
            // pick it up here.
            applyPendingSearchHighlight()
        }
        .onChange(of: viewModel.pendingSearchHighlight) { _, newValue in
            if newValue != nil { applyPendingSearchHighlight() }
        }
        .onDisappear {
            // Flush the editor's debounced restyle/RTF first (synchronous), so
            // saveCurrentNote() persists content and rich text consistently.
            NotificationCenter.default.post(name: .commitEditorPendingWork, object: nil)
            updateViewModelTask?.cancel()
            updateViewModelTask = nil
            saveCurrentNote()
            findController.removeKeyMonitor()
        }
        .onChange(of: findController.focusTrigger) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFindFieldFocused = true
            }
        }
        .onChange(of: isFindFieldFocused) { _, focused in
            // Let the find key monitor know when Return should mean find-next/
            // prev (field focused) vs. a normal editor newline.
            findController.isFieldFocused = focused
        }
        .onReceive(NotificationCenter.default.publisher(for: .findInNote)) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                findController.isVisible = true
            }
            findController.focusTrigger += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            commitPendingWorkEagerly()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            commitPendingWorkEagerly()
        }
    }

    private var editorArea: some View {
        VimTextView(
            text: $content,
            rtfData: $rtfData,
            vimEngine: vimEngine,
            findController: findController,
            onSave: { saveCurrentNote() },
            font: editorFont,
            startInInsertMode: startInInsertMode,
            backgroundColor: .clear,
            textColor: theme.textNS,
            accentColor: theme.accentNS,
            paperStyle: paperStyle,
            smartLists: smartLists,
            showLineNumbers: showLineNumbers
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(editorPaperFill)
        .onChange(of: content) { _, newValue in
            updateWordCountAsync(text: newValue)
            queueViewModelUpdate(content: newValue, rtfData: rtfData)
        }
        .onChange(of: rtfData) { _, newValue in
            queueViewModelUpdate(content: content, rtfData: newValue)
        }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            TextField("Find in note…", text: $findController.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 190)
                .focused($isFindFieldFocused)
                .onSubmit {
                    findController.findNext?()
                }
                .onExitCommand {
                    closeFindBar()
                }
                .onChange(of: findController.query) { _, newValue in
                    findController.performFind?(newValue)
                }

            if findController.totalMatches > 0 {
                Text("\(findController.currentMatch) of \(findController.totalMatches)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else if !findController.query.isEmpty {
                Text("No results")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.8))
                    .fixedSize()
            }

            Button(action: { findController.findPrev?() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(findController.totalMatches == 0)

            Button(action: { findController.findNext?() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(findController.totalMatches == 0)

            Divider()
                .frame(height: 16)

            Button(action: { closeFindBar() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .padding(.top, 10)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func closeFindBar() {
        withAnimation(.easeInOut(duration: 0.15)) {
            findController.isVisible = false
        }
        findController.dismiss?()
        findController.query = ""
        findController.currentMatch = 0
        findController.totalMatches = 0
        findController.refocusEditor?()
    }

    private var commandLine: some View {
        HStack(spacing: 4) {
            Text(vimEngine.commandLinePrefix)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(theme.text)
            Text(vimEngine.commandLineText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(theme.text)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.clear)
    }

    nonisolated private static func countWords(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    private func updateWordCountAsync(text: String) {
        wordCountTask?.cancel()
        wordCountTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            let count = Self.countWords(text)
            await MainActor.run {
                self.wordCount = count
            }
        }
    }

    private func queueViewModelUpdate(content: String, rtfData: Data) {
        guard hasLoaded else { return }
        updateViewModelTask?.cancel()
        updateViewModelTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
            guard !Task.isCancelled else { return }
            
            let title = extractTitle(from: content)
            viewModel.updateNoteContent(
                id: noteId,
                title: title.isEmpty ? "Untitled" : title,
                content: content,
                rtfData: rtfData
            )
        }
    }

    private func commitPendingWorkEagerly() {
        guard hasLoaded else { return }
        NotificationCenter.default.post(name: .commitEditorPendingWork, object: nil)
        updateViewModelTask?.cancel()
        updateViewModelTask = nil

        let title = extractTitle(from: content)
        viewModel.updateNoteContent(
            id: noteId,
            title: title.isEmpty ? "Untitled" : title,
            content: content,
            rtfData: rtfData
        )
        viewModel.flushPendingSavesSynchronously()
    }

    private var readingTime: Int {
        max(1, Int(ceil(Double(wordCount) / 200.0)))
    }

    private var paperStyleIconName: String {
        switch paperStyle {
        case "dotted": return "grid"
        case "lined": return "list.bullet.indent"
        default: return "doc.text"
        }
    }

    private var paperStyleDisplayName: String {
        switch paperStyle {
        case "dotted": return "Dotted"
        case "lined": return "Lined"
        default: return "Plain"
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            // Mode Pill
            modeIndicator
            
            // Saved status pill
            HStack(spacing: 4) {
                Image(systemName: saveStateIconName)
                    .font(.system(size: 10))
                    .foregroundStyle(saveStateColor)
                Text(viewModel.saveState.displayText)
                    .font(.system(.caption, design: .default).weight(.semibold))
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(theme.text.opacity(theme.isDark ? 0.08 : 0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.separator.opacity(0.3), lineWidth: 0.5))
            .help(saveStateHelp)

            if !vimEngine.statusMessage.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                    Text(vimEngine.statusMessage)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(theme.text.opacity(theme.isDark ? 0.08 : 0.04), in: Capsule())
                .overlay(Capsule().strokeBorder(theme.separator.opacity(0.3), lineWidth: 0.5))
                .frame(maxWidth: 260, alignment: .leading)
            }
            
            Spacer()
            
            // Reading stats pill
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                Text("\(wordCount.formatted()) words · \(readingTime) min read")
                    .font(.system(.caption, design: .default).weight(.semibold))
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(theme.text.opacity(theme.isDark ? 0.08 : 0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.separator.opacity(0.3), lineWidth: 0.5))
            
            // Paper Style Pill
            HStack(spacing: 4) {
                Image(systemName: paperStyleIconName)
                    .font(.system(size: 10))
                Text(paperStyleDisplayName)
                    .font(.system(.caption, design: .default).weight(.medium))
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(theme.text.opacity(theme.isDark ? 0.08 : 0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.separator.opacity(0.3), lineWidth: 0.5))
            
            // Cursor Coordinates Pill
            HStack(spacing: 4) {
                Image(systemName: "scope")
                    .font(.system(size: 10))
                Text(cursorInfo)
                    .font(.system(.caption, design: .monospaced))
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(theme.text.opacity(theme.isDark ? 0.08 : 0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.separator.opacity(0.3), lineWidth: 0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(editorPaperFill)
    }

    private var themeMenu: some View {
        Menu {
            ForEach(AppTheme.all) { item in
                Button {
                    themeManager.themeID = item.id
                } label: {
                    if themeManager.themeID == item.id {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
        } label: {
            ToolbarMenuLabel(iconName: "paintpalette", theme: theme)
        }
        .menuStyle(.borderlessButton)
        .help("Theme")
    }

    private var modeIndicator: some View {
        Text(vimEngine.mode.displayName)
            .font(.system(.caption, design: .default).weight(.bold))
            .foregroundStyle(modeTextColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(modeFillColor, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(modeStrokeColor, lineWidth: 0.6)
            )
            .shadow(color: modeFillColor.opacity(theme.isMonochrome ? 0.12 : 0.35), radius: 3, y: 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: vimEngine.mode)
    }

    private var saveStateIconName: String {
        switch viewModel.saveState {
        case .saved: return "checkmark.circle.fill"
        case .saving: return "arrow.triangle.2.circlepath.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var saveStateColor: Color {
        switch viewModel.saveState {
        case .saved: return .green
        case .saving: return .orange
        case .error: return .red
        }
    }

    private var saveStateHelp: String {
        if case .error(let message) = viewModel.saveState {
            return message
        }
        return viewModel.saveState.displayText
    }

    private var editorPanelFill: Color {
        EditorSurfacePalette.panelFill(for: theme)
    }

    private var editorPanelStroke: Color {
        EditorSurfacePalette.panelStroke(for: theme)
    }

    private var editorPaperFill: Color {
        EditorSurfacePalette.paperFill(for: theme)
    }

    private var modeColor: Color {
        switch vimEngine.mode {
        case .normal: return .blue
        case .insert: return .green
        case .visual, .visualLine, .visualBlock: return .purple
        case .command: return .orange
        case .replace: return .red
        }
    }

    private var modeFillColor: Color {
        if theme.isGraphite { return Color(hex: "3F4146") }
        if theme.isInk { return Color(hex: "2F3033") }
        return modeColor
    }

    private var modeTextColor: Color {
        if theme.isInk { return Color(hex: "F1F0EC") }
        return .white
    }

    private var modeStrokeColor: Color {
        if theme.isMonochrome { return theme.separator.opacity(theme.isDark ? 0.72 : 0.42) }
        return Color.white.opacity(0)
    }

    @ViewBuilder
    private var fontSizeMenu: some View {
        Button("Increase Font Size") { fontSize = EditorPreferences.increaseFontSize() }
            .keyboardShortcut("+", modifiers: .command)
        Button("Decrease Font Size") { fontSize = EditorPreferences.decreaseFontSize() }
            .keyboardShortcut("-", modifiers: .command)
        Button("Reset Font Size") { fontSize = EditorPreferences.resetFontSize() }
            .keyboardShortcut("0", modifiers: .command)
    }

    private var cursorInfo: String {
        "Ln \(vimEngine.cursorLine), Col \(vimEngine.cursorCol)"
    }

    private func loadNote() {
        if let note = viewModel.notes.first(where: { $0.id == noteId }) {
            content = note.content
            rtfData = note.rtfData ?? Data()
            wordCount = Self.countWords(note.content)
            hasLoaded = true
            let isNewEmpty = note.content.isEmpty
            startInInsertMode = isNewEmpty
            vimEngine.mode = isNewEmpty ? .insert : .normal
            vimEngine.resetBuffers()
            vimEngine.statusMessage = ""
            vimEngine.showCommandLine = false
            if findController.isVisible {
                closeFindBar()
            }
            applyPendingSearchHighlight()
        }
    }

    private func applyPendingSearchHighlight() {
        // Only the editor for the currently-selected note should consume the
        // pending query — otherwise the outgoing editor (during a note switch)
        // would grab it and apply it to the wrong note.
        guard noteId == viewModel.selectedNoteId else { return }
        guard let highlight = viewModel.pendingSearchHighlight, !highlight.isEmpty else { return }
        viewModel.pendingSearchHighlight = nil
        findController.isVisible = true
        findController.query = highlight
        // Focus the find field so the next Enter advances to the next match
        // (the find bar's onSubmit calls findNext).
        findController.focusTrigger += 1
        // If the note is already loaded (re-searching the open note), run the
        // find on the next runloop tick. For a freshly-opened note the text
        // view triggers the find itself the instant its content loads, so there
        // is no guessed delay anywhere.
        DispatchQueue.main.async {
            findController.performFind?(highlight)
        }
    }

    private func saveCurrentNote() {
        guard hasLoaded else { return }
        NotificationCenter.default.post(name: .commitEditorPendingWork, object: nil)
        let title = extractTitle(from: content)
        viewModel.updateNoteContent(id: noteId, title: title.isEmpty ? "Untitled" : title, content: content, rtfData: rtfData)
        // Explicit save (⌘S / :w) and closing the editor should hit disk now,
        // not wait for the debounce window.
        viewModel.flushPendingSavesSynchronously()
    }

    private func extractTitle(from text: String) -> String {
        // Use the first non-empty line that isn't just an embedded image, so a
        // note starting with a pasted image still gets a sensible title.
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || ImageMarkdown.isImageOnly(line) { continue }
            return String(line.prefix(100))
        }
        return ""
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func relativeTimeString(for date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 {
            return "Saved just now"
        } else if elapsed < 3600 {
            let minutes = Int(elapsed / 60)
            return "Edited \(minutes) min ago"
        } else {
            return "Edited " + formatDate(date)
        }
    }
}

struct ToolbarButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false
    
    var body: some View {
        configuration.label
            .padding(6)
            .background(
                Circle()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (isHovered ? 0.06 : 0.0)))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : (isHovered ? 1.02 : 1.0))
            .onHover { hovering in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                    isHovered = hovering
                }
            }
            .animation(.spring(response: 0.18, dampingFraction: 0.85), value: configuration.isPressed)
    }
}

struct ToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolbarButton(configuration: configuration)
    }
}

struct ToolbarMenuLabel: View {
    let iconName: String
    let theme: AppTheme
    @State private var isHovered = false

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.secondaryText.opacity(0.6))
            .frame(width: 26, height: 22)
            .background(
                Circle()
                    .fill(Color.primary.opacity(isHovered ? 0.06 : 0.0))
            )
            .onHover { hovering in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                    isHovered = hovering
                }
            }
    }
}
