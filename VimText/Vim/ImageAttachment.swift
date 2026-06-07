import AppKit

/// Default cap for a freshly embedded image's on-screen width (points). Used
/// when no explicit width is stored; the user can resize from there.
private let defaultImageDisplayWidth: CGFloat = 560

/// An `NSTextAttachment` that remembers the relative asset path it came from
/// (e.g. `assets/UUID.png`) and its current display width, so the editor's
/// in-memory image can be serialized back to portable Markdown
/// (`![|width](assets/UUID.png)`) on save and round-trip at a stable size.
final class ImageTextAttachment: NSTextAttachment {
    let assetRelativePath: String
    let nativeSize: NSSize

    init(image: NSImage, assetRelativePath: String, displayWidth: CGFloat?) {
        self.assetRelativePath = assetRelativePath
        self.nativeSize = image.size
        super.init(data: nil, ofType: nil)
        self.image = image
        let width = displayWidth ?? min(image.size.width, defaultImageDisplayWidth)
        setDisplayWidth(width)
        attachmentCell = ResizableImageAttachmentCell(imageCell: image)
    }

    required init?(coder: NSCoder) {
        self.assetRelativePath = coder.decodeObject(forKey: "assetRelativePath") as? String ?? ""
        self.nativeSize = .zero
        super.init(coder: coder)
        if let image { attachmentCell = ResizableImageAttachmentCell(imageCell: image) }
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(assetRelativePath, forKey: "assetRelativePath")
    }

    /// Resizes the attachment to `width` points, preserving aspect ratio.
    func setDisplayWidth(_ width: CGFloat) {
        guard nativeSize.width > 0, nativeSize.height > 0 else {
            bounds = CGRect(x: 0, y: 0, width: max(48, width), height: max(48, width))
            return
        }
        let w = max(48, width)
        let h = (nativeSize.height / nativeSize.width) * w
        bounds = CGRect(x: 0, y: 0, width: w.rounded(), height: h.rounded())
    }
}

/// On-screen size of the square resize handle drawn at an image's bottom-right
/// corner. The text view uses the same value for hit-testing the drag.
let imageResizeHandleSize: CGFloat = 18

/// Draws the image plus a bottom-right resize handle. The actual drag is driven
/// by `VimNSTextView.mouseDown` (more reliable than cell mouse-tracking inside a
/// customized text view), so this cell only handles sizing + drawing.
final class ResizableImageAttachmentCell: NSTextAttachmentCell {
    private var imageAttachment: ImageTextAttachment? { attachment as? ImageTextAttachment }

    override func cellSize() -> NSSize {
        imageAttachment?.bounds.size ?? super.cellSize()
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: 0)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        image?.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1.0)
        // The selection box + handles are drawn by VimNSTextView (on top, not
        // clipped to the cell) when this image is selected.
    }
}

/// Converts between the editor's attributed string (which holds live
/// `ImageTextAttachment`s) and the portable Markdown stored on disk.
enum ImageAttachments {
    /// Serializes `attr` to a plain string, replacing each image attachment
    /// with its `![|width](path)` Markdown. This is what gets written to `.txt`.
    static func markdownString(from attr: NSAttributedString) -> String {
        let full = NSRange(location: 0, length: attr.length)
        let nsString = attr.string as NSString
        let out = NSMutableString()
        attr.enumerateAttribute(.attachment, in: full, options: []) { value, range, _ in
            if let image = value as? ImageTextAttachment {
                out.append(ImageMarkdown.reference(for: image.assetRelativePath, width: image.bounds.width))
            } else {
                out.append(nsString.substring(with: range))
            }
        }
        return out as String
    }

    /// A copy of `attr` with image attachments replaced by their Markdown text,
    /// so it can be serialized to RTF (which can't hold our attachments).
    static func flattened(_ attr: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attr)
        let full = NSRange(location: 0, length: attr.length)
        var replacements: [(NSRange, String)] = []
        attr.enumerateAttribute(.attachment, in: full, options: []) { value, range, _ in
            if let image = value as? ImageTextAttachment {
                replacements.append((range, ImageMarkdown.reference(for: image.assetRelativePath, width: image.bounds.width)))
            }
        }
        for (range, text) in replacements.reversed() {
            var attrs = mutable.attributes(at: range.location, effectiveRange: nil)
            attrs[.attachment] = nil
            mutable.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attrs))
        }
        return mutable
    }
}
