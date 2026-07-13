import SwiftUI
import AppKit

struct NoteListView: View {
    @ObservedObject var viewModel: NotesViewModel
    var onToggleSidebar: (() -> Void)? = nil
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var selectedNoteIds: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var showDeleteAllConfirm = false
    @State private var showQuickCaptureShortcutSheet = false
    @State private var showDeleteSelectedConfirm = false
    @State private var searchFocusTrigger = false
    @State private var highlightedIndex: Int? = nil
    @State private var showSidebarColorPicker = false
    @State private var isSearchFocused = false
    @State private var isSearchHovered = false
    @State private var collapsedSections: Set<String> = []
    @State private var noteToDelete: Note? = nil
    /// True while the sidebar list (not the editor) owns keyboard focus and is
    /// being driven with Vim keys. Mirrors the NavKeyCatcher's first-responder
    /// state, so it flips back to false the moment the editor, search field, or
    /// command palette takes focus.
    @State private var listNavActive = false
    /// Flipped to ask NavKeyCatcher to grab first responder (enter list nav).
    @State private var listNavFocusTrigger = false
    /// Transient footer message for list-nav feedback (e.g. a locked note that
    /// can't be `dd`-deleted). Auto-clears after a couple of seconds.
    @State private var navMessage: String? = nil

    private var sidebarTintBinding: Binding<Color> {
        Binding(
            get: { themeManager.sidebarTint },
            set: { themeManager.setSidebarTint($0) }
        )
    }

    private var allSelected: Bool {
        !viewModel.filteredNotes.isEmpty && selectedNoteIds.count == viewModel.filteredNotes.count
    }

    private var searchActive: Bool { !viewModel.searchText.isEmpty }

    /// The notes the keyboard cursor can land on, in the exact top-to-bottom
    /// order they're rendered. While searching, that's the flat result list;
    /// otherwise it's pinned-then-date-sections, skipping any collapsed
    /// section (which isn't on screen to land on). Used by the action handlers
    /// (open/delete/clamp), which run once per action — `notesList` builds its
    /// own copy once per render so rows don't each recompute it.
    private var navigableNotes: [Note] {
        let notes = viewModel.filteredNotes
        if searchActive { return notes }
        let pinned = notes.filter { $0.isPinned }
        let unpinned = notes.filter { !$0.isPinned }
        return navigationOrder(
            isSearching: false,
            notes: notes,
            pinned: pinned,
            pinnedVisible: !pinned.isEmpty && !collapsedSections.contains("Pinned"),
            sections: dateSections(unpinned)
        )
    }

    /// Count of navigable rows, cheaply. The hot j/k path only needs a count to
    /// clamp the cursor; with nothing collapsed every filtered note is
    /// navigable, so we skip rebuilding the Calendar-heavy date sections.
    private var navigableCount: Int {
        if searchActive { return viewModel.filteredNotes.count }
        if collapsedSections.isEmpty { return viewModel.filteredNotes.count }
        return navigableNotes.count
    }

    /// Flattens the on-screen order (pinned, then non-collapsed date sections)
    /// into the cursor's navigable list.
    private func navigationOrder(isSearching: Bool, notes: [Note], pinned: [Note], pinnedVisible: Bool, sections: [(title: String, notes: [Note])]) -> [Note] {
        if isSearching { return notes }
        var order: [Note] = []
        order.reserveCapacity(notes.count)
        if pinnedVisible { order.append(contentsOf: pinned) }
        for section in sections where !collapsedSections.contains(section.title) {
            order.append(contentsOf: section.notes)
        }
        return order
    }

    /// id → row index over the navigable order, built once per render.
    private func indexMap(for order: [Note]) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        map.reserveCapacity(order.count)
        for (index, note) in order.enumerated() { map[note.id] = index }
        return map
    }

    /// The list `highlightedIndex` indexes into for the current context.
    private var currentNavList: [Note] {
        searchActive ? viewModel.filteredNotes : navigableNotes
    }

    /// Footer text: a transient nav message takes priority, then a "you're
    /// driving the list with the keyboard" indicator while list nav is active,
    /// otherwise the plain note count.
    @ViewBuilder
    private var footerStatus: some View {
        if let navMessage {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9.5))
                Text(navMessage)
                    .lineLimit(1)
            }
            .font(.system(.caption2, design: .default).weight(.semibold))
            .foregroundStyle(theme.accent)
            .transition(.opacity)
        } else if listNavActive {
            HStack(spacing: 5) {
                Circle()
                    .fill(themeManager.sidebarTint)
                    .frame(width: 6, height: 6)
                Text("Navigating · j/k move · ⏎ open · esc exit")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.system(.caption2, design: .default).weight(.semibold))
            .foregroundStyle(themeManager.sidebarTint)
            .transition(.opacity)
        } else {
            Text("\(viewModel.filteredNotes.count) notes")
                .font(.system(.caption2, design: .default))
                .foregroundStyle(.secondary.opacity(0.7))
        }
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
            theme.surface
            if themeManager.isUsingCustomSidebarTint {
                LinearGradient(
                    colors: [
                        themeManager.sidebarTint.opacity(sidebarTintTopOpacity),
                        themeManager.sidebarTint.opacity(sidebarTintBottomOpacity)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Color.primary.opacity(theme.isDark ? 0.05 : 0.025)
            }
        }
        .ignoresSafeArea()
    }

    private var sidebarTintTopOpacity: Double {
        if theme.isMonochrome { return theme.isDark ? 0.06 : 0.035 }
        return theme.isDark ? 0.15 : 0.11
    }

    private var sidebarTintBottomOpacity: Double {
        theme.isMonochrome ? 0.0 : 0.02
    }

    /// Groups notes into the sidebar's date buckets (Today, Yesterday, Previous
    /// 7/30 Days, then per-month). The day boundaries are computed once up front
    /// instead of per note: the old per-note `Calendar.isDateInToday`/
    /// `date(byAdding:)` calls were most of the cost of running this over
    /// hundreds of notes on every sidebar render.
    private func dateSections(_ notes: [Note]) -> [(title: String, notes: [Note])] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let weekAgo = cal.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let monthAgo = cal.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday
        let currentYear = cal.component(.year, from: now)

        func group(_ date: Date) -> (order: Int, title: String) {
            if date >= startOfToday { return (0, "Today") }
            if date >= startOfYesterday { return (1, "Yesterday") }
            if date >= weekAgo { return (2, "Previous 7 Days") }
            if date >= monthAgo { return (3, "Previous 30 Days") }
            let comps = cal.dateComponents([.year, .month], from: date)
            let df = comps.year == currentYear ? AppDateFormatters.month : AppDateFormatters.monthYear
            let ym = (comps.year ?? 0) * 12 + (comps.month ?? 0)
            return (10_000_000 - ym, df.string(from: date))
        }

        var groups: [Int: (String, [Note])] = [:]
        var orderSeen: [Int] = []
        for note in notes {
            let key = group(note.modifiedAt)
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
                .font(.system(size: 11, weight: .semibold, design: .default))
                .kerning(0.7)
                .foregroundStyle(themeManager.sidebarTint.opacity(0.9))
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// A tappable section header with a disclosure chevron. Toggling adds/
    /// removes the title from `collapsedSections`, which `notesList` reads to
    /// hide the section's rows.
    private func collapsibleSectionHeader(_ title: String, count: Int) -> some View {
        let isCollapsed = collapsedSections.contains(title)
        return Button {
            withAnimation(DS.snappy) {
                if isCollapsed {
                    collapsedSections.remove(title)
                } else {
                    collapsedSections.insert(title)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(themeManager.sidebarTint.opacity(0.8))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .kerning(0.7)
                    .foregroundStyle(themeManager.sidebarTint.opacity(0.9))
                    .textCase(.uppercase)
                Text("· \(count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .default))
                    .foregroundStyle(themeManager.sidebarTint.opacity(0.5))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let onToggleSidebar {
                    Button(action: onToggleSidebar) {
                        Image(systemName: "sidebar.leading")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.secondaryText.opacity(0.74))
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                        .background(
                            Capsule()
                                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.42))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(PressableIconButtonStyle())
                    .help("Collapse Sidebar (⌘⌥B)")
                    .accessibilityLabel("Collapse sidebar")
                    .accessibilityHint("Hides the notes sidebar. Shortcut: Command Option B.")
                }

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
                .layoutPriority(1)

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
                footerStatus
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
                        
                        Section(notesLocationLabel) {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: StorageManager.shared.baseDirectoryPath)]
                                )
                            }

                            Button("Change Notes Location…") {
                                changeNotesDirectory()
                            }

                            if StorageManager.shared.customDirectoryPath != nil {
                                Button("Use Default Location") {
                                    switchNotesDirectory(to: nil)
                                }
                            }
                        }

                        Divider()

                        Button("Quick Capture Shortcut… (\(QuickCaptureHotKey.shared.shortcutDescription))") {
                            showQuickCaptureShortcutSheet = true
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
        .background(navKeyCatcher)
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
            let lockedCount = viewModel.notes.filter(\.isLocked).count
            Text(lockedCount > 0
                 ? "This will permanently delete all unlocked notes. \(lockedCount) locked note\(lockedCount == 1 ? "" : "s") will be kept. This action cannot be undone."
                 : "This will permanently delete all \(viewModel.notes.count) notes. This action cannot be undone.")
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
            let lockedSelected = viewModel.notes.filter { selectedNoteIds.contains($0.id) && $0.isLocked }.count
            Text(lockedSelected > 0
                 ? "This will permanently delete the selected notes, except \(lockedSelected) locked note\(lockedSelected == 1 ? "" : "s") which will be kept. This action cannot be undone."
                 : "This will permanently delete \(selectedNoteIds.count) selected notes. This action cannot be undone.")
        }
        .confirmationDialog(
            "Delete \"\(noteToDelete?.displayTitle ?? "")\"?",
            isPresented: Binding(
                get: { noteToDelete != nil },
                set: { if !$0 { noteToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let note = noteToDelete {
                    viewModel.deleteNote(note)
                }
                noteToDelete = nil
            }
            Button("Cancel", role: .cancel) { noteToDelete = nil }
        } message: {
            Text("This will permanently delete the note. This action cannot be undone.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusNoteSearch)) { _ in
            searchFocusTrigger.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChangeLocationPanel)) { _ in
            changeNotesDirectory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openQuickCaptureShortcutSettings)) { _ in
            showQuickCaptureShortcutSheet = true
        }
        .sheet(isPresented: $showQuickCaptureShortcutSheet) {
            QuickCaptureShortcutSheet()
        }
        .onChange(of: viewModel.searchText) {
            if viewModel.searchText.isEmpty {
                highlightedIndex = nil
            } else {
                highlightedIndex = viewModel.filteredNotes.isEmpty ? nil : 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusNoteList)) { _ in
            activateListNav()
        }
        .onChange(of: viewModel.filteredNotes.count) {
            guard listNavActive else { return }
            let count = navigableNotes.count
            if count == 0 {
                highlightedIndex = nil
            } else if let index = highlightedIndex {
                highlightedIndex = min(max(index, 0), count - 1)
            }
        }
    }

    /// Menu-section header showing where notes currently live, so the
    /// location isn't discoverable only via the ⋯ button's tooltip.
    private var notesLocationLabel: String {
        guard let path = StorageManager.shared.customDirectoryPath else {
            return "Notes in Default Location"
        }
        return "Notes in \((path as NSString).abbreviatingWithTildeInPath)"
    }

    private func changeNotesDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Notes Location"
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.path != StorageManager.shared.baseDirectoryPath else { return }
        switchNotesDirectory(to: url.path)
    }

    /// Switches the notes location, offering to copy the existing notes over
    /// first so they don't silently disappear from view. `nil` = default
    /// App Support location.
    private func switchNotesDirectory(to path: String?) {
        guard !viewModel.notes.isEmpty else {
            viewModel.changeDirectoryPath(to: path)
            return
        }
        let count = viewModel.notes.count
        let alert = NSAlert()
        alert.messageText = "Copy your notes to the new location?"
        alert.informativeText = "\"Copy & Switch\" copies your \(count) note\(count == 1 ? "" : "s") (including images) to the new location before switching. \"Switch Only\" shows just the notes already there. The files in the current location are left untouched either way."
        alert.addButton(withTitle: "Copy & Switch")
        alert.addButton(withTitle: "Switch Only")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            viewModel.changeDirectoryPath(to: path, migratingNotes: true)
        case .alertSecondButtonReturn:
            viewModel.changeDirectoryPath(to: path)
        default:
            break
        }
    }

    @ViewBuilder
    private var notesList: some View {
        let notes = viewModel.filteredNotes
        let isSearching = !viewModel.searchText.isEmpty

        // Compute the on-screen layout and the cursor index map ONCE per render.
        // Previously each row read `navIndexByID`, which rebuilt the whole map
        // (and the Calendar-heavy date sections) on every access — O(n²) per
        // keystroke, which is what made j/k crawl with many notes.
        let pinned = isSearching ? [] : notes.filter { $0.isPinned }
        let unpinned = isSearching ? [] : notes.filter { !$0.isPinned }
        let sections = isSearching ? [] : dateSections(unpinned)
        let pinnedVisible = !pinned.isEmpty && !collapsedSections.contains("Pinned")
        let navOrder = navigationOrder(isSearching: isSearching, notes: notes, pinned: pinned, pinnedVisible: pinnedVisible, sections: sections)
        let navIndex = indexMap(for: navOrder)

        ScrollViewReader { proxy in
            ScrollView {
                // VStack (not LazyVStack): LazyVStack's deferred row
                // instantiation can race with NSTrackingArea install for
                // top-of-list rows, dropping hover events on the most
                // recent notes. Eager rendering eliminates that race; the
                // expected note count for this app is small enough that
                // we don't need the lazy variant.
                VStack(spacing: 12) {
                    if isSearching {
                        ForEach(Array(notes.enumerated()), id: \.element.id) { idx, note in
                            noteRow(note: note, flatIndex: idx, isSearching: true)
                        }
                    } else {
                        if !pinned.isEmpty {
                            collapsibleSectionHeader("Pinned", count: pinned.count)
                            if pinnedVisible {
                                ForEach(pinned) { note in
                                    noteRow(note: note, flatIndex: navIndex[note.id] ?? -1, isSearching: false)
                                }
                            }
                        }

                        ForEach(sections, id: \.title) { section in
                            collapsibleSectionHeader(section.title, count: section.notes.count)
                            if !collapsedSections.contains(section.title) {
                                ForEach(section.notes) { note in
                                    noteRow(note: note, flatIndex: navIndex[note.id] ?? -1, isSearching: false)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.never)
            .onChange(of: highlightedIndex) {
                // Keep the cursor visible with the minimum scroll (no full
                // re-centre on every keystroke). Index into the navigable
                // order — not filteredNotes, which differs once notes regroup
                // into date sections.
                if let idx = highlightedIndex, idx >= 0, idx < navOrder.count {
                    proxy.scrollTo(navOrder[idx].id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .revealNoteInSidebar)) { notification in
                // Sent by the command palette (and any future "open
                // note from elsewhere" caller). Scrolls the selected
                // row into view and centers it so it's obvious where
                // we landed. Sidebar-internal clicks don't post this,
                // so clicking a visible row doesn't cause a re-centre.
                guard let id = notification.object as? UUID else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func noteRow(note: Note, flatIndex: Int, isSearching: Bool) -> some View {
        let isOnCursor = highlightedIndex == flatIndex
        // The faint search highlight and the bold list-nav keyboard cursor are
        // visually distinct: search just tints the row, nav draws a clear ring
        // so you can see where focus is as you j/k around.
        let isHighlighted = isSearching && isOnCursor
        let isNavCursor = !isSearching && listNavActive && isOnCursor
        let isSelected = !isSearching && viewModel.selectedNoteId == note.id

        // Hover state lives inside NoteRowListItem so moving the mouse only
        // re-renders the row entered/left — not the whole list.
        NoteRowListItem(
            note: note,
            preview: viewModel.preview(for: note.id) ?? note.preview,
            isSelected: isSelected,
            isHighlighted: isHighlighted,
            isNavCursor: isNavCursor,
            themeID: themeManager.theme.id,
            sidebarTint: themeManager.sidebarTint,
            onCopyPath: { copyPath(for: note) },
            onTogglePin: {
                withAnimation(DS.snappy) { viewModel.togglePin(note) }
            },
            onToggleLock: {
                withAnimation(DS.snappy) { viewModel.toggleLock(note) }
            },
            onDelete: { noteToDelete = note },
            onTap: {
                withAnimation(DS.spring) {
                    viewModel.selectedNoteId = note.id
                }
                highlightedIndex = nil
                viewModel.searchText = ""
            }
        )
        // Equatable so a j/k cursor move re-renders only the two rows whose
        // highlight actually changed — not every row in the (non-lazy) list.
        // Without this each keystroke rebuilt hundreds of row bodies (each
        // doing Calendar date math), so the cursor and scroll couldn't keep up
        // with key-repeat and only caught up once the key was released.
        .equatable()
        .id(note.id)
        .contextMenu {
            noteContextMenu(for: note)
        }
    }

    private func moveHighlight(down: Bool) {
        // navigableCount avoids rebuilding the navigable list (and its date
        // sections) on every j/k — the hot path only needs a count to clamp.
        let count = navigableCount

        if let current = highlightedIndex, count > 0 {
            let next = down ? current + 1 : current - 1
            if next >= 0 && next < count {
                highlightedIndex = next
            } else {
                // Dead-ended against the list edge: unfold the adjacent
                // collapsed section (if any) and step into it.
                expandAdjacentCollapsedSection(down: down)
            }
        } else if count > 0 {
            highlightedIndex = down ? 0 : count - 1
        } else {
            // Every section is folded — j/k opens the nearest one.
            expandAdjacentCollapsedSection(down: down)
        }
    }

    /// The full on-screen section sequence (Pinned, then date sections),
    /// including collapsed ones. Only consulted at the navigable-list edges,
    /// so the per-keystroke j/k path never pays for the section rebuild.
    private func screenSections() -> [(title: String, notes: [Note])] {
        let notes = viewModel.filteredNotes
        let pinned = notes.filter { $0.isPinned }
        var sections = dateSections(notes.filter { !$0.isPinned })
        if !pinned.isEmpty { sections.insert((title: "Pinned", notes: pinned), at: 0) }
        return sections
    }

    /// j/k at the edge of the list unfolds the nearest collapsed section in
    /// that direction and lands on its closest note — the keyboard equivalent
    /// of clicking the section header.
    private func expandAdjacentCollapsedSection(down: Bool) {
        guard !searchActive, !collapsedSections.isEmpty else { return }
        let sections = screenSections()

        // Screen-order index of the section holding the cursor; with no
        // cursor, scan the whole list from the matching end.
        var cursorSection = down ? -1 : sections.count
        if let index = highlightedIndex {
            let order = navigableNotes
            if index >= 0, index < order.count {
                let id = order[index].id
                if let found = sections.firstIndex(where: { $0.notes.contains { $0.id == id } }) {
                    cursorSection = found
                }
            }
        }

        let scan: [Int] = down
            ? Array((cursorSection + 1)..<sections.count)
            : Array((0..<cursorSection).reversed())
        guard let targetIndex = scan.first(where: { collapsedSections.contains(sections[$0].title) })
        else { return }
        let target = sections[targetIndex]

        withAnimation(DS.snappy) {
            collapsedSections.remove(target.title)
        }
        // Land on the newly revealed section's nearest note, located in the
        // post-expansion navigable order.
        let landing = down ? target.notes.first : target.notes.last
        if let landing, let idx = navigableNotes.firstIndex(where: { $0.id == landing.id }) {
            highlightedIndex = idx
        }
    }

    /// gg/G land on the true first/last note, unfolding the edge section
    /// first if it's collapsed.
    private func goToListEdge(bottom: Bool) {
        if !searchActive, !collapsedSections.isEmpty {
            let sections = screenSections()
            let edge = bottom ? sections.last : sections.first
            if let edge, collapsedSections.contains(edge.title) {
                withAnimation(DS.snappy) { collapsedSections.remove(edge.title) }
            }
        }
        let count = currentNavList.count
        guard count > 0 else { return }
        highlightedIndex = bottom ? count - 1 : 0
    }

    private func selectHighlighted() {
        let notes = currentNavList
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

    // MARK: - Keyboard list navigation (⌘L)

    /// Invisible focus sink that turns Vim keys into list navigation while the
    /// sidebar — not the editor — holds focus. Lives as a full-size background
    /// so it's reliably in the window; it draws nothing and ignores the mouse.
    private var navKeyCatcher: some View {
        NavKeyCatcher(
            focusTrigger: $listNavFocusTrigger,
            onFocusChange: { active in
                withAnimation(DS.snappy) { listNavActive = active }
                if !active {
                    if !searchActive { highlightedIndex = nil }
                    navMessage = nil
                }
            },
            onMove: { down in moveHighlight(down: down) },
            onTop: { goToListEdge(bottom: false) },
            onBottom: { goToListEdge(bottom: true) },
            onOpen: { openHighlightedFromNav() },
            onExit: { exitListNav() },
            onDelete: { deleteHighlightedFromNav() },
            onFocusSearch: {
                highlightedIndex = nil
                searchFocusTrigger.toggle()
            }
        )
    }

    /// Enter list navigation (or leave it again if already active — ⌘L toggles).
    private func activateListNav() {
        guard !isSelectionMode else { return }
        if listNavActive { exitListNav(); return }
        let list = navigableNotes
        guard !list.isEmpty else { return }
        if let selected = viewModel.selectedNoteId,
           let index = list.firstIndex(where: { $0.id == selected }) {
            highlightedIndex = index
        } else {
            highlightedIndex = 0
        }
        listNavFocusTrigger.toggle()
    }

    private func openHighlightedFromNav() {
        let list = navigableNotes
        if let index = highlightedIndex, index >= 0, index < list.count {
            withAnimation(DS.spring) {
                viewModel.selectedNoteId = list[index].id
            }
        }
        highlightedIndex = nil
        NotificationCenter.default.post(name: .refocusEditor, object: nil)
    }

    private func exitListNav() {
        highlightedIndex = nil
        NotificationCenter.default.post(name: .refocusEditor, object: nil)
    }

    private func deleteHighlightedFromNav() {
        let list = navigableNotes
        guard let index = highlightedIndex, index >= 0, index < list.count else { return }
        let note = list[index]
        if note.isLocked {
            NSSound.beep()
            showNavMessage("“\(note.displayTitle)” is locked — unlock to delete")
            return
        }
        // Reuse the same confirmation dialog as the row trash button, so a
        // keyboard `dd` is exactly as safe (and undoable-by-cancel) as a click.
        noteToDelete = note
    }

    /// Show a transient message in the sidebar footer, then clear it (unless a
    /// newer message replaced it in the meantime).
    private func showNavMessage(_ text: String) {
        withAnimation(DS.snappy) { navMessage = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if navMessage == text {
                withAnimation(DS.snappy) { navMessage = nil }
            }
        }
    }

    @ViewBuilder
    private func selectableNoteRow(note: Note) -> some View {
        SelectableNoteRowItem(
            note: note,
            isChecked: selectedNoteIds.contains(note.id),
            onToggle: {
                if selectedNoteIds.contains(note.id) {
                    selectedNoteIds.remove(note.id)
                } else {
                    selectedNoteIds.insert(note.id)
                }
            }
        )
    }

    @ViewBuilder
    private func noteContextMenu(for note: Note) -> some View {
        Button(note.isPinned ? "Unpin" : "Pin") {
            viewModel.togglePin(note)
        }

        Button(note.isLocked ? "Unlock" : "Lock") {
            viewModel.toggleLock(note)
        }

        Button("Duplicate") {
            viewModel.duplicateNote(note)
        }

        Divider()

        Button("Reveal in Finder") {
            revealInFinder(note)
        }

        Button("Copy Path") {
            copyPath(for: note)
        }

        Divider()

        if note.isLocked {
            Button("Delete (locked)") {}
                .disabled(true)
        } else {
            Button("Delete", role: .destructive) {
                viewModel.deleteNote(note)
            }
        }
    }

    private func copyPath(for note: Note) {
        let path = StorageManager.shared.fileURL(for: note).path
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    private func revealInFinder(_ note: Note) {
        let url = StorageManager.shared.fileURL(for: note)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// A single sidebar note row. Owns its own hover state so that moving the
/// mouse only invalidates the row being entered/left, instead of the parent
/// list (which would re-run folder lookups, fills, and date formatting for
/// every row on every mouse move).
private struct NoteRowListItem: View, Equatable {
    let note: Note
    /// Cached preview text (see NoteRowView.preview). Not part of `==`: it only
    /// changes when content changes, which already bumps `note.modifiedAt`.
    let preview: String
    let isSelected: Bool
    let isHighlighted: Bool
    var isNavCursor: Bool = false
    /// Theme identity, threaded in so `==` can detect a theme or sidebar-tint
    /// change. `theme.id` fully determines the row's styling (isDark /
    /// isMonochrome / colors all derive from it); the tint is a separate user
    /// setting. Everything else `==` deliberately ignores — closures and the
    /// injected environment — which is what lets unchanged rows be skipped.
    let themeID: String
    let sidebarTint: Color
    let onCopyPath: () -> Void
    let onTogglePin: () -> Void
    let onToggleLock: () -> Void
    let onDelete: () -> Void
    let onTap: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager
    @State private var isHovered = false

    private var theme: AppTheme { themeManager.theme }

    /// Two rows compare equal — and so skip re-rendering — when nothing that
    /// affects their appearance has changed. `modifiedAt` is bumped on every
    /// content / title / pin edit, so comparing it (with the lock & pin flags
    /// and the selection / cursor state) catches every visible change without
    /// comparing note bodies. Hover lives in `@State`, which invalidates the
    /// body independently of this check.
    static func == (lhs: NoteRowListItem, rhs: NoteRowListItem) -> Bool {
        lhs.note.id == rhs.note.id &&
        lhs.note.modifiedAt == rhs.note.modifiedAt &&
        lhs.note.isPinned == rhs.note.isPinned &&
        lhs.note.isLocked == rhs.note.isLocked &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isHighlighted == rhs.isHighlighted &&
        lhs.isNavCursor == rhs.isNavCursor &&
        lhs.themeID == rhs.themeID &&
        lhs.sidebarTint == rhs.sidebarTint
    }

    var body: some View {
        let tint = themeManager.sidebarTint
        // The keyboard cursor (list nav) reads as "emphasized" like the open
        // note, but adds a bold ring on top so it's obvious where focus is.
        let emphasized = isSelected || isNavCursor
        let rowFill = Self.fill(theme: theme, emphasized: emphasized, isHighlighted: isHighlighted, isHovered: isHovered, tint: tint)
        let rowStroke = Self.stroke(theme: theme, emphasized: emphasized, isHighlighted: isHighlighted, isHovered: isHovered, tint: tint)

        let rowShadowOpacity = emphasized
            ? (theme.isDark ? 0.18 : 0.05)
            : (isHovered ? (theme.isDark ? 0.12 : 0.03) : 0)
        let rowShadowRadius: CGFloat = emphasized ? 6 : (isHovered ? 4 : 0)
        let rowShadowY: CGFloat = emphasized ? 2 : (isHovered ? 1.5 : 0)
        // Note: don't scale or offset on hover. Even a 1pt vertical shift can
        // race with `.onHover`'s tracking install on the top row of the list,
        // leaving it visually unresponsive to the cursor.
        let rowScale: CGFloat = emphasized ? 1.01 : 1.0

        return NoteRowView(
            note: note,
            preview: preview,
            isHovered: isHovered,
            isSelected: emphasized || isHighlighted,
            onCopyPath: onCopyPath,
            onTogglePin: onTogglePin,
            onToggleLock: onToggleLock,
            onDelete: onDelete
        )
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(rowFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(emphasized && theme.isDark ? Color.white.opacity(0.03) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(rowStroke, lineWidth: 0.5)
                    )
            )
            // Bold accent ring = the keyboard cursor. Drawn over the row so it
            // stays crisp and clearly travels with j/k, distinct from both the
            // faint hover/search tint and the filled "open note" selection.
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(tint.opacity(isNavCursor ? (theme.isDark ? 0.95 : 0.8) : 0),
                                  lineWidth: isNavCursor ? 2 : 0)
            )
            .shadow(color: Color.black.opacity(rowShadowOpacity),
                    radius: rowShadowRadius,
                    y: rowShadowY)
            .scaleEffect(rowScale, anchor: .center)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .onHover { hovering in
                withAnimation(DS.snappy) { isHovered = hovering }
            }
            .onTapGesture(perform: onTap)
            .animation(DS.spring, value: isSelected)
            .animation(DS.snappy, value: isNavCursor)
    }

    private static func fill(theme: AppTheme, emphasized: Bool, isHighlighted: Bool, isHovered: Bool, tint: Color) -> Color {
        if emphasized {
            return theme.isDark
                ? tint.opacity(theme.isMonochrome ? 0.11 : 0.15)
                : tint.opacity(theme.isMonochrome ? 0.05 : 0.08)
        }
        if isHighlighted { return tint.opacity(theme.isDark ? 0.10 : 0.07) }
        if isHovered { return theme.isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.52) }
        return Color.clear
    }

    private static func stroke(theme: AppTheme, emphasized: Bool, isHighlighted: Bool, isHovered: Bool, tint: Color) -> Color {
        if emphasized { return tint.opacity(theme.isMonochrome ? (theme.isDark ? 0.20 : 0.12) : (theme.isDark ? 0.26 : 0.14)) }
        if isHighlighted { return tint.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.06) }
        return Color.clear
    }
}

/// A note row in multi-select mode. Owns its own hover state for the same
/// reason as `NoteRowListItem`.
private struct SelectableNoteRowItem: View {
    let note: Note
    let isChecked: Bool
    let onToggle: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager
    @State private var isHovered = false

    private var theme: AppTheme { themeManager.theme }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isChecked ? Color.blue : Color.secondary.opacity(0.4))
                .font(.system(size: 16, weight: .medium))

            NoteRowView(note: note, isHovered: isHovered, isSelected: isChecked)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(isChecked
                      ? theme.accent.opacity(theme.isDark ? 0.10 : 0.07)
                      : (isHovered ? Color.white.opacity(theme.isDark ? 0.06 : 0.42) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(isChecked
                              ? theme.accent.opacity(theme.isDark ? 0.28 : 0.20)
                              : (isHovered ? theme.accent.opacity(0.12) : Color.clear), lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onHover { hovering in
            withAnimation(DS.snappy) { isHovered = hovering }
        }
        .onTapGesture(perform: onToggle)
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

/// An invisible, focusable view that turns Vim-style keys into note-list
/// navigation when the *sidebar* (not the editor) holds focus. Because a view
/// only receives `keyDown` while it is first responder, there's no global key
/// monitor to gate: focus is handed over explicitly (⌘L → `focusTrigger`) and
/// handed back by posting `.refocusEditor`. First-responder changes are
/// mirrored out through `onFocusChange` so the list can show/hide its cursor.
struct NavKeyCatcher: NSViewRepresentable {
    @Binding var focusTrigger: Bool
    var onFocusChange: (Bool) -> Void
    var onMove: (Bool) -> Void
    var onTop: () -> Void
    var onBottom: () -> Void
    var onOpen: () -> Void
    var onExit: () -> Void
    var onDelete: () -> Void
    var onFocusSearch: () -> Void

    func makeNSView(context: Context) -> NavKeyView {
        let view = NavKeyView()
        wire(view)
        return view
    }

    func updateNSView(_ nsView: NavKeyView, context: Context) {
        wire(nsView)
        if focusTrigger != context.coordinator.lastTriggerValue {
            context.coordinator.lastTriggerValue = focusTrigger
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    private func wire(_ view: NavKeyView) {
        view.onFocusChange = onFocusChange
        view.onMove = onMove
        view.onTop = onTop
        view.onBottom = onBottom
        view.onOpen = onOpen
        view.onExit = onExit
        view.onDelete = onDelete
        view.onFocusSearch = onFocusSearch
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastTriggerValue = false
    }
}

final class NavKeyView: NSView {
    var onFocusChange: ((Bool) -> Void)?
    var onMove: ((Bool) -> Void)?
    var onTop: (() -> Void)?
    var onBottom: (() -> Void)?
    var onOpen: (() -> Void)?
    var onExit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onFocusSearch: (() -> Void)?

    private var pendingG = false
    private var pendingD = false

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            resetPending()
            onFocusChange?(false)
        }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Let ⌘/⌃/⌥ combos fall through so menu shortcuts (⌘N, ⌘K, ⌘L…) still
        // work while the list is focused. Plain keys and Shift+key are ours.
        if !flags.subtracting(.shift).isEmpty {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 125: onMove?(true); resetPending(); return    // ↓
        case 126: onMove?(false); resetPending(); return   // ↑
        case 36, 76: leave(open: true); return             // Return / Enter
        case 53: leave(open: false); return                // Esc
        default: break
        }

        switch event.charactersIgnoringModifiers {
        case "j": onMove?(true); resetPending()
        case "k": onMove?(false); resetPending()
        case "G": onBottom?(); resetPending()
        case "g":
            if pendingG { onTop?(); pendingG = false } else { pendingG = true; pendingD = false }
        case "d":
            if pendingD { onDelete?(); pendingD = false } else { pendingD = true; pendingG = false }
        case "l", "o": leave(open: true)
        case "q": leave(open: false)
        case "/": onFocusSearch?(); resetPending()
        default: resetPending()   // swallow stray keys so there's no system beep
        }
    }

    /// Open the highlighted note (or just exit), then make sure focus actually
    /// leaves: `onOpen`/`onExit` post `.refocusEditor`, which focuses the editor
    /// when one exists; if none does (empty detail), we resign so the catcher
    /// stops swallowing keys.
    private func leave(open: Bool) {
        resetPending()
        if open { onOpen?() } else { onExit?() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.window?.firstResponder === self {
                self.window?.makeFirstResponder(nil)
            }
        }
    }

    private func resetPending() {
        pendingG = false
        pendingD = false
    }
}
