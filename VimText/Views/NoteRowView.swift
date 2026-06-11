import SwiftUI

struct NoteRowView: View {
    let note: Note
    var isHovered: Bool = false
    var isSelected: Bool = false
    var onCopyPath: (() -> Void)? = nil
    var onTogglePin: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var didCopy = false

    private var theme: AppTheme { themeManager.theme }

    private var formattedDate: String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(note.modifiedAt) {
            return AppDateFormatters.timeOnly.string(from: note.modifiedAt)
        } else if calendar.isDateInYesterday(note.modifiedAt) {
            return "Yesterday"
        } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                  note.modifiedAt > weekAgo {
            return AppDateFormatters.weekday.string(from: note.modifiedAt)
        } else {
            return AppDateFormatters.shortDate.string(from: note.modifiedAt)
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

                if let onTogglePin, isHovered {
                    Button(action: onTogglePin) {
                        Image(systemName: note.isPinned ? "pin.slash" : "pin")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(note.isPinned ? theme.accent : theme.secondaryText)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(theme.text.opacity(0.06)))
                    }
                    .buttonStyle(PressableIconButtonStyle(pressedScale: 0.94))
                    .help(note.isPinned ? "Unpin note" : "Pin note")
                    .transition(.opacity)
                } else if note.isPinned {
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

                if let onDelete, isHovered {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.red.opacity(0.85))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.red.opacity(0.08)))
                    }
                    .buttonStyle(PressableIconButtonStyle(pressedScale: 0.94))
                    .help("Delete note")
                    .transition(.opacity)
                }
            }

            // Date leads the preview line (like Apple Notes) — right-aligned
            // dates of varying width made the rows' right edge ragged.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formattedDate)
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(theme.secondaryText.opacity(isSelected ? 0.9 : 0.72))
                    .fixedSize()

                Text(note.preview.isEmpty ? "No additional text" : note.preview)
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(theme.secondaryText.opacity(isSelected ? 0.82 : 0.62))
                    .lineLimit(2)
                    .frame(minHeight: 16, alignment: .topLeading)
            }
        }
        .padding(.vertical, 9)
        .animation(DS.snappy, value: isHovered)
        .animation(DS.snappy, value: isSelected)
    }
}
