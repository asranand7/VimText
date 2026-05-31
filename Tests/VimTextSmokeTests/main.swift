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

    let multiline = Note(title: "Preview", content: "one\ntwo\nthree\nfour")
    try expectEqual(multiline.preview, "one two three", "preview should include only the first three lines")

    let longContent = String(repeating: "a", count: 200)
    try expectEqual(Note(title: "Long", content: longContent).preview.count, 120, "preview should be capped")
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
    try expectEqual(feed(engine, "F", "a"), [.moveCursor(.findChar("a", false))], "Fa should find backward")
    try expectEqual(feed(engine, "T", "a"), [.moveCursor(.tillChar("a", false))], "Ta should till backward")

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
        try expectSuccess(manager.saveNote(note), "renamed save should succeed")

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

let tests: [(String, () throws -> Void)] = [
    ("Note model derived text", testNoteModelDerivedText),
    ("Editor preferences font sizing", testEditorPreferencesFontSizing),
    ("Sidebar width clamping", testSidebarWidthClamping),
    ("Graphite editor contrast", testGraphiteEditorContrast),
    ("Vim normal motions and counts", testVimNormalModeMotionsAndCounts),
    ("Vim insert, replace, and command modes", testVimInsertReplaceAndCommandModes),
    ("Vim operators, text objects, and repeats", testVimOperatorsTextObjectsAndRepeats),
    ("Vim find, search, visual, and control parsing", testVimFindSearchVisualAndControlParsing),
    ("Vim command execution", testVimCommandExecution),
    ("Storage round-trip, rename, collision, and RTF", testStorageRoundTripRenameCollisionAndRTF),
    ("Storage malformed files and write errors", testStorageMalformedFilesAndWriteErrors),
    ("Command Palette search matching", testCommandPaletteSearchMatching)
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
