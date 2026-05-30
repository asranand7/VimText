import SwiftUI

struct NoteListView: View {
    @ObservedObject var viewModel: NotesViewModel
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var selectedNoteIds: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var showDeleteAllConfirm = false
    @State private var showDeleteSelectedConfirm = false
    @State private var searchFocusTrigger = false
    @State private var highlightedIndex: Int? = nil
    @State private var hoveredNoteId: UUID? = nil
    @State private var showSidebarColorPicker = false
    @State private var isSearchFocused = false
    @State private var isSearchHovered = false

    private var sidebarTintBinding: Binding<Color> {
        Binding(
            get: { themeManager.sidebarTint },
            set: { themeManager.setSidebarTint($0) }
        )
    }

    private var allSelected: Bool {
        !viewModel.filteredNotes.isEmpty && selectedNoteIds.count == viewModel.filteredNotes.count
    }

    private var searchBarFill: Color {
        if theme.isDark {
            return isSearchHovered ? Color.white.opacity(0.09) : Color.white.opacity(0.06)
        } else {
            return isSearchHovered ? Color.white.opacity(0.48) : Color.white.opacity(0.38)
        }
    }

    private var searchBarStroke: Color {
        if isSearchFocused {
            return themeManager.sidebarTint.opacity(0.50)
        } else if isSearchHovered {
            return Color.primary.opacity(0.14)
        } else {
            return Color.primary.opacity(0.08)
        }
    }

    private var theme: AppTheme { themeManager.theme }

    private var glassBackground: some View {
        ZStack {
            VisualEffectView(material: .sidebar)
                .opacity(theme.isGraphite ? 0.38 : 1)
            theme.surface.opacity(sidebarSurfaceOpacity)
            LinearGradient(
                colors: [
                    themeManager.sidebarTint.opacity(sidebarTintTopOpacity),
                    themeManager.sidebarTint.opacity(sidebarTintBottomOpacity)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var sidebarSurfaceOpacity: Double {
        if theme.isGraphite { return 0.74 }
        if theme.isInk { return 0.46 }
        return theme.isDark ? 0.36 : 0.52
    }

    private var sidebarTintTopOpacity: Double {
        if theme.isMonochrome { return theme.isDark ? 0.06 : 0.035 }
        return theme.isDark ? 0.15 : 0.11
    }

    private var sidebarTintBottomOpacity: Double {
        theme.isMonochrome ? 0.0 : 0.02
    }

    private func folderName(for note: Note) -> String {
        if let id = note.folderId, let folder = viewModel.folders.first(where: { $0.id == id }) {
            return folder.name
        }
        return "Notes"
    }

    private func dateGroup(_ date: Date) -> (order: Int, title: String) {
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) { return (0, "Today") }
        if cal.isDateInYesterday(date) { return (1, "Yesterday") }
        if let d7 = cal.date(byAdding: .day, value: -7, to: now), date > d7 { return (2, "Previous 7 Days") }
        if let d30 = cal.date(byAdding: .day, value: -30, to: now), date > d30 { return (3, "Previous 30 Days") }
        let comps = cal.dateComponents([.year, .month], from: date)
        let df = DateFormatter()
        df.dateFormat = comps.year == cal.component(.year, from: now) ? "MMMM" : "MMMM yyyy"
        let ym = (comps.year ?? 0) * 12 + (comps.month ?? 0)
        return (10_000_000 - ym, df.string(from: date))
    }

    private func dateSections(_ notes: [Note]) -> [(title: String, notes: [Note])] {
        var groups: [Int: (String, [Note])] = [:]
        var orderSeen: [Int] = []
        for note in notes {
            let key = dateGroup(note.modifiedAt)
            if groups[key.order] == nil { groups[key.order] = (key.title, []); orderSeen.append(key.order) }
            groups[key.order]?.1.append(note)
        }
        return orderSeen.sorted().map { (groups[$0]!.0, groups[$0]!.1) }
    }

    private var sidebarColorPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sidebar Color")
                .font(.system(.headline, design: .default))

            ColorPicker("Custom color", selection: sidebarTintBinding, supportsOpacity: false)
                .font(.system(.subheadline, design: .default))

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 10), count: 7), spacing: 10) {
                ForEach(sidebarTintPresets, id: \.self) { hex in
                    Button {
                        themeManager.sidebarTintHex = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().strokeBorder(
                                    Color.primary.opacity(themeManager.sidebarTintHex == hex ? 0.9 : 0.12),
                                    lineWidth: themeManager.sidebarTintHex == hex ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                themeManager.resetSidebarTint()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Use Theme Color")
                }
                .font(.system(.caption, design: .default).weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(themeManager.isUsingCustomSidebarTint ? theme.accent : .secondary)
            .disabled(!themeManager.isUsingCustomSidebarTint)
        }
        .padding(16)
        .frame(width: 260)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(.caption, design: .default).weight(.bold))
                .foregroundStyle(themeManager.sidebarTint)
                .textCase(nil)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                        .font(.subheadline)
                    SearchField(
                        text: $viewModel.searchText,
                        focusTrigger: $searchFocusTrigger,
                        isFocused: $isSearchFocused,
                        onArrowDown: { moveHighlight(down: true) },
                        onArrowUp: { moveHighlight(down: false) },
                        onEnter: { selectHighlighted() },
                        onEscape: { dismissSearch() }
                    )
                    .frame(height: 22)
                    if !viewModel.searchText.isEmpty {
                        Button(action: {
                            viewModel.searchText = ""
                            highlightedIndex = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(theme.secondaryText.opacity(0.5))
                                .font(.subheadline)
                        }
                        .buttonStyle(PressableIconButtonStyle(pressedScale: 0.94))
                    } else {
                        HStack(spacing: 1.5) {
                            Text("⌘")
                                .font(.system(size: 9, weight: .medium))
                            Text("K")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(theme.isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.68))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(theme.isDark ? 0.15 : 0.08), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(theme.isDark ? 0.22 : 0.06), radius: 0.5, y: 0.8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 36)
                .background(
                    Capsule()
                        .fill(searchBarFill)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(searchBarStroke, lineWidth: isSearchFocused ? 1.0 : 0.5)
                )
                .shadow(
                    color: themeManager.sidebarTint.opacity(isSearchFocused ? 0.10 : 0),
                    radius: isSearchFocused ? 6 : 0,
                    y: isSearchFocused ? 1.5 : 0
                )
                .scaleEffect(isSearchFocused ? 1.01 : 1, anchor: .center)
                .animation(DS.snappy, value: isSearchFocused)
                .onHover { hovering in
                    withAnimation(DS.snappy) {
                        isSearchHovered = hovering
                    }
                }

                Button(action: { viewModel.createNote() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.42))
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                        )
                }
                .buttonStyle(PressableIconButtonStyle())
                .help("New Note (⌘N)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 30)
            .padding(.bottom, 10)

            if isSelectionMode {
                HStack(spacing: 8) {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        if allSelected {
                            selectedNoteIds.removeAll()
                        } else {
                            selectedNoteIds = Set(viewModel.filteredNotes.map { $0.id })
                        }
                    }
                    .font(.system(.caption, design: .default).weight(.medium))
                    .buttonStyle(.borderless)

                    Spacer()

                    Text("\(selectedNoteIds.count) selected")
                        .font(.system(.caption, design: .default))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Done") {
                        isSelectionMode = false
                        selectedNoteIds.removeAll()
                    }
                    .font(.system(.caption, design: .default).weight(.semibold))
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))

                Divider()
                    .foregroundStyle(theme.separator.opacity(0.5))
            }

            if viewModel.filteredNotes.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: viewModel.searchText.isEmpty ? "note.text" : "magnifyingglass")
                        .font(.system(size: 32, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text(viewModel.searchText.isEmpty ? "No Notes" : "No Results")
                        .font(.system(.callout, design: .default))
                        .foregroundStyle(.secondary)
                    if viewModel.searchText.isEmpty {
                        Text("Create a note to get started")
                            .font(.system(.caption, design: .default))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if isSelectionMode {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        let pinned = viewModel.filteredNotes.filter { $0.isPinned }
                        let unpinned = viewModel.filteredNotes.filter { !$0.isPinned }

                        if !pinned.isEmpty {
                            sectionHeader("Pinned")
                            ForEach(pinned) { note in
                                selectableNoteRow(note: note)
                            }
                        }

                        if !unpinned.isEmpty {
                            if !pinned.isEmpty {
                                sectionHeader("Notes")
                            }
                            ForEach(unpinned) { note in
                                selectableNoteRow(note: note)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.never)
            } else {
                notesList
            }

            Divider()
                .foregroundStyle(theme.separator.opacity(0.5))

            HStack {
                Text("\(viewModel.filteredNotes.count) notes")
                    .font(.system(.caption2, design: .default))
                    .foregroundStyle(.secondary.opacity(0.7))
                Spacer()

                if isSelectionMode && !selectedNoteIds.isEmpty {
                    Button(role: .destructive) {
                        showDeleteSelectedConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(PressableIconButtonStyle(pressedScale: 0.94))
                    .help("Delete selected notes")
                }

                Button {
                    showSidebarColorPicker.toggle()
                } label: {
                    Image(systemName: "paintbrush.pointed")
                        .font(.caption)
                        .foregroundStyle(themeManager.sidebarTint)
                }
                .buttonStyle(PressableIconButtonStyle(pressedScale: 0.94))
                .help("Sidebar Color")
                .popover(isPresented: $showSidebarColorPicker, arrowEdge: .bottom) {
                    sidebarColorPicker
                }

                Menu {
                    if !isSelectionMode {
                        Button("Select Notes…") {
                            isSelectionMode = true
                            selectedNoteIds.removeAll()
                        }
                        
                        Divider()
                        
                        Button("Change Notes Location…") {
                            changeNotesDirectory()
                        }
                        
                        if StorageManager.shared.customDirectoryPath != nil {
                            Button("Use Default Location") {
                                StorageManager.shared.customDirectoryPath = nil
                                viewModel.load()
                            }
                        }
                    }

                    Divider()

                    Button("Delete All Notes…", role: .destructive) {
                        showDeleteAllConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
                .help(StorageManager.shared.customDirectoryPath != nil
                      ? "Current Location: \(StorageManager.shared.customDirectoryPath!)"
                      : "Using Default App Support Location")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(glassBackground)
        .animation(.easeInOut(duration: 0.28), value: theme.id)
        .confirmationDialog(
            "Delete All Notes?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                viewModel.deleteAllNotes()
                isSelectionMode = false
                selectedNoteIds.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all \(viewModel.notes.count) notes. This action cannot be undone.")
        }
        .confirmationDialog(
            "Delete \(selectedNoteIds.count) Notes?",
            isPresented: $showDeleteSelectedConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedNoteIds.count) Notes", role: .destructive) {
                viewModel.deleteNotes(ids: selectedNoteIds)
                selectedNoteIds.removeAll()
                isSelectionMode = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete \(selectedNoteIds.count) selected notes. This action cannot be undone.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusNoteSearch)) { _ in
            searchFocusTrigger.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChangeLocationPanel)) { _ in
            changeNotesDirectory()
        }
        .onChange(of: viewModel.searchText) {
            if viewModel.searchText.isEmpty {
                highlightedIndex = nil
            } else {
                highlightedIndex = viewModel.filteredNotes.isEmpty ? nil : 0
            }
        }
    }

    private func changeNotesDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Notes Location"
        panel.prompt = "Select"
        
        if panel.runModal() == .OK, let url = panel.url {
            StorageManager.shared.customDirectoryPath = url.path
            viewModel.load()
        }
    }

    @ViewBuilder
    private var notesList: some View {
        let notes = viewModel.filteredNotes
        let isSearching = !viewModel.searchText.isEmpty

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if isSearching {
                        ForEach(Array(notes.enumerated()), id: \.element.id) { idx, note in
                            noteRow(note: note, flatIndex: idx, isSearching: true)
                        }
                    } else {
                        let pinned = notes.filter { $0.isPinned }
                        let unpinned = notes.filter { !$0.isPinned }

                        if !pinned.isEmpty {
                            sectionHeader("Pinned")
                            ForEach(pinned) { note in
                                noteRow(note: note, flatIndex: 0, isSearching: false)
                            }
                        }

                        ForEach(dateSections(unpinned), id: \.title) { section in
                            sectionHeader(section.title)
                            ForEach(section.notes) { note in
                                noteRow(note: note, flatIndex: 0, isSearching: false)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.never)
            .onChange(of: highlightedIndex) {
                if let idx = highlightedIndex, idx < notes.count {
                    proxy.scrollTo(notes[idx].id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func noteRow(note: Note, flatIndex: Int, isSearching: Bool) -> some View {
        let isHighlighted = isSearching && highlightedIndex == flatIndex
        let isSelected = !isSearching && viewModel.selectedNoteId == note.id
        let isHovered = hoveredNoteId == note.id

        let tint = themeManager.sidebarTint
        let rowFill = noteRowFill(isSelected: isSelected, isHighlighted: isHighlighted, isHovered: isHovered, tint: tint)
        let rowStroke = noteRowStroke(isSelected: isSelected, isHighlighted: isHighlighted, isHovered: isHovered, tint: tint)
        
        let rowShadowOpacity = isSelected
            ? (theme.isDark ? 0.18 : 0.05)
            : (isHovered ? (theme.isDark ? 0.12 : 0.03) : 0)
        let rowShadowRadius: CGFloat = isSelected ? 6 : (isHovered ? 4 : 0)
        let rowShadowY: CGFloat = isSelected ? 2 : (isHovered ? 1.5 : 0)
        let rowScale: CGFloat = isSelected ? 1.01 : (isHovered ? 1.005 : 1.0)
        let rowOffset: CGFloat = isHovered && !isSelected ? -1.0 : 0

        NoteRowView(
            note: note,
            folderName: folderName(for: note),
            isHovered: isHovered,
            isSelected: isSelected || isHighlighted,
            onCopyPath: { copyPath(for: note) }
        )
            .id(note.id)
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(rowFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(isSelected && theme.isDark ? Color.white.opacity(0.03) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(rowStroke, lineWidth: 0.5)
                    )
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(tint)
                        .frame(width: 3.0, height: 32)
                        .padding(.leading, 5.5)
                }
            }
            .shadow(color: Color.black.opacity(rowShadowOpacity),
                    radius: rowShadowRadius,
                    y: rowShadowY)
            .scaleEffect(rowScale, anchor: .center)
            .offset(y: rowOffset)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .onHover { hovering in
                withAnimation(DS.snappy) {
                    if hovering {
                        hoveredNoteId = note.id
                    } else if hoveredNoteId == note.id {
                        hoveredNoteId = nil
                    }
                }
            }
            .onTapGesture {
                withAnimation(DS.spring) {
                    viewModel.selectedNoteId = note.id
                }
                highlightedIndex = nil
                viewModel.searchText = ""
            }
            .animation(DS.spring, value: isSelected)
            .contextMenu {
                noteContextMenu(for: note)
            }
    }

    private func moveHighlight(down: Bool) {
        let count = viewModel.filteredNotes.count
        guard count > 0 else { return }

        if let current = highlightedIndex {
            if down {
                highlightedIndex = min(current + 1, count - 1)
            } else {
                highlightedIndex = max(current - 1, 0)
            }
        } else {
            highlightedIndex = down ? 0 : count - 1
        }
    }

    private func selectHighlighted() {
        let notes = viewModel.filteredNotes
        guard !notes.isEmpty else { return }

        if let idx = highlightedIndex, idx < notes.count {
            viewModel.selectedNoteId = notes[idx].id
        } else if let first = notes.first {
            viewModel.selectedNoteId = first.id
        }

        highlightedIndex = nil
        viewModel.searchText = ""
    }

    private func dismissSearch() {
        highlightedIndex = nil
        viewModel.searchText = ""
    }

    private func noteRowFill(isSelected: Bool, isHighlighted: Bool, isHovered: Bool, tint: Color) -> Color {
        if isSelected {
            return theme.isDark
                ? tint.opacity(theme.isMonochrome ? 0.11 : 0.15)
                : tint.opacity(theme.isMonochrome ? 0.05 : 0.08)
        }
        if isHighlighted { return tint.opacity(theme.isDark ? 0.10 : 0.07) }
        if isHovered { return theme.isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.52) }
        return Color.clear
    }

    private func noteRowStroke(isSelected: Bool, isHighlighted: Bool, isHovered: Bool, tint: Color) -> Color {
        if isSelected { return tint.opacity(theme.isMonochrome ? (theme.isDark ? 0.20 : 0.12) : (theme.isDark ? 0.26 : 0.14)) }
        if isHighlighted { return tint.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.06) }
        return Color.clear
    }

    @ViewBuilder
    private func selectableNoteRow(note: Note) -> some View {
        let isSelected = selectedNoteIds.contains(note.id)
        let isHovered = hoveredNoteId == note.id

        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.blue : Color.secondary.opacity(0.4))
                .font(.system(size: 16, weight: .medium))

            NoteRowView(note: note, folderName: folderName(for: note), isHovered: isHovered, isSelected: isSelected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(isSelected
                      ? theme.accent.opacity(theme.isDark ? 0.10 : 0.07)
                      : (isHovered ? Color.white.opacity(theme.isDark ? 0.06 : 0.42) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(isSelected
                              ? theme.accent.opacity(theme.isDark ? 0.28 : 0.20)
                              : (isHovered ? theme.accent.opacity(0.12) : Color.clear), lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onHover { hovering in
            withAnimation(DS.snappy) {
                if hovering {
                    hoveredNoteId = note.id
                } else if hoveredNoteId == note.id {
                    hoveredNoteId = nil
                }
            }
        }
        .onTapGesture {
            if selectedNoteIds.contains(note.id) {
                selectedNoteIds.remove(note.id)
            } else {
                selectedNoteIds.insert(note.id)
            }
        }
    }

    @ViewBuilder
    private func noteContextMenu(for note: Note) -> some View {
        Button(note.isPinned ? "Unpin" : "Pin") {
            viewModel.togglePin(note)
        }

        Button("Copy Path") {
            copyPath(for: note)
        }

        Divider()

        Button("Delete", role: .destructive) {
            viewModel.deleteNote(note)
        }
    }

    private func copyPath(for note: Note) {
        let path = StorageManager.shared.fileURL(for: note).path
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}

final class FocusReportingTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusTrigger: Bool
    @Binding var isFocused: Bool
    var onArrowDown: () -> Void
    var onArrowUp: () -> Void
    var onEnter: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusReportingTextField()
        field.placeholderString = "Search"
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.onFocusChange = { focused in
            DispatchQueue.main.async { isFocused = focused }
        }
        context.coordinator.textField = field
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if focusTrigger != context.coordinator.lastTriggerValue {
            context.coordinator.lastTriggerValue = focusTrigger
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> SearchFieldCoordinator {
        SearchFieldCoordinator(self)
    }

    class SearchFieldCoordinator: NSObject, NSTextFieldDelegate {
        let parent: SearchField
        weak var textField: NSTextField?
        var lastTriggerValue: Bool = false

        init(_ parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onArrowDown()
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onArrowUp()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onEnter()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}
