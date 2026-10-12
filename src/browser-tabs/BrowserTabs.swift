import Foundation

enum TabBrowser: String, Codable, CaseIterable {
    case safari = "com.apple.Safari"
    case chrome = "com.google.Chrome"
    var name: String {
        self == .safari ? "Safari" : "Chrome"
    }
}

struct BrowserTabsTarget: Codable {
    let browser: TabBrowser
    let processId: Int32
}

struct BrowserTab: Codable, Equatable {
    let browser: TabBrowser
    let processId: Int32
    let windowId: String
    let tabId: String?
    let index: Int
    let title: String
    let url: String
    let active: Bool
    var profileName: String? = nil
    var browserLabel: String {
        profileName.map { "\(browser.name) · \($0)" } ?? browser.name
    }

    var identity: String {
        "\(browser.rawValue):\(processId):\(tabId ?? "\(windowId):\(index)")"
    }

    var displayTitle: String {
        title.isEmpty ? url : title
    }

    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: { $0.isWhitespace }).allSatisfy { term in
            [title, url, browser.name, profileName ?? ""].contains { $0.localizedStandardContains(String(term)) }
        }
    }
}

struct BrowserTabsIssue: Codable, Equatable {
    let browser: TabBrowser
    let code: Int
    var message: String {
        if code == -1743 {
            return "Allow Switcheroo to control \(browser.name) in System Settings > Privacy & Security > Automation."
        }
        return "Could not read \(browser.name) tabs. Try refreshing."
    }
}

struct BrowserTabsSnapshot: Codable {
    let tabs: [BrowserTab]
    let issues: [BrowserTabsIssue]
    var windows: [BrowserTabsWindow]? = nil
}

extension BrowserTabsSnapshot {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try values.decode([BrowserTab].self, forKey: .tabs)
        issues = try values.decode([BrowserTabsIssue].self, forKey: .issues)
        windows = try? values.decodeIfPresent([BrowserTabsWindow].self, forKey: .windows)
    }
}

struct BrowserTabActivation: Codable {
    let activated: Bool
    let code: Int?
}


enum SwitcherTargetPreference: CaseIterable { case windows, browserTabs }
enum TabReleaseBehaviorPreference: CaseIterable { case keepOpen, switchOnRelease }
enum TabBrowserScopePreference: CaseIterable {
    case all, safari, chrome
    var browsers: Set<TabBrowser> {
        switch self {
        case .all: return Set(TabBrowser.allCases)
        case .safari: return [.safari]
        case .chrome: return [.chrome]
        }
    }
}
