import AppKit
import Foundation
@testable import VimTextCore

enum SmokeTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws -> Bool {
    if !condition() {
        throw SmokeTestFailure.failed(message)
    }
    return true
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) throws {
    if lhs != rhs {
        throw SmokeTestFailure.failed("\(message). Expected \(rhs), got \(lhs)")
    }
}

func expectSuccess(_ result: Result<Void, StorageError>, _ message: String) throws {
    if case .failure(let error) = result {
        throw SmokeTestFailure.failed("\(message): \(error.localizedDescription)")
    }
}

func expectFailure(_ result: Result<Void, StorageError>, _ message: String) throws -> StorageError {
    if case .failure(let error) = result {
        return error
    }
    throw SmokeTestFailure.failed(message)
}

@discardableResult
func feed(_ engine: VimEngine, _ keys: String...) -> [VimAction] {
    var actions: [VimAction] = []
    for key in keys {
        actions = engine.processKey(key)
    }
    return actions
}

func withTemporaryStorage(_ body: (StorageManager, URL) throws -> Void) throws {
    let manager = StorageManager.shared
    let originalPath = manager.customDirectoryPath
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("VimTextSmokeTests-\(UUID().uuidString)", isDirectory: true)
    defer {
        manager.customDirectoryPath = originalPath
        _ = manager.loadNotes()
        try? FileManager.default.removeItem(at: tempURL)
    }

    manager.customDirectoryPath = tempURL.path
    _ = manager.loadNotes()
    try body(manager, tempURL)
}

func testNoteModelDerivedText() throws {
    let untitled = Note(title: "   \n\t", content: "")
    try expectEqual(untitled.displayTitle, "New Note", "blank titles should display as New Note")
    try expectEqual(untitled.preview, "No additional text", "blank notes should use empty preview copy")

    // The first content line is the title source, so preview skips it and
    // shows the next three lines (avoids printing the title twice in rows).
    let multiline = Note(title: "Preview", content: "one\ntwo\nthree\nfour\nfive")
    try expectEqual(multiline.preview, "two three four", "preview should skip the title line and include the next three")

    let titleOnly = Note(title: "Solo", content: "Just the title line")
    try expectEqual(titleOnly.preview, "No additional text", "a single-line note has no body to preview")

    let longContent = "title\n" + String(repeating: "a", count: 200)
    try expectEqual(Note(title: "Long", content: longContent).preview.count, 120, "preview should be capped")

    let withImage = Note(title: "Img", content: "Title line\n![](assets/x.png)\nreal text")
    try expectEqual(withImage.preview, "real text", "preview should strip embedded-image references")

    let list = Note(title: "List", content: "Gifts\n1. Hand bag\n2) Earphones\n- chocolates")
    try expectEqual(list.preview, "Hand bag Earphones chocolates", "preview should strip list markers")
    let notAList = Note(title: "N", content: "t\n2024. A year\n-dash not list")
    try expectEqual(notAList.preview, "2024. A year -dash not list", "4+ digit numbers and unspaced dashes are not list markers")
}

func testEditorPreferencesFontSizing() throws {
    let suiteName = "VimTextSmokeTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw SmokeTestFailure.failed("could not create isolated defaults suite")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    try expectEqual(EditorPreferences.fontSize(defaults: defaults), EditorPreferences.defaultFontSize, "missing font preference should use default")
    try expectEqual(EditorPreferences.setFontSize(999, defaults: defaults), EditorPreferences.maximumFontSize, "font size should clamp to maximum")
    try expectEqual(EditorPreferences.increaseFontSize(defaults: defaults), EditorPreferences.maximumFontSize, "increase should stay clamped at maximum")
    try expectEqual(EditorPreferences.setFontSize(-1, defaults: defaults), EditorPreferences.minimumFontSize, "font size should clamp to minimum")
    try expectEqual(EditorPreferences.decreaseFontSize(defaults: defaults), EditorPreferences.minimumFontSize, "decrease should stay clamped at minimum")
    try expectEqual(EditorPreferences.resetFontSize(defaults: defaults), EditorPreferences.defaultFontSize, "reset should restore default")
}

func testSidebarWidthClamping() throws {
    try expectEqual(SidebarLayout.clampedWidth(10), SidebarLayout.minimumWidth, "sidebar width should clamp to minimum")
    try expectEqual(SidebarLayout.clampedWidth(300), 300, "sidebar width should preserve valid values")
    try expectEqual(SidebarLayout.clampedWidth(999), SidebarLayout.maximumWidth, "sidebar width should clamp to maximum")
}

func testGraphiteEditorContrast() throws {
    let contrast = ThemeContrastChecks.graphiteEditorTextContrastRatio()
    try expect(
        contrast >= ThemeContrastChecks.minimumReadableContrastRatio,
        "Graphite editor text contrast should stay readable"
    )
}

func testVimNormalModeMotionsAndCounts() throws {
    let engine = VimEngine()

    try expectEqual(feed(engine, "4", "j"), Array(repeating: .moveCursor(.down), count: 4), "4j should repeat down motion")
    try expectEqual(engine.processKey("0"), [.moveCursor(.lineStart)], "0 should be line start, not a count")
    try expectEqual(engine.processKey("$"), [.moveCursor(.lineEnd)], "$ should move to line end")
    try expectEqual(engine.processKey("^"), [.moveCursor(.firstNonBlank)], "^ should move to first non-blank")
    try expectEqual(engine.processKey("%"), [.moveCursor(.matchingBracket)], "% should match brackets")
    try expectEqual(engine.processKey("H"), [.moveCursor(.screenTop)], "H should move to top visible line")
    try expectEqual(engine.processKey("M"), [.moveCursor(.screenMiddle)], "M should move to middle visible line")
    try expectEqual(engine.processKey("L"), [.moveCursor(.screenBottom)], "L should move to bottom visible line")
    try expectEqual(engine.processKey("{"), [.moveCursor(.paragraphBackward)], "{ should move back by paragraph")
    try expectEqual(engine.processKey("}"), [.moveCursor(.paragraphForward)], "} should move forward by paragraph")

    try expectEqual(engine.processKey("W"), [.moveCursor(.bigWordForward)], "W should move by big WORD")
    try expectEqual(engine.processKey("B"), [.moveCursor(.bigWordBackward)], "B should move backward by big WORD")
    try expectEqual(engine.processKey("E"), [.moveCursor(.bigWordEnd)], "E should move to end of big WORD")
    try expectEqual(feed(engine, "g", "e"), [.moveCursor(.wordEndBackward)], "ge should move to previous word end")
    try expectEqual(feed(engine, "g", "E"), [.moveCursor(.bigWordEndBackward)], "gE should move to previous WORD end")
    try expectEqual(feed(engine, "2", "g", "g"), [.goToLine(2)], "2gg should go to line 2")
    try expectEqual(feed(engine, "g", "g"), [.moveCursor(.documentStart)], "gg should go to the document start")
    try expectEqual(feed(engine, "9", "G"), [.goToLine(9)], "9G should go to line 9")
    try expectEqual(engine.processKey("G"), [.moveCursor(.documentEnd)], "G should go to the document end")
}

func testVimInsertReplaceAndCommandModes() throws {
    var engine = VimEngine()
    try expectEqual(engine.processKey("i"), [.insertMode(.beforeCursor)], "i should enter insert before cursor")
    try expectEqual(engine.mode, .insert, "i should set insert mode")
    try expectEqual(engine.processKey("escape"), [.normalMode], "escape should leave insert mode")
    try expectEqual(engine.mode, .normal, "escape should set normal mode")

    engine = VimEngine()
    try expectEqual(engine.processKey("a"), [.insertMode(.afterCursor)], "a should enter insert after cursor")
    engine = VimEngine()
    try expectEqual(engine.processKey("I"), [.insertMode(.lineStart)], "I should insert at line start")
    engine = VimEngine()
    try expectEqual(engine.processKey("A"), [.insertMode(.lineEnd)], "A should insert at line end")
    engine = VimEngine()
    try expectEqual(engine.processKey("o"), [.insertMode(.newLineBelow)], "o should open a line below")
    engine = VimEngine()
    try expectEqual(engine.processKey("O"), [.insertMode(.newLineAbove)], "O should open a line above")

    engine = VimEngine()
    try expectEqual(engine.processKey("R"), [.none], "R should enter replace mode without an immediate edit")
    try expectEqual(engine.mode, .replace, "R should set replace mode")
    try expectEqual(engine.processKey("x"), [.replaceChar], "typing in replace mode should replace a character")
    try expectEqual(engine.processKey("escape"), [.normalMode], "escape should leave replace mode")

    engine = VimEngine()
    try expectEqual(engine.processKey(":"), [.commandMode], ": should enter command mode")
    try expectEqual(engine.mode, .command, ": should set command mode")
    try expectEqual(engine.processKey("escape"), [.normalMode], "escape should leave command mode")

    engine = VimEngine()
    try expectEqual(engine.processKey("[" , modifiers: .control), [.none], "Ctrl-[ in normal mode should be ignored")
    _ = engine.processKey("i")
    try expectEqual(engine.processKey("[", modifiers: .control), [.normalMode], "Ctrl-[ should leave insert mode")
}

func testVimOperatorsTextObjectsAndRepeats() throws {
    var engine = VimEngine()
    try expectEqual(feed(engine, "3", "d", "d"), [.deleteLines(3)], "3dd should be one counted line deletion")
    try expectEqual(feed(engine, "2", "c", "c"), [.changeLines(2)], "2cc should be one counted line change")
    try expectEqual(engine.mode, .insert, "cc should enter insert mode")
    _ = engine.processKey("escape")
    try expectEqual(feed(engine, "4", "y", "y"), [.yankLines(4)], "4yy should yank four lines")
    try expectEqual(feed(engine, "2", ">",
                        ">"), [.indentLines(2)], "2>> should indent two lines")
    try expectEqual(feed(engine, "3", "<",
                        "<"), [.outdentLines(3)], "3<< should outdent three lines")

    engine = VimEngine()
    try expectEqual(feed(engine, "d", "w"), [.deleteMotion(.wordForward, 1)], "dw should delete a word")
    try expectEqual(feed(engine, "2", "d", "W"), [.deleteMotion(.bigWordForward, 2)], "2dW should delete two WORDs")
    try expectEqual(feed(engine, "d", "$"), [.deleteToEnd], "d$ should delete to end of line")
    try expectEqual(feed(engine, "c", "G"), [.changeMotion(.documentEnd, 1)], "cG should change to document end")
    _ = engine.processKey("escape")
    try expectEqual(feed(engine, "y", "%"), [.yankMotion(.matchingBracket, 1)], "y% should yank to matching bracket")
    try expectEqual(engine.processKey("D"), [.deleteToEnd], "D should delete to end")
    try expectEqual(engine.processKey("C"), [.changeToEnd], "C should change to end")

    engine = VimEngine()
    try expectEqual(feed(engine, "d", "i", "w"), [.deleteTextObject(.inner(.word))], "diw should delete inner word")
    try expectEqual(feed(engine, "d", "a", "("), [.deleteTextObject(.around(.paren))], "da( should delete around parens")
    try expectEqual(feed(engine, "c", "i", "\""), [.changeTextObject(.inner(.doubleQuote))], "ci\" should change inside quotes")
    _ = engine.processKey("escape")
    try expectEqual(feed(engine, "y", "a", "W"), [.yankTextObject(.around(.bigWord))], "yaW should yank around WORD")

    engine = VimEngine()
    try expectEqual(engine.processKey("x"), [.deleteChar], "x should delete character")
    try expectEqual(feed(engine, "3", "X"), Array(repeating: .deleteCharBefore, count: 3), "3X should delete three chars before")
    try expectEqual(feed(engine, "2", "~"), Array(repeating: .toggleCase, count: 2), "2~ should toggle twice")
    try expectEqual(feed(engine, "2", "p"), Array(repeating: .pasteAfter, count: 2), "2p should paste twice")
    try expectEqual(feed(engine, "2", "P"), Array(repeating: .pasteBefore, count: 2), "2P should paste twice before")
    try expectEqual(engine.processKey("."), [.repeatLastChange], ". should repeat last change")
}

func testVimFindSearchVisualAndControlParsing() throws {
    var engine = VimEngine()
    try expectEqual(feed(engine, "f", "x"), [.moveCursor(.findChar("x", true))], "fx should find forward")
    try expectEqual(engine.processKey(";"), [.moveCursor(.findChar("x", true))], "; should repeat find")
    try expectEqual(engine.processKey(","), [.moveCursor(.findChar("x", false))], ", should reverse find")
    try expectEqual(feed(engine, "t", ")"), [.moveCursor(.tillChar(")", true))], "t) should move till char")
    // ; / , repeating a t/T must emit the skip-adjacent variant so the cursor
    // advances past the char it already rests before instead of staying put.
    try expectEqual(engine.processKey(";"), [.moveCursor(.tillCharRepeat(")", true))], "; should repeat till (skip-adjacent)")
    try expectEqual(engine.processKey(","), [.moveCursor(.tillCharRepeat(")", false))], ", should reverse till (skip-adjacent)")
    try expectEqual(feed(engine, "F", "a"), [.moveCursor(.findChar("a", false))], "Fa should find backward")
    try expectEqual(feed(engine, "T", "a"), [.moveCursor(.tillChar("a", false))], "Ta should till backward")
    try expectEqual(engine.processKey(";"), [.moveCursor(.tillCharRepeat("a", false))], "; should repeat backward till (skip-adjacent)")

    engine = VimEngine()
    try expectEqual(feed(engine, "d", "f", ")"), [.deleteMotion(.findChar(")", true), 1)], "df) should delete through char")
    try expectEqual(feed(engine, "c", "t", "\""), [.changeMotion(.tillChar("\"", true), 1)], "ct\" should change till quote")
    _ = engine.processKey("escape")
    try expectEqual(feed(engine, "y", "F", "x"), [.yankMotion(.findChar("x", false), 1)], "yFx should yank to previous x")

    engine = VimEngine()
    try expectEqual(engine.processKey("/"), [.searchForward], "/ should enter forward search")
    _ = engine.processKey("escape")
    try expectEqual(engine.processKey("?"), [.searchBackward], "? should enter backward search")
    _ = engine.processKey("escape")
    try expectEqual(engine.processKey("n"), [.nextMatch], "n should go to next match")
    try expectEqual(engine.processKey("N"), [.previousMatch], "N should go to previous match")
    try expectEqual(engine.processKey("*"), [.searchWordUnderCursor(forward: true)], "* should search the word under the cursor forward")
    try expectEqual(engine.processKey("#"), [.searchWordUnderCursor(forward: false)], "# should search the word under the cursor backward")

    engine = VimEngine()
    try expectEqual(engine.processKey("v"), [.visualMode], "v should enter visual mode")
    try expectEqual(engine.mode, .visual, "v should set visual mode")
    try expectEqual(engine.processKey("W"), [.moveCursor(.bigWordForward)], "visual W should move by WORD")
    try expectEqual(feed(engine, "g", "E"), [.moveCursor(.bigWordEndBackward)], "visual gE should move backward by WORD end")
    try expectEqual(feed(engine, "i", "w"), [.visualSelectTextObject(.inner(.word))], "visual iw should select inner word")
    try expectEqual(feed(engine, "a", "("), [.visualSelectTextObject(.around(.paren))], "visual a( should select around parens")
    try expectEqual(feed(engine, "f", "x"), [.moveCursor(.findChar("x", true))], "visual fx should move to char")
    try expectEqual(engine.processKey("o"), [.visualSwapAnchor], "visual o should swap anchor")
    try expectEqual(engine.processKey(">"), [.visualIndent], "visual > should indent selection")
    try expectEqual(engine.mode, .normal, "visual > should return to normal")

    engine = VimEngine()
    try expectEqual(engine.processKey("v", modifiers: .control), [.visualBlockMode], "Ctrl-V should enter visual block")
    try expectEqual(engine.mode, .visualBlock, "Ctrl-V should set visual block mode")
    try expectEqual(engine.processKey("I"), [.visualBlockInsert], "I should insert into visual block")
    engine = VimEngine()
    _ = engine.processKey("v", modifiers: .control)
    try expectEqual(engine.processKey("A"), [.visualBlockAppend], "A should append into visual block")

    engine = VimEngine()
    try expectEqual(engine.processKey("r", modifiers: .control), [.redo], "Ctrl-R should redo")
    try expectEqual(engine.processKey("d", modifiers: .control), Array(repeating: .moveCursor(.down), count: 15), "Ctrl-D should move half-page down")
    try expectEqual(engine.processKey("u", modifiers: .control), Array(repeating: .moveCursor(.up), count: 15), "Ctrl-U should move half-page up")
}

func testVimWordUnderCursorExtraction() throws {
    let line = "foo bar_baz qux" as NSString
    try expectEqual(VimWordUnderCursor.word(in: line, at: 0), "foo", "cursor on the first char should yield the word")
    try expectEqual(VimWordUnderCursor.word(in: line, at: 2), "foo", "cursor mid-word should yield the whole word")
    try expectEqual(VimWordUnderCursor.word(in: line, at: 4), "bar_baz", "underscore should be part of the keyword")
    try expectEqual(VimWordUnderCursor.word(in: line, at: 7), "bar_baz", "cursor on the underscore should yield the whole keyword")
    try expectEqual(VimWordUnderCursor.word(in: line, at: 3), "bar_baz", "cursor on a space should scan forward to the next word")
    try expectEqual(VimWordUnderCursor.word(in: line, at: 12), "qux", "cursor on the last word should yield it")

    let trailing = "hi   \nnext" as NSString
    try expectEqual(VimWordUnderCursor.word(in: trailing, at: 3), nil, "spaces before end-of-line should yield no word")

    try expectEqual(VimWordUnderCursor.word(in: "" as NSString, at: 0), nil, "empty text should yield no word")
    try expectEqual(VimWordUnderCursor.word(in: "x" as NSString, at: 9), "x", "out-of-range location should clamp into the text")
}

func testImageMarkdownHelpers() throws {
    // Reference round-trip with and without an explicit width.
    try expectEqual(ImageMarkdown.reference(for: "assets/a.png", width: 320), "![|320](assets/a.png)", "reference should embed width")
    try expectEqual(ImageMarkdown.reference(for: "assets/a.png", width: nil), "![](assets/a.png)", "no width should produce a plain reference")

    // Width parsing from the alt slot.
    try expect(ImageMarkdown.width(fromAlt: "|320") == 320, "should parse |width")
    try expect(ImageMarkdown.width(fromAlt: "alt|240") == 240, "should parse a trailing width")
    try expect(ImageMarkdown.width(fromAlt: "") == nil, "empty alt has no width")
    try expect(ImageMarkdown.width(fromAlt: "nobar") == nil, "alt without a bar has no width")

    // Reference extraction + width.
    let content = "intro\n![|200](assets/x.png)\n![](https://ext/y.png)\nend"
    let refs = ImageMarkdown.references(in: content)
    try expectEqual(refs.count, 2, "should find two references")
    try expectEqual(refs[0].path, "assets/x.png", "first reference path")
    try expect(refs[0].width == 200, "first reference width should parse")
    try expect(refs[1].width == nil, "external reference has no width")
    try expectEqual(ImageMarkdown.localAssetPaths(in: content), ["assets/x.png"], "only local assets are owned")

    // Image-only line detection (used by title extraction).
    try expect(ImageMarkdown.isImageOnly("![|200](assets/x.png)"), "a bare image line is image-only")
    try expect(!ImageMarkdown.isImageOnly("see ![](assets/x.png)"), "text plus image is not image-only")
    try expect(!ImageMarkdown.isImageOnly("hello"), "plain text is not image-only")

    // Stripping for previews.
    try expectEqual(ImageMarkdown.strippingImageRefs(from: "a ![](assets/x.png) b"), "a  b", "image refs should be stripped from previews")
}

func testVimAdditionalActions() throws {
    var engine = VimEngine()
    try expectEqual(engine.processKey("Y"), [.yankLines(1)], "Y should yank the current line")
    try expectEqual(feed(engine, "3", "Y"), [.yankLines(3)], "3Y should yank three lines")
    try expectEqual(engine.processKey("J"), [.joinLines], "J should join lines")

    engine = VimEngine()
    try expectEqual(engine.processKey("s"), [.deleteChar, .insertMode(.beforeCursor)], "s should delete a char then insert")
    try expectEqual(engine.mode, .insert, "s should enter insert mode")

    engine = VimEngine()
    try expectEqual(engine.processKey("S"), [.changeLine], "S should change the whole line")
    try expectEqual(engine.mode, .insert, "S should enter insert mode")

    engine = VimEngine()
    try expectEqual(engine.processKey("r"), [.none], "r should wait for a replacement character")
    try expectEqual(engine.processKey("z"), [.replaceChar], "r{char} should replace the character")

    engine = VimEngine()
    try expectEqual(feed(engine, "z", "z"), [.centerCursor(.center)], "zz should center the cursor line")
    try expectEqual(feed(engine, "z", "t"), [.centerCursor(.top)], "zt should move the cursor line to the top")
    try expectEqual(feed(engine, "z", "b"), [.centerCursor(.bottom)], "zb should move the cursor line to the bottom")
}

func testVimVisualCountsPasteAndCaseOps() throws {
    var engine = VimEngine()
    _ = engine.processKey("v")
    try expectEqual(feed(engine, "3", "j"), Array(repeating: .moveCursor(.down), count: 3), "visual 3j should repeat the motion")
    try expectEqual(feed(engine, "2", "w"), Array(repeating: .moveCursor(.wordForward), count: 2), "visual 2w should repeat the motion")
    try expectEqual(feed(engine, "5", "G"), [.goToLine(5)], "visual 5G should go to line 5")
    try expectEqual(engine.processKey("p"), [.visualPaste(linewise: false)], "visual p should paste over the selection")
    try expectEqual(engine.mode, .normal, "visual p should return to normal mode")

    engine = VimEngine()
    _ = engine.processKey("V")
    try expectEqual(engine.processKey("p"), [.visualPaste(linewise: true)], "V-line p should paste linewise")

    engine = VimEngine()
    _ = engine.processKey("v")
    try expectEqual(engine.processKey("U"), [.visualChangeCase(upper: true)], "visual U should uppercase the selection")
    try expectEqual(engine.mode, .normal, "visual U should return to normal mode")
    _ = engine.processKey("v")
    try expectEqual(engine.processKey("u"), [.visualChangeCase(upper: false)], "visual u should lowercase the selection")

    engine = VimEngine()
    try expectEqual(feed(engine, "g", "U", "w"), [.changeCaseMotion(.wordForward, 1, upper: true)], "gUw should uppercase a word")
    try expectEqual(feed(engine, "g", "u", "$"), [.changeCaseMotion(.lineEnd, 1, upper: false)], "gu$ should lowercase to line end")
    try expectEqual(feed(engine, "g", "u", "u"), [.changeCaseLines(1, upper: false)], "guu should lowercase the line")
    try expectEqual(feed(engine, "3", "g", "U", "U"), [.changeCaseLines(3, upper: true)], "3gUU should uppercase three lines")

    try expect(Motion.lineEnd.isInclusive, "$ must be inclusive so gU$ / y$ reach the last character of the line")
}

func testVimMarksAndNoh() throws {
    let engine = VimEngine()
    try expectEqual(feed(engine, "m", "a"), [.setMark("a")], "ma should set mark a")
    try expectEqual(feed(engine, "`", "a"), [.jumpToMark("a", exact: true)], "`a should jump to the exact mark position")
    try expectEqual(feed(engine, "'", "a"), [.jumpToMark("a", exact: false)], "'a should jump to the mark's line")
    try expectEqual(feed(engine, "m", "1"), [.none], "marks only accept letters")
    try expectEqual(engine.executeCommand("noh"), [.clearSearchHighlight], ":noh should clear search highlights")
    try expectEqual(engine.executeCommand("nohlsearch"), [.clearSearchHighlight], ":nohlsearch should clear search highlights")
}

func testStorageImageAssets() throws {
    try withTemporaryStorage { manager, _ in
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        guard let rel = manager.saveImageAsset(png, fileExtension: "png") else {
            throw SmokeTestFailure.failed("saveImageAsset should return a relative path")
        }
        try expect(rel.hasPrefix("assets/") && rel.hasSuffix(".png"), "asset path should be assets/<uuid>.png")
        let url = manager.assetURL(forRelativePath: rel)
        try expect(FileManager.default.fileExists(atPath: url.path), "asset file should be written to disk")
        try expectEqual(try? Data(contentsOf: url), png, "asset bytes should round-trip")

        // Prune keeps referenced assets, removes orphans.
        guard let orphan = manager.saveImageAsset(Data([1, 2, 3]), fileExtension: "png") else {
            throw SmokeTestFailure.failed("orphan asset should save")
        }
        let orphanURL = manager.assetURL(forRelativePath: orphan)
        let note = Note(title: "Has image", content: "see ![](\(rel))")
        manager.pruneOrphanAssets(referencedBy: [note])
        try expect(FileManager.default.fileExists(atPath: url.path), "referenced asset should survive prune")
        try expect(!FileManager.default.fileExists(atPath: orphanURL.path), "unreferenced asset should be pruned")
    }

    try withTemporaryStorage { manager, _ in
        guard let rel = manager.saveImageAsset(Data([9, 9, 9]), fileExtension: "png") else {
            throw SmokeTestFailure.failed("asset should save")
        }
        let url = manager.assetURL(forRelativePath: rel)
        let note = Note(title: "Doomed", content: "![](\(rel))")
        try expectSuccess(manager.saveNote(note), "note with an image should save")
        manager.deleteNote(note, remainingNotes: [])
        try expect(!FileManager.default.fileExists(atPath: url.path), "deleting a note should remove its assets")
    }

    // A duplicated note shares the original's asset files; deleting one copy
    // must not delete assets the surviving copy still references.
    try withTemporaryStorage { manager, _ in
        guard let rel = manager.saveImageAsset(Data([7, 7, 7]), fileExtension: "png") else {
            throw SmokeTestFailure.failed("asset should save")
        }
        let url = manager.assetURL(forRelativePath: rel)
        let original = Note(title: "Original", content: "![](\(rel))")
        let duplicate = Note(title: "Original", content: original.content)
        try expectSuccess(manager.saveNote(original), "original should save")
        try expectSuccess(manager.saveNote(duplicate), "duplicate should save")

        manager.deleteNote(original, remainingNotes: [duplicate])
        try expect(FileManager.default.fileExists(atPath: url.path), "assets referenced by a surviving duplicate should be kept")

        manager.deleteNote(duplicate, remainingNotes: [])
        try expect(!FileManager.default.fileExists(atPath: url.path), "deleting the last referencing note should remove the asset")
    }
}

func testNotesViewModelFiltering() throws {
    let folder = UUID()
    let older = Date(timeIntervalSince1970: 1000)
    let newer = Date(timeIntervalSince1970: 2000)
    let notes = [
        Note(title: "Grocery list", content: "milk and eggs", createdAt: older),
        Note(title: "Work notes", content: "meeting agenda", folderId: folder, createdAt: newer),
        Note(title: "Pinned idea", content: "build a thing", createdAt: older, isPinned: true)
    ]

    try MainActor.assumeIsolated {
        let all = NotesViewModel.computeFilteredNotes(notes: notes, showAllNotes: true, selectedFolderId: nil, searchText: "")
        try expectEqual(all.map(\.title), ["Pinned idea", "Work notes", "Grocery list"], "pinned first, then newest by createdAt")

        let inFolder = NotesViewModel.computeFilteredNotes(notes: notes, showAllNotes: false, selectedFolderId: folder, searchText: "")
        try expectEqual(inFolder.map(\.title), ["Work notes"], "folder filter keeps only that folder")

        let byContent = NotesViewModel.computeFilteredNotes(notes: notes, showAllNotes: true, selectedFolderId: nil, searchText: "AGENDA")
        try expectEqual(byContent.map(\.title), ["Work notes"], "search matches content case-insensitively")

        let byTitle = NotesViewModel.computeFilteredNotes(notes: notes, showAllNotes: true, selectedFolderId: nil, searchText: "idea")
        try expectEqual(byTitle.map(\.title), ["Pinned idea"], "search matches the title")
    }
}

/// Drives the real `VimNSTextView.keyDown` path for `/watch⏎`, exactly as the
/// app routes live keystrokes — regression test for "/ search does nothing".
func testVimSlashSearchViaKeyDown() throws {
    try MainActor.assumeIsolated {
    _ = NSApplication.shared
    let engine = VimEngine()
    let parent = VimTextView(
        initialText: "",
        initialRTFData: Data(),
        onContentChange: nil,
        vimEngine: engine,
        findController: nil,
        onSave: nil,
        font: NSFont.systemFont(ofSize: 14)
    )
    let coordinator = VimTextView.Coordinator(parent)
    let textView = VimNSTextView()
    textView.vimEngine = engine
    textView.coordinator = coordinator
    coordinator.textView = textView
    textView.string = "alpha\nbravo watch\ncharlie watch"
    textView.setSelectedRange(NSRange(location: 0, length: 0))

    func press(_ chars: String, code: UInt16) throws {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code
        ) else { throw SmokeTestFailure.failed("could not synthesize key event for \(chars)") }
        textView.keyDown(with: event)
    }

    try press("/", code: 44)
    try expect(engine.mode == .command, "/ should enter command mode")
    try expect(engine.isSearchMode, "/ should arm search mode")
    try expect(engine.showCommandLine, "/ should show the command line")

    for ch in "watch" { try press(String(ch), code: 0) }
    try expectEqual(engine.commandLineText, "watch", "typed term should accumulate in the command line")

    try press("\r", code: 36)
    try expect(engine.mode == .normal, "Enter should return to normal mode")
    try expectEqual(textView.selectedRange().location, 12, "cursor should land on the first match")
    try expectEqual(engine.searchTerm, "watch", "search register should hold the term for n/N")

    // n should jump to the next match (second "watch", after wrap-forward).
    try press("n", code: 45)
    try expectEqual(textView.selectedRange().location, 26, "n should advance to the next match")
    }
}

/// Builds a live `VimNSTextView` wired to its engine/coordinator and seeded
/// with `text`, plus a `press` helper that drives the real `keyDown` path —
/// the shared rig for execution-level Vim regression tests.
///
/// The coordinator is returned (not just stored) because `VimNSTextView.coordinator`
/// is `weak`; the caller must retain it for the lifetime of the test.
@MainActor
private func makeVimRig(_ text: String) -> (VimEngine, VimNSTextView, VimTextView.Coordinator, (String) -> Void) {
    _ = NSApplication.shared
    let engine = VimEngine()
    let parent = VimTextView(
        initialText: "", initialRTFData: Data(), onContentChange: nil,
        vimEngine: engine, findController: nil, onSave: nil,
        font: NSFont.systemFont(ofSize: 14)
    )
    let coordinator = VimTextView.Coordinator(parent)
    let textView = VimNSTextView()
    textView.vimEngine = engine
    textView.coordinator = coordinator
    coordinator.textView = textView
    textView.string = text
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    let press: (String) -> Void = { chars in
        for ch in chars {
            let s = String(ch)
            if let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: s,
                charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0
            ) { textView.keyDown(with: event) }
        }
    }
    return (engine, textView, coordinator, press)
}

/// Regression for "yy/p on the file's last line pastes inline": the final line
/// has no trailing newline, so the yank register must still be linewise and the
/// paste must open a new line below rather than concatenating onto it.
func testVimLinewisePasteLastLine() throws {
    try MainActor.assumeIsolated {
        // Last line ("second") carries no trailing newline.
        let (eng, tv, coord, press) = makeVimRig("first\nsecond")
        tv.setSelectedRange(NSRange(location: 6, length: 0)) // on "second"
        press("yy")
        try expectEqual(eng.register, "second\n", "yy on last line must yank a linewise register")
        press("p")
        try expectEqual(tv.string, "first\nsecond\nsecond",
                        "yyp on the last line must duplicate it on a new line below")
        try expectEqual(tv.selectedRange().location, 13,
                        "cursor should land at the start of the pasted line")

        // Regression guard: a non-last line still pastes below as before.
        let (_, tv2, coord2, press2) = makeVimRig("alpha\nbeta\ngamma")
        tv2.setSelectedRange(NSRange(location: 0, length: 0)) // on "alpha"
        press2("yy")
        press2("p")
        try expectEqual(tv2.string, "alpha\nalpha\nbeta\ngamma",
                        "yyp on a middle line must still paste a copy below")
        withExtendedLifetime((coord, coord2)) {}
    }
}

/// Regression for "; / , after t/T gets stuck": repeating a till motion must
/// step over the adjacent target so the cursor advances each time.
func testVimTillRepeatAdvances() throws {
    try MainActor.assumeIsolated {
        // a . b . c . d  → indices of '.' are 1, 3, 5.
        let (_, tv, coord, press) = makeVimRig("a.b.c.d")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        press("t.")
        try expectEqual(tv.selectedRange().location, 0, "t. stops just before the first dot")
        press(";")
        try expectEqual(tv.selectedRange().location, 2, "; must advance to just before the next dot")
        press(";")
        try expectEqual(tv.selectedRange().location, 4, "repeated ; keeps advancing")

        // Backward T then ; advances leftward instead of sticking.
        tv.setSelectedRange(NSRange(location: 6, length: 0)) // on "d"
        press("T.")
        try expectEqual(tv.selectedRange().location, 6, "T. stops just after the nearest preceding dot")
        press(";")
        try expectEqual(tv.selectedRange().location, 4, "; must advance left past the adjacent dot")
        withExtendedLifetime(coord) {}
    }
}

func testVimCommandExecution() throws {
    let engine = VimEngine()
    try expectEqual(engine.executeCommand("42"), [.goToLine(42)], ":42 should go to line 42")
    try expectEqual(engine.executeCommand("w"), [.save], ":w should save")
    try expectEqual(engine.executeCommand("q"), [.quit], ":q should quit")
    try expectEqual(engine.executeCommand("wq"), [.save, .quit], ":wq should save and quit")
    try expectEqual(engine.executeCommand("x"), [.save, .quit], ":x should save and quit")
    try expectEqual(engine.executeCommand("q!"), [.quit], ":q! should quit")
    try expectEqual(
        engine.executeCommand("%s/foo/bar/gi"),
        [.substitute(pattern: "foo", replacement: "bar", isEntireDocument: true, isGlobalReplace: true, isCaseInsensitive: true)],
        ":%s/foo/bar/gi should parse global case-insensitive substitute"
    )
    try expectEqual(
        engine.executeCommand("s/foo/bar\\/baz/g"),
        [.substitute(pattern: "foo", replacement: "bar/baz", isEntireDocument: false, isGlobalReplace: true, isCaseInsensitive: false)],
        ":s should unescape slashes in replacement"
    )
    try expectEqual(engine.executeCommand("nope"), [.none], "unknown commands should be no-ops")
}

func testStorageRoundTripRenameCollisionAndRTF() throws {
    try withTemporaryStorage { manager, _ in
        var note = Note(title: "First / Unsafe", content: "one")
        try expectSuccess(manager.saveNote(note), "initial save should succeed")
        let oldURL = manager.fileURL(for: note)
        let oldTextURL = oldURL.deletingPathExtension().appendingPathExtension("txt")

        var loaded = manager.loadNotes()
        try expectEqual(loaded.count, 1, "one note should load")
        try expectEqual(loaded.first?.content, "one", "saved content should round-trip")

        note.title = "Second"
        note.content = "two"
        note.isLocked = true
        try expectSuccess(manager.saveNote(note), "renamed save should succeed")

        // isLocked must survive the metadata round-trip (it once silently
        // dropped because NoteMetadata didn't carry the field).
        try expectEqual(manager.loadNotes().first?.isLocked, true, "isLocked should persist across save/load")
        note.isLocked = false
        try expectSuccess(manager.saveNote(note), "unlock save should succeed")
        try expectEqual(manager.loadNotes().first?.isLocked, false, "unlock should persist across save/load")

        try expect(!FileManager.default.fileExists(atPath: oldURL.path), "old metadata file should be removed after rename")
        try expect(!FileManager.default.fileExists(atPath: oldTextURL.path), "old text sidecar should be removed after rename")

        loaded = manager.loadNotes()
        try expectEqual(loaded.first?.title, "Second", "renamed title should load")
        try expectEqual(loaded.first?.content, "two", "renamed content should load")
    }

    try withTemporaryStorage { manager, _ in
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Note(title: "Same Title", content: "first", createdAt: createdAt)
        let second = Note(title: "Same Title", content: "second", createdAt: createdAt)

        try expectSuccess(manager.saveNote(first), "first duplicate title should save")
        try expectSuccess(manager.saveNote(second), "second duplicate title should save")

        let firstURL = manager.fileURL(for: first)
        let secondURL = manager.fileURL(for: second)
        try expect(firstURL != secondURL, "duplicate title/createdAt notes should not collide")
        try expect(secondURL.deletingPathExtension().lastPathComponent.hasSuffix("-2"), "second duplicate should get a numeric suffix")

        let contents = Set(manager.loadNotes().map(\.content))
        try expectEqual(contents, Set(["first", "second"]), "both duplicate notes should load")
    }

    try withTemporaryStorage { manager, _ in
        let rtf = Data("{\\rtf1\\ansi hello}".utf8)
        var note = Note(title: "Rich", content: "hello", rtfData: rtf)
        try expectSuccess(manager.saveNote(note, rtfInSync: true), "RTF note should save")
        try expectEqual(manager.loadNotes().first?.rtfData, rtf, "in-sync RTF should round-trip")

        note.content = "changed"
        try expectSuccess(manager.saveNote(note, rtfInSync: false), "stale RTF note should save")
        try expectEqual(manager.loadNotes().first?.rtfData, nil, "stale RTF should not be loaded")

        note.rtfData = nil
        try expectSuccess(manager.saveNote(note), "nil RTF note should save")
        let rtfURL = manager.fileURL(for: note).deletingPathExtension().appendingPathExtension("rtf")
        try expect(!FileManager.default.fileExists(atPath: rtfURL.path), "nil RTF should remove sidecar")
    }

    // Lazy RTF: readNotesSnapshot(loadRTF: false) defers the (potentially huge)
    // sidecar read but still records that it's in sync, and loadRTFData fetches
    // the bytes on demand when a note is actually opened.
    try withTemporaryStorage { manager, _ in
        let rtf = Data("{\\rtf1\\ansi world}".utf8)
        let rich = Note(title: "Rich", content: "world", rtfData: rtf)
        try expectSuccess(manager.saveNote(rich, rtfInSync: true), "rich note should save")
        let plain = Note(title: "Plain", content: "just text")
        try expectSuccess(manager.saveNote(plain), "plain note should save")

        let lazy = manager.readNotesSnapshot(loadRTF: false)
        let lazyRichRTF = lazy.notes.first { $0.id == rich.id }?.rtfData
        try expect(lazyRichRTF == nil, "lazy snapshot should not read RTF bytes")
        try expect(lazy.rtfInSyncByID[rich.id] == true, "rich note should be flagged in-sync")
        try expect(lazy.rtfInSyncByID[plain.id] == false, "plain note should be flagged not-in-sync")
        try expect(manager.loadRTFData(for: rich.id) == rtf, "on-demand load returns the sidecar bytes")
        try expect(manager.loadRTFData(for: plain.id) == nil, "plain note has no sidecar to load")
    }
}

func testStorageMalformedFilesAndWriteErrors() throws {
    try withTemporaryStorage { manager, tempURL in
        let notesURL = tempURL.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: notesURL.appendingPathComponent("broken.json"))
        try expectEqual(manager.loadNotes(), [], "malformed notes should be ignored during load")
    }

    let manager = StorageManager.shared
    let originalPath = manager.customDirectoryPath
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("VimTextSmokeTests-Failure-\(UUID().uuidString)", isDirectory: true)
    defer {
        manager.customDirectoryPath = originalPath
        _ = manager.loadNotes()
        try? FileManager.default.removeItem(at: tempURL)
    }

    try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
    let fileURL = tempURL.appendingPathComponent("not-a-directory")
    try Data("file".utf8).write(to: fileURL)
    manager.customDirectoryPath = fileURL.path

    let error = try expectFailure(manager.saveNote(Note(title: "Cannot Save", content: "body")), "saving under a file path should fail")
    if case .cannotCreateDirectory = error {
        // Expected.
    } else {
        throw SmokeTestFailure.failed("expected cannotCreateDirectory, got \(error)")
    }
}

func testCommandPaletteSearchMatching() throws {
    let notes = [
        Note(title: "Haskell tutorial", content: "Learn monads and functors"),
        Note(title: "Vim configuration", content: "Keybindings and syntax highlighting"),
        Note(title: "SwiftUI tips", content: "Using FocusState and onAppear"),
        Note(title: "Cooking guide", content: "Making the perfect carbonara pasta")
    ]

    // 1. Test exact/case-insensitive title matching
    let hMatch = CommandPaletteState.matchingNotes(notes, query: "haskell")
    try expectEqual(hMatch.count, 1, "Should find 1 note matching 'haskell'")
    try expectEqual(hMatch.first?.title, "Haskell tutorial", "Title should match 'Haskell tutorial'")

    // 2. Test content matching
    let vMatch = CommandPaletteState.matchingNotes(notes, query: "syntax")
    try expectEqual(vMatch.count, 1, "Should find 1 note matching content 'syntax'")
    try expectEqual(vMatch.first?.title, "Vim configuration", "Should match content owner note")

    // 3. Test query returning multiple notes
    let multipleMatch = CommandPaletteState.matchingNotes(notes, query: "and")
    try expectEqual(multipleMatch.count, 3, "Should find 3 notes containing the word 'and'")

    // 4. Test empty query (should return all notes)
    let emptyQueryMatch = CommandPaletteState.matchingNotes(notes, query: "")
    try expectEqual(emptyQueryMatch.count, 4, "Empty query should return all notes")
}

func testFuzzySearchAndRanking() throws {
    // Subsequence matching: initials find the note, missing letters don't.
    let initials = FuzzySearch.match("sgs", in: "Shreya Gifting Strategy")
    try expect(initials != nil, "Initials 'sgs' should fuzzy-match 'Shreya Gifting Strategy'")
    try expectEqual(initials!.matchedOffsets, [0, 7, 15], "Fuzzy match should land on the word starts")
    try expect(FuzzySearch.match("xyz", in: "Shreya Gifting Strategy") == nil,
               "Out-of-order/missing letters must not match")
    try expect(FuzzySearch.match("", in: "anything")?.score == 0, "Empty query matches with zero score")

    // Word-prefix matches outrank mid-word ones; tight beats scattered.
    let prefix = FuzzySearch.match("gift", in: "Gifting ideas")!.score
    let midWord = FuzzySearch.match("gift", in: "Regifting")!.score
    try expect(prefix > midWord, "Word-prefix match should outscore mid-word match")
    let tight = FuzzySearch.match("note", in: "notes")!.score
    let scattered = FuzzySearch.match("note", in: "no quote either")!.score
    try expect(tight > scattered, "Consecutive match should outscore scattered match")

    // Note ranking: title hits beat content hits; recency boosts ties.
    let titleHit = Note(title: "Wifi password home", content: "air67996")
    let contentHit = Note(title: "Random scribbles", content: "the wifi here is slow")
    let ranked = CommandPaletteState.matchingNotes([contentHit, titleHit], query: "wifi")
    try expectEqual(ranked.first?.id, titleHit.id, "Title match should rank above content match")

    let a = Note(title: "Meeting notes A", content: "")
    let b = Note(title: "Meeting notes B", content: "")
    let recentFirst = CommandPaletteState.matchingNotes([a, b], query: "meeting", recentIds: [b.id])
    try expectEqual(recentFirst.first?.id, b.id, "Recently opened note should win a score tie")

    let noMatch = CommandPaletteState.matchingNotes([titleHit, contentHit], query: "qqqq")
    try expectEqual(noMatch.count, 0, "Unmatchable query should return nothing")
}

func testSearchQuoteFolding() throws {
    // The folding itself: typographic punctuation → ASCII, 1:1 in UTF-16
    // (the find/highlight paths rely on offsets staying valid).
    try expectEqual("don\u{2019}t".searchFolded, "don't", "Curly apostrophe should fold to straight")
    try expectEqual("\u{201C}hi\u{201D} \u{2014} ok".searchFolded, "\"hi\" - ok", "Smart quotes and em dash should fold")
    try expectEqual("plain text".searchFolded, "plain text", "ASCII text should be untouched")
    try expectEqual(
        ("a\u{2019}b\u{201C}c" as NSString).length,
        ("a\u{2019}b\u{201C}c".searchFolded as NSString).length,
        "Folding must preserve UTF-16 length"
    )

    // End to end: a straight-quote query finds smart-quote note text in both
    // the palette scorer and the sidebar filter.
    let smartNote = Note(title: "Gift ideas", content: "Bluetooth earphones \u{2014} you don\u{2019}t use them")
    let palette = CommandPaletteState.matchingNotes([smartNote], query: "don't")
    try expectEqual(palette.count, 1, "Palette: straight-quote query should match smart-quote content")
    let sidebar = MainActor.assumeIsolated {
        NotesViewModel.computeFilteredNotes(
            notes: [smartNote], showAllNotes: true, selectedFolderId: nil, searchText: "don't"
        )
    }
    try expectEqual(sidebar.count, 1, "Sidebar: straight-quote query should match smart-quote content")
}

func testLinkDetectionAndGx() throws {
    // Detection: https, bare www, and email, with correct UTF-16 ranges.
    let text = "See https://example.com/a?b=1 and www.apple.com or mail me@test.org done"
    let links = LinkDetection.links(in: text)
    try expectEqual(links.count, 3, "Should detect URL, www host, and email")
    try expectEqual(links[0].url.absoluteString, "https://example.com/a?b=1", "Full URL should parse")
    let ns = text as NSString
    try expectEqual(ns.substring(with: links[0].range), "https://example.com/a?b=1", "Range should cover the URL text")
    try expectEqual(ns.substring(with: links[1].range), "www.apple.com", "Range should cover the www link")
    try expect(links[1].url.absoluteString.contains("apple.com"), "www link should resolve to a URL")
    try expect(links[2].url.absoluteString.hasPrefix("mailto:"), "Email should become a mailto URL")

    try expectEqual(LinkDetection.links(in: "no links here").count, 0, "Plain text has no links")
    try expectEqual(LinkDetection.links(in: "").count, 0, "Empty text has no links")

    // Vim: `gd` parses to openLinkUnderCursor; `gg` still goes to start.
    let engine = VimEngine()
    engine.mode = .normal
    let gd = feed(engine, "g", "d")
    try expectEqual(gd, [.openLinkUnderCursor], "gd should produce openLinkUnderCursor")
    let gg = feed(engine, "g", "g")
    try expectEqual(gg, [.moveCursor(.documentStart)], "gg must still jump to document start")
}

func testLinkFoldingComputeFolds() throws {
    // A scheme+path URL collapses to its host (minus a leading www.).
    let text = "Buy: https://www.amazon.in/TIMEX/dp/B0FVF here" as NSString
    let links = LinkDetection.links(in: text as String)
    try expectEqual(links.count, 1, "one URL detected")
    let folds = LinkFolding.computeFolds(links: links, activeLinkRange: nil, in: text)
    try expectEqual(folds.count, 1, "a URL with scheme+path folds to a chip")
    let fold = folds[0]
    try expectEqual(text.substring(with: fold.visibleRange), "amazon.in", "chip shows the host minus www.")
    try expect(fold.iconSlotIndex == fold.visibleRange.location - 1, "icon slot sits just before the domain")
    try expect(!fold.hiddenRanges.isEmpty, "the scheme/path is hidden")
    try expect(!fold.precededByNonSpace, "a space precedes this link")

    // The link under the caret is left expanded — excluded from the fold set.
    let active = LinkFolding.computeFolds(links: links, activeLinkRange: links[0].range, in: text)
    try expectEqual(active.count, 0, "the active link is not folded")

    // A link that directly abuts punctuation flags precededByNonSpace, and a
    // host with no www. shows in full.
    let tight = "panda :https://seikowatches.co.in/p/x end" as NSString
    let tightFolds = LinkFolding.computeFolds(links: LinkDetection.links(in: tight as String), activeLinkRange: nil, in: tight)
    try expectEqual(tightFolds.count, 1, "the tight URL folds")
    try expectEqual(tight.substring(with: tightFolds[0].visibleRange), "seikowatches.co.in", "host shown in full")
    try expect(tightFolds[0].precededByNonSpace, "a ':' immediately precedes this link")

    // Emails (mailto:, no host) stay expanded — nothing to collapse.
    let mail = "ping me@test.org now" as NSString
    let mailFolds = LinkFolding.computeFolds(links: LinkDetection.links(in: mail as String), activeLinkRange: nil, in: mail)
    try expectEqual(mailFolds.count, 0, "emails have no host to fold")

    // A bare domain (no scheme, no path) isn't worth a chip — nothing to hide.
    let bare = "amazon.in" as NSString
    let bareLink = LinkDetection.Link(range: NSRange(location: 0, length: bare.length), url: URL(string: "https://amazon.in")!)
    let bareFolds = LinkFolding.computeFolds(links: [bareLink], activeLinkRange: nil, in: bare)
    try expectEqual(bareFolds.count, 0, "a bare domain isn't folded")
}

func testListMarkerDetection() throws {
    // Line offsets: "Title"=0-4 \n5 | "- Milk"=6-11 \n12 | "* Eggs"=13-18 \n19
    // | "- [ ] open"=20-29 \n30 | "- [x] done"=31-40 \n41 | "  - indent"=42-51
    // \n52 | "---"=53-55 \n56 | "-nospace"=57-64
    let text = "Title\n- Milk\n* Eggs\n- [ ] open\n- [x] done\n  - indent\n---\n-nospace" as NSString
    let markers = ListMarkers.detect(in: text)
    try expectEqual(markers.count, 5, "five markers; the rule and the unspaced dash are ignored")

    try expectEqual(markers[0].kind, .bullet, "'- Milk' is a bullet")
    try expectEqual(markers[0].slotIndex, 6, "bullet slot is at the dash")
    try expectEqual(markers[1].kind, .bullet, "'* Eggs' is a bullet")

    try expectEqual(markers[2].kind, .checkbox(checked: false), "'- [ ]' is an unchecked box")
    try expectEqual(markers[2].slotIndex, 20, "checkbox slot is at the dash")
    try expect(markers[2].hiddenRange == NSRange(location: 21, length: 4), "the ' [ ]' chars are hidden")
    try expect(markers[2].toggleCharIndex == 23, "toggle char sits between the brackets")
    try expect(text.character(at: 23) == 0x20, "unchecked toggle char is a space")

    try expectEqual(markers[3].kind, .checkbox(checked: true), "'- [x]' is a checked box")
    try expect(markers[4].slotIndex == 44, "indented bullet's slot is after its leading spaces")

    // Variants and non-markers.
    try expect(ListMarkers.detect(in: "- [X] yes" as NSString).first?.kind == .checkbox(checked: true), "uppercase X is checked")
    try expect(ListMarkers.detect(in: "+ plus" as NSString).first?.kind == .bullet, "'+ ' is a bullet too")
    try expectEqual(ListMarkers.detect(in: "---" as NSString).count, 0, "a horizontal rule is not a bullet")
    try expectEqual(ListMarkers.detect(in: "-nospace" as NSString).count, 0, "a dash with no following space is not a bullet")
    try expectEqual(ListMarkers.detect(in: "- [x]done" as NSString).first?.kind, .bullet, "a checkbox needs a space after ']' — else it's a plain bullet")
    try expectEqual(ListMarkers.detect(in: "" as NSString).count, 0, "empty text has no markers")
}

func testStoragePinnedStatePersists() throws {
    // isPinned is a persisted field (model + NoteMetadata). Like isLocked, it
    // must survive the round-trip — otherwise pins vanish on app restart.
    try withTemporaryStorage { manager, _ in
        var note = Note(title: "Idea", content: "build a thing", isPinned: true)
        try expectSuccess(manager.saveNote(note), "pinned note should save")
        try expectEqual(manager.loadNotes().first?.isPinned, true, "isPinned should persist across save/load")

        note.isPinned = false
        try expectSuccess(manager.saveNote(note), "unpin save should succeed")
        try expectEqual(manager.loadNotes().first?.isPinned, false, "unpin should persist across save/load")
    }
}

func testSearchNormalization() throws {
    // searchNormalized = searchFolded + lowercased — the case-insensitive scan
    // key behind sidebar/⌘K filtering (v2.19.5). Unlike searchFolded it is not
    // 1:1 in UTF-16, so it's only for membership scans, never range mapping.
    try expectEqual("Don\u{2019}T".searchNormalized, "don't", "folds the curly apostrophe and lowercases")
    try expectEqual("HELLO".searchNormalized, "hello", "lowercases ASCII")
    try expectEqual("A \u{2014} B".searchNormalized, "a - b", "folds the em dash and lowercases")
    try expectEqual("CAF\u{00C9}".searchNormalized, "caf\u{00E9}", "non-folded scalars (É) just lowercase")

    // The modifier-letter apostrophe (ʼ, U+02BC) also folds in searchFolded.
    try expectEqual("can\u{02BC}t".searchFolded, "can't", "modifier-letter apostrophe folds to straight")
}

let tests: [(String, () throws -> Void)] = [
    ("Note model derived text", testNoteModelDerivedText),
    ("Editor preferences font sizing", testEditorPreferencesFontSizing),
    ("Sidebar width clamping", testSidebarWidthClamping),
    ("Graphite editor contrast", testGraphiteEditorContrast),
    ("Vim normal motions and counts", testVimNormalModeMotionsAndCounts),
    ("Vim insert, replace, and command modes", testVimInsertReplaceAndCommandModes),
    ("Vim operators, text objects, and repeats", testVimOperatorsTextObjectsAndRepeats),
    ("Vim find, search, visual, and control parsing", testVimFindSearchVisualAndControlParsing),
    ("Vim word-under-cursor extraction", testVimWordUnderCursorExtraction),
    ("Vim additional actions (Y/J/s/S/r/zz)", testVimAdditionalActions),
    ("Vim visual counts, paste, and case operators", testVimVisualCountsPasteAndCaseOps),
    ("Vim marks and :noh", testVimMarksAndNoh),
    ("Image Markdown helpers", testImageMarkdownHelpers),
    ("Storage image assets", testStorageImageAssets),
    ("Notes view-model filtering", testNotesViewModelFiltering),
    ("Vim command execution", testVimCommandExecution),
    ("Vim / search via keyDown", testVimSlashSearchViaKeyDown),
    ("Vim linewise paste on last line", testVimLinewisePasteLastLine),
    ("Vim till-repeat advances (t/T + ;/,)", testVimTillRepeatAdvances),
    ("Storage round-trip, rename, collision, and RTF", testStorageRoundTripRenameCollisionAndRTF),
    ("Storage malformed files and write errors", testStorageMalformedFilesAndWriteErrors),
    ("Command Palette search matching", testCommandPaletteSearchMatching),
    ("Fuzzy search and palette ranking", testFuzzySearchAndRanking),
    ("Search smart-quote folding", testSearchQuoteFolding),
    ("Link detection and gd", testLinkDetectionAndGx),
    ("Link folding (computeFolds)", testLinkFoldingComputeFolds),
    ("List marker detection (bullets/checkboxes)", testListMarkerDetection),
    ("Storage pinned-state persistence", testStoragePinnedStatePersists),
    ("Search normalization (fold + lowercase)", testSearchNormalization)
]

do {
    for (name, test) in tests {
        try test()
        print("PASS: \(name)")
    }
    print("All smoke tests passed")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
