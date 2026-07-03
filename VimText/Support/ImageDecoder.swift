import AppKit
import ImageIO

/// Decodes note images at their on-screen size instead of full resolution.
/// A 5MP screenshot displayed at 560pt was previously decoded in full on the
/// main thread at note-open and rescaled from the full bitmap on every repaint;
/// downsampling once via ImageIO keeps draws cheap and memory proportional to
/// what's actually shown. Metadata probes read only the header, so attachment
/// bounds can be laid out before any pixel decoding happens.
enum ImageDecoder {
    /// Where an image's bytes come from: a saved asset file or an in-memory
    /// buffer (paste path, before/while the asset lands on disk).
    enum Source {
        case url(URL)
        case data(Data)

        fileprivate func makeImageSource() -> CGImageSource? {
            // Don't let ImageIO cache full-size decodes we'll never draw.
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            switch self {
            case .url(let url): return CGImageSourceCreateWithURL(url as CFURL, options)
            case .data(let data): return CGImageSourceCreateWithData(data as CFData, options)
            }
        }
    }

    /// Header-only facts about an image: its pixel dimensions (orientation
    /// applied) and its point size (pixels scaled by the file's DPI, matching
    /// what `NSImage.size` reports for the same file).
    struct Probe {
        let pixelSize: NSSize
        let pointSize: NSSize
    }

    /// A decoded, display-sized bitmap plus the pixel width it was decoded at,
    /// so callers can tell when an upsized image needs a fresh decode.
    struct Decoded {
        let image: NSImage
        let pixelWidth: CGFloat
    }

    /// Reads dimensions from the image header without decoding pixels.
    static func probe(_ source: Source) -> Probe? {
        guard let imageSource = source.makeImageSource(),
              let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              var pixelW = (props[kCGImagePropertyPixelWidth] as? NSNumber).map({ CGFloat(truncating: $0) }),
              var pixelH = (props[kCGImagePropertyPixelHeight] as? NSNumber).map({ CGFloat(truncating: $0) }),
              pixelW > 0, pixelH > 0 else { return nil }

        // EXIF orientations 5-8 are rotated 90°: width and height swap on screen.
        if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
           orientation >= 5, orientation <= 8 {
            swap(&pixelW, &pixelH)
        }

        let dpiW = (props[kCGImagePropertyDPIWidth] as? NSNumber).map { CGFloat(truncating: $0) } ?? 72
        let dpiH = (props[kCGImagePropertyDPIHeight] as? NSNumber).map { CGFloat(truncating: $0) } ?? 72
        let pointSize = NSSize(
            width: pixelW * 72 / max(dpiW, 1),
            height: pixelH * 72 / max(dpiH, 1)
        )
        return Probe(pixelSize: NSSize(width: pixelW, height: pixelH), pointSize: pointSize)
    }

    /// Decodes the image scaled so its width is ~`targetPointWidth × scale`
    /// pixels (never upscaled past native). Thread-safe; call off-main for
    /// large images.
    static func downsampledImage(from source: Source, targetPointWidth: CGFloat, scale: CGFloat) -> Decoded? {
        guard let probe = probe(source), let imageSource = source.makeImageSource() else { return nil }

        let targetPixelWidth = min(max(48, targetPointWidth) * max(scale, 1), probe.pixelSize.width)
        // kCGImageSourceThumbnailMaxPixelSize caps the LARGER dimension, so a
        // portrait image needs the cap scaled up by its aspect ratio for the
        // width to come out at the target.
        let aspect = probe.pixelSize.height / probe.pixelSize.width
        let maxPixel = (targetPixelWidth * max(aspect, 1)).rounded(.up)

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // bake in EXIF rotation
            kCGImageSourceShouldCacheImmediately: true,       // decode now, not at first draw
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) else { return nil }

        let pixelWidth = CGFloat(cgImage.width)
        // Point size mirrors the native point-per-pixel ratio so the NSImage
        // reports a size consistent with the full-resolution original.
        let pointsPerPixel = probe.pointSize.width / probe.pixelSize.width
        let size = NSSize(width: pixelWidth * pointsPerPixel,
                          height: CGFloat(cgImage.height) * pointsPerPixel)
        return Decoded(image: NSImage(cgImage: cgImage, size: size), pixelWidth: pixelWidth)
    }
}
