import SwiftUI

struct NoteRowView: View {
    let note: Note
    var folderName: String = "Notes"
    @EnvironmentObject private var themeManager: ThemeManager

    private var theme: AppTheme { themeManager.theme }

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
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(note.displayTitle)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Spacer()
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.accent)
                }
            }

            HStack(spacing: 6) {
                Text(formattedDate)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)

                Text(note.preview)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText.opacity(0.65))
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(folderName)
                    .font(.caption2)
            }
            .foregroundStyle(theme.secondaryText.opacity(0.75))
            .padding(.top, 1)
        }
        .padding(.vertical, 6)
    }
}
