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
}
