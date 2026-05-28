import SwiftUI

struct NoteEditorView: View {
    @ObservedObject var viewModel: NotesViewModel
    let noteId: UUID

    @StateObject private var vimEngine = VimEngine()
    @StateObject private var findController = FindController()
    @State private var content: String = ""
    @State private var rtfData: Data = Data()
    @State private var hasLoaded = false
    @State private var startInInsertMode = false
    @State private var showDeleteConfirm = false
    @FocusState private var isFindFieldFocused: Bool
    @AppStorage("editorFontSize") private var fontSize: Double = 16
    @AppStorage("showLineNumbers") private var showLineNumbers: Bool = false
    @AppStorage("useMonospacedFont") private var useMonospacedFont: Bool = false
    @AppStorage("editorPaperStyle") private var paperStyle: String = "plain"
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

    private var folderName: String {
        if let note = note, let id = note.folderId, let folder = viewModel.folders.first(where: { $0.id == id }) {
            return folder.name
        }
        return "Notes"
    }

    private var editorHeader: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                Text(folderName)
                    .font(.system(.subheadline, design: .default).weight(.semibold))
            }
            .foregroundStyle(theme.text.opacity(0.85))

            Spacer()

            if let note = note {
                Text(formatDate(note.modifiedAt))
                    .font(.system(.subheadline, design: .default).weight(.medium))
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
            }

            Spacer()

            HStack(spacing: 12) {
                Button(action: {
                    if let note = note {
                        withAnimation(DS.snappy) {
                            viewModel.togglePin(note)
                        }
                    }
                }) {
                    Image(systemName: note?.isPinned == true ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(note?.isPinned == true ? theme.accent : theme.secondaryText)
                }
                .buttonStyle(PressableIconButtonStyle(pressedScale: 0.94))
                .help(note?.isPinned == true ? "Unpin Note" : "Pin Note")

                Button(action: {
                    showDeleteConfirm = true
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(PressableIconButtonStyle(pressedScale: 0.94))
                .help("Delete Note")

                themeMenu

                Menu {
                    fontSizeMenu
                    Divider()
                    Toggle("Monospaced Font", isOn: $useMonospacedFont)
                    Toggle("Line Numbers", isOn: $showLineNumbers)
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
                .help("Font Settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(theme.separator.opacity(0.4), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(theme.isDark ? 0.12 : 0.03), radius: 5, y: 2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
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
                    .padding(.horizontal, 18)
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
        }
        .onDisappear {
            saveCurrentNote()
            findController.removeKeyMonitor()
        }
        .onChange(of: findController.focusTrigger) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFindFieldFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .findInNote)) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                findController.isVisible = true
            }
            findController.focusTrigger += 1
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
            paperStyle: paperStyle
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(editorPaperFill)
        .onChange(of: content) { _, newValue in
            let newTitle = extractTitle(from: newValue)
            viewModel.updateNoteContent(id: noteId, title: newTitle.isEmpty ? "Untitled" : newTitle, content: newValue, rtfData: rtfData)
        }
        .onChange(of: rtfData) { _, newValue in
            let title = extractTitle(from: content)
            viewModel.updateNoteContent(id: noteId, title: title.isEmpty ? "Untitled" : title, content: content, rtfData: newValue)
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

    private var wordCount: Int {
        content.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
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
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("Saved")
                    .font(.system(.caption, design: .default).weight(.semibold))
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(theme.text.opacity(theme.isDark ? 0.08 : 0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.separator.opacity(0.3), lineWidth: 0.5))
            
            Spacer()
            
            // Reading stats pill
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                Text("\(wordCount) words · \(readingTime) min read")
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
            Image(systemName: "paintpalette")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 20)
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

    private var editorPanelFill: Color {
        if theme.isInk { return theme.surface.opacity(0.82) }
        if theme.isGraphite { return Color.white.opacity(0.72) }
        return theme.isDark ? theme.surface.opacity(0.34) : Color.white.opacity(0.78)
    }

    private var editorPanelStroke: Color {
        if theme.isMonochrome { return theme.separator.opacity(theme.isDark ? 0.55 : 0.62) }
        return Color.white.opacity(theme.isDark ? 0.055 : 0.55)
    }

    private var editorPaperFill: Color {
        if theme.isGraphite { return Color(hex: "F7F6F3") }
        if theme.isInk { return Color(hex: "121315") }
        return theme.editorBackground.opacity(theme.isDark ? 0.14 : 0.18)
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
        Button("Increase Font Size") { fontSize = min(fontSize + 1, 32) }
            .keyboardShortcut("+", modifiers: .command)
        Button("Decrease Font Size") { fontSize = max(fontSize - 1, 10) }
            .keyboardShortcut("-", modifiers: .command)
        Button("Reset Font Size") { fontSize = 15 }
    }

    private var cursorInfo: String {
        "Ln \(vimEngine.cursorLine), Col \(vimEngine.cursorCol)"
    }

    private func loadNote() {
        if let note = viewModel.notes.first(where: { $0.id == noteId }) {
            content = note.content
            rtfData = note.rtfData ?? Data()
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
        }
    }

    private func saveCurrentNote() {
        let title = extractTitle(from: content)
        viewModel.updateNoteContent(id: noteId, title: title.isEmpty ? "Untitled" : title, content: content, rtfData: rtfData)
    }

    private func extractTitle(from text: String) -> String {
        let firstLine = text.components(separatedBy: .newlines).first ?? ""
        return String(firstLine.prefix(100)).trimmingCharacters(in: .whitespaces)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
