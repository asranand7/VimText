import SwiftUI
import AppKit

class CommandPaletteState: ObservableObject {
    @Published var searchText = ""
    @Published var selectedIndex = 0
    
    func filteredNotes(from notes: [Note]) -> [Note] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return notes
        }
        return notes.filter { note in
            note.title.localizedCaseInsensitiveContains(query) ||
            note.content.localizedCaseInsensitiveContains(query)
        }
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
    
    private var notes: [Note] {
        state.filteredNotes(from: viewModel.notes)
    }
    
    private var searchFieldRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(theme.secondaryText.opacity(0.8))
            
            TextField("Search notes by title or content…", text: $state.searchText)
                .textFieldStyle(.plain)
                .font(.system(.title3, design: .rounded))
                .focused($isFieldFocused)
                .foregroundStyle(theme.text)
                .onSubmit {
                    selectCurrentNote()
                }
            
            if !state.searchText.isEmpty {
                Button(action: { state.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.secondaryText.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            
            Text("ESC")
                .font(.system(size: 10, weight: .bold, design: .rounded))
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
            if notes.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "note.text")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(theme.secondaryText.opacity(0.4))
                    Text("No notes found")
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                           ForEach(Array(notes.enumerated()), id: \.element.id) { idx, note in
                               paletteRow(note: note, index: idx, isSelected: state.selectedIndex == idx)
                                   .id(note.id)
                           }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: .infinity)
                    .onChange(of: state.selectedIndex) { _, newIndex in
                        if newIndex >= 0 && newIndex < notes.count {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(notes[newIndex].id, anchor: .center)
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
                Text("Open")
            }
            Spacer()
            Text("\(notes.count) notes")
            
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
        .font(.system(size: 11, design: .rounded))
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
    private func paletteRow(note: Note, index: Int, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(note.displayTitle)
                    .font(.system(.body, design: .rounded).weight(.semibold))
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
            selectCurrentNote()
        }
    }
    
    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isPresented = false
        }
    }
    
    private func selectCurrentNote() {
        guard !notes.isEmpty else { return }
        if state.selectedIndex >= 0 && state.selectedIndex < notes.count {
            viewModel.selectedNoteId = notes[state.selectedIndex].id
            viewModel.searchText = ""
        }
        dismiss()
    }
    
    private func setupKeyboardMonitor() {
        let isPres = Binding(
            get: { self.isPresented },
            set: { self.isPresented = $0 }
        )
        let paletteState = state
        let vm = viewModel
        
        keyboardMonitor.onKey = { [weak paletteState] event in
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
                let notes = paletteState.filteredNotes(from: vm.notes)
                let count = notes.count
                if count > 0 {
                    paletteState.selectedIndex = (paletteState.selectedIndex - 1 + count) % count
                }
                return nil
            }
            if isDown {
                let notes = paletteState.filteredNotes(from: vm.notes)
                let count = notes.count
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
