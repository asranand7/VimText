import SwiftUI
import AppKit

struct PaletteCommand: Identifiable {
    let id: String
    let name: String
    let icon: String
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
    
    func getCommands(themeManager: ThemeManager, viewModel: NotesViewModel, dismiss: @escaping () -> Void) -> [PaletteCommand] {
        return [
            PaletteCommand(id: "new_note", name: "Create New Note", icon: "square.and.pencil") {
                Task { @MainActor in
                    viewModel.createNote()
                }
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
            }
        ]
    }
    
    func filteredItems(from notes: [Note], themeManager: ThemeManager, viewModel: NotesViewModel, dismiss: @escaping () -> Void) -> [PaletteItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [PaletteItem] = []
        
        let filteredNotes = notes.filter { note in
            query.isEmpty || 
            note.title.localizedCaseInsensitiveContains(query) ||
            note.content.localizedCaseInsensitiveContains(query)
        }
        
        // Pinned notes first
        let pinnedNotes = filteredNotes.filter { $0.isPinned }
        for note in pinnedNotes {
            items.append(.note(note))
        }
        
        // Unpinned notes next
        let unpinnedNotes = filteredNotes.filter { !$0.isPinned }
        for note in unpinnedNotes {
            items.append(.note(note))
        }
        
        // Commands
        let allCommands = getCommands(themeManager: themeManager, viewModel: viewModel, dismiss: dismiss)
        let filteredCommands = allCommands.filter { cmd in
            query.isEmpty || cmd.name.localizedCaseInsensitiveContains(query)
        }
        for cmd in filteredCommands {
            items.append(.command(cmd))
        }
        
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
        state.filteredItems(from: viewModel.notes, themeManager: themeManager, viewModel: viewModel, dismiss: { dismiss() })
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
        .onAppear {
            isFieldFocused = true
            startWidth = width
            startHeight = height
            setupKeyboardMonitor()
        }
        .onChange(of: state.searchText) {
            state.selectedIndex = 0
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
                Text(note.displayTitle)
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
            
            Text(note.preview.isEmpty ? "No additional text" : note.preview)
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
            
            Text(cmd.name)
                .font(.system(.body, design: .default).weight(.medium))
                .foregroundStyle(theme.text)
            
            Spacer()
            
            Text("Action")
                .font(.caption2)
                .foregroundStyle(theme.secondaryText.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.05), in: Capsule())
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
        .onTapGesture {
            state.selectedIndex = index
            selectCurrentItem()
        }
    }
    
    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isPresented = false
        }
    }
    
    private func selectCurrentItem() {
        guard !items.isEmpty else { return }
        if state.selectedIndex >= 0 && state.selectedIndex < items.count {
            let item = items[state.selectedIndex]
            switch item {
            case .note(let note):
                viewModel.selectedNoteId = note.id
                viewModel.searchText = ""
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
        let vm = viewModel
        let tMgr = themeManager
        
        keyboardMonitor.onKey = { [weak paletteState] event -> NSEvent? in
            guard let paletteState = paletteState else { return event }
            let isEsc = event.keyCode == 53
            let isUp = event.keyCode == 126
            let isDown = event.keyCode == 125
            
            if isEsc {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isPres.wrappedValue = false
                }
                return nil
            }
            if isUp {
                let items = paletteState.filteredItems(from: vm.notes, themeManager: tMgr, viewModel: vm, dismiss: {})
                let count = items.count
                if count > 0 {
                    paletteState.selectedIndex = (paletteState.selectedIndex - 1 + count) % count
                }
                return nil
            }
            if isDown {
                let items = paletteState.filteredItems(from: vm.notes, themeManager: tMgr, viewModel: vm, dismiss: {})
                let count = items.count
                if count > 0 {
                    paletteState.selectedIndex = (paletteState.selectedIndex + 1) % count
                }
                return nil
            }
            return event
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
