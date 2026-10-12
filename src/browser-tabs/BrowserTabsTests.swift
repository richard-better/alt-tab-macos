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
    var chromeWindow = {id: function(){return 20;}, tabs: function(){return chromeTabs;}, activeTabIndex: function(){return 1;}};
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
        XCTAssertEqual(snapshot.issues, [BrowserTabsIssue(browser: .safari, code: -1743)])
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
}

private final class DeferredBrowserTabsCollector: BrowserTabsCollecting {
    var onCollect: (() -> Void)?
    var completion: ((Result<BrowserTabsSnapshot, Error>) -> Void)?
    func collect(_ completion: @escaping (Result<BrowserTabsSnapshot, Error>) -> Void) {
        self.completion = completion
        onCollect?()
    }

    func activate(_: BrowserTab, completion _: @escaping (Result<Bool, Error>) -> Void) {}
}
