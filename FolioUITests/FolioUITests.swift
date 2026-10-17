import XCTest

private final class CurlScreenshots: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(String, Data)] = []

    func capture(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        lock.lock()
        frames.append((name, data))
        lock.unlock()
    }

    func attachments() -> [XCTAttachment] {
        lock.lock()
        defer { lock.unlock() }
        return frames.map { name, data in
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            return attachment
        }
    }
}

@MainActor
final class FolioUITests: XCTestCase {
    var app: XCUIApplication!
    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func openSample() {
        let sample = app.buttons["sampleDocument"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        sample.tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 10))
    }

    func jump(to page: Int) {
        app.buttons["pageIndicator"].tap()
        let field = app.textFields["pageNumberInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "\(page)")
        app.buttons["goToPage"].tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["pageIndicator"].label, "Page \(page) of 25")
    }

    func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func readingSettings() {
        app.buttons["Library actions"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        scrollTo(app.buttons["readingMode-flip"])
    }

    func enableFlip(sound: Bool = false) {
        readingSettings()
        app.buttons["readingMode-flip"].tap()
        if sound {
            app.switches["pageTurnSoundToggle"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            XCTAssertEqual(app.switches["pageTurnSoundToggle"].value as? String, "1")
        }
        app.buttons["Done"].tap()
    }

    func selectTool(_ name: String) {
        let tool = app.buttons["tool-\(name)"]
        let strip = app.scrollViews["annotationToolStrip"]
        for _ in 0..<3 where !tool.isHittable { strip.swipeLeft() }
        if !tool.isHittable {
            for _ in 0..<3 where !tool.isHittable { strip.swipeRight() }
        }
        XCTAssertTrue(tool.isHittable)
        tool.tap()
    }

    func assertPage(_ page: Int) {
        let indicator = app.buttons["pageIndicator"]
        let expected = NSPredicate(format: "label == %@", "Page \(page) of 25")
        expectation(for: expected, evaluatedWith: indicator)
        waitForExpectations(timeout: 5)
    }

    func scrollTo(_ element: XCUIElement) {
        let settings = app.scrollViews["settingsScrollView"]
        let inSettings = app.navigationBars["Settings"].exists
        let scroll = inSettings ? settings : app.scrollViews["libraryScrollView"]
        let window = app.windows.firstMatch.frame
        let navigation = app.navigationBars.firstMatch
        let toolbar = app.toolbars.firstMatch
        let top = navigation.exists ? navigation.frame.maxY + 8 : window.minY + 8
        let bottom = !inSettings && toolbar.exists ? toolbar.frame.minY - 8 : window.maxY - 48
        for _ in 0..<12 {
            let frame = element.exists ? element.frame : .zero
            if element.exists && frame.midY >= top && frame.midY <= bottom
                && frame.midX >= window.minX && frame.midX <= window.maxX { return }
            let towardTop = element.exists && frame.midY < top
            // Drag in the trailing padding, away from the sound slider and controls.
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: towardTop ? 0.35 : 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: towardTop ? 0.7 : 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.frame.midY >= top && element.frame.midY <= bottom, app.debugDescription)
    }

    func testLibraryLayoutPersistenceAndFolderChipActions() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--reset-library", "--seed-library"]
        app.launch()
        let toggle = app.buttons["libraryLayoutToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.label, "Show list")
        toggle.tap()
        XCTAssertEqual(toggle.label, "Show grid")
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Show grid")
        app.buttons["folder-Work"].press(forDuration: 1)
        app.buttons["Rename folder"].tap()
        let field = app.alerts.textFields.firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "Research")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["folder-Research"].waitForExistence(timeout: 5))
        app.buttons["folder-Research"].tap()
        XCTAssertTrue(app.buttons["document-Field notes"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["All"].tap()
        XCTAssertTrue(app.buttons["document-The art of focused reading"].exists)
        app.buttons["Library actions"].tap()
        app.buttons["Select documents"].tap()
        app.buttons["document-The art of focused reading"].tap()
        app.buttons["document-Field notes"].tap()
        XCTAssertEqual(app.staticTexts["librarySelectionCount"].label, "2 selected")
        app.buttons["moveSelectedDocuments"].tap()
        app.buttons["destination-Notes"].tap()
        app.buttons["finishLibrarySelection"].tap()
        app.buttons["folder-Notes"].tap()
        XCTAssertTrue(app.buttons["document-The art of focused reading"].exists)
        XCTAssertTrue(app.buttons["document-Field notes"].exists)
    }

    func testLargeDocumentPageGrid() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--reset-library", "--seed-library", "--large-document"]
        app.launch()
        let resume = app.buttons["continueReading"]
        XCTAssertTrue(resume.waitForExistence(timeout: 15)); resume.tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["pageIndicator"].label, "Page 12 of 500")
        app.buttons["Page thumbnails"].tap()
        XCTAssertTrue(app.navigationBars["Pages"].waitForExistence(timeout: 5))
        screenshot("Large document page grid before scrolling")
        for _ in 0..<10 { app.swipeUp(velocity: .fast) }
        screenshot("Large document page grid after scrolling")
        XCTAssertTrue(app.buttons["Done"].isHittable)
    }

    func testRedesignLightScreens() { redesignScreens(name: "light", theme: "light") }
    func testRedesignDarkScreens() { redesignScreens(name: "dark", theme: "dark") }
    func testRedesignLandscapeScreens() { redesignScreens(name: "landscape", theme: "light", landscape: true) }
    func testRedesignAccessibilityScreens() { redesignScreens(name: "accessibility", theme: "light", accessibility: true) }

    private func redesignScreens(name: String, theme: String, landscape: Bool = false, accessibility: Bool = false) {
        var arguments = ["--ui-testing", "--reset-library", "-appearance", theme]
        if accessibility { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.terminate()
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.buttons["sampleDocument"].waitForExistence(timeout: 10))
        screenshot("Redesign-\(name)-empty")
        app.terminate()
        app.launchArguments = arguments + ["--seed-library"]
        app.launch()
        XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout: 10))
        screenshot("Redesign-\(name)-grid")
        let toggle = app.buttons["libraryLayoutToggle"]
        if accessibility {
            XCTAssertFalse(toggle.isEnabled, "Accessibility sizes use the list automatically")
        } else {
            toggle.tap()
            XCTAssertEqual(toggle.label, "Show grid")
            screenshot("Redesign-\(name)-list")
            toggle.tap()
        }
        if landscape {
            scrollTo(app.buttons["document-The art of focused reading"])
            screenshot("Redesign-\(name)-grid-scrolled")
        }
        app.buttons["Library actions"].tap()
        app.buttons["Select documents"].tap()
        let document = app.buttons["document-The art of focused reading"]
        scrollTo(document)
        if landscape {
            document.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        } else {
            document.tap()
        }
        XCTAssertEqual(app.staticTexts["librarySelectionCount"].label, "1 selected")
        screenshot("Redesign-\(name)-selection")
        app.buttons["finishLibrarySelection"].tap()
        readingSettings()
        screenshot("Redesign-\(name)-settings-scroll")
        app.buttons["readingMode-flip"].tap()
        scrollTo(app.switches["pageTurnSoundToggle"])
        app.switches["pageTurnSoundToggle"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        screenshot("Redesign-\(name)-settings-flip")
        scrollTo(app.buttons["Tips & gestures"])
        app.buttons["Tips & gestures"].tap()
        screenshot("Redesign-\(name)-tips")
        app.navigationBars["Tips & gestures"].buttons["Settings"].tap()
        app.buttons["Done"].tap()
        let resume = app.buttons["continueReading"]
        for _ in 0..<6 where !resume.isHittable { app.swipeDown() }
        resume.tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 10))
        screenshot("Redesign-\(name)-reader-flip")
        app.buttons["annotationTools"].tap()
        selectTool("pen")
        screenshot("Redesign-\(name)-reader-tray")
        XCTAssertTrue(app.buttons["finishMarkup"].isHittable)
        app.buttons["finishMarkup"].tap()
        if landscape { jump(to: 1) }
        app.buttons["searchDocument"].tap()
        let search = app.searchFields["Word or phrase"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("curiosity")
        if landscape { search.typeText("\n") }
        let hit = app.buttons.containing(.staticText, identifier: "Page 1").firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5)); hit.tap()
        XCTAssertTrue(app.buttons["clearTextSelection"].waitForExistence(timeout: 5))
        screenshot("Redesign-\(name)-reader-selection")
        app.buttons["closeReader"].tap()
        readingSettings()
        app.buttons["readingMode-verticalScroll"].tap()
        app.buttons["Done"].tap()
        for _ in 0..<6 where !resume.isHittable { app.swipeDown() }
        resume.tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 10))
        screenshot("Redesign-\(name)-reader-toolbar")
    }

    func testReadingSettingsDefaultsAndPersistence() {
        readingSettings()
        XCTAssertTrue(app.buttons["readingMode-verticalScroll"].isSelected)
        let sound = app.switches["pageTurnSoundToggle"]
        let volume = app.sliders["pageTurnSoundVolume"]
        XCTAssertFalse(sound.exists)
        XCTAssertFalse(volume.exists)
        app.buttons["readingMode-flip"].tap()
        XCTAssertTrue(sound.isEnabled)
        XCTAssertFalse(volume.isEnabled)
        sound.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(sound.value as? String, "1")
        XCTAssertTrue(volume.isEnabled)
        volume.adjust(toNormalizedSliderPosition: 0.75)
        let savedVolume = volume.value as? String
        screenshot("Flip and sound settings")
        app.buttons["Done"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        readingSettings()
        XCTAssertTrue(app.buttons["readingMode-flip"].isSelected)
        XCTAssertEqual(app.switches["pageTurnSoundToggle"].value as? String, "1")
        XCTAssertTrue(app.sliders["pageTurnSoundVolume"].isEnabled)
        XCTAssertEqual(app.sliders["pageTurnSoundVolume"].value as? String, savedVolume)
        app.buttons["readingMode-verticalScroll"].tap()
        XCTAssertFalse(app.switches["pageTurnSoundToggle"].exists)
        XCTAssertFalse(app.sliders["pageTurnSoundVolume"].exists)
        app.buttons["readingMode-flip"].tap()
        XCTAssertEqual(app.switches["pageTurnSoundToggle"].value as? String, "1")
    }

    func testFlipSwipesBoundariesControlsAndRestoration() {
        enableFlip(sound: true)
        openSample()
        var canvas = app.otherElements["pdfCanvas"]
        let scrubber = app.descendants(matching: .any)["pageScrubber"].firstMatch
        XCTAssertFalse(scrubber.exists)
        canvas.swipeRight()
        assertPage(1)
        canvas.swipeLeft()
        assertPage(2)
        XCTAssertTrue(app.buttons["closeReader"].exists)
        canvas = app.otherElements["pdfCanvas"]
        canvas.swipeRight()
        assertPage(1)
        jump(to: 25)
        canvas.swipeLeft()
        assertPage(25)
        jump(to: 14)
        XCUIDevice.shared.orientation = .landscapeLeft
        assertPage(14)
        XCTAssertTrue(app.buttons["closeReader"].exists)
        XCTAssertFalse(scrubber.exists)
        XCUIDevice.shared.orientation = .portrait
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["pageIndicator"].exists)
        XCTAssertTrue(app.buttons["closeReader"].exists)
        XCTAssertFalse(scrubber.exists)
        canvas.swipeLeft()
        assertPage(15)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["pageIndicator"].exists)
        XCTAssertTrue(app.buttons["closeReader"].exists)
        XCTAssertFalse(scrubber.exists)
        screenshot("Book reader with persistent controls")
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["continueReading"].tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 10))
        assertPage(15)
        XCTAssertTrue(app.buttons["closeReader"].exists)
        XCTAssertFalse(scrubber.exists)
    }

    func testFlipSearchThumbnailsAndMarkup() {
        enableFlip()
        testSearchAndPageBrowser()
        app.buttons["annotationTools"].tap()
        selectTool("pen")
        let canvas = app.otherElements["pdfCanvas"]
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.35))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
        assertPage(3)
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
        selectTool("note")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3)).tap()
        XCTAssertTrue(app.textViews["noteText"].waitForExistence(timeout: 5))
        app.textViews["noteText"].tap()
        app.textViews["noteText"].typeText("Book mode note")
        app.buttons["Save note"].tap()
        app.buttons["finishMarkup"].tap()
        canvas.swipeLeft()
        assertPage(4)
        canvas.swipeRight()
        assertPage(3)
        app.buttons["closeReader"].tap()
        app.buttons["continueReading"].tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 10))
        assertPage(3)
        screenshot("Book reader markup")
    }

    func testFlipWithReduceMotion() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--reset-library", "--reduce-motion"]
        app.launch()
        enableFlip()
        openSample()
        app.otherElements["pdfCanvas"].swipeLeft()
        assertPage(2)
        app.otherElements["pdfCanvas"].swipeRight()
        assertPage(1)
        XCTAssertTrue(app.buttons["closeReader"].exists)
    }

    func testFlipSinglePageSwipesAndPaperBounds() {
        enableFlip()
        openSample()
        let canvas = app.otherElements["pdfCanvas"]
        XCTAssertEqual(canvas.frame.width / canvas.frame.height, 612.0 / 792, accuracy: 0.01)
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let captures = CurlScreenshots()
        let captureQueue = DispatchQueue(label: "Folio.CurlVerification")
        let captured = DispatchGroup()
        for delay in [0.7, 1.1, 1.5] {
            captured.enter()
            captureQueue.asyncAfter(deadline: .now() + delay) {
                captures.capture("Softened curl at \(delay)s")
                captured.leave()
            }
        }
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertEqual(captured.wait(timeout: .now() + 5), .success)
        for attachment in captures.attachments() { add(attachment) }
        assertPage(2)
        for page in 3...5 {
            canvas.swipeLeft(velocity: .fast)
            assertPage(page)
        }
        canvas.swipeRight(velocity: .fast)
        assertPage(4)
        screenshot("PDF-sized curl in portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let layoutReady = NSPredicate { _, _ in
            self.app.frame.width > self.app.frame.height && canvas.frame.width < self.app.frame.width * 0.8
        }
        expectation(for: layoutReady, evaluatedWith: canvas)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(canvas.frame.width / canvas.frame.height, 612.0 / 792, accuracy: 0.01)
        assertPage(4)
        canvas.swipeLeft()
        assertPage(5)
        screenshot("PDF-sized curl in landscape")
        let paragraph = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A good document")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2)).press(forDuration: 0.9)
        let deselect = app.buttons["clearTextSelection"]
        XCTAssertTrue(deselect.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: canvas.frame.minX / 2, dy: canvas.frame.midY)).tap()
        XCTAssertTrue(deselect.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["closeReader"].exists)
        assertPage(5)
    }

    func testFlipZoomPansUntilPageFitsAgain() {
        enableFlip()
        openSample()
        let canvas = app.otherElements["pdfCanvas"]
        canvas.pinch(withScale: 2, velocity: 1)
        canvas.swipeLeft()
        assertPage(1)
        XCTAssertTrue(app.buttons["closeReader"].exists)
        canvas.pinch(withScale: 0.4, velocity: -1)
        canvas.swipeLeft()
        assertPage(2)
    }

    func testFlipNativeTextSelectionDismissesOnOutsideTap() {
        enableFlip()
        testLongPressSelectionDismissesOnOutsideTap()
        app.otherElements["pdfCanvas"].coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["pageIndicator"].exists)
        XCTAssertTrue(app.buttons["closeReader"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["pageScrubber"].firstMatch.exists)
    }

    func testResumeAfterTerminationAndRotation() {
        openSample()
        jump(to: 14)
        app.buttons["bookmarkPage"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout: 10))
        app.buttons["continueReading"].tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["pageIndicator"].label, "Page 14 of 25")
        XCTAssertEqual(app.buttons["bookmarkPage"].label, "Remove bookmark")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(app.buttons["pageIndicator"].label, "Page 14 of 25")
        XCUIDevice.shared.orientation = .portrait
        screenshot("Reader restored to page 14")
        app.buttons["closeReader"].tap()
        XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout: 5))
        screenshot("Library with reading history")
    }

    func testPenNoteUndoAndReopen() {
        openSample()
        app.buttons["annotationTools"].tap()
        selectTool("pen")
        let canvas = app.otherElements["pdfCanvas"]
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
        app.buttons["Redo"].tap()
        selectTool("note")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3)).tap()
        let editor = app.textViews["noteText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText("A thought worth keeping.")
        app.buttons["Save note"].tap()
        screenshot("Reader with markup")
        app.buttons["closeReader"].tap()
        XCTAssertTrue(app.buttons["continueReading"].waitForExistence(timeout: 5))
        app.buttons["continueReading"].tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 5))
    }

    func testSearchAndPageBrowser() {
        openSample()
        app.buttons["searchDocument"].tap()
        let field = app.searchFields["Word or phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("curiosity")
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "Page 1").firstMatch.waitForExistence(timeout: 5))
        app.buttons.containing(.staticText, identifier: "Page 1").firstMatch.tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 5))
        app.buttons["Page thumbnails"].tap()
        XCTAssertTrue(app.navigationBars["Pages"].waitForExistence(timeout: 5))
        app.buttons["thumbnail-2"].tap()
        XCTAssertEqual(app.buttons["pageIndicator"].label, "Page 3 of 25")
    }

    func testLibraryRenameAndDelete() {
        openSample()
        app.buttons["closeReader"].tap()
        let actions = app.buttons["Actions for The art of focused reading"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap(); app.buttons["Rename"].tap()
        let field = app.alerts.textFields.firstMatch
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "My reading")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Actions for My reading"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Actions for My reading"].tap()
        app.buttons["Delete"].tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["sampleDocument"].waitForExistence(timeout: 5))
        screenshot("Empty library")
    }
    func testFullScreenCanvasAndPageScroller() {
        openSample()
        let canvas = app.otherElements["pdfCanvas"]
        let initialFrame = canvas.frame
        XCTAssertGreaterThan(initialFrame.minY, 0)
        let scrubber = app.descendants(matching: .any)["pageScrubber"].firstMatch
        // Re-show the auto-hiding marker immediately before interacting with it.
        app.buttons["pageIndicator"].tap()
        app.buttons["goToPage"].tap()
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.65)))
        XCTAssertNotEqual(app.buttons["pageIndicator"].label, "Page 1 of 25")
        Thread.sleep(forTimeInterval: 0.3) // Deliberate tap after the scrub cooldown.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let hidden = NSPredicate(format: "exists == false")
        expectation(for: hidden, evaluatedWith: app.buttons["closeReader"])
        waitForExpectations(timeout: 5)
        XCTAssertLessThanOrEqual(canvas.frame.minY, 1)
        XCTAssertGreaterThanOrEqual(canvas.frame.maxY, app.frame.maxY - 1)
        XCTAssertFalse(scrubber.exists)
        screenshot("Edge-to-edge reading")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["closeReader"].waitForExistence(timeout: 5))
        screenshot("Reader with page scroller")
    }

    func testFoldersAndAppearanceSettings() {
        openSample()
        app.buttons["closeReader"].tap()
        app.buttons["Library actions"].tap()
        app.buttons["New folder"].tap()
        app.alerts.textFields.firstMatch.tap()
        app.alerts.textFields.firstMatch.typeText("Work")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["folder-Work"].waitForExistence(timeout: 5))
        app.buttons["Actions for The art of focused reading"].tap()
        app.buttons["Move to folder"].tap()
        app.buttons["destination-Work"].tap()
        app.buttons["folder-Work"].tap()
        XCTAssertTrue(app.buttons["document-The art of focused reading"].waitForExistence(timeout: 5))
        app.buttons["Library actions"].tap()
        app.buttons["New folder"].tap()
        app.alerts.textFields.firstMatch.tap()
        app.alerts.textFields.firstMatch.typeText("Notes")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["folder-Notes"].waitForExistence(timeout: 5))
        screenshot("Library folders")
        app.buttons["Library actions"].tap()
        app.buttons["Settings"].tap()
        let picker = app.descendants(matching: .any)["appearancePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["iCloudSync"].exists)
        XCTAssertFalse(app.buttons["Sync Now"].exists)
        app.segmentedControls["appearancePicker"].buttons["Dark"].tap()
        screenshot("Dark appearance settings")
        app.buttons["Done"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["Library actions"].tap()
        app.buttons["Settings"].tap()
        let restored = app.descendants(matching: .any)["appearancePicker"].firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["appearancePicker"].buttons["Dark"].isSelected)
    }

    func testScrollingDoesNotToggleControlsAndMarkerAutoHides() {
        openSample()
        let canvas = app.otherElements["pdfCanvas"]
        let marker = app.descendants(matching: .any)["pageScrubber"].firstMatch
        for fullscreen in [false, true] {
            if fullscreen {
                Thread.sleep(forTimeInterval: 0.3)
                canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
                XCTAssertTrue(app.buttons["closeReader"].waitForNonExistence(timeout: 3))
            }
            if fullscreen { XCTAssertFalse(marker.exists) }
            canvas.swipeUp(velocity: .slow)
            if fullscreen { XCTAssertFalse(marker.exists) }
            XCTAssertEqual(app.buttons["closeReader"].exists, !fullscreen)
            XCTAssertTrue(marker.waitForNonExistence(timeout: 4))
            for _ in 0..<2 {
                let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.65))
                let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.55))
                start.press(forDuration: 0.05, thenDragTo: end)
                XCTAssertEqual(app.buttons["closeReader"].exists, !fullscreen)
                if fullscreen { XCTAssertFalse(marker.exists) }
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["closeReader"].waitForExistence(timeout: 3))
    }

    func testZoomDoesNotToggleControls() {
        openSample()
        let canvas = app.otherElements["pdfCanvas"]
        canvas.doubleTap()
        XCTAssertTrue(app.buttons["closeReader"].exists)
        canvas.pinch(withScale: 1.2, velocity: 1)
        XCTAssertTrue(app.buttons["closeReader"].exists)
        Thread.sleep(forTimeInterval: 0.3)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["closeReader"].waitForNonExistence(timeout: 3))
        canvas.pinch(withScale: 0.8, velocity: -1)
        XCTAssertFalse(app.buttons["closeReader"].exists)
        Thread.sleep(forTimeInterval: 0.3)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["closeReader"].waitForExistence(timeout: 3))
    }

    func testSelectedTextOutsideTapDoesNotEnterFullscreen() {
        openSample()
        app.buttons["searchDocument"].tap()
        let search = app.searchFields["Word or phrase"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("curiosity")
        let hit = app.buttons.containing(.staticText, identifier: "Page 1").firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5))
        hit.tap()
        let deselect = app.buttons["clearTextSelection"]
        XCTAssertTrue(deselect.waitForExistence(timeout: 5))
        screenshot("Text selection actions")
        let canvas = app.otherElements["pdfCanvas"]
        Thread.sleep(forTimeInterval: 0.4)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.35)).tap()
        XCTAssertTrue(deselect.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["closeReader"].exists)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.35)).tap()
        XCTAssertTrue(app.buttons["closeReader"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["pageScrubber"].firstMatch.exists)
    }

    func testPageJumpValidatesWithoutLosingInput() {
        openSample()
        app.buttons["pageIndicator"].tap()
        let field = app.textFields["pageNumberInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(XCUIKeyboardKey.delete.rawValue + "26")
        XCTAssertFalse(app.buttons["goToPage"].isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["pageNumberError"].firstMatch.exists)
        screenshot("Page jump inline validation")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "25")
        XCTAssertTrue(app.buttons["goToPage"].isEnabled)
        app.buttons["goToPage"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["pageIndicator"].label, "Page 25 of 25")
    }

    func testContextualToolsAndLibrarySelectionDone() {
        openSample()
        app.buttons["annotationTools"].tap()
        XCTAssertFalse(app.buttons["Pen thickness"].exists)
        XCTAssertFalse(app.buttons["Gold ink"].exists)
        selectTool("pen")
        XCTAssertTrue(app.buttons["Pen thickness"].exists)
        XCTAssertTrue(app.buttons["Gold ink"].exists)
        screenshot("Contextual pen tools")
        selectTool("read")
        XCTAssertFalse(app.buttons["Pen thickness"].exists)
        XCTAssertFalse(app.buttons["Gold ink"].exists)
        app.buttons["finishMarkup"].tap()
        XCTAssertFalse(app.buttons["tool-pen"].exists)
        app.buttons["closeReader"].tap()
        app.buttons["Library actions"].tap()
        app.buttons["Select documents"].tap()
        let done = app.buttons["finishLibrarySelection"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Actions for The art of focused reading"].exists)
        XCTAssertFalse(app.buttons["moveSelectedDocuments"].isEnabled)
        app.buttons["document-The art of focused reading"].tap()
        XCTAssertTrue(app.buttons["moveSelectedDocuments"].isEnabled)
        screenshot("Library selection")
        done.tap()
        XCTAssertTrue(app.buttons["Actions for The art of focused reading"].exists)
        app.buttons["Library actions"].tap()
        app.buttons["Select documents"].tap()
        XCTAssertFalse(app.buttons["moveSelectedDocuments"].isEnabled)
    }

    func testLongPressSelectionDismissesOnOutsideTap() {
        openSample()
        let paragraph = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A good document")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2)).press(forDuration: 0.9)
        let deselect = app.buttons["clearTextSelection"]
        XCTAssertTrue(deselect.waitForExistence(timeout: 5))
        screenshot("Native text selection")
        let canvas = app.otherElements["pdfCanvas"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.25)).tap()
        XCTAssertTrue(deselect.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["closeReader"].exists)
        XCTAssertFalse(app.menuItems["Copy"].exists)
    }

    func testAccessibilityTextAndLandscapeLayouts() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--reset-library", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let sample = app.buttons["sampleDocument"]
        for _ in 0..<4 where !sample.isHittable { app.swipeUp() }
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 5))
        app.buttons["annotationTools"].tap()
        screenshot("Accessibility text annotation controls")
        XCTAssertTrue(app.buttons["finishMarkup"].isHittable)
        XCTAssertTrue(app.buttons["pageIndicator"].isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        let canvas = app.otherElements["pdfCanvas"]
        let layoutReady = NSPredicate { _, _ in self.app.frame.width > self.app.frame.height && canvas.frame.height > 60 }
        expectation(for: layoutReady, evaluatedWith: canvas)
        waitForExpectations(timeout: 5)
        screenshot("Landscape annotation controls")
        XCTAssertGreaterThan(canvas.frame.height, 60)
        XCTAssertTrue(app.buttons["finishMarkup"].isHittable)
        app.buttons["finishMarkup"].tap()
        XCUIDevice.shared.orientation = .portrait
        app.buttons["closeReader"].tap()
        screenshot("Accessibility text library")
        app.buttons["Library actions"].tap()
        app.buttons["Settings"].tap()
        app.segmentedControls["appearancePicker"].buttons["Dark"].tap()
        app.buttons["Done"].tap()
        screenshot("Dark accessibility library")
        let resume = app.buttons["continueReading"]
        for _ in 0..<4 where !resume.isHittable { app.swipeDown() }
        resume.tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 5))
        screenshot("Dark accessibility reader")
    }

}
