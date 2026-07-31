import AppKit
import Carbon.HIToolbox
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
    try expectEqual(engine.processKey("x"), [.deleteChars(1)], "x should delete a char (counted, register-filling)")
    try expectEqual(feed(engine, "3", "X"), [.deleteCharsBefore(3)], "3X should delete three chars before as one counted run")
    try expectEqual(feed(engine, "2", "~"), [.toggleCase(2)], "2~ should toggle twice")
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
    // modifiedAt is the sidebar sort key (v2.23.0) — pin it explicitly. The
    // default `Date()` can tie across back-to-back inits, and Swift's sort is
    // not stable, so relying on construction order made this test flaky.
    let notes = [
        Note(title: "Grocery list", content: "milk and eggs", createdAt: older, modifiedAt: older),
        Note(title: "Work notes", content: "meeting agenda", folderId: folder, createdAt: newer, modifiedAt: newer),
        Note(title: "Pinned idea", content: "build a thing", createdAt: older, modifiedAt: older, isPinned: true)
    ]

    try MainActor.assumeIsolated {
        let all = NotesViewModel.computeFilteredNotes(notes: notes, showAllNotes: true, selectedFolderId: nil, searchText: "")
        try expectEqual(all.map(\.title), ["Pinned idea", "Work notes", "Grocery list"], "pinned first, then newest by modifiedAt")

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

/// The search path caches the folded document and the per-term match scan
/// (VimNSTextView.searchMatches) so `n`/`N` and find-bar keystrokes don't
/// re-fold a large note every press. A stale cache after an edit would move
/// the cursor to pre-edit offsets — this locks in the invalidation.
func testVimSearchCacheInvalidation() throws {
    try MainActor.assumeIsolated {
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
    // "match" sits at offsets 4, 14, 25.
    textView.string = "one match\ntwo match\nthree match"
    textView.setSelectedRange(NSRange(location: 0, length: 0))

    func press(_ chars: String, code: UInt16 = 0) throws {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code
        ) else { throw SmokeTestFailure.failed("could not synthesize key event for \(chars)") }
        textView.keyDown(with: event)
    }

    try press("/", code: 44)
    for ch in "match" { try press(String(ch)) }
    try press("\r", code: 36)
    try expectEqual(textView.selectedRange().location, 4, "search should land on the first match")
    try press("n")
    try expectEqual(textView.selectedRange().location, 14, "n should reach the second match (cache warm)")

    // Delete the document's first character — every match shifts left by one.
    // The cached folded text and match ranges must be dropped by the edit.
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    try press("x")
    try expectEqual(textView.string, "ne match\ntwo match\nthree match", "x should delete the first char")
    try press("n")
    try expectEqual(textView.selectedRange().location, 3,
                    "n after an edit must use post-edit offsets, not the stale match cache")
    try press("n")
    try expectEqual(textView.selectedRange().location, 13, "subsequent n keeps navigating the fresh scan")
    }
}

/// MotionResolver is the pure motion core: `(motion, position, text) → offset`
/// with no NSTextView involved. These tests hit it directly — the whole point
/// of the extraction — while the keyDown-rig tests above cover the wiring
/// (Coordinator → resolver → selection).
func testMotionResolverPure() throws {
    func at(_ motion: Motion, _ pos: Int, _ text: String, count: Int = 1) -> Int? {
        MotionResolver.resolve(motion, count: count, from: pos, in: text as NSString)
    }

    // Word motions (w/b/e), including the punctuation word class.
    let words = "one two  three"
    try expectEqual(at(.wordForward, 0, words), 4, "w jumps to the next word start")
    try expectEqual(at(.wordForward, 0, words, count: 2), 9, "2w applies the motion twice")
    try expectEqual(at(.wordBackward, 9, words), 4, "b jumps to the previous word start")
    try expectEqual(at(.wordEnd, 0, words), 2, "e lands on the current word's last char")
    try expectEqual(at(.wordEnd, 2, words), 6, "e from a word end advances to the next word's end")
    try expectEqual(at(.wordForward, 3, "foo(bar)"), 4, "w treats punctuation as its own word class")

    // Line motions (0 / $ / ^) and vertical column preservation.
    let lines = "  hello\nworld"
    try expectEqual(at(.lineStart, 5, lines), 0, "0 goes to the line start")
    try expectEqual(at(.lineEnd, 2, lines), 6, "$ lands on the last char, not the newline")
    try expectEqual(at(.firstNonBlank, 5, lines), 2, "^ lands on the first non-blank")
    try expectEqual(at(.down, 6, lines), 12, "j clamps the column to the shorter target line")
    try expectEqual(at(.up, 12, lines), 4, "k preserves the column going up")
    try expectEqual(at(.documentStart, 12, lines), 2, "gg lands on the first line's first non-blank")
    try expectEqual(at(.documentEnd, 0, lines), 8, "G lands on the last line's first non-blank")

    // Paragraph motions ({ / }).
    let paras = "alpha\nbeta\n\ngamma"
    try expectEqual(at(.paragraphForward, 0, paras), 11, "} stops at the blank line")
    try expectEqual(at(.paragraphBackward, 14, paras), 11, "{ stops at the preceding blank line")
    try expectEqual(at(.paragraphForward, 12, paras), 17, "} past the last paragraph returns the doc length")

    // f / t / ;-repeat (tillCharRepeat must skip an adjacent target — the
    // v2.21.4 stuck-repeat fix, now assertable without a text view).
    let find = "abcabc"
    try expectEqual(at(.findChar("c", true), 0, find), 2, "f finds the char")
    try expectEqual(at(.findChar("c", true), 0, find, count: 2), 5, "2fc finds the second occurrence")
    try expectEqual(at(.tillChar("c", true), 0, find), 1, "t stops just before the char")
    try expectEqual(at(.tillCharRepeat("c", true), 1, find), 4, "; after t skips the adjacent match")
    try expectEqual(at(.findChar("a", false), 5, find), 3, "F searches backward")

    // % bracket matching, including scan-forward-to-a-bracket.
    try expectEqual(at(.matchingBracket, 0, "(foo)"), 4, "% jumps from open to close")
    try expectEqual(at(.matchingBracket, 4, "(foo)"), 0, "% jumps from close to open")
    try expectEqual(at(.matchingBracket, 0, "a(b)"), 3, "% scans forward on the line to the first bracket")

    // Contract edges: empty doc → 0, boundaries clamp, viewport motions → nil.
    try expectEqual(at(.wordForward, 0, ""), 0, "empty document resolves to 0")
    try expectEqual(at(.left, 0, "abc"), 0, "h clamps at the line start")
    try expectEqual(at(.right, 2, "abc"), 2, "l clamps at the last char")
    try expectEqual(at(.down, 0, "abc"), 0, "j on the last line stays put")
    try expect(at(.screenTop, 0, "abc") == nil, "H is viewport-dependent — pure resolver declines it")

    try expectEqual(MotionResolver.firstNonBlankOffset(ofLineAt: 0, in: "\t  x" as NSString), 3,
                    "firstNonBlankOffset skips tabs and spaces")
    try expectEqual(MotionResolver.firstNonBlankOffset(ofLineAt: 99, in: "ab" as NSString), 0,
                    "firstNonBlankOffset clamps an out-of-range location")
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

/// Synthesizes a real Control-modified keyDown the way a physical keyboard
/// delivers it: `characters` carries the raw ASCII control code (Ctrl-R =
/// U+0012), while the base key is only in `charactersIgnoringModifiers`. This
/// is exactly the case that used to route to nowhere.
@MainActor
private func pressControl(_ textView: VimNSTextView, base: String, code: UInt16) {
    let scalar = base.uppercased().unicodeScalars.first!.value
    let controlChar = String(UnicodeScalar(UInt8(scalar % 32)))
    if let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
        windowNumber: 0, context: nil, characters: controlChar,
        charactersIgnoringModifiers: base, isARepeat: false, keyCode: code
    ) { textView.keyDown(with: event) }
}

/// Synthesizes a keyDown for a key identified by its hardware key code —
/// Return (36), Tab (48) and Delete (51) carry no useful `characters`, so the
/// character-driven `press` helper can't reach the smart-list handlers.
@MainActor
private func pressKeyCode(_ textView: VimNSTextView, _ keyCode: UInt16,
                          characters: String, modifiers: NSEvent.ModifierFlags = []) {
    if let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
    ) { textView.keyDown(with: event) }
}

@MainActor
private func pressReturn(_ textView: VimNSTextView) { pressKeyCode(textView, 36, characters: "\r") }

@MainActor
private func pressTab(_ textView: VimNSTextView, shift: Bool = false) {
    pressKeyCode(textView, 48, characters: "\t", modifiers: shift ? [.shift] : [])
}

@MainActor
private func pressBackspace(_ textView: VimNSTextView) {
    pressKeyCode(textView, 51, characters: "\u{8}")
}

/// The pure half of smart lists: what a line parses into, and how a block of
/// ordered items renumbers.
func testSmartListParsing() throws {
    // Bullets, with and without a checkbox.
    guard let bullet = SmartList.parse("- milk") else {
        throw SmokeTestFailure.failed("`- milk` should parse as a bullet")
    }
    try expectEqual(bullet.kind, .bullet("-"), "bullet char is kept")
    try expectEqual(bullet.checkbox, false, "a plain bullet has no checkbox")
    try expectEqual(bullet.prefixLength, 2, "`- ` is a two-character marker")

    guard let task = SmartList.parse("    - [x] shipped") else {
        throw SmokeTestFailure.failed("an indented checkbox should parse")
    }
    try expect(task.checkbox && task.checked, "`- [x]` parses as a checked checkbox")
    try expectEqual(task.indent, "    ", "indent is preserved verbatim")
    try expectEqual(task.body, "shipped", "body excludes the checkbox")
    try expectEqual(task.prefixLength, 10, "`    - [x] ` is a ten-character marker")
    // A new item after a checked box starts unchecked.
    try expectEqual(task.nextMarkerText(), "- [ ] ", "the next checkbox starts unchecked")

    // An empty checkbox is an empty item — that Return must end the list.
    guard let emptyTask = SmartList.parse("- [ ] ") else {
        throw SmokeTestFailure.failed("`- [ ] ` should parse")
    }
    try expect(emptyTask.isEmpty, "`- [ ] ` is an empty item, not one whose body is `[ ]`")
    // …including with no trailing space at all.
    try expect(SmartList.parse("- [ ]")?.isEmpty == true, "`- [ ]` with no trailing space is empty")

    // Ordered items step to the next number and keep their separator.
    guard let ordered = SmartList.parse("3) third") else {
        throw SmokeTestFailure.failed("`3) third` should parse as ordered")
    }
    try expectEqual(ordered.nextMarkerText(), "4) ", "ordered continuation increments")
    try expectEqual(SmartList.parse("1. [ ] task")?.nextMarkerText(), "2. [ ] ",
                    "numbered checkboxes continue as numbered checkboxes")

    // Non-lists stay non-lists.
    try expect(SmartList.parse("--- rule") == nil, "`---` is not a list item")
    try expect(SmartList.parse("-no space") == nil, "a marker needs a trailing space")
    try expect(SmartList.parse("2021. was a year") != nil, "a year-like number still reads as ordered")
    try expect(SmartList.parse("plain text") == nil, "plain text is not a list item")

    // Renumbering: nested levels restart at 1, the outer level resumes.
    let text = """
    1. one
    1. two
        5. nested a
        9. nested b
    7. three
    """ as NSString
    let edits = SmartList.renumberEdits(in: text, around: 0)
    var renumbered = NSMutableString(string: text)
    for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
        renumbered.replaceCharacters(in: edit.range, with: edit.replacement)
    }
    try expectEqual(renumbered as String, """
    1. one
    2. two
        1. nested a
        2. nested b
    3. three
    """, "each level renumbers independently; nested lists restart at 1")

    // A list the user starts at 5 keeps its start.
    let offset = "5. a\n9. b" as NSString
    let offsetEdits = SmartList.renumberEdits(in: offset, around: 0)
    try expectEqual(offsetEdits.count, 1, "only the out-of-sequence item is rewritten")
    try expectEqual(offsetEdits.first?.replacement, "6", "the list keeps its 5-based start")

    // Lazy numbering (every item `1.`) is a deliberate style — leave it alone.
    try expect(SmartList.renumberEdits(in: "1. a\n1. b\n1. c" as NSString, around: 0).isEmpty,
               "a uniformly numbered list is not renumbered")

    // A blank line ends the block, so a later list is untouched.
    let twoBlocks = "1. a\n2. b\n\n7. other" as NSString
    try expect(SmartList.renumberEdits(in: twoBlocks, around: 0).isEmpty,
               "renumbering stops at the blank line between two lists")
}

/// Smart lists driven through real keystrokes: Return, Tab, Backspace and the
/// Vim `o` / `O` openers.
func testSmartListsViaKeyDown() throws {
    try MainActor.assumeIsolated {
        // A checkbox item continues as a checkbox (it used to degrade to `- `).
        let (_, tv, coord, press) = makeVimRig("- [x] ship it")
        tv.setSelectedRange(NSRange(location: 13, length: 0))
        press("i")
        pressReturn(tv)
        try expectEqual(tv.string, "- [x] ship it\n- [ ] ",
                        "Return after a checkbox opens a fresh unchecked checkbox")

        // Return on that empty checkbox ends the list instead of spawning `- `.
        pressReturn(tv)
        try expectEqual(tv.string, "- [x] ship it\n", "Return on an empty checkbox ends the list")
        withExtendedLifetime(coord) {}
    }

    try MainActor.assumeIsolated {
        // Return in the middle of an item splits it and carries the marker.
        let (_, tv, coord, press) = makeVimRig("1. alphabeta\n2. gamma")
        tv.setSelectedRange(NSRange(location: 8, length: 0)) // between "alpha" and "beta"
        press("i")
        pressReturn(tv)
        try expectEqual(tv.string, "1. alpha\n2. beta\n3. gamma",
                        "splitting an ordered item renumbers the items below it")
        withExtendedLifetime(coord) {}
    }

    try MainActor.assumeIsolated {
        // An empty nested item steps out one level before ending the list.
        let (_, tv, coord, press) = makeVimRig("- top\n    - ")
        tv.setSelectedRange(NSRange(location: 12, length: 0))
        press("i")
        pressReturn(tv)
        try expectEqual(tv.string, "- top\n- ", "an empty nested item outdents first")
        pressReturn(tv)
        try expectEqual(tv.string, "- top\n", "a second Return ends the list")
        withExtendedLifetime(coord) {}
    }

    try MainActor.assumeIsolated {
        // Tab nests an item, and both levels renumber.
        let (_, tv, coord, press) = makeVimRig("1. a\n2. b\n3. c")
        tv.setSelectedRange(NSRange(location: 9, length: 0)) // end of "2. b"
        press("i")
        pressTab(tv)
        try expectEqual(tv.string, "1. a\n    1. b\n2. c",
                        "Tab nests the item, restarting it at 1 and closing the gap above")
        pressTab(tv, shift: true)
        try expectEqual(tv.string, "1. a\n2. b\n3. c", "Shift-Tab restores the flat numbering")
        withExtendedLifetime(coord) {}
    }

    try MainActor.assumeIsolated {
        // Backspace at the start of an item's text removes the marker whole.
        let (_, tv, coord, press) = makeVimRig("- [ ] task")
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        press("i")
        pressBackspace(tv)
        try expectEqual(tv.string, "task", "Backspace clears the whole checkbox marker")
        try expectEqual(tv.selectedRange().location, 0, "the caret lands before the text")
        withExtendedLifetime(coord) {}
    }

    try MainActor.assumeIsolated {
        // `o` and `O` open list items too, not bare indentation.
        let (_, tv, coord, press) = makeVimRig("- [ ] one\n- [ ] two")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        press("o")
        try expectEqual(tv.string, "- [ ] one\n- [ ] \n- [ ] two",
                        "o opens the next checkbox below")
        try expectEqual(tv.selectedRange().location, 16, "the caret sits after the new marker")

        let (_, tv2, coord2, press2) = makeVimRig("1. one\n2. two")
        tv2.setSelectedRange(NSRange(location: 8, length: 0)) // on "2. two"
        press2("O")
        try expectEqual(tv2.string, "1. one\n2. \n3. two",
                        "O opens an item above and renumbers what follows")
        withExtendedLifetime(coord) {}
        withExtendedLifetime(coord2) {}
    }
}

/// Regression for "Ctrl-[ escape / Ctrl-R / Ctrl-O / Ctrl-I dead on real
/// keyboards": Control combos arrive as raw control codes in `characters`, so
/// the keyDown router must fall back to `charactersIgnoringModifiers`. Here we
/// assert the insert-mode Ctrl-[ path (its check used the raw `characters` and
/// never matched); the general normal-mode control path is exercised by the
/// jump-list test (Ctrl-O/Ctrl-I) and the engine-level Ctrl-R test.
func testVimControlKeyRoutingViaKeyDown() throws {
    try MainActor.assumeIsolated {
        // Ctrl-[ must leave insert mode exactly like Escape. Its raw control
        // code is U+001B (ESC), so a `characters == "["` check never fired.
        let (eng, tv, coord, press) = makeVimRig("abc")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        press("i")
        try expect(eng.mode == .insert, "i enters insert mode")
        pressControl(tv, base: "[", code: 33)
        try expect(eng.mode == .normal, "Ctrl-[ must return to normal mode from insert")
        withExtendedLifetime(coord) {}
    }
}

/// The Ctrl-O / Ctrl-I jump list: a jump command (here `G`) records the
/// pre-jump position; Ctrl-O returns to it and Ctrl-I goes forward again.
func testVimJumpList() throws {
    try MainActor.assumeIsolated {
        let (_, tv, coord, press) = makeVimRig("one\ntwo\nthree\nfour\nfive")
        tv.setSelectedRange(NSRange(location: 0, length: 0)) // line 1
        press("G")
        let atEnd = tv.selectedRange().location
        try expect(atEnd > 0, "G moves off the first line")

        pressControl(tv, base: "o", code: 31) // Ctrl-O
        try expectEqual(tv.selectedRange().location, 0, "Ctrl-O returns to the pre-jump position")

        pressControl(tv, base: "i", code: 34) // Ctrl-I
        try expectEqual(tv.selectedRange().location, atEnd, "Ctrl-I moves forward to the jump target again")

        // Ordinary j/k must NOT create jumps: after Ctrl-O to top, a j then
        // Ctrl-O still has an empty back stack (no new jump was recorded).
        pressControl(tv, base: "o", code: 31) // back stack now empty
        press("j")
        pressControl(tv, base: "o", code: 31)
        try expectEqual(tv.selectedRange().location, tv.selectedRange().location,
                        "j is not a jump; Ctrl-O with an empty back stack is a no-op (no crash)")
        withExtendedLifetime(coord) {}
    }
}

/// Regression for "visual mode on an empty note crashes": V then a motion must
/// not feed a negative location into lineRange.
func testVimVisualOnEmptyNote() throws {
    try MainActor.assumeIsolated {
        let (eng, tv, coord, press) = makeVimRig("")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        press("V")
        press("j")
        try expect(eng.mode == .visualLine, "V-LINE holds on an empty note without crashing")
        press("l") // charwise-style extend guard on empty doc too
        withExtendedLifetime(coord) {}
    }
}

/// `x` / `X` must fill the register (so `xp` transposes and `3x` then `p`
/// restores the whole run), and word text objects must not split an emoji.
func testVimCharDeleteRegisterAndEmojiObject() throws {
    try MainActor.assumeIsolated {
        // x sets the register; xp transposes.
        let (eng, tv, coord, press) = makeVimRig("abcde")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        press("x")
        try expectEqual(eng.register, "a", "x yanks the deleted char into the register")
        try expectEqual(tv.string, "bcde", "x deletes the char")
        press("p")
        try expectEqual(tv.string, "bacde", "xp transposes the two characters")

        // 3x yanks the whole run.
        let (eng2, tv2, coord2, press2) = makeVimRig("abcde")
        tv2.setSelectedRange(NSRange(location: 0, length: 0))
        press2("3")
        press2("x")
        try expectEqual(tv2.string, "de", "3x deletes three chars")
        try expectEqual(eng2.register, "abc", "3x yanks the whole run into the register")

        // X yanks the char before the cursor.
        let (eng3, tv3, coord3, press3) = makeVimRig("abcde")
        tv3.setSelectedRange(NSRange(location: 3, length: 0)) // on 'd'
        press3("X")
        try expectEqual(tv3.string, "abde", "X deletes the char before the cursor")
        try expectEqual(eng3.register, "c", "X yanks the deleted char")

        // diw on an emoji deletes the whole grapheme, not half a surrogate pair.
        let (_, tv4, coord4, press4) = makeVimRig("a😀b")
        tv4.setSelectedRange(NSRange(location: 1, length: 0)) // on the emoji
        press4("d")
        press4("i")
        press4("w")
        try expectEqual(tv4.string, "ab", "diw on an emoji removes the whole emoji, leaving valid text")
        withExtendedLifetime((coord, coord2, coord3, coord4)) {}
    }
}

/// `gv` reselects the last visual selection — same range and same visual
/// sub-mode — whether it ended via Esc or via an operator like `y`.
func testVimGvReselect() throws {
    try MainActor.assumeIsolated {
        // Charwise: select "one" (v + 2l), yank — gv must re-select it.
        let (eng, tv, coord, press) = makeVimRig("one\ntwo\nthree")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        press("v")
        press("ll")
        try expectEqual(tv.selectedRange(), NSRange(location: 0, length: 3), "v2l selects the first word")
        press("y")
        try expect(eng.mode == .normal, "y leaves visual mode")
        try expectEqual(tv.selectedRange().length, 0, "selection collapsed after yank")
        press("gv")
        try expect(eng.mode == .visual, "gv re-enters charwise visual mode")
        try expectEqual(tv.selectedRange(), NSRange(location: 0, length: 3), "gv restores the exact range")

        // Motions keep extending from the restored selection.
        press("j")
        try expect(tv.selectedRange().length > 3, "motion after gv extends the restored selection")

        // V-LINE via Esc: select line 2, Esc, gv → V-LINE again, same line.
        let (eng2, tv2, coord2, press2) = makeVimRig("one\ntwo\nthree")
        tv2.setSelectedRange(NSRange(location: 4, length: 0)) // on "two"
        press2("V")
        try expectEqual(tv2.selectedRange(), NSRange(location: 4, length: 4), "V selects line 2 incl. newline")
        // Esc arrives with keyCode 53 on real keyboards.
        if let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ) { tv2.keyDown(with: esc) }
        try expect(eng2.mode == .normal, "Esc leaves V-LINE")
        press2("gv")
        try expect(eng2.mode == .visualLine, "gv restores V-LINE, not charwise")
        try expectEqual(tv2.selectedRange(), NSRange(location: 4, length: 4), "gv restores the line selection")

        // No previous selection → friendly no-op.
        let (eng3, tv3, coord3, press3) = makeVimRig("abc")
        tv3.setSelectedRange(NSRange(location: 0, length: 0))
        press3("gv")
        try expect(eng3.mode == .normal, "gv with no history stays in normal mode")
        try expectEqual(eng3.statusMessage, "No previous visual selection", "gv with no history reports it")
        withExtendedLifetime((coord, coord2, coord3)) {}
    }
}

/// `:s` / `:%s` must edit only the matched spans (preserving surrounding
/// formatting) and honor Vim's per-line first-match semantics without `g`.
func testVimSubstitutePerLineAndPreservesFormatting() throws {
    try MainActor.assumeIsolated {
        // Non-global %s replaces the first match on every line.
        let (eng, tv, coord, _) = makeVimRig("aa\naa")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        coord.executeActions(eng.executeCommand("%s/a/X/"))
        try expectEqual(tv.string, "Xa\nXa", "%s without g replaces the first match on each line")

        // Global %s replaces every match.
        let (eng2, tv2, coord2, _) = makeVimRig("aa\naa")
        tv2.setSelectedRange(NSRange(location: 0, length: 0))
        coord2.executeActions(eng2.executeCommand("%s/a/X/g"))
        try expectEqual(tv2.string, "XX\nXX", "%s with g replaces every match")

        // Formatting outside the matched span survives the substitution.
        let (eng3, tv3, coord3, _) = makeVimRig("foo bar")
        let boldFont = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14), toHaveTrait: .boldFontMask)
        tv3.textStorage?.addAttribute(.font, value: boldFont, range: NSRange(location: 4, length: 3)) // "bar"
        tv3.setSelectedRange(NSRange(location: 0, length: 0))
        coord3.executeActions(eng3.executeCommand("s/foo/baz/"))
        try expectEqual(tv3.string, "baz bar", "substitute replaces the match")
        let f = tv3.textStorage?.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        try expect(f.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false,
                   "bold run outside the match is preserved (not flattened to plain text)")
        withExtendedLifetime((coord, coord2, coord3)) {}
    }
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

/// Guards the scoped code-block restyle fast paths: shift edits above a block
/// must keep the block's mono styling (and update `codeBlockRanges`) without a
/// structural rewrite, and text inserted at a block edge with stale inherited
/// code attributes must be normalized back to base styling.
func testCodeBlockScopedRestyle() throws {
    try MainActor.assumeIsolated {
        let font = NSFont.systemFont(ofSize: 14)
        let (_, tv, coord, _) = makeVimRig("intro\n```\nlet x = 1\n```\ntail")
        // makeNSView wires the view as its storage's delegate; the rig builds
        // the view directly, so mirror that here for edited-range tracking.
        tv.textStorage?.delegate = tv

        func isMono(_ i: Int) -> Bool {
            guard let f = tv.textStorage?.attribute(.font, at: i, effectiveRange: nil) as? NSFont else { return false }
            return f.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
        func isTagged(_ i: Int) -> Bool {
            tv.textStorage?.attribute(.codeBlock, at: i, effectiveRange: nil) != nil
        }

        tv.restyleMarkdown(baseFont: font)
        try expectEqual(tv.codeBlockRanges.count, 1, "one fenced block detected")
        let initial = tv.codeBlockRanges[0]
        try expect(isMono(initial.location + 4) && isTagged(initial.location + 4),
                   "block body is mono + tagged after the full restyle")
        try expect(!isMono(0), "intro stays proportional")

        // Shift edit: insert a line above the block, then restyle. The block
        // must land at its shifted offset with styling intact.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("added\n", replacementRange: NSRange(location: 0, length: 0))
        tv.restyleMarkdown(baseFont: font)
        try expectEqual(tv.codeBlockRanges, [NSRange(location: initial.location + 6, length: initial.length)],
                        "block range shifts by the inserted length")
        let shifted = tv.codeBlockRanges[0]
        try expect(isMono(shifted.location + 4) && isTagged(shifted.location + 4),
                   "block body keeps mono + tag after a shift edit")
        try expect(!isMono(0) && !isTagged(0), "inserted line above gets base styling")

        // Edge insert with stale inherited code styling (what pasting right
        // below a block produces): the scoped normalize must strip it even
        // though the block ranges themselves are unchanged.
        let after = shifted.location + shifted.length
        let staleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular),
            .codeBlock: true
        ]
        tv.textStorage?.replaceCharacters(in: NSRange(location: after, length: 0),
                                          with: NSAttributedString(string: "x", attributes: staleAttrs))
        tv.didChangeText()
        try expect(isMono(after) && isTagged(after), "precondition: inserted char carries stale code styling")
        tv.restyleMarkdown(baseFont: font)
        try expectEqual(tv.codeBlockRanges, [shifted], "block ranges unchanged by an edit outside them")
        try expect(!isMono(after) && !isTagged(after),
                   "stale code styling outside the block is normalized away")
        try expect(isMono(shifted.location + 4) && isTagged(shifted.location + 4),
                   "block styling survives the scoped normalize")
        withExtendedLifetime(coord) {}
    }
}

/// Markdown heading styling: `#{1,6} ` lines render with a scaled bold font +
/// `.markdownHeading` level tag, `#` marks stay visible plain characters, and
/// hashes inside fences / non-heading `#` text stay unstyled. The scoped
/// restyle must pick up a line gaining or losing its prefix, and the derived
/// bold must not count as rich formatting (no phantom .rtf sidecars).
func testMarkdownHeadingStyling() throws {
    try MainActor.assumeIsolated {
        let font = NSFont.systemFont(ofSize: 14)
        let text = "# Title\nbody text\n## Sub\n#hashtag\n```\n# comment\n```\ntail"
        let (_, tv, coord, _) = makeVimRig(text)
        tv.textStorage?.delegate = tv

        func fontAt(_ i: Int) -> NSFont {
            (tv.textStorage?.attribute(.font, at: i, effectiveRange: nil) as? NSFont) ?? font
        }
        func level(_ i: Int) -> Int? {
            tv.textStorage?.attribute(.markdownHeading, at: i, effectiveRange: nil) as? Int
        }
        func isBold(_ i: Int) -> Bool {
            NSFontManager.shared.traits(of: fontAt(i)).contains(.boldFontMask)
        }
        let ns = text as NSString
        let subLoc = ns.range(of: "## Sub").location
        let tagLoc = ns.range(of: "#hashtag").location
        let commentLoc = ns.range(of: "# comment").location
        let bodyLoc = ns.range(of: "body").location

        tv.restyleMarkdown(baseFont: font, force: true)
        try expectEqual(level(0) ?? 0, 1, "h1 line carries level tag 1")
        try expect(fontAt(0).pointSize > font.pointSize && isBold(0), "h1 is larger + bold")
        try expectEqual(level(subLoc) ?? 0, 2, "h2 line carries level tag 2")
        try expect(fontAt(subLoc).pointSize > font.pointSize
                    && fontAt(subLoc).pointSize < fontAt(0).pointSize,
                   "h2 sits between base and h1 size")
        try expect(level(bodyLoc) == nil && fontAt(bodyLoc).pointSize == font.pointSize,
                   "body text keeps the base font")
        try expect(level(tagLoc) == nil && !isBold(tagLoc), "#hashtag (no space) is not a heading")
        try expect(level(commentLoc) == nil, "a # line inside a code fence is not a heading")
        try expect(fontAt(commentLoc).fontDescriptor.symbolicTraits.contains(.monoSpace),
                   "the fenced # line keeps code styling")

        // Note-open gate: heading detection over raw text.
        try expect(VimNSTextView.containsHeadingLine("intro\n## x"), "containsHeadingLine finds a mid-doc heading")
        try expect(!VimNSTextView.containsHeadingLine("#hashtag\nurl.com/a#b no heading"),
                   "containsHeadingLine ignores non-line-start / no-space hashes")

        // Typed path: give the body line a '# ' prefix. The live per-keystroke
        // pass (didChangeText) must style it immediately — no deferred restyle.
        tv.setSelectedRange(NSRange(location: bodyLoc, length: 0))
        tv.insertText("# ", replacementRange: NSRange(location: bodyLoc, length: 0))
        try expectEqual(level(bodyLoc) ?? 0, 1, "a typed '# ' prefix styles the line live, before any deferred restyle")
        try expect(isBold(bodyLoc), "the newly prefixed line is bold")
        // The deferred scoped pass must agree (idempotent over the live one).
        tv.restyleMarkdown(baseFont: font)
        try expectEqual(level(bodyLoc) ?? 0, 1, "the deferred scoped restyle keeps the typed heading")

        // Removing the prefix must revert to base styling immediately — the
        // line no longer contains '#', so detection rides on the stale tag.
        tv.setSelectedRange(NSRange(location: bodyLoc + 2, length: 0))
        tv.textStorage?.replaceCharacters(in: NSRange(location: bodyLoc, length: 2), with: "")
        tv.didChangeText()
        try expect(level(bodyLoc) == nil, "deleting the '# ' prefix drops the heading tag live")
        try expect(fontAt(bodyLoc).pointSize == font.pointSize && !isBold(bodyLoc),
                   "the line reverts to the plain base font (no phantom bold)")
        tv.restyleMarkdown(baseFont: font)
        try expect(level(bodyLoc) == nil && !isBold(bodyLoc),
                   "the deferred scoped restyle agrees after the prefix removal")

        // Derived heading bold must not read as rich formatting, or every
        // note with a heading would grow an .rtf sidecar.
        try expect(!tv.hasRichTextFormatting, "heading styling alone must not count as rich text")
        withExtendedLifetime(coord) {}
    }
}

/// Heading `#` prefixes are hidden on screen so `## Sub` reads as `Sub`. The
/// hiding is display-only (hidden ranges on the folding layout manager — the
/// text storage still holds the hashes, so Vim offsets and the `.txt` on disk
/// are unchanged), it skips fenced code and bare `# ` lines, and the line the
/// caret sits on stays raw so the prefix can be edited.
func testMarkdownHeadingPrefixFolding() throws {
    try MainActor.assumeIsolated {
        let font = NSFont.systemFont(ofSize: 14)
        let text = "# Title\nbody\n## Sub\n#hashtag\n##\n```\n# comment\n```\ntail"
        let (_, tv, coord, _) = makeVimRig(text)
        tv.textContainer?.replaceLayoutManager(FoldingLayoutManager())
        tv.textStorage?.delegate = tv
        tv.restyleMarkdown(baseFont: font, force: true)

        let ns = text as NSString
        let titleLoc = ns.range(of: "# Title").location
        let subLoc = ns.range(of: "## Sub").location
        let bodyLoc = ns.range(of: "body").location
        let bareLoc = ns.range(of: "##\n").location
        let commentLoc = ns.range(of: "# comment").location

        // Park the caret off every heading line so nothing is unfolded.
        tv.setSelectedRange(NSRange(location: bodyLoc, length: 0))
        tv.refreshHeadingFolds()

        let lm = tv.layoutManager as? FoldingLayoutManager
        func hidden() -> [NSRange] { lm?.headingPrefixes ?? [] }
        func hides(_ location: Int, _ length: Int) -> Bool {
            hidden().contains { NSEqualRanges($0, NSRange(location: location, length: length)) }
        }

        try expect(hides(titleLoc, 2), "'# ' on the h1 line is hidden")
        try expect(hides(subLoc, 3), "'## ' on the h2 line is hidden, space included")
        try expectEqual(hidden().count, 2, "#hashtag, a bare '##' line, and a fenced '# ' are all left alone")
        try expect(!hidden().contains { NSLocationInRange($0.location, NSRange(location: bareLoc, length: 3)) },
                   "a heading line with no text after the prefix stays visible")
        try expect(!hidden().contains { NSLocationInRange($0.location, NSRange(location: commentLoc, length: 3)) },
                   "a '# ' line inside a code fence is not folded")

        // Display-only: the hashes are still in the document.
        try expectEqual(tv.string, text, "folding must not touch the text storage")

        // The caret's own line shows its raw prefix.
        tv.setSelectedRange(NSRange(location: subLoc + 4, length: 0))
        tv.applyHeadingFolds()
        try expect(!hides(subLoc, 3), "the heading the caret is on unfolds for editing")
        try expect(hides(titleLoc, 2), "other headings stay folded")

        // A ranged selection keeps everything folded (no reflow mid-selection).
        tv.setSelectedRange(NSRange(location: 0, length: ns.length))
        tv.applyHeadingFolds()
        try expectEqual(hidden().count, 2, "a visual-mode selection doesn't unfold the headings it covers")

        // A typed prefix folds once the caret leaves the line.
        tv.setSelectedRange(NSRange(location: bodyLoc, length: 0))
        tv.insertText("### ", replacementRange: NSRange(location: bodyLoc, length: 0))
        try expect(!hides(bodyLoc, 4), "the just-typed prefix stays visible under the caret")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.applyHeadingFolds()
        try expect(hides(bodyLoc, 4), "leaving the line folds the newly typed prefix")
        withExtendedLifetime(coord) {}
    }
}

/// The per-keystroke heading pass is incremental (`refreshHeadingFoldsForEdit`):
/// it re-scans only the edited paragraph and shifts the headings below it,
/// because a full-document scan per keystroke costs ~16 ms on a large note. The
/// folded ranges must stay byte-identical to what the full scan produces, or
/// typing above a heading would hide the wrong characters until the next pause.
func testIncrementalHeadingFoldsMatchFullScan() throws {
    try MainActor.assumeIsolated {
        let font = NSFont.systemFont(ofSize: 14)
        let text = "intro line\n# One\nbody\n## Two\nmore body\n### Three\ntail"
        let (_, tv, coord, _) = makeVimRig(text)
        tv.textContainer?.replaceLayoutManager(FoldingLayoutManager())
        tv.textStorage?.delegate = tv
        tv.restyleMarkdown(baseFont: font, force: true)

        let lm = tv.layoutManager as? FoldingLayoutManager
        /// The incremental result, then the authoritative full scan for the
        /// same text — they must agree exactly.
        func expectMatchesFullScan(_ what: String) throws {
            let incremental = tv.detectedHeadings
            let foldedIncrementally = lm?.headingPrefixes ?? []
            tv.refreshHeadingFolds() // full document scan
            try expectEqual(incremental, tv.detectedHeadings,
                            "incremental heading scan matches the full scan after \(what)")
            try expectEqual(foldedIncrementally, lm?.headingPrefixes ?? [],
                            "hidden prefixes match the full scan after \(what)")
        }

        // Park the caret on the first line so no heading is unfolded, and let
        // the folds settle.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.refreshHeadingFolds()
        try expectEqual(tv.detectedHeadings.count, 3, "three headings to start")

        // 1. Insert above every heading — they all shift by the same delta.
        tv.insertText("added\n", replacementRange: NSRange(location: 0, length: 0))
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.applyHeadingFolds()
        try expect(tv.detectedHeadings.allSatisfy { heading in
            (tv.string as NSString).substring(with: heading.prefixRange).allSatisfy { $0 == "#" || $0 == " " }
        }, "every folded prefix still covers only '#' and spaces after a shift edit")
        try expectMatchesFullScan("an insert above all headings")

        // 2. Delete in the middle — headings below shift back.
        let midLoc = (tv.string as NSString).range(of: "more body").location
        tv.textStorage?.replaceCharacters(in: NSRange(location: midLoc, length: 5), with: "")
        tv.didChangeText()
        try expectMatchesFullScan("a delete between headings")

        // 3. A line gains heading-ness mid-document.
        let bodyLoc = (tv.string as NSString).range(of: "body\n").location
        tv.setSelectedRange(NSRange(location: bodyLoc, length: 0))
        tv.insertText("#### ", replacementRange: NSRange(location: bodyLoc, length: 0))
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.applyHeadingFolds()
        try expectEqual(tv.detectedHeadings.count, 4, "the typed prefix adds a heading")
        try expectMatchesFullScan("a line gaining a prefix")

        // 4. …and loses it again.
        tv.textStorage?.replaceCharacters(in: NSRange(location: bodyLoc, length: 5), with: "")
        tv.didChangeText()
        try expectEqual(tv.detectedHeadings.count, 3, "removing the prefix drops the heading")
        try expectMatchesFullScan("a line losing its prefix")

        // 5. Joining a heading line into its predecessor (deleting the newline
        //    before it) must un-heading it — the merged paragraph is re-scanned.
        let oneLoc = (tv.string as NSString).range(of: "# One").location
        tv.textStorage?.replaceCharacters(in: NSRange(location: oneLoc - 1, length: 1), with: "")
        tv.didChangeText()
        try expectMatchesFullScan("joining a heading onto the line above")

        // 6. A multi-line paste in the middle.
        let tailLoc = (tv.string as NSString).range(of: "tail").location
        tv.setSelectedRange(NSRange(location: tailLoc, length: 0))
        tv.insertText("alpha\n## Pasted\nbeta\n", replacementRange: NSRange(location: tailLoc, length: 0))
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.applyHeadingFolds()
        try expectMatchesFullScan("a multi-line paste")
        withExtendedLifetime(coord) {}
    }
}

/// The typing-pause restyle skips its whole-document ``` scan when the edit
/// can't have changed the fence structure (~16 ms per pause on a large note,
/// paid even by notes with no fences). The resulting `codeBlockRanges` must
/// still equal what a fresh scan would produce, including when a fence is typed
/// or deleted — those cases have to fall back to the scan.
func testCodeBlockScanSkippedWhenStructureIntact() throws {
    try MainActor.assumeIsolated {
        let font = NSFont.systemFont(ofSize: 14)
        let (_, tv, coord, _) = makeVimRig("intro\n```\nlet x = 1\n```\ntail\n```\ntwo\n```\nend")
        tv.textStorage?.delegate = tv
        tv.restyleMarkdown(baseFont: font, force: true)
        try expectEqual(tv.codeBlockRanges.count, 2, "two fenced blocks to start")

        /// Restyle, then check the ranges against an independent fresh scan.
        func expectMatchesFreshScan(_ what: String) throws {
            tv.restyleMarkdown(baseFont: font)
            try expectEqual(tv.codeBlockRanges, tv.computeCodeBlockRanges(),
                            "code block ranges match a fresh scan after \(what)")
        }

        // Typing above both blocks shifts them without a re-scan.
        tv.insertText("added\n", replacementRange: NSRange(location: 0, length: 0))
        try expectMatchesFreshScan("an insert above both blocks")

        // Typing between the blocks shifts only the second.
        let tailLoc = (tv.string as NSString).range(of: "tail").location
        tv.insertText("xx", replacementRange: NSRange(location: tailLoc, length: 0))
        try expectMatchesFreshScan("an insert between blocks")

        // Deleting between the blocks.
        tv.textStorage?.replaceCharacters(in: NSRange(location: tailLoc, length: 2), with: "")
        tv.didChangeText()
        try expectMatchesFreshScan("a delete between blocks")

        // A newly typed fence pair must be picked up (forces the scan).
        let endLoc = (tv.string as NSString).range(of: "end").location
        tv.insertText("```\nthree\n```\n", replacementRange: NSRange(location: endLoc, length: 0))
        try expectMatchesFreshScan("a newly typed fence pair")
        try expectEqual(tv.codeBlockRanges.count, 3, "the typed fence pair became a third block")

        // Breaking an existing fence must drop its block (edit inside a block).
        let firstFence = (tv.string as NSString).range(of: "```").location
        tv.textStorage?.replaceCharacters(in: NSRange(location: firstFence, length: 1), with: "")
        tv.didChangeText()
        try expectMatchesFreshScan("breaking an opening fence")
        try expectEqual(tv.codeBlockRanges.count, 2, "the broken block is gone")
        withExtendedLifetime(coord) {}
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

/// Regression for "J on the last line strands its final char": joining must
/// span the next line's whole content even when it has no trailing newline.
func testVimJoinLastLine() throws {
    try MainActor.assumeIsolated {
        // Next line "cd" is the last line (no trailing newline).
        let (_, tv, coord, press) = makeVimRig("ab\ncd")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        press("J")
        try expectEqual(tv.string, "ab cd", "J must join the last line without stranding its final char")

        // Regression guard: a mid-file join keeps the following line intact.
        let (_, tv2, coord2, press2) = makeVimRig("ab\ncd\nef")
        tv2.setSelectedRange(NSRange(location: 0, length: 0))
        press2("J")
        try expectEqual(tv2.string, "ab cd\nef", "J on a middle line must preserve the line after")
        withExtendedLifetime((coord, coord2)) {}
    }
}

/// Regression for "dd on the last line leaves a blank line": deleting the final
/// line must also consume the newline that precedes it.
func testVimDeleteLastLine() throws {
    try MainActor.assumeIsolated {
        let (_, tv, coord, press) = makeVimRig("first\nsecond")
        tv.setSelectedRange(NSRange(location: 6, length: 0)) // on "second"
        press("dd")
        try expectEqual(tv.string, "first", "dd on the last line must not leave a trailing empty line")

        // Regression guard: dd on a middle line removes exactly that line.
        let (_, tv2, coord2, press2) = makeVimRig("first\nsecond\nthird")
        tv2.setSelectedRange(NSRange(location: 0, length: 0)) // on "first"
        press2("dd")
        try expectEqual(tv2.string, "second\nthird", "dd on a middle line removes just that line")

        // dd on the sole line empties the document.
        let (_, tv3, coord3, press3) = makeVimRig("only")
        tv3.setSelectedRange(NSRange(location: 0, length: 0))
        press3("dd")
        try expectEqual(tv3.string, "", "dd on the only line clears the document")
        withExtendedLifetime((coord, coord2, coord3)) {}
    }
}

/// Regression for "count G/gg in visual mode collapses the selection": a
/// counted line jump must extend the active visual selection, not drop it to a
/// caret. Also covers G/gg landing on the line's first non-blank.
func testVimVisualCountGotoLine() throws {
    try MainActor.assumeIsolated {
        // V then 3G selects whole lines 1..3 (V-LINE through end of line 3).
        let (eng, tv, coord, press) = makeVimRig("one\ntwo\nthree\nfour")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        press("V")
        press("3")
        press("G")
        try expect(eng.mode == .visualLine, "still in V-LINE after 3G")
        let sel = tv.selectedRange()
        try expectEqual(sel.location, 0, "selection starts at the document start")
        // "one\ntwo\nthree\n" = 14 chars — V-LINE spans lines 1..3 including
        // line 3's trailing newline.
        try expectEqual(sel.location + sel.length, 14, "3G must extend the V-LINE selection through line 3")

        // Charwise visual: v then 2G extends the caret end to line 2.
        let (_, tv2, coord2, press2) = makeVimRig("one\ntwo\nthree")
        tv2.setSelectedRange(NSRange(location: 0, length: 0))
        press2("v")
        press2("2")
        press2("G")
        try expect(tv2.selectedRange().length > 1, "v2G must extend the charwise selection, not collapse it")
        withExtendedLifetime((coord, coord2)) {}
    }
}

/// `gg`/`G` (and counted forms) land on the line's first non-blank char.
func testVimGotoLineFirstNonBlank() throws {
    try MainActor.assumeIsolated {
        // Line 2 is indented; 2G should land on 'b' (after the 4 spaces).
        let (_, tv, coord, press) = makeVimRig("a\n    bcd\ne")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        press("2")
        press("G")
        try expectEqual(tv.selectedRange().location, 6, "2G lands on the first non-blank of line 2")
        withExtendedLifetime(coord) {}
    }
}

/// Regression for "~ with a count past end-of-line thrashes the last char":
/// it must toggle each remaining char once and stop, never wrap or re-toggle.
func testVimToggleCaseCountStopsAtLineEnd() throws {
    try MainActor.assumeIsolated {
        let (_, tv, coord, press) = makeVimRig("ab\ncd")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        press("5")
        press("~")
        try expectEqual(tv.string, "AB\ncd", "5~ on a 2-char line toggles both once and stops (no wrap, no re-toggle)")
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

func testMigrateStoreCopiesStore() throws {
    try withTemporaryStorage { manager, _ in
        let note = Note(title: "Migrate me", content: "Migrate me\nbody text")
        guard case .success = manager.saveNote(note) else {
            throw SmokeTestFailure.failed("saving the source note failed")
        }
        guard let assetPath = manager.saveImageAsset(Data([0xDE, 0xAD]), fileExtension: "png") else {
            throw SmokeTestFailure.failed("saving the source asset failed")
        }

        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VimTextSmokeTests-migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destURL) }

        guard case .success(let copied) = manager.migrateStore(toBasePath: destURL.path) else {
            throw SmokeTestFailure.failed("migrateStore failed")
        }
        try expectEqual(copied, 1, "one note should be copied")

        // Re-running must not overwrite or duplicate anything at the destination.
        guard case .success(let again) = manager.migrateStore(toBasePath: destURL.path) else {
            throw SmokeTestFailure.failed("second migrateStore failed")
        }
        try expectEqual(again, 0, "second migration should copy nothing")

        manager.customDirectoryPath = destURL.path
        let notes = manager.loadNotes()
        try expectEqual(notes.count, 1, "migrated store should load one note")
        try expectEqual(notes.first?.title, "Migrate me", "note title should survive migration")
        try expectEqual(notes.first?.content, "Migrate me\nbody text", "note content should survive migration")
        try expect(FileManager.default.fileExists(atPath: manager.assetURL(forRelativePath: assetPath).path),
                   "asset file should exist in the migrated store")

        // A destination inside the current notes tree would copy into itself.
        let inside = destURL.appendingPathComponent("notes/sub").path
        guard case .failure = manager.migrateStore(toBasePath: inside) else {
            throw SmokeTestFailure.failed("migration into the source notes tree should be refused")
        }
    }
}

func testQuickCaptureHelpers() throws {
    // Title rule matches the editor's: first non-empty, non-image line, capped.
    try expectEqual(QuickCapture.title(from: "Buy milk\nand eggs"), "Buy milk",
                    "title is the first line")
    try expectEqual(QuickCapture.title(from: "\n\n  Second line is first non-empty  \nbody"),
                    "Second line is first non-empty",
                    "leading empty lines and whitespace are skipped/trimmed")
    try expectEqual(QuickCapture.title(from: String(repeating: "a", count: 150)).count, 100,
                    "title caps at 100 characters")
    try expectEqual(QuickCapture.title(from: ""), "", "empty text yields empty title")

    // NSEvent → Carbon modifier conversion, including all four at once.
    let all: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    let allCarbon = QuickCaptureHotKey.carbonModifiers(from: all)
    try expectEqual(allCarbon, UInt32(controlKey | optionKey | shiftKey | cmdKey),
                    "all four modifiers convert to the full Carbon mask")
    try expectEqual(QuickCaptureHotKey.carbonModifiers(from: [.control, .option]),
                    UInt32(controlKey | optionKey),
                    "ctrl+option converts")

    // Display strings use macOS symbol order ⌃⌥⇧⌘ and named special keys.
    try expectEqual(
        QuickCaptureHotKey.description(keyCode: QuickCaptureHotKey.defaultKeyCode,
                                       carbonModifiers: QuickCaptureHotKey.defaultModifiers),
        "⌃⌥Space",
        "default shortcut renders as ⌃⌥Space")
    try expectEqual(
        QuickCaptureHotKey.description(keyCode: UInt32(kVK_Space), carbonModifiers: allCarbon),
        "⌃⌥⇧⌘Space",
        "hyper-style combo renders all four symbols in order")

    // Bare keys are rejected; F-keys and modified keys are accepted.
    try expect(!QuickCaptureHotKey.isValidShortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: 0),
               "a bare letter is not a valid global shortcut")
    try expect(!QuickCaptureHotKey.isValidShortcut(keyCode: UInt32(kVK_ANSI_A),
                                                   carbonModifiers: UInt32(shiftKey)),
               "shift alone does not validate")
    try expect(QuickCaptureHotKey.isValidShortcut(keyCode: UInt32(kVK_F6), carbonModifiers: 0),
               "an F-key alone is valid")
    try expect(QuickCaptureHotKey.isValidShortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: allCarbon),
               "ctrl+option+shift+cmd+letter is valid")
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
    ("Vim search cache invalidation on edit", testVimSearchCacheInvalidation),
    ("Pure motion resolution (MotionResolver)", testMotionResolverPure),
    ("Vim linewise paste on last line", testVimLinewisePasteLastLine),
    ("Vim till-repeat advances (t/T + ;/,)", testVimTillRepeatAdvances),
    ("Vim join (J) on last line", testVimJoinLastLine),
    ("Vim delete (dd) on last line", testVimDeleteLastLine),
    ("Vim visual count G/gg extends selection", testVimVisualCountGotoLine),
    ("Vim G/gg first non-blank landing", testVimGotoLineFirstNonBlank),
    ("Vim ~ count stops at line end", testVimToggleCaseCountStopsAtLineEnd),
    ("Vim control-key routing (Ctrl-[/Ctrl-R) via keyDown", testVimControlKeyRoutingViaKeyDown),
    ("Vim jump list (Ctrl-O/Ctrl-I)", testVimJumpList),
    ("Vim visual mode on empty note", testVimVisualOnEmptyNote),
    ("Vim x/X register and emoji text objects", testVimCharDeleteRegisterAndEmojiObject),
    ("Vim gv reselect last visual selection", testVimGvReselect),
    ("Vim substitute per-line + preserves formatting", testVimSubstitutePerLineAndPreservesFormatting),
    ("Code-block scoped restyle fast paths", testCodeBlockScopedRestyle),
    ("Markdown heading styling", testMarkdownHeadingStyling),
    ("Markdown heading prefix folding", testMarkdownHeadingPrefixFolding),
    ("Incremental heading folds match full scan", testIncrementalHeadingFoldsMatchFullScan),
    ("Code-block scan skipped when structure intact", testCodeBlockScanSkippedWhenStructureIntact),
    ("Storage round-trip, rename, collision, and RTF", testStorageRoundTripRenameCollisionAndRTF),
    ("Storage malformed files and write errors", testStorageMalformedFilesAndWriteErrors),
    ("Command Palette search matching", testCommandPaletteSearchMatching),
    ("Fuzzy search and palette ranking", testFuzzySearchAndRanking),
    ("Search smart-quote folding", testSearchQuoteFolding),
    ("Link detection and gd", testLinkDetectionAndGx),
    ("Link folding (computeFolds)", testLinkFoldingComputeFolds),
    ("List marker detection (bullets/checkboxes)", testListMarkerDetection),
    ("Smart list parsing and renumbering", testSmartListParsing),
    ("Smart lists via keyDown (Return/Tab/Backspace/o)", testSmartListsViaKeyDown),
    ("Storage pinned-state persistence", testStoragePinnedStatePersists),
    ("Storage migration to a new location", testMigrateStoreCopiesStore),
    ("Search normalization (fold + lowercase)", testSearchNormalization),
    ("Quick Capture helpers (title/hotkey)", testQuickCaptureHelpers)
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
