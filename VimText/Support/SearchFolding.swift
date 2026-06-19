import Foundation

/// Folds typographic punctuation to its ASCII form so a search typed with a
/// straight quote finds text written with macOS smart-quote substitution
/// ("don't" must find "don't"). Every folded scalar is one UTF-16 unit
/// replaced by one UTF-16 unit, so NSRanges found in the folded string are
/// valid in the original — the find/highlight paths depend on this.
public extension String {
    var searchFolded: String {
        // Fast path: most strings carry no typographic punctuation, so don't
        // allocate a copy unless something actually needs folding.
        guard unicodeScalars.contains(where: { Self.foldedScalar($0) != $0 }) else { return self }
        var view = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            view.append(Self.foldedScalar(scalar))
        }
        return String(view)
    }

    /// Folded **and** lowercased, for case-insensitive membership scans. Pre-
    /// normalizing both haystack and query this way lets the filter use a plain
    /// literal `range(of:)` instead of the much slower `.caseInsensitive`
    /// option, whose worst case (no match → full scan of every note) dominated
    /// sidebar/⌘K search at scale. Not 1:1 in UTF-16, so it must NOT be used
    /// where folded ranges are mapped back to the original string (highlighting).
    var searchNormalized: String {
        searchFolded.lowercased()
    }

    private static func foldedScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar {
        case "\u{2018}", "\u{2019}", "\u{02BC}": return "'"   // ‘ ’ ʼ
        case "\u{201C}", "\u{201D}": return "\""              // “ ”
        case "\u{2013}", "\u{2014}": return "-"               // – —
        default: return scalar
        }
    }
}
