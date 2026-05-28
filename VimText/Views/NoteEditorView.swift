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
    @FocusState private var isFindFieldFocused: Bool
    @AppStorage("editorFontSize") private var fontSize: Double = 16
    @AppStorage("showLineNumbers") private var showLineNumbers: Bool = false
    @AppStorage("useMonospacedFont") private var useMonospacedFont: Bool = false
    @EnvironmentObject private var themeManager: ThemeManager

    private var theme: AppTheme { themeManager.theme }

    private var editorFont: NSFont {
        useMonospacedFont
            ? NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
            : NSFont.systemFont(ofSize: CGFloat(fontSize))
    }

    private var note: Note? {
        viewModel.notes.first { $0.id == noteId }
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .windowBackground, blendingMode: .behindWindow)
            theme.editorBackground.opacity(theme.isDark ? 0.35 : 0.6)
            
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        if let note = note {
                            Text(formatDate(note.modifiedAt))
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(theme.secondaryText.opacity(0.8))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 14)
                                .padding(.bottom, 8)
                        }
                        
                        editorArea
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        
                        if vimEngine.showCommandLine {
                            Divider()
                                .foregroundStyle(theme.separator.opacity(0.4))
                            commandLine
                        }
                        
                        Divider()
                            .foregroundStyle(theme.separator.opacity(0.4))
                        statusBar
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(theme.surface.opacity(theme.isDark ? 0.35 : 0.75))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(theme.isDark ? 0.05 : 0.35), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(theme.isDark ? 0.28 : 0.06), radius: 16, x: 0, y: 6)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                    
                    if findController.isVisible {
                        findBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(1)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.28), value: theme.id)
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
            accentColor: theme.accentNS
        )
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

    private var statusBar: some View {
        HStack(spacing: 12) {
            modeIndicator

            if !vimEngine.statusMessage.isEmpty {
                Text(vimEngine.statusMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            Text(cursorInfo)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.secondaryText)

            themeMenu

            Menu {
                fontSizeMenu
                Divider()
                Toggle("Monospaced Font", isOn: $useMonospacedFont)
                Toggle("Line Numbers", isOn: $showLineNumbers)
            } label: {
                Image(systemName: "textformat.size")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.clear)
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
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
        .help("Theme")
    }

    private var modeIndicator: some View {
        Text(vimEngine.mode.displayName)
            .font(.system(.caption, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(modeColor.gradient, in: Capsule())
            .shadow(color: modeColor.opacity(0.35), radius: 3, y: 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: vimEngine.mode)
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
