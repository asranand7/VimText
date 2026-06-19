import SwiftUI

struct NoteRowView: View {
    let note: Note
    /// Precomputed preview text (cached by the view model). When nil it's
    /// derived from `note` — the multi-select rows pass nil; the main list
    /// passes the cache to avoid re-deriving it for every row each render.
    var preview: String? = nil
    var isHovered: Bool = false
    var isSelected: Bool = false
    var onCopyPath: (() -> Void)? = nil
    var onTogglePin: (() -> Void)? = nil
    var onToggleLock: (() -> Void)? = nil
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

    private var lockStatusGlyph: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 10))
            .foregroundStyle(theme.secondaryText.opacity(0.75))
            .help("Locked — read-only, can't be deleted")
    }

    /// One consistent style for every hover action on a row: 20pt circle,
    /// 11pt icon. Keeping them identical makes the row scannable — the lock
    /// indicator no longer looks like a differently-drawn odd one out.
    private func hoverIconButton(
        icon: String,
        tint: Color,
        background: Color? = nil,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(background ?? theme.text.opacity(0.06)))
        }
        .buttonStyle(PressableIconButtonStyle(pressedScale: 0.94))
        .help(help)
        .transition(.opacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.displayTitle)
                    .font(.system(size: 14.5, weight: .semibold, design: .default))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)

                Spacer(minLength: 4)

                // Resting state shows compact status glyphs (lock/pin); on
                // hover they become actionable buttons with one consistent
                // 20pt circular style, ordered: lock · pin · copy · delete.
                if isHovered {
                    if let onToggleLock {
                        hoverIconButton(
                            icon: note.isLocked ? "lock.fill" : "lock.open",
                            tint: note.isLocked ? theme.accent : theme.secondaryText,
                            help: note.isLocked
                                ? "Unlock note (allow editing and deletion)"
                                : "Lock note (prevent editing and deletion)",
                            action: onToggleLock
                        )
                    } else if note.isLocked {
                        lockStatusGlyph
                    }

                    if let onTogglePin {
                        hoverIconButton(
                            icon: note.isPinned ? "pin.slash" : "pin",
                            tint: note.isPinned ? theme.accent : theme.secondaryText,
                            help: note.isPinned ? "Unpin note" : "Pin note",
                            action: onTogglePin
                        )
                    }

                    if let onCopyPath {
                        hoverIconButton(
                            icon: didCopy ? "checkmark" : "doc.on.doc",
                            tint: didCopy ? theme.accent : theme.secondaryText,
                            help: "Copy note file path"
                        ) {
                            onCopyPath()
                            didCopy = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                didCopy = false
                            }
                        }
                    }

                    if let onDelete {
                        if note.isLocked {
                            hoverIconButton(
                                icon: "trash.slash",
                                tint: theme.secondaryText.opacity(0.55),
                                help: "Locked — unlock to delete",
                                action: {}
                            )
                        } else {
                            hoverIconButton(
                                icon: "trash",
                                tint: Color.red.opacity(0.85),
                                background: Color.red.opacity(0.08),
                                help: "Delete note",
                                action: onDelete
                            )
                        }
                    }
                } else {
                    if note.isLocked { lockStatusGlyph }
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.accent)
                    }
                }
            }

            // Date leads the preview line (like Apple Notes) — right-aligned
            // dates of varying width made the rows' right edge ragged.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formattedDate)
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(theme.secondaryText.opacity(isSelected ? 0.9 : 0.72))
                    .fixedSize()

                Text((preview ?? note.preview).isEmpty ? "No additional text" : (preview ?? note.preview))
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
