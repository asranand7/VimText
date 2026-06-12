import SwiftUI
import AppKit

struct PaletteCommand: Identifiable {
    let id: String
    let name: String
    let icon: String
    var shortcut: String? = nil
    let action: () -> Void
}

enum PaletteItem: Identifiable {
    case note(Note)
    case command(PaletteCommand)
    
    var id: String {
        switch self {
        case .note(let note): return note.id.uuidString
        case .command(let cmd): return cmd.id
        }
    }
}

class CommandPaletteState: ObservableObject {
    @Published var searchText = ""
    @Published var selectedIndex = 0
    @Published var results: [PaletteItem] = []
    /// True when the latest selection change came from hover. Hover-driven
    /// selection must not auto-scroll the list, or rows would slide out from
    /// under the cursor and re-trigger hover in a feedback loop.
    var selectionCameFromHover = false
    /// Ids shown under the "Recent" header for the current (empty-query)
    /// results; empty when a query is active.
    private(set) var recentNoteIdSet: Set<UUID> = []
    private var searchGeneration = 0
    private var debounceItem: DispatchWorkItem?

    func getCommands(themeManager: ThemeManager, viewModel: NotesViewModel, dismiss: @escaping () -> Void) -> [PaletteCommand] {
        return [
            PaletteCommand(id: "new_note", name: "Create New Note", icon: "square.and.pencil", shortcut: "⌘N") {
                Task { @MainActor in
                    viewModel.createNote()
                }
            },
            PaletteCommand(id: "duplicate_note", name: "Duplicate Current Note", icon: "plus.square.on.square", shortcut: "⌘D") {
                NotificationCenter.default.post(name: .duplicateCurrentNote, object: nil)
            },
            PaletteCommand(id: "find_in_note", name: "Find in Note", icon: "magnifyingglass", shortcut: "⌘F") {
                NotificationCenter.default.post(name: .findInNote, object: nil)
            },
            PaletteCommand(id: "toggle_sidebar", name: "Toggle Sidebar", icon: "sidebar.leading", shortcut: "⌘⌥B") {
                NotificationCenter.default.post(name: .toggleSidebar, object: nil)
            },
            PaletteCommand(id: "change_location", name: "Change Notes Location…", icon: "folder.badge.gearshape") {
                NotificationCenter.default.post(name: .openChangeLocationPanel, object: nil)
            },
            PaletteCommand(id: "theme_light", name: "Switch to Light Theme", icon: "sun.max") {
                themeManager.themeID = AppTheme.light.id
            },
            PaletteCommand(id: "theme_dark", name: "Switch to Dark Theme", icon: "moon") {
                themeManager.themeID = AppTheme.dark.id
            },
            PaletteCommand(id: "theme_nord", name: "Switch to Nord Theme", icon: "desktopcomputer") {
                themeManager.themeID = AppTheme.nord.id
            },
            PaletteCommand(id: "toggle_line_numbers", name: "Toggle Line Numbers", icon: "list.number") {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "showLineNumbers"), forKey: "showLineNumbers")
            },
            PaletteCommand(id: "toggle_monospace", name: "Toggle Monospaced Font", icon: "textformat") {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "useMonospacedFont"), forKey: "useMonospacedFont")
            },
            PaletteCommand(id: "paper_plain", name: "Paper: Plain", icon: "doc") {
                UserDefaults.standard.set("plain", forKey: "editorPaperStyle")
            },
            PaletteCommand(id: "paper_dotted", name: "Paper: Dotted Grid", icon: "ellipsis") {
                UserDefaults.standard.set("dotted", forKey: "editorPaperStyle")
            },
            PaletteCommand(id: "paper_lined", name: "Paper: Lined", icon: "line.horizontal.3") {
                UserDefaults.standard.set("lined", forKey: "editorPaperStyle")
            }
        ]
    }
    
    func scheduleSearch(notes: [Note], recentIds: [UUID], themeManager: ThemeManager, viewModel: NotesViewModel, dismiss: @escaping () -> Void) {
        debounceItem?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration &+= 1
        let gen = searchGeneration

        if query.isEmpty {
            results = buildItems(matched: notes, query: "", recentIds: recentIds, themeManager: themeManager, viewModel: viewModel, dismiss: dismiss)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            let matched = CommandPaletteState.matchingNotes(notes, query: query, recentIds: recentIds)
            DispatchQueue.main.async {
                guard let self, gen == self.searchGeneration else { return }
                self.results = self.buildItems(matched: matched, query: query, recentIds: recentIds, themeManager: themeManager, viewModel: viewModel, dismiss: dismiss)
            }
        }
        debounceItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Ranked search: notes are scored (see `scoreNote`) and returned best
    /// first, instead of filtered in storage order.
    static func matchingNotes(_ notes: [Note], query: String, recentIds: [UUID] = []) -> [Note] {
        if query.isEmpty { return notes }
        var recencyRank: [UUID: Int] = [:]
        for (i, id) in recentIds.enumerated() { recencyRank[id] = i }

        let count = notes.count
        var scored: [(note: Note, score: Int)]
        if count < 200 {
            scored = notes.compactMap { note in
                scoreNote(note, query: query, recencyRank: recencyRank).map { (note, $0) }
            }
        } else {
            let cores = min(ProcessInfo.processInfo.activeProcessorCount, count)
            let chunk = (count + cores - 1) / cores
            var buckets = [[(note: Note, score: Int)]](repeating: [], count: cores)
            buckets.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: cores) { k in
                    let lo = k * chunk
                    let hi = min(lo + chunk, count)
                    guard lo < hi else { return }
                    var local: [(note: Note, score: Int)] = []
                    for i in lo..<hi {
                        if let s = scoreNote(notes[i], query: query, recencyRank: recencyRank) {
                            local.append((notes[i], s))
                        }
                    }
                    buf[k] = local
                }
            }
            scored = buckets.flatMap { $0 }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.note.modifiedAt > $1.note.modifiedAt }
            .map(\.note)
    }

    /// Relevance score for one note, or nil if the query doesn't match it.
    /// Weights: title substring (with a prefix bonus) ≫ fuzzy title match ≫
    /// content substring, plus flat boosts for pinned and recently opened
    /// notes. The weights only need to preserve that ordering — their exact
    /// values are taste, not science.
    static func scoreNote(_ note: Note, query: String, recencyRank: [UUID: Int]) -> Int? {
        var score = 0
        var matched = false
        // Folding lets a straight-quote query match smart-quote note text.
        let query = query.searchFolded
        let title = note.displayTitle.searchFolded
        if let r = title.range(of: query, options: .caseInsensitive) {
            matched = true
            score += 100
            if r.lowerBound == title.startIndex { score += 30 }
        }
        if let fuzzy = FuzzySearch.match(query, in: title), fuzzy.score > 0 {
            matched = true
            score += fuzzy.score * 2
        }
        if note.content.searchFolded.range(of: query, options: .caseInsensitive) != nil {
            matched = true
            score += 40
        }
        guard matched else { return nil }
        if note.isPinned { score += 25 }
        if let rank = recencyRank[note.id] { score += max(0, 30 - rank * 4) }
        return score
    }

    func buildItems(matched: [Note], query: String, recentIds: [UUID], themeManager: ThemeManager, viewModel: NotesViewModel, dismiss: @escaping () -> Void) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if query.isEmpty, !recentIds.isEmpty {
            // Empty query: recently opened notes first (recency order), then
            // the rest by last modified. Section headers key off this set.
            var byId = Dictionary(matched.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var recents: [Note] = []
            for id in recentIds {
                if let note = byId.removeValue(forKey: id) { recents.append(note) }
            }
            let rest = matched
                .filter { byId[$0.id] != nil }
                .sorted { $0.modifiedAt > $1.modifiedAt }
            recentNoteIdSet = Set(recents.map(\.id))
            for note in recents { items.append(.note(note)) }
            for note in rest { items.append(.note(note)) }
        } else if query.isEmpty {
            recentNoteIdSet = []
            for note in matched where note.isPinned { items.append(.note(note)) }
            for note in matched where !note.isPinned { items.append(.note(note)) }
        } else {
            // Query active: `matched` is already in relevance order (pinned is
            // a score boost, not a section), so keep it intact.
            recentNoteIdSet = []
            for note in matched { items.append(.note(note)) }
        }
        let commands = getCommands(themeManager: themeManager, viewModel: viewModel, dismiss: dismiss)
        let filteredCommands: [PaletteCommand]
        if query.isEmpty {
            filteredCommands = commands
        } else {
            filteredCommands = commands
                .compactMap { cmd in FuzzySearch.match(query, in: cmd.name).map { (cmd, $0.score) } }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }
        for cmd in filteredCommands { items.append(.command(cmd)) }
        return items
    }
}

struct CommandPaletteView: View {
    @ObservedObject var viewModel: NotesViewModel
    @Binding var isPresented: Bool
    
    @StateObject private var state = CommandPaletteState()
    @FocusState private var isFieldFocused: Bool
    @StateObject private var keyboardMonitor = KeyboardMonitor()
    
    @AppStorage("commandPaletteWidth") private var width: Double = 600
    @AppStorage("commandPaletteHeight") private var height: Double = 420
    
    @State private var startWidth: Double = 600
    @State private var startHeight: Double = 420
    
    @EnvironmentObject private var themeManager: ThemeManager
    private var theme: AppTheme { themeManager.theme }
    
    private var items: [PaletteItem] {
        state.results
    }
    
    private var searchFieldRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(theme.secondaryText.opacity(0.8))
            
            TextField("Search notes or type commands…", text: $state.searchText)
                .textFieldStyle(.plain)
                .font(.system(.title3, design: .default))
                .focused($isFieldFocused)
                .foregroundStyle(theme.text)
                .onSubmit {
                    selectCurrentItem()
                }
            
            if !state.searchText.isEmpty {
                Button(action: { state.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.secondaryText.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            
            Text("ESC")
                .font(.system(size: 10, weight: .bold, design: .default))
                .foregroundStyle(theme.secondaryText.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }
    
    private var resultsListView: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "note.text")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(theme.secondaryText.opacity(0.4))
                    Text("No results found")
                        .font(.system(.callout, design: .default))
                        .foregroundStyle(theme.secondaryText)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                VStack(alignment: .leading, spacing: 0) {
                                    if idx == 0 || isNewSection(at: idx, in: items) {
                                        Text(sectionHeaderTitle(for: item))
                                            .font(.system(size: 10, weight: .bold, design: .default))
                                            .foregroundStyle(theme.secondaryText.opacity(0.6))
                                            .padding(.horizontal, 12)
                                            .padding(.top, idx == 0 ? 6 : 14)
                                            .padding(.bottom, 6)
                                    }
                                    
                                    rowView(for: item, index: idx, isSelected: state.selectedIndex == idx)
                                        .id(item.id)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: .infinity)
                    .onChange(of: state.selectedIndex) { _, newIndex in
                        guard !state.selectionCameFromHover else { return }
                        if newIndex >= 0 && newIndex < items.count {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(items[newIndex].id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private var footerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.and.down")
                Text("Navigate")
            }
            HStack(spacing: 4) {
                Image(systemName: "return")
                Text("Select")
            }
            Spacer()
            Text("\(items.count) results")
            
            // Resize Handle
            Image(systemName: "line.diagonal.corner")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText.opacity(0.6))
                .onHover { inside in
                    if inside {
                        NSCursor.pointingHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let newWidth = max(450, min(850, startWidth + value.translation.width))
                            let newHeight = max(280, min(700, startHeight + value.translation.height))
                            width = newWidth
                            height = newHeight
                        }
                        .onEnded { _ in
                            startWidth = width
                            startHeight = height
                        }
                )
        }
        .font(.system(size: 11, design: .default))
        .foregroundStyle(theme.secondaryText.opacity(0.8))
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.02))
    }
    
    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(theme.isDark ? 0.45 : 0.18)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }
            
            // Search Dialog Card
            VStack(spacing: 0) {
                searchFieldRow
                
                Divider()
                    .foregroundStyle(theme.separator.opacity(0.5))
                
                resultsListView
                
                Divider()
                    .foregroundStyle(theme.separator.opacity(0.5))
                
                footerBar
            }
            .frame(width: CGFloat(width), height: CGFloat(height))
            .background(
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                    theme.surface.opacity(theme.isDark ? 0.35 : 0.7)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(theme.isDark ? 0.06 : 0.4), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(theme.isDark ? 0.45 : 0.15), radius: 24, x: 0, y: 12)
        }
        .onExitCommand {
            dismiss()
        }
        .onAppear {
            // Resign the editor's first responder status so key events can route to SwiftUI
            NSApp.keyWindow?.makeFirstResponder(nil)
            
            // Focus the search field in the next run loop pass after the window responder chain clears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFieldFocused = true
            }
            
            startWidth = width
            startHeight = height
            setupKeyboardMonitor()
            state.scheduleSearch(notes: viewModel.notes, recentIds: viewModel.recentNoteIds, themeManager: themeManager, viewModel: viewModel, dismiss: { dismiss() })
        }
        .onChange(of: state.searchText) {
            state.selectionCameFromHover = false
            state.selectedIndex = 0
            state.scheduleSearch(notes: viewModel.notes, recentIds: viewModel.recentNoteIds, themeManager: themeManager, viewModel: viewModel, dismiss: { dismiss() })
        }
    }
    
    @ViewBuilder
    private func rowView(for item: PaletteItem, index: Int, isSelected: Bool) -> some View {
        switch item {
        case .note(let note):
            paletteNoteRow(note: note, index: index, isSelected: isSelected)
        case .command(let cmd):
            paletteCommandRow(cmd: cmd, index: index, isSelected: isSelected)
        }
    }
    
    @ViewBuilder
    private func paletteNoteRow(note: Note, index: Int, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(highlightedText(note.displayTitle, query: state.searchText, fuzzyFallback: true))
                    .font(.system(.body, design: .default).weight(.semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.accent)
                }
                Text(formatDate(note.modifiedAt))
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
            }
            
            Text(highlightedText(note.preview.isEmpty ? "No additional text" : note.preview, query: state.searchText))
                .font(.caption)
                .foregroundStyle(theme.secondaryText.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? theme.accent.opacity(theme.isDark ? 0.18 : 0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? theme.accent.opacity(0.35) : Color.clear, lineWidth: 0.8)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                state.selectionCameFromHover = true
                state.selectedIndex = index
            }
        }
        .onTapGesture {
            state.selectedIndex = index
            selectCurrentItem()
        }
    }

    @ViewBuilder
    private func paletteCommandRow(cmd: PaletteCommand, index: Int, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: cmd.icon)
                .font(.subheadline)
                .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                .frame(width: 20, height: 20)
            
            Text(highlightedText(cmd.name, query: state.searchText, fuzzyFallback: true))
                .font(.system(.body, design: .default).weight(.medium))
                .foregroundStyle(theme.text)

            Spacer()

            // A real shortcut hint earns its pixels; a generic "Action"
            // badge doesn't, so commands without one get nothing.
            if let shortcut = cmd.shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .foregroundStyle(theme.secondaryText.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? theme.accent.opacity(theme.isDark ? 0.18 : 0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? theme.accent.opacity(0.35) : Color.clear, lineWidth: 0.8)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                state.selectionCameFromHover = true
                state.selectedIndex = index
            }
        }
        .onTapGesture {
            state.selectedIndex = index
            selectCurrentItem()
        }
    }

    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isPresented = false
        }
        NotificationCenter.default.post(name: .refocusEditor, object: nil)
    }
    
    private func selectCurrentItem() {
        guard !items.isEmpty else { return }
        if state.selectedIndex >= 0 && state.selectedIndex < items.count {
            let item = items[state.selectedIndex]
            switch item {
            case .note(let note):
                let q = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.pendingSearchHighlight = q.isEmpty ? nil : q
                viewModel.selectedNoteId = note.id
                viewModel.searchText = ""
                // Ask the sidebar to scroll to and reveal this note —
                // otherwise opening an old note from the palette leaves
                // the sidebar scrolled to wherever it was before.
                NotificationCenter.default.post(
                    name: .revealNoteInSidebar,
                    object: note.id
                )
                dismiss()
            case .command(let cmd):
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    cmd.action()
                }
            }
        }
    }
    
    private func isNewSection(at index: Int, in items: [PaletteItem]) -> Bool {
        guard index > 0 else { return true }
        let prev = items[index - 1]
        let curr = items[index]
        switch (prev, curr) {
        case (.note(let p), .note(let c)):
            if !state.recentNoteIdSet.isEmpty {
                return state.recentNoteIdSet.contains(p.id) != state.recentNoteIdSet.contains(c.id)
            }
            // Ranked results interleave pinned and unpinned notes; splitting
            // them into sections would imply an ordering that isn't there.
            if !state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            return p.isPinned != c.isPinned
        case (.note, .command):
            return true
        case (.command, .note):
            return true
        case (.command, .command):
            return false
        }
    }
    
    private func sectionHeaderTitle(for item: PaletteItem) -> String {
        switch item {
        case .note(let note):
            if !state.recentNoteIdSet.isEmpty {
                return state.recentNoteIdSet.contains(note.id) ? "RECENT" : "NOTES"
            }
            if !state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "NOTES" }
            return note.isPinned ? "PINNED" : "NOTES"
        case .command:
            return "COMMANDS"
        }
    }
    
    private func setupKeyboardMonitor() {
        let isPres = Binding(
            get: { self.isPresented },
            set: { self.isPresented = $0 }
        )
        let paletteState = state

        keyboardMonitor.onKey = { [weak paletteState] event -> NSEvent? in
            guard let paletteState = paletteState else { return event }
            let isEsc = event.keyCode == 53
            let isUp = event.keyCode == 126
            let isDown = event.keyCode == 125
            
            if isEsc {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isPres.wrappedValue = false
                }
                NotificationCenter.default.post(name: .refocusEditor, object: nil)
                return nil
            }
            if isUp {
                let count = paletteState.results.count
                if count > 0 {
                    paletteState.selectionCameFromHover = false
                    paletteState.selectedIndex = (paletteState.selectedIndex - 1 + count) % count
                }
                return nil
            }
            if isDown {
                let count = paletteState.results.count
                if count > 0 {
                    paletteState.selectionCameFromHover = false
                    paletteState.selectedIndex = (paletteState.selectedIndex + 1) % count
                }
                return nil
            }
            return event
        }
    }
    
    /// `fuzzyFallback` marks the fuzzy-matched characters when no contiguous
    /// substring run exists (e.g. "sgs" → **S**hreya **G**ifting **S**trategy).
    /// Only titles/command names opt in — scattered per-character highlights
    /// read as noise in preview text.
    private func highlightedText(_ text: String, query: String, fuzzyFallback: Bool = false) -> AttributedString {
        var attr = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return attr }
        var didHighlight = false
        // Match against folded text (so "don't" finds "don't"), then map each
        // range back to the original via UTF-16 offsets — folding is 1:1, so
        // the offsets line up.
        let foldedText = text.searchFolded
        let foldedQuery = q.searchFolded
        var searchStart = foldedText.startIndex
        while let r = foldedText.range(of: foldedQuery, options: .caseInsensitive, range: searchStart..<foldedText.endIndex) {
            if let orig = Range(NSRange(r, in: foldedText), in: text),
               let lo = AttributedString.Index(orig.lowerBound, within: attr),
               let hi = AttributedString.Index(orig.upperBound, within: attr) {
                attr[lo..<hi].backgroundColor = theme.accent.opacity(0.3)
                attr[lo..<hi].foregroundColor = theme.text
                attr[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
                didHighlight = true
            }
            if r.upperBound >= foldedText.endIndex { break }
            searchStart = r.upperBound
        }
        if fuzzyFallback, !didHighlight, let match = FuzzySearch.match(q, in: text) {
            let charIndices = Array(text.indices)
            for offset in match.matchedOffsets where offset < charIndices.count {
                let lo = charIndices[offset]
                let hi = text.index(after: lo)
                if let alo = AttributedString.Index(lo, within: attr),
                   let ahi = AttributedString.Index(hi, within: attr) {
                    attr[alo..<ahi].backgroundColor = theme.accent.opacity(0.3)
                    attr[alo..<ahi].foregroundColor = theme.text
                    attr[alo..<ahi].inlinePresentationIntent = .stronglyEmphasized
                }
            }
        }
        return attr
    }

    private func formatDate(_ date: Date) -> String {
        AppDateFormatters.shortDateTime.string(from: date)
    }
}

class KeyboardMonitor: ObservableObject {
    var onKey: (NSEvent) -> NSEvent? = { $0 }
    private var monitor: Any? = nil
    
    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            return self?.onKey(event) ?? event
        }
    }
    
    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
