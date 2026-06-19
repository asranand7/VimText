// Headless scale benchmark for VimText. Seeds N notes into a temp dir, points
// the real StorageManager at it, and times the actual hot paths (no UI, no
// computer-use). Run: swift run -c release VimTextBench [count]
//
// It exercises the same functions the app uses at launch and while typing in
// the sidebar search / ⌘K: readNotesSnapshot, buildIndexes, computeFilteredNotes,
// loadRTFData, and LinkDetection.links.
import AppKit
import Foundation
@testable import VimTextCore

// MARK: - Timing helpers

/// Median wall-clock seconds over `iterations` runs (median is steadier than
/// mean under GC/scheduler jitter). Returns (median, min).
func bench(_ name: String, iterations: Int = 5, _ body: () -> Void) -> (median: Double, min: Double) {
    var samples: [Double] = []
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        let end = DispatchTime.now().uptimeNanoseconds
        samples.append(Double(end - start) / 1_000_000_000)
    }
    samples.sort()
    let median = samples[samples.count / 2]
    return (median, samples.first!)
}

func ms(_ s: Double) -> String { String(format: "%7.2f ms", s * 1000) }

// MARK: - Synthetic corpus

let words = ("vim motion buffer register macro yank delete normal insert visual command "
    + "line cursor search replace fold mark jump undo redo paste indent textobject "
    + "paragraph sentence word column block escape colon swift appkit textkit nstextview "
    + "storage perf latency render layout https example com note tag todo done")
    .split(separator: " ").map(String.init)

func paragraph(_ rng: inout SplitMix64, _ n: Int) -> String {
    var out: [String] = []
    for _ in 0..<n { out.append(words[Int(rng.next() % UInt64(words.count))]) }
    // Sprinkle a real URL roughly every other paragraph so link detection has
    // something to find (mirrors how notes actually contain links).
    if rng.next() % 2 == 0 { out.insert("https://example.com/path/\(rng.next() % 9999)", at: out.count / 2) }
    return out.joined(separator: " ") + "."
}

func makeBody(_ rng: inout SplitMix64, index: Int) -> (title: String, content: String) {
    let r = rng.next() % 100
    let paras: Int = r < 1 ? 400 + Int(rng.next() % 800)   // ~1% huge
                  : r < 6 ? 40 + Int(rng.next() % 80)       // ~5% large
                          : 2 + Int(rng.next() % 10)        // rest small
    var blocks = ["# Scale note \(String(format: "%05d", index))", ""]
    for _ in 0..<paras { blocks.append(paragraph(&rng, 15 + Int(rng.next() % 45))); blocks.append("") }
    return ("Scale note \(String(format: "%05d", index))", blocks.joined(separator: "\n"))
}

/// Deterministic RNG so runs are comparable across builds.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - RTF sidecars

/// Styled-text RTF for a note's body — the common case (note opened/edited in
/// rich mode, no images). Size tracks the text, like the app's own sidecars.
func plainRTF(_ content: String) -> Data {
    let attr = NSMutableAttributedString(string: content, attributes: [
        .font: NSFont.systemFont(ofSize: 14)
    ])
    // A little inline styling so it isn't a degenerate all-one-run string.
    let n = attr.length
    if n > 40 {
        attr.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: 20))
    }
    return attr.rtf(from: NSRange(location: 0, length: attr.length), documentAttributes: [:]) ?? Data()
}

/// A noisy raster image built with CoreGraphics (works headlessly — no window
/// server / `lockFocus`). Noise keeps it from compressing to nothing.
func makeImage(side: Int, seed: UInt64) -> NSImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: side * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var rng = SplitMix64(state: seed)
    for x in stride(from: 0, to: side, by: 4) {
        for y in stride(from: 0, to: side, by: 4) {
            let r = Double(rng.next() % 255) / 255, g = Double(rng.next() % 255) / 255
            ctx.setFillColor(red: r, green: g, blue: 0.6, alpha: 1)
            ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
        }
    }
    let cg = ctx.makeImage()!
    return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
}

/// RTF with `count` embedded raster images — the heavy case (multi-hundred-KB
/// to multi-MB sidecars). Mirrors notes with pasted screenshots.
func imageRTF(_ content: String, images count: Int, side: Int) -> Data {
    let attr = NSMutableAttributedString(string: content, attributes: [.font: NSFont.systemFont(ofSize: 14)])
    for k in 0..<count {
        let att = NSTextAttachment()
        att.image = makeImage(side: side, seed: UInt64(side) &* 2654435761 &+ UInt64(k))
        attr.append(NSAttributedString(attachment: att))
    }
    return attr.rtf(from: NSRange(location: 0, length: attr.length), documentAttributes: [:]) ?? Data()
}

// MARK: - Main

@MainActor
func run() {
    let count = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 2000 : 2000

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("VimTextBench-\(UUID().uuidString)", isDirectory: true)
    let notesDir = tmp.appendingPathComponent("notes", isDirectory: true)
    try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // --- Seed on disk (json + txt sidecars), the exact format the app reads ---
    var rng = SplitMix64(state: 0xDEADBEEF)
    let iso = ISO8601DateFormatter()
    let base = Date().addingTimeInterval(-Double(count) * 60)
    var totalBytes = 0
    var rtfBytes = 0
    var rtfCount = 0
    // Indices of notes that ended up with an RTF sidecar, so the open-cost
    // measurements hit real reads (plain-text RTF) and the heaviest image RTF.
    var plainRTFIndex: Int? = nil
    var heavyRTFIndex: (idx: Int, bytes: Int)? = nil
    for i in 0..<count {
        let (title, content) = makeBody(&rng, index: i)
        totalBytes += content.utf8.count
        let id = UUID().uuidString
        let date = iso.string(from: base.addingTimeInterval(Double(i) * 60))
        let stem = notesDir.appendingPathComponent(String(format: "scale-%05d", i))

        // Distribution mirrors a real library: most notes have been opened in
        // rich mode (plain styled RTF), a few carry pasted images (heavy RTF),
        // and the rest were never edited richly (no sidecar, rtfInSync:false).
        let roll = rng.next() % 100
        var rtf: Data? = nil
        if roll < 5 {                                   // ~5% image-heavy
            rtf = imageRTF(content, images: 1 + Int(rng.next() % 3), side: 480 + Int(rng.next() % 400))
        } else if roll < 75 {                           // ~70% plain styled RTF
            rtf = plainRTF(content)
        }                                               // ~25% no sidecar
        let inSync = rtf != nil
        if let rtf {
            try? rtf.write(to: stem.appendingPathExtension("rtf"))
            rtfBytes += rtf.count
            rtfCount += 1
            if roll < 5 {
                if heavyRTFIndex == nil || rtf.count > heavyRTFIndex!.bytes { heavyRTFIndex = (i, rtf.count) }
            } else if plainRTFIndex == nil {
                plainRTFIndex = i
            }
        }

        let json = """
        {"createdAt":"\(date)","id":"\(id)","isLocked":false,"isPinned":false,"modifiedAt":"\(date)","rtfInSync":\(inSync),"title":"\(title)"}
        """
        try? json.write(to: stem.appendingPathExtension("json"), atomically: false, encoding: .utf8)
        try? content.write(to: stem.appendingPathExtension("txt"), atomically: false, encoding: .utf8)
    }

    let storage = StorageManager.shared
    let originalPath = storage.customDirectoryPath
    storage.customDirectoryPath = tmp.path
    defer { storage.customDirectoryPath = originalPath }

    print("VimText scale benchmark")
    print(String(repeating: "=", count: 52))
    print("notes:        \(count)")
    print(String(format: "corpus:       %.1f MB of text", Double(totalBytes) / 1_048_576))
    print(String(format: "rtf sidecars: %d (%.0f%%), %.1f MB on disk",
                 rtfCount, 100 * Double(rtfCount) / Double(max(count, 1)), Double(rtfBytes) / 1_048_576))
    print("")

    // Load once to populate urlsByID (needed for loadRTFData) and to grab notes
    // for the in-memory benchmarks.
    let notes = storage.loadNotes()
    print("Operation                            median       best")
    print(String(repeating: "-", count: 52))

    // 1. Cold load from disk WITHOUT rtf (what the app does at launch).
    let load = bench("load") { _ = storage.readNotesSnapshot(loadRTF: false) }
    print("readNotesSnapshot(loadRTF:false)  \(ms(load.median))  \(ms(load.min))")

    // 2. Cold load WITH rtf (worst case / legacy path).
    let loadRTF = bench("loadRTF", iterations: 3) { _ = storage.readNotesSnapshot(loadRTF: true) }
    print("readNotesSnapshot(loadRTF:true)   \(ms(loadRTF.median))  \(ms(loadRTF.min))")

    // 3. Build the three sidebar/search caches (runs off-main at launch).
    let index = bench("index") { _ = NotesViewModel.buildIndexes(notes) }
    print("buildIndexes (haystack/preview)   \(ms(index.median))  \(ms(index.min))")

    // 4. ⌘K / sidebar filter — uncached (cold) and cached (warm), the per-
    //    keystroke cost. "swift" matches many notes; "zzqq" matches none.
    let warm = NotesViewModel.buildIndexes(notes).haystack
    let filterCold = bench("filterCold") {
        _ = NotesViewModel.computeFilteredNotes(notes: notes, showAllNotes: true,
            selectedFolderId: nil, searchText: "swift")
    }
    print("filter cold (no index) 'swift'    \(ms(filterCold.median))  \(ms(filterCold.min))")
    let filterWarm = bench("filterWarm") {
        _ = NotesViewModel.computeFilteredNotes(notes: notes, showAllNotes: true,
            selectedFolderId: nil, searchText: "swift", searchIndex: warm)
    }
    print("filter warm (cached)   'swift'    \(ms(filterWarm.median))  \(ms(filterWarm.min))")
    let filterMiss = bench("filterMiss") {
        _ = NotesViewModel.computeFilteredNotes(notes: notes, showAllNotes: true,
            selectedFolderId: nil, searchText: "zzqq", searchIndex: warm)
    }
    print("filter warm (no match) 'zzqq'     \(ms(filterMiss.median))  \(ms(filterMiss.min))")

    // 5. Open one note: lazy RTF hydrate (one file read). Measured on a note
    //    with a plain-text RTF sidecar, on the heaviest image RTF, and on a
    //    note with no sidecar (the miss path) — the three real open costs.
    func note(titledIndex i: Int) -> Note? {
        let t = "Scale note \(String(format: "%05d", i))"
        return notes.first { $0.title == t }
    }
    if let i = plainRTFIndex, let n = note(titledIndex: i) {
        let h = bench("hydratePlain", iterations: 50) { _ = storage.loadRTFData(for: n.id) }
        print("loadRTFData (plain rtf note)      \(ms(h.median))  \(ms(h.min))")
    }
    if let heavy = heavyRTFIndex, let n = note(titledIndex: heavy.idx) {
        let h = bench("hydrateHeavy", iterations: 20) { _ = storage.loadRTFData(for: n.id) }
        print(String(format: "loadRTFData (image rtf, %.0f KB)   ", Double(heavy.bytes) / 1024) + "\(ms(h.median))  \(ms(h.min))")
    }
    // A note with no sidecar resolves to the miss path (no file read).
    let missID = notes.first { storage.loadRTFData(for: $0.id) == nil }?.id ?? notes[0].id
    let miss = bench("hydrateMiss", iterations: 50) { _ = storage.loadRTFData(for: missID) }
    print("loadRTFData (no sidecar, miss)    \(ms(miss.median))  \(ms(miss.min))")

    // 6. Parse RTF bytes into NSAttributedString — the real per-note-open cost
    //    (loadRTFData only reads bytes; the editor must then parse them).
    if let i = plainRTFIndex, let n = note(titledIndex: i), let d = storage.loadRTFData(for: n.id) {
        let p = bench("parsePlain", iterations: 20) { _ = try? NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
        print("parse RTF→attr (plain note)       \(ms(p.median))  \(ms(p.min))")
    }
    if let heavy = heavyRTFIndex, let n = note(titledIndex: heavy.idx), let d = storage.loadRTFData(for: n.id) {
        let p = bench("parseHeavy", iterations: 10) { _ = try? NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
        print(String(format: "parse RTF→attr (image, %.0f KB)    ", Double(heavy.bytes) / 1024) + "\(ms(p.median))  \(ms(p.min))")
    }

    // 6b. Faithful note-open: parse + setAttributedString into a live TextKit
    //     stack and force layout — exactly what VimTextView does on open
    //     (NSAttributedString(rtf:) then textStorage.setAttributedString). This
    //     captures the layout cost the bare parse above omits. Measured on the
    //     largest plain note (line count drives layout) and the heaviest image.
    func openCost(_ data: Data) -> () -> Void {
        return {
            guard let attr = try? NSAttributedString(data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else { return }
            let storage = NSTextStorage()
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            storage.setAttributedString(attr)
            layout.ensureLayout(for: container)   // force glyph + fragment layout
        }
    }
    let bigPlain = notes.filter { storage.loadRTFData(for: $0.id) != nil }
        .max { $0.content.count < $1.content.count }
    if let n = bigPlain, let d = storage.loadRTFData(for: n.id) {
        let lines = n.content.split(separator: "\n").count
        let o = bench("openBig", iterations: 10, openCost(d))
        print("open note: parse+layout (\(lines) lines)\(ms(o.median))  \(ms(o.min))")
    }
    if let heavy = heavyRTFIndex, let n = note(titledIndex: heavy.idx), let d = storage.loadRTFData(for: n.id) {
        let o = bench("openHeavy", iterations: 10, openCost(d))
        print(String(format: "open note: parse+layout (img %.0f KB)", Double(heavy.bytes) / 1024) + "\(ms(o.median))  \(ms(o.min))")
    }

    // 6. Link detection on the largest note (runs when a note is displayed).
    let biggest = notes.max { $0.content.count < $1.content.count }!
    let bigLines = biggest.content.split(separator: "\n").count
    let link = bench("link", iterations: 20) { _ = LinkDetection.links(in: biggest.content) }
    print("LinkDetection (largest, \(bigLines) lines)\(ms(link.median))  \(ms(link.min))")

    print(String(repeating: "-", count: 52))
    print("done")
}

await run()
