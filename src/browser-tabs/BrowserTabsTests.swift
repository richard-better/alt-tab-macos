import Carbon.HIToolbox.Events
import Cocoa
import JavaScriptCore
import XCTest

final class BrowserTabsTests: XCTestCase {
    private let fixture = """
    var activated = false;
    var safariTabs = [
        {name: function(){return 'First';}, url: function(){return 'https://one.test';}},
        {name: function(){return 'Second : \\n\\"quoted\\"';}, url: function(){return 'https://two.test';}}
    ];
    var chromeTabs = [
        {id: function(){return 31;}, title: function(){return 'Same';}, url: function(){return 'https://same.test';}},
        {id: function(){return 32;}, title: function(){return 'Same';}, url: function(){return 'https://same.test';}}
    ];
    var safariWindow = {id: function(){return 10;}, tabs: function(){return safariTabs;},
        currentTab: function(){return {index: function(){return 2;}};}};
    var chromeWindow = {id: function(){return 20;}, tabs: function(){return chromeTabs;}, activeTabIndex: function(){return 1;}, mode: function(){return 'normal';},
        bounds: function(){return {x:10,y:20,width:800,height:600};}};
    function Application(id) { return {running: function(){return true;},
        windows: function(){return id === 100 ? [safariWindow] : [chromeWindow];},
        activate: function(){activated = true;}}; }
    """
    private func evaluate(_ script: String, extra: String = "") throws -> (String, JSContext) {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(fixture + extra)
        XCTAssertNil(context.exception)
        let value = context.evaluateScript(script)
        XCTAssertNil(context.exception)
        return try (XCTUnwrap(value?.toString()), context)
    }

    func testCollectPreservesTitlesDuplicateURLsAndNativeIdentity() throws {
        let script = try BrowserTabsScripts.collect([
            BrowserTabsTarget(browser: .safari, processId: 100),
            BrowserTabsTarget(browser: .chrome, processId: 200),
        ])
        let (json, _) = try evaluate(script)
        let snapshot = try JSONDecoder().decode(BrowserTabsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.tabs.count, 4)
        XCTAssertEqual(snapshot.issues, [])
        let safari = snapshot.tabs.filter { $0.browser == .safari }
        XCTAssertEqual(safari[1].title, "Second : \n\"quoted\"")
        XCTAssertTrue(safari[1].active)
        XCTAssertNil(safari[1].tabId)
        let chrome = snapshot.tabs.filter { $0.browser == .chrome }
        XCTAssertEqual(chrome[0].url, chrome[1].url)
        XCTAssertNotEqual(chrome[0].identity, chrome[1].identity)
        XCTAssertEqual(chrome[0].tabId, "31")
    }

    func testPermissionFailurePreservesOtherBrowserResults() throws {
        let script = try BrowserTabsScripts.collect([
            BrowserTabsTarget(browser: .safari, processId: 100),
            BrowserTabsTarget(browser: .chrome, processId: 200),
        ])
        let (json, _) = try evaluate(
            script,
            extra: "var original = Application; Application = function(id) { if (id === 100) throw {errorNumber: -1743}; return original(id); };"
        )
        let snapshot = try JSONDecoder().decode(BrowserTabsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.tabs.map(\.browser), [.chrome, .chrome])
        XCTAssertEqual(snapshot.issues, [BrowserTabsIssue(browser: .safari, code: -1743)])
    }

    private let profileBounds = BrowserTabsBounds(x: 10, y: 20, width: 800, height: 600)
    private func profileWindow(id: String = "20", title: String = "Same", mode: String = "normal") -> BrowserTabsWindow {
        BrowserTabsWindow(processId: 200, windowId: id, activeTitle: title, mode: mode, bounds: profileBounds)
    }

    func testProfileMetadataIsCollectedOncePerChromeWindowAndSafariIsExcluded() throws {
        let script = try BrowserTabsScripts.collect([
            BrowserTabsTarget(browser: .safari, processId: 100), BrowserTabsTarget(browser: .chrome, processId: 200)])
        let (json, _) = try evaluate(script)
        let snapshot = try JSONDecoder().decode(BrowserTabsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.tabs.count, 4)
        XCTAssertEqual(snapshot.windows, [profileWindow()])
    }

    func testMissingOptionalWindowMetadataDoesNotLoseTabsOrReportAnIssue() throws {
        let (json, _) = try evaluate(BrowserTabsScripts.collect([BrowserTabsTarget(browser: .chrome, processId: 200)]),
                                   extra: "chromeWindow.bounds = function(){throw new Error('Unavailable');};")
        let snapshot = try JSONDecoder().decode(BrowserTabsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.tabs.count, 2)
        XCTAssertEqual(snapshot.windows, [])
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    func testProfileResolutionAcceptsUniqueGeometryAndActiveTitle() {
        let accessible = BrowserTabsAccessibleWindow(title: "Same - Google Chrome - Work - Voy", bounds: profileBounds)
        XCTAssertEqual(BrowserTabsProfiles.resolve([profileWindow()], accessible: [accessible]), ["20": "Work - Voy"])
        XCTAssertNil(BrowserTabsProfiles.profileName("Same - Google Chrome", activeTitle: "Same"))
        XCTAssertNil(BrowserTabsProfiles.profileName("Same - Google Chrome -   ", activeTitle: "Same"))
        XCTAssertNil(BrowserTabsProfiles.profileName("Other - Google Chrome - Work", activeTitle: "Same"))
        XCTAssertNil(BrowserTabsProfiles.profileName(" - Google Chrome - Work", activeTitle: ""))
        XCTAssertEqual(BrowserTabsProfiles.profileName("Same - Google Chrome - Fake - Google Chrome - Real",
                                                     activeTitle: "Same - Google Chrome - Fake"), "Real")
    }

    func testProfileResolutionRejectsCollisionsInEitherSnapshotAndDuplicateIDs() {
        let accessible = BrowserTabsAccessibleWindow(title: "Same - Google Chrome - Work", bounds: profileBounds)
        XCTAssertTrue(BrowserTabsProfiles.resolve([profileWindow()], accessible: [accessible, accessible]).isEmpty)
        XCTAssertTrue(BrowserTabsProfiles.resolve([profileWindow(), profileWindow(id: "21")], accessible: [accessible]).isEmpty)
        XCTAssertTrue(BrowserTabsProfiles.resolve([profileWindow(), profileWindow(title: "Other")], accessible: [accessible]).isEmpty)
    }

    func testPrivateGuestModalAndUnrecognizedLocalizedTitlesStayUnlabeled() {
        for mode in ["incognito", "guest", "unknown"] {
            let accessible = BrowserTabsAccessibleWindow(title: "Same - Google Chrome - Work", bounds: profileBounds)
            XCTAssertTrue(BrowserTabsProfiles.resolve([profileWindow(mode: mode)], accessible: [accessible]).isEmpty)
        }
        for title in ["Same - Google Chrome (Incognito)", "Dialog", "Same - Google Chrome", "Same / Google Chrome / Work"] {
            let accessible = BrowserTabsAccessibleWindow(title: title, bounds: profileBounds)
            XCTAssertTrue(BrowserTabsProfiles.resolve([profileWindow()], accessible: [accessible]).isEmpty)
        }
    }

    func testMovedWindowsAndStaleActiveTitlesStayUnlabeled() {
        let moved = BrowserTabsBounds(x: 11, y: 20, width: 800, height: 600)
        XCTAssertTrue(BrowserTabsProfiles.resolve([profileWindow()], accessible: [
            BrowserTabsAccessibleWindow(title: "Same - Google Chrome - Work", bounds: moved)]).isEmpty)
        XCTAssertTrue(BrowserTabsProfiles.resolve([profileWindow()], accessible: [
            BrowserTabsAccessibleWindow(title: "Changed - Google Chrome - Work", bounds: profileBounds)]).isEmpty)
        XCTAssertFalse(profileBounds.matches(BrowserTabsBounds(x: .nan, y: 20, width: 800, height: 600)))
        XCTAssertFalse(profileBounds.matches(BrowserTabsBounds(x: 10, y: 20, width: 0, height: 600)))
    }

    func testProfileEnrichmentKeepsIdentityAndIsScopedToBrowserAndProcess() throws {
        let (json, _) = try evaluate(BrowserTabsScripts.collect([
            BrowserTabsTarget(browser: .safari, processId: 100), BrowserTabsTarget(browser: .chrome, processId: 200)]))
        let original = try JSONDecoder().decode(BrowserTabsSnapshot.self, from: Data(json.utf8))
        let tabs = BrowserTabsProfiles.applying(["20": "Work"], processId: 200, to: original.tabs)
        XCTAssertEqual(tabs.map(\.identity), original.tabs.map(\.identity))
        XCTAssertEqual(tabs.map(\.profileName), [nil, nil, "Work", "Work"])
        XCTAssertEqual(tabs.last?.browserLabel, "Chrome · Work")
        XCTAssertTrue(try XCTUnwrap(tabs.last).matches("chrome work same"))
        XCTAssertEqual(BrowserTabsProfiles.applying(["20": "Other"], processId: 201, to: tabs), tabs)
        XCTAssertNil(BrowserTabsProfiles.applying([:], processId: 200, to: tabs).last?.profileName)
    }

    func testLegacySnapshotDecodesWithoutProfileMetadata() throws {
        let snapshot = try JSONDecoder().decode(BrowserTabsSnapshot.self, from: Data("{\"tabs\":[],\"issues\":[]}".utf8))
        XCTAssertNil(snapshot.windows)
    }

    func testIncompleteScriptingWindowInventoryDoesNotClaimAUniqueProfileMatch() throws {
        let (json, _) = try evaluate(BrowserTabsScripts.collect([BrowserTabsTarget(browser: .chrome, processId: 200)]),
                                   extra: """
                                   var otherWindow = Object.create(chromeWindow);
                                   otherWindow.id = function(){return 21;};
                                   otherWindow.bounds = function(){throw new Error('Unavailable');};
                                   Application = function(){return {running:function(){return true;},
                                       windows:function(){return [chromeWindow, otherWindow];}};};
                                   """)
        let snapshot = try JSONDecoder().decode(BrowserTabsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.tabs.count, 4)
        XCTAssertEqual(snapshot.windows, [])
    }

    func testMalformedOptionalWindowMetadataDoesNotInvalidateTabCollection() throws {
        let (json, _) = try evaluate(BrowserTabsScripts.collect([BrowserTabsTarget(browser: .chrome, processId: 200)]),
                                   extra: "chromeWindow.bounds = function(){return null;};")
        let snapshot = try JSONDecoder().decode(BrowserTabsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.tabs.count, 2)
        XCTAssertNil(snapshot.windows)
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    func testProfileArrivalFiltersAlreadyDisplayedTabsAndPreservesSelection() throws {
        _ = NSApplication.shared
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        let profilesStarted = expectation(description: "profile enrichment started")
        collector.onCollect = { started.fulfill() }
        collector.onCollectProfiles = { profilesStarted.fulfill() }
        let panel = BrowserTabsPanel(collector: collector)
        defer { panel.dismiss() }
        panel.present()
        wait(for: [started], timeout: 1)
        collector.completion?(.success(BrowserTabsSnapshot(tabs: sampleTabs(), issues: [], windows: [profileWindow()])))
        XCTAssertEqual(panel.numberOfRows(in: NSTableView()), 3)
        wait(for: [profilesStarted], timeout: 1)
        let table = try XCTUnwrap(findTable(try XCTUnwrap(panel.contentView)))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        collector.profileCompletion?(200, ["20": "Work"])
        XCTAssertEqual(table.selectedRow, 1)
        let search = try XCTUnwrap(findSearchField(try XCTUnwrap(panel.contentView)))
        search.stringValue = "work"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(panel.numberOfRows(in: table), 3)
    }

    func testLongProfileLabelsLeaveRoomForTheTabTitle() throws {
        _ = NSApplication.shared
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        collector.onCollect = { started.fulfill() }
        let populatedPanel = BrowserTabsPanel(collector: collector)
        defer { populatedPanel.dismiss() }
        populatedPanel.present()
        wait(for: [started], timeout: 1)
        var tab = try XCTUnwrap(sampleTabs().first)
        tab.profileName = String(repeating: "Long profile ", count: 30)
        collector.completion?(.success(BrowserTabsSnapshot(tabs: [tab], issues: [])))
        let table = try XCTUnwrap(findTable(try XCTUnwrap(populatedPanel.contentView)))
        let cell = try XCTUnwrap(populatedPanel.tableView(table, viewFor: nil, row: 0))
        cell.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
        cell.layoutSubtreeIfNeeded()
        let labels = cell.subviews.compactMap { $0 as? NSTextField }
        let browser = try XCTUnwrap(labels.first { $0.stringValue == tab.browserLabel })
        let title = try XCTUnwrap(labels.first { $0.stringValue == tab.displayTitle })
        XCTAssertLessThanOrEqual(browser.alignmentRect(forFrame: browser.frame).width, 180)
        XCTAssertGreaterThan(title.frame.width, 300)
        XCTAssertTrue(cell.toolTip?.contains(tab.browserLabel) == true)
    }

    func testLateProfileResultsCannotChangeANewerRefreshOrReopenedPanel() throws {
        _ = NSApplication.shared
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        let profilesStarted = expectation(description: "profile enrichment started")
        collector.onCollect = { started.fulfill() }
        collector.onCollectProfiles = { profilesStarted.fulfill() }
        let panel = BrowserTabsPanel(collector: collector)
        defer { panel.dismiss() }
        panel.present()
        wait(for: [started], timeout: 1)
        collector.completion?(.success(BrowserTabsSnapshot(tabs: sampleTabs(), issues: [], windows: [profileWindow()])))
        wait(for: [profilesStarted], timeout: 1)
        let lateProfiles = try XCTUnwrap(collector.profileCompletion)
        let refreshed = expectation(description: "refresh started")
        collector.onCollect = { refreshed.fulfill() }
        collector.onCollectProfiles = nil
        _ = panel.handle(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: UInt16(kVK_ANSI_R))))
        wait(for: [refreshed], timeout: 1)
        collector.completion?(.success(BrowserTabsSnapshot(tabs: sampleTabs(), issues: [], windows: [profileWindow()])))
        lateProfiles(200, ["20": "Stale"])
        let search = try XCTUnwrap(findSearchField(try XCTUnwrap(panel.contentView)))
        search.stringValue = "stale"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(panel.numberOfRows(in: NSTableView()), 0)
        panel.dismiss()
        panel.present()
        lateProfiles(200, ["20": "Stale"])
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(panel.numberOfRows(in: NSTableView()), 0)
    }

    private func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.compactMap { findTable($0) }.first
    }

    func testChromeActivationFindsMovedTabByID() throws {
        let tab = BrowserTab(
            browser: .chrome,
            processId: 200,
            windowId: "old-window",
            tabId: "32",
            index: 1,
            title: "Same",
            url: "https://same.test",
            active: false
        )
        let (json, context) = try evaluate(BrowserTabsScripts.activate(tab))
        XCTAssertTrue(try JSONDecoder().decode(BrowserTabActivation.self, from: Data(json.utf8)).activated)
        XCTAssertEqual(context.evaluateScript("chromeWindow.activeTabIndex")?.toInt32(), 2)
        XCTAssertTrue(try XCTUnwrap(context.evaluateScript("activated")?.toBool()))
    }

    func testSafariRejectsTabThatMovedSinceSnapshot() throws {
        let tab = BrowserTab(
            browser: .safari,
            processId: 100,
            windowId: "10",
            tabId: nil,
            index: 1,
            title: "Second",
            url: "https://two.test",
            active: false
        )
        let (json, context) = try evaluate(BrowserTabsScripts.activate(tab))
        XCTAssertFalse(try JSONDecoder().decode(BrowserTabActivation.self, from: Data(json.utf8)).activated)
        XCTAssertFalse(try XCTUnwrap(context.evaluateScript("activated")?.toBool()))
    }

    func testActivationEscapesUntrustedTitleAndURL() throws {
        let title = "'; this.injected = true; //\n\"quoted\""
        let tab = BrowserTab(
            browser: .safari,
            processId: 100,
            windowId: "10",
            tabId: nil,
            index: 1,
            title: title,
            url: "https://one.test",
            active: false
        )
        let (json, context) = try evaluate(BrowserTabsScripts.activate(tab))
        XCTAssertFalse(try JSONDecoder().decode(BrowserTabActivation.self, from: Data(json.utf8)).activated)
        XCTAssertTrue(try XCTUnwrap(context.evaluateScript("typeof injected === 'undefined'")?.toBool()))
    }

    func testSearchMatchesTermsAcrossTitleURLAndBrowser() {
        let tab = BrowserTab(
            browser: .chrome,
            processId: 200,
            windowId: "20",
            tabId: "31",
            index: 1,
            title: "Café notes",
            url: "https://example.test",
            active: false
        )
        XCTAssertTrue(tab.matches("chrome CAFE example"))
        XCTAssertTrue(tab.matches("   "))
        XCTAssertFalse(tab.matches("chrome missing"))
    }

    func testConsentCompletesBeforeStartingScriptAndDeniedBrowserPreservesOtherTabs() throws {
        var steps = [String]()
        let targets = [BrowserTabsTarget(browser: .safari, processId: 100),
                       BrowserTabsTarget(browser: .chrome, processId: 200)]
        let snapshot = try BrowserTabsCollector.collectSnapshot(targets, requestPermission: { target in
            steps.append(target.browser.name)
            return target.browser == .safari ? -1743 : 0
        }, executeScript: { script in
            XCTAssertEqual(steps, ["Safari", "Chrome"])
            XCTAssertFalse(script.contains("com.apple.Safari\""))
            let (json, _) = try self.evaluate(script)
            return Data(json.utf8)
        })
        XCTAssertEqual(snapshot.tabs.map(\.browser), [.chrome, .chrome])
        XCTAssertEqual(snapshot.windows, [profileWindow()])
        XCTAssertEqual(snapshot.issues, [BrowserTabsIssue(browser: .safari, code: -1743)])
    }

    func testAutomationSetupRequestsEveryBrowserAndKeepsDenialsSeparate() {
        let targets = [BrowserTabsTarget(browser: .safari, processId: 100),
                       BrowserTabsTarget(browser: .chrome, processId: 200)]
        var requested = [TabBrowser]()
        let issues = BrowserTabsCollector.automationIssues(targets, requestPermission: { target in
            requested.append(target.browser)
            return target.browser == .safari ? -1743 : 0
        })
        XCTAssertEqual(requested, [.safari, .chrome])
        XCTAssertEqual(issues, [BrowserTabsIssue(browser: .safari, code: -1743)])
        XCTAssertTrue(BrowserTabsCollector.automationIssues([], requestPermission: { _ in
            XCTFail("Setup must not request consent without a running browser")
            return 0
        }).isEmpty)
    }

    func testDeniedConsentDoesNotStartScript() throws {
        let snapshot = try BrowserTabsCollector.collectSnapshot(
            [BrowserTabsTarget(browser: .chrome, processId: 200)],
            requestPermission: { _ in -1743 },
            executeScript: { _ in
                XCTFail("A denied browser must not start the timed script")
                return Data()
            }
        )
        XCTAssertTrue(snapshot.tabs.isEmpty)
        XCTAssertEqual(snapshot.issues, [BrowserTabsIssue(browser: .chrome, code: -1743)])
    }

    func testPermissionDialogFocusLossKeepsPanelOpenUntilCollectionFinishes() {
        _ = NSApplication.shared
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        collector.onCollect = { started.fulfill() }
        let panel = BrowserTabsPanel(collector: collector)
        panel.present()
        wait(for: [started], timeout: 1)
        panel.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.hidesOnDeactivate)
        collector.completion?(.success(BrowserTabsSnapshot(tabs: [], issues: [])))
        XCTAssertTrue(panel.isVisible)
        panel.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        XCTAssertFalse(panel.isVisible)
    }

    func testDismissDuringConsentDoesNotReopenPanelWhenCollectionFinishes() {
        _ = NSApplication.shared
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        collector.onCollect = { started.fulfill() }
        let panel = BrowserTabsPanel(collector: collector)
        panel.present()
        wait(for: [started], timeout: 1)
        panel.dismiss()
        collector.completion?(.success(BrowserTabsSnapshot(tabs: [], issues: [])))
        XCTAssertFalse(panel.isVisible)
    }

    func testLauncherSearchIsVisibleAndFiltersTabs() throws {
        _ = NSApplication.shared
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        collector.onCollect = { started.fulfill() }
        let panel = BrowserTabsPanel(collector: collector)
        panel.present()
        wait(for: [started], timeout: 1)
        let tabs = ["Zebra notes", "Account"].enumerated().map { offset, title in
            BrowserTab(browser: .chrome, processId: 200, windowId: "20", tabId: String(offset),
                       index: offset + 1, title: title, url: "https://example.test", active: false)
        }
        collector.completion?(.success(BrowserTabsSnapshot(tabs: tabs, issues: [])))
        let search = try XCTUnwrap(try findSearchField(XCTUnwrap(panel.contentView)))
        XCTAssertFalse(search.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(search.isBezeled)
        XCTAssertTrue(search.isEditable)
        XCTAssertTrue(search.isSelectable)
        XCTAssertEqual(panel.numberOfRows(in: NSTableView()), 2)
        search.stringValue = "z"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertFalse(search.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(search.stringValue, "z")
        XCTAssertEqual(panel.numberOfRows(in: NSTableView()), 1)
        panel.dismiss()
    }

    func testModifierReleaseKeepsATabShortcutOpenWhenConfiguredToKeepOpen() {
        _ = NSApplication.shared
        Preferences.tabBehaviors[2] = .keepOpen
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        collector.onCollect = { started.fulfill() }
        let panel = BrowserTabsPanel(collector: collector)
        defer { panel.dismiss(); Preferences.tabBehaviors.removeValue(forKey: 2) }
        panel.present(shortcutIndex: 2)
        wait(for: [started], timeout: 1)
        collector.completion?(.success(BrowserTabsSnapshot(tabs: sampleTabs(), issues: [])))
        ModifierFlags.current = []
        panel.modifiersReleased()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(collector.activatedTabs.isEmpty)
    }

    func testModifierReleaseDuringCollectionCommitsTheNextTabWhenReady() {
        _ = NSApplication.shared
        Preferences.tabBehaviors[2] = .switchOnRelease
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        collector.onCollect = { started.fulfill() }
        let panel = BrowserTabsPanel(collector: collector)
        defer { panel.dismiss(); Preferences.tabBehaviors.removeValue(forKey: 2) }
        panel.present(shortcutIndex: 2)
        wait(for: [started], timeout: 1)
        ModifierFlags.current = []
        ControlsTab.shortcutsActionsTriggered = []
        handleKeyboardEvent(nil, nil, nil, [], false)
        XCTAssertTrue(collector.activatedTabs.isEmpty)
        collector.completion?(.success(BrowserTabsSnapshot(tabs: sampleTabs(), issues: [])))
        XCTAssertEqual(collector.activatedTabs.map { $0.tabId }, ["tab-1"])
        collector.activationCompletion?(.success(true))
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(BrowserTabsPanel.activeShortcutIndex)
    }

    func testRepeatedTabShortcutAdvancesWhileCollectionIsPending() {
        _ = NSApplication.shared
        Preferences.tabBehaviors[2] = .switchOnRelease
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        collector.onCollect = { started.fulfill() }
        let panel = BrowserTabsPanel(collector: collector)
        defer { panel.dismiss(); Preferences.tabBehaviors.removeValue(forKey: 2) }
        panel.present(shortcutIndex: 2)
        wait(for: [started], timeout: 1)
        panel.present(shortcutIndex: 2)
        panel.modifiersReleased()
        collector.completion?(.success(BrowserTabsSnapshot(tabs: sampleTabs(), issues: [])))
        XCTAssertEqual(collector.activatedTabs.map { $0.tabId }, ["tab-2"])
    }

    func testBrowserScopeIsAppliedBeforeCollection() {
        _ = NSApplication.shared
        Preferences.tabScopes[2] = .chrome
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        collector.onCollect = { started.fulfill() }
        let panel = BrowserTabsPanel(collector: collector)
        defer { panel.dismiss(); Preferences.tabScopes.removeValue(forKey: 2) }
        panel.present(shortcutIndex: 2)
        wait(for: [started], timeout: 1)
        XCTAssertEqual(collector.requestedBrowsers, [.chrome])
    }

    func testMenuInvocationKeepsThePanelOpenEvenWhenTheShortcutSwitchesOnRelease() {
        _ = NSApplication.shared
        Preferences.tabBehaviors[0] = .switchOnRelease
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        collector.onCollect = { started.fulfill() }
        let panel = BrowserTabsPanel(collector: collector)
        defer { panel.dismiss(); Preferences.tabBehaviors.removeValue(forKey: 0) }
        panel.present()
        wait(for: [started], timeout: 1)
        collector.completion?(.success(BrowserTabsSnapshot(tabs: sampleTabs(), issues: [])))
        panel.modifiersReleased()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(collector.activatedTabs.isEmpty)
        XCTAssertNil(BrowserTabsPanel.activeShortcutIndex)
        XCTAssertFalse(findButton(panel.contentView!, title: "Switch  ↵")!.superview!.isHidden)
    }

    func testSwitchOnReleaseHidesTheActionAndReclaimsTheFooter() throws {
        _ = NSApplication.shared
        Preferences.tabBehaviors[2] = .switchOnRelease
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        collector.onCollect = { started.fulfill() }
        let panel = BrowserTabsPanel(collector: collector)
        defer { panel.dismiss(); Preferences.tabBehaviors.removeValue(forKey: 2) }
        panel.present(shortcutIndex: 2)
        wait(for: [started], timeout: 1)
        collector.completion?(.success(BrowserTabsSnapshot(tabs: sampleTabs(), issues: [])))
        let button = try XCTUnwrap(findButton(panel.contentView!, title: "Switch  ↵"))
        XCTAssertTrue(button.superview!.isHidden)
        XCTAssertTrue(button.superview!.superview!.isHidden)
        let compactHeight = panel.frame.height
        Preferences.tabBehaviors[2] = .keepOpen
        panel.dismiss()
        panel.present(shortcutIndex: 2)
        XCTAssertFalse(button.superview!.isHidden)
        XCTAssertEqual(panel.frame.height - compactHeight, TitlesStyle.footerHeight)
    }

    func testSwitchOnReleaseKeepsRefreshVisibleWithoutSearch() throws {
        _ = NSApplication.shared
        Preferences.tabBehaviors[2] = .switchOnRelease
        Preferences.disabledSearchShortcuts.insert(2)
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        collector.onCollect = { started.fulfill() }
        let panel = BrowserTabsPanel(collector: collector)
        defer { panel.dismiss(); Preferences.tabBehaviors.removeValue(forKey: 2); Preferences.disabledSearchShortcuts.remove(2) }
        panel.present(shortcutIndex: 2)
        wait(for: [started], timeout: 1)
        collector.completion?(.success(BrowserTabsSnapshot(tabs: sampleTabs(), issues: [])))
        XCTAssertTrue(findButton(panel.contentView!, title: "Switch  ↵")!.superview!.isHidden)
        let refresh = try XCTUnwrap(findButton(panel.contentView!, title: "Refresh"))
        XCTAssertFalse(refresh.superview!.isHidden)
    }

    private func sampleTabs() -> [BrowserTab] {
        (0..<3).map { index in
            BrowserTab(browser: .chrome, processId: 200, windowId: "20", tabId: "tab-\(index)",
                index: index + 1, title: "Tab \(index)", url: "https://example.test/\(index)", active: index == 0)
        }
    }

    func testDisabledSearchRemovesTheHeaderButKeepsKeyboardNavigationAndRefresh() throws {
        _ = NSApplication.shared
        Preferences.disabledSearchShortcuts.insert(2)
        let collector = DeferredBrowserTabsCollector()
        let started = expectation(description: "collection started")
        collector.onCollect = { started.fulfill() }
        let panel = BrowserTabsPanel(collector: collector)
        defer { panel.dismiss(); Preferences.disabledSearchShortcuts.remove(2) }
        panel.present(shortcutIndex: 2)
        wait(for: [started], timeout: 1)
        collector.completion?(.success(BrowserTabsSnapshot(tabs: sampleTabs(), issues: [])))
        let search = try XCTUnwrap(findSearchField(panel.contentView!))
        XCTAssertTrue(search.superview!.isHidden)
        XCTAssertFalse(search.isEditable)
        XCTAssertFalse(panel.firstResponder === search.currentEditor())
        search.stringValue = "missing"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(panel.numberOfRows(in: NSTableView()), 3)
        let refresh = try XCTUnwrap(findButton(panel.contentView!, title: "Refresh"))
        XCTAssertFalse(refresh.superview!.isHidden)
        let arrow = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_DownArrow)))
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(kVK_Return)))
        XCTAssertNil(panel.handle(arrow))
        XCTAssertNil(panel.handle(enter))
        XCTAssertEqual(collector.activatedTabs.map { $0.tabId }, ["tab-1"])
    }

    func testDisabledSearchReclaimsItsHeightWithoutChangingTheScreenLimit() {
        let withSearch = TitlesStyle.panelHeight(rowsHeight: 200, screenHeight: 900)
        let withoutSearch = TitlesStyle.panelHeight(rowsHeight: 200, screenHeight: 900, showsSearch: false)
        XCTAssertEqual(withSearch - withoutSearch, TitlesStyle.headerHeight)
        XCTAssertEqual(TitlesStyle.panelHeight(rowsHeight: 2000, screenHeight: 900, showsSearch: false), 876)
    }

    private func findButton(_ view: NSView, title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.findButton($0, title: title) }.first
    }

    private func findSearchField(_ view: NSView) -> LauncherSearchField? {
        if let search = view as? LauncherSearchField {
            return search
        }
        return view.subviews.compactMap { findSearchField($0) }.first
    }
}

private final class DeferredBrowserTabsCollector: BrowserTabsCollecting {
    var onCollect: (() -> Void)?
    var onCollectProfiles: (() -> Void)?
    var profileCompletion: ((Int32, [String: String]) -> Void)?
    var completion: ((Result<BrowserTabsSnapshot, Error>) -> Void)?
    var activationCompletion: ((Result<Bool, Error>) -> Void)?
    var activatedTabs = [BrowserTab]()
    var requestedBrowsers = Set<TabBrowser>()
    func collect(browsers: Set<TabBrowser>, _ completion: @escaping (Result<BrowserTabsSnapshot, Error>) -> Void) {
        requestedBrowsers = browsers
        self.completion = completion
        onCollect?()
    }

    func collectProfiles(_ windows: [BrowserTabsWindow], completion: @escaping (Int32, [String: String]) -> Void) {
        profileCompletion = completion
        onCollectProfiles?()
    }

    func activate(_ tab: BrowserTab, completion: @escaping (Result<Bool, Error>) -> Void) {
        activatedTabs.append(tab)
        activationCompletion = completion
    }
}
