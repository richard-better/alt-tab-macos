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
    var identity: String {
        "\(browser.rawValue):\(processId):\(tabId ?? "\(windowId):\(index)")"
    }

    var displayTitle: String {
        title.isEmpty ? url : title
    }

    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: { $0.isWhitespace }).allSatisfy { term in
            [title, url, browser.name].contains { $0.localizedStandardContains(String(term)) }
        }
    }
}

struct BrowserTabsIssue: Codable, Equatable {
    let browser: TabBrowser
    let code: Int
    var message: String {
        if code == -1743 {
            return "Allow AltTab to control \(browser.name) in System Settings > Privacy & Security > Automation."
        }
        return "Could not read \(browser.name) tabs. Try refreshing."
    }
}

struct BrowserTabsSnapshot: Codable {
    let tabs: [BrowserTab]
    let issues: [BrowserTabsIssue]
}

struct BrowserTabActivation: Codable {
    let activated: Bool
    let code: Int?
}
