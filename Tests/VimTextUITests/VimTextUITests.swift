import XCTest

final class VimTextUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testCommandPaletteFocusAndType() throws {
        // 1. Press Command + K to open the palette
        app.typeKey("k", modifierFlags: .command)
        
        // 2. Locate the search text field
        let searchField = app.textFields["Search notes or type commands…"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2.0), "Command Palette search field should be visible")
        
        // 3. Type directly into the active focus. Since the search field has keyboard focus,
        // it should capture the typed characters.
        app.typeText("Haskell")
        
        // 4. Assert that the search field's text value was updated to "Haskell"
        XCTAssertEqual(searchField.value as? String, "Haskell", "Focus should be in the search field and accept text input")
        
        // 5. Dismiss the palette
        app.typeKey(.escape, modifierFlags: [])
    }
}
