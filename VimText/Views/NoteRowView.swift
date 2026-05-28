import SwiftUI

struct NoteRowView: View {
    let note: Note
    var folderName: String = "Notes"
    var isHovered: Bool = false
    var isSelected: Bool = false
    var onCopyPath: (() -> Void)? = nil
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var didCopy = false

    private var theme: AppTheme { themeManager.theme }
    private var tint: Color { themeManager.sidebarTint }

    private var formattedDate: String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(note.modifiedAt) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: note.modifiedAt)
        } else if calendar.isDateInYesterday(note.modifiedAt) {
            return "Yesterday"
        } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                  note.modifiedAt > weekAgo {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: note.modifiedAt)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d/yy"
            return formatter.string(from: note.modifiedAt)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.displayTitle)
                    .font(.system(size: 14.5, weight: .semibold, design: .default))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(formattedDate)
                    .font(.system(size: 10.5, weight: .medium, design: .default))
                    .foregroundStyle(theme.secondaryText.opacity(isSelected ? 0.86 : 0.66))
                    .fixedSize()

                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.accent)
                }

                if let onCopyPath, isHovered || didCopy {
                    Button {
                        onCopyPath()
                        didCopy = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            didCopy = false
                        }
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(didCopy ? theme.accent : theme.secondaryText)
                            .frame(width: 18, height: 18)
                            .background(
                                Circle().fill(theme.text.opacity(didCopy ? 0 : 0.06))
                            )
                    }
                    .buttonStyle(PressableIconButtonStyle(pressedScale: 0.94))
                    .help("Copy note file path")
                    .transition(.opacity)
                }
            }

            Text(note.preview.isEmpty ? "No additional text" : note.preview)
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(theme.secondaryText.opacity(isSelected ? 0.82 : 0.62))
                .lineLimit(2)
                .frame(minHeight: 16, alignment: .topLeading)

            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                Text(folderName)
                    .font(.system(size: 10.5, weight: .medium, design: .default))
            }
            .foregroundStyle(isSelected ? tint.opacity(theme.isDark ? 0.58 : 0.46) : theme.secondaryText.opacity(0.46))
            .padding(.top, 2)
        }
        .padding(.vertical, 9)
        .animation(DS.snappy, value: isHovered)
        .animation(DS.snappy, value: isSelected)
    }
}
