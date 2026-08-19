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
    @State private var showThemePicker = false
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

    private var isLocked: Bool {
        note?.isLocked == true
    }

    private var editorHeader: some View {
        HStack(spacing: 8) {

            // Left: sidebar toggle + timestamp
            HStack(spacing: 4) {
                if let onToggleSidebar {
                    Button(action: onToggleSidebar) {
                        Image(systemName: "sidebar.leading")
                            .font(.system(size: 11, weight: .semibold))
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

            // Right pill: pin · trash · theme │ Aa. Each icon sits in a
            // 28×26 hover-highlighted hit area so targets are visible and
            // comfortably clickable, not 12pt slivers.
            HStack(spacing: 6) {
                headerIconButton(
                    icon: isLocked ? "lock.fill" : "lock.open",
                    tint: isLocked ? theme.accent : nil,
                    help: isLocked ? "Unlock Note (allow editing and deletion)" : "Lock Note (prevent editing and deletion)"
                ) {
                    if let note = note {
                        withAnimation(DS.snappy) { viewModel.toggleLock(note) }
                        if note.isLocked {
                            vimEngine.statusMessage = "Note unlocked"
                        } else {
                            // Just locked: leave any half-open insert session.
                            vimEngine.mode = .normal
                            vimEngine.resetBuffers()
                            vimEngine.statusMessage = "Note locked — editing and deletion disabled"
                        }
                    }
                }

                headerIconButton(
                    icon: note?.isPinned == true ? "pin.fill" : "pin",
                    tint: note?.isPinned == true ? theme.accent : nil,
                    help: note?.isPinned == true ? "Unpin Note" : "Pin Note"
                ) {
                    if let note = note {
                        withAnimation(DS.snappy) { viewModel.togglePin(note) }
                    }
                }

                headerIconButton(
                    icon: "trash",
                    help: isLocked ? "Note is locked — unlock to delete" : "Delete Note"
                ) {
                    if isLocked {
                        vimEngine.statusMessage = "Note is locked — unlock to delete"
                    } else {
                        showDeleteConfirm = true
                    }
                }
                .opacity(isLocked ? 0.4 : 1)

                headerIconButton(icon: "paintpalette", help: "Theme") {
                    showThemePicker.toggle()
                }
                .popover(isPresented: $showThemePicker, arrowEdge: .bottom) {
                    themeSwatchPicker
                }

                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 2)

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
                    HeaderIconLabel(icon: "textformat.size", tint: nil, theme: theme)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Font Settings")
            }
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(theme.separator.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
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
            .keyboardShortcut(.defaultAction)
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
            applyPendingCaretTarget()
        }
        .onChange(of: viewModel.pendingSearchHighlight) { _, newValue in
            if newValue != nil { applyPendingSearchHighlight() }
        }
        .onChange(of: viewModel.pendingCaretTarget) { _, newValue in
            if newValue != nil { applyPendingCaretTarget() }
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
        .onReceive(NotificationCenter.default.publisher(for: .requestDeleteCurrentNote)) { _ in
            // Same locked-aware path as the header trash button, so a palette
            // "Delete Note" goes through the confirmation dialog too.
            if isLocked {
                vimEngine.statusMessage = "Note is locked — unlock to delete"
            } else {
                showDeleteConfirm = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            commitPendingWorkEagerly()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            commitPendingWorkEagerly()
        }
    }

    private var editorArea: some View {
        // The text view owns the content after creation (NSTextStorage is the
        // source of truth); edits flow back through onContentChange. The
        // editor is recreated per note via .id(noteId), so initial values are
        // read straight from the note.
        VimTextView(
            initialText: note?.content ?? "",
            initialRTFData: note?.rtfData ?? Data(),
            onContentChange: { newText, newRTF in
                content = newText
                rtfData = newRTF
                updateWordCountAsync(text: newText)
                queueViewModelUpdate(content: newText, rtfData: newRTF)
            },
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
            showLineNumbers: showLineNumbers,
            isLocked: isLocked
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(editorPaperFill)
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
        findController.navigationMode = false
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

    /// Word count over the raw text. `CharacterSet.contains` costs a bridged
    /// lookup per scalar — ~195 ms on a 2.7 MB note, paid on the main thread at
    /// every note open — so ASCII (every scalar in ordinary prose) is decided
    /// inline and the character set only sees the rest. Same result, ~30×
    /// faster: Unicode whitespace such as NBSP still separates words.
    nonisolated private static func countWords(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isWhitespace = value < 0x80
                ? (value == 0x20 || (value >= 0x09 && value <= 0x0D))
                : CharacterSet.whitespacesAndNewlines.contains(scalar)
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

    // Calm statusline: quiet text everywhere, color only for state changes.
    // NORMAL (the default 95% of the time) is muted; the mode only becomes a
    // colored pill when you LEAVE normal mode — that's the signal worth ink.
    private var statusBar: some View {
        HStack(spacing: 14) {
            modeIndicator

            // Locked hint — quiet text; the lock glyph carries the meaning.
            if isLocked {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                    Text("locked")
                        .font(.system(.caption, design: .default).weight(.medium))
                }
                .foregroundStyle(theme.secondaryText.opacity(0.8))
                .help("This note is read-only and can't be deleted. Click the lock in the toolbar to unlock.")
            }

            // Save status only surfaces when something is happening — a
            // permanent "Saved ✓" indicator is noise (silence = saved).
            if viewModel.saveState != .saved {
                HStack(spacing: 4) {
                    Image(systemName: saveStateIconName)
                        .font(.system(size: 10))
                        .foregroundStyle(saveStateColor)
                    Text(viewModel.saveState.displayText)
                        .font(.system(.caption, design: .default).weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                }
                .help(saveStateHelp)
            }

            if !vimEngine.statusMessage.isEmpty {
                Text(vimEngine.statusMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 280, alignment: .leading)
            }

            // Browser-style instant link preview: the moment you hover a link
            // chip, its full URL appears here — no waiting on the native tooltip.
            if let hovered = vimEngine.hoveredLinkURL, !hovered.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                    Text(hovered)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(.caption, design: .default))
                .foregroundStyle(theme.accent)
                .frame(maxWidth: 380, alignment: .leading)
                .transition(.opacity)
            }

            Spacer()

            // Counts as one quiet trailing line: "48 words · 7:31"
            // (reading time in the words tooltip, Vim-style ruler for Ln:Col).
            HStack(spacing: 7) {
                Text("\(wordCount.formatted()) words")
                    .font(.system(.caption, design: .default))
                    .help("\(readingTime) min read")
                Text("·")
                    .font(.system(.caption, design: .default))
                    .opacity(0.6)
                Text("\(vimEngine.cursorLine):\(vimEngine.cursorCol)")
                    .font(.system(.caption, design: .monospaced))
                    .help("Line \(vimEngine.cursorLine), column \(vimEngine.cursorCol)")
            }
            // Lighter: the counts are reference info, not something to read on
            // every glance — let them recede below the mode indicator.
            .foregroundStyle(theme.secondaryText.opacity(0.62))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(editorPaperFill)
    }

    private func headerIconButton(
        icon: String,
        tint: Color? = nil,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HeaderIconLabel(icon: icon, tint: tint, theme: theme)
        }
        .buttonStyle(PressableIconButtonStyle(pressedScale: 0.92))
        .help(help)
    }

    /// A grid of theme swatches — each shows the theme's editor background,
    /// text color ("Aa"), and accent dot, so themes can be compared at a
    /// glance instead of guessing from a name in a text menu.
    private var themeSwatchPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
                .font(.system(.headline, design: .default))

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 10), count: 4), spacing: 12) {
                ForEach(AppTheme.all) { item in
                    Button {
                        themeManager.themeID = item.id
                    } label: {
                        VStack(spacing: 5) {
                            ZStack(alignment: .bottomTrailing) {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(item.editorBackground)
                                    .frame(width: 72, height: 44)
                                    .overlay(
                                        Text("Aa")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(item.text)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(
                                                themeManager.themeID == item.id
                                                    ? item.accent
                                                    : Color.primary.opacity(0.12),
                                                lineWidth: themeManager.themeID == item.id ? 2 : 1
                                            )
                                    )

                                Circle()
                                    .fill(item.accent)
                                    .frame(width: 10, height: 10)
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 0.5))
                                    .padding(5)
                            }

                            Text(item.name)
                                .font(.system(size: 10, weight: themeManager.themeID == item.id ? .semibold : .regular))
                                .foregroundStyle(themeManager.themeID == item.id ? theme.accent : .secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(item.name)
                }
            }
        }
        .padding(16)
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

    @ViewBuilder
    private var modeIndicator: some View {
        if vimEngine.mode == .normal {
            // The default state looks default: quiet uppercase text. A
            // permanently-lit pill carries no information.
            Text("NORMAL")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(theme.secondaryText.opacity(0.65))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: vimEngine.mode)
        } else {
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

    private func loadNote() {
        if let note = viewModel.notes.first(where: { $0.id == noteId }) {
            content = note.content
            rtfData = note.rtfData ?? Data()
            wordCount = Self.countWords(note.content)
            hasLoaded = true
            let isNewEmpty = note.content.isEmpty && !note.isLocked
            startInInsertMode = isNewEmpty
            vimEngine.mode = isNewEmpty ? .insert : .normal
            vimEngine.resetBuffers()
            vimEngine.statusMessage = note.isLocked ? "Note is locked — unlock to edit" : ""
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
        findController.navigationMode = true
        findController.query = highlight
        // Focus the find field so the next Enter advances to the next match
        // (the find bar's onSubmit calls findNext).
        findController.focusTrigger += 1
        // The text view receives the note's content at creation (makeNSView),
        // so by the next runloop tick the editor always holds the full text —
        // run the find then, with no guessed delay.
        DispatchQueue.main.async {
            findController.performFind?(highlight)
        }
    }

    /// Hands a deep link's caret destination to the editor. Same guard as the
    /// search highlight: only the editor for the selected note may take it, or
    /// the outgoing editor would consume it mid-switch and jump the wrong note.
    private func applyPendingCaretTarget() {
        guard noteId == viewModel.selectedNoteId else { return }
        guard let target = viewModel.pendingCaretTarget else { return }
        viewModel.pendingCaretTarget = nil
        // The text view receives its content in makeNSView, so it holds the
        // full note by the next runloop tick — the same timing the ⌘K search
        // jump relies on.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .jumpToCaretTarget, object: target)
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

    private func relativeTimeString(for date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 {
            return "Saved just now"
        }
        if elapsed < 3600 {
            return "Edited \(Int(elapsed / 60)) min ago"
        }
        // Match the sidebar's friendly date buckets rather than a stiff
        // "9 Jun 2026 at 11:35 PM" for notes touched recently.
        let cal = Calendar.current
        let time = AppDateFormatters.timeOnly.string(from: date)
        if cal.isDateInToday(date) {
            return "Edited today at \(time)"
        }
        if cal.isDateInYesterday(date) {
            return "Edited yesterday at \(time)"
        }
        if let weekAgo = cal.date(byAdding: .day, value: -7, to: Date()), date > weekAgo {
            return "Edited \(AppDateFormatters.weekday.string(from: date)) at \(time)"
        }
        return "Edited " + AppDateFormatters.ordinalDateTime(from: date)
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

/// Icon in a fixed 28×26 frame with a hover-highlight circle — the shared
/// look for the editor header's action pill (buttons and menu labels alike).
struct HeaderIconLabel: View {
    let icon: String
    let tint: Color?
    let theme: AppTheme
    @State private var isHovered = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint ?? theme.secondaryText.opacity(isHovered ? 0.95 : 0.62))
            .frame(width: 28, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { hovering in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                    isHovered = hovering
                }
            }
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
