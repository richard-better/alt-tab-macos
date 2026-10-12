import Foundation

struct BrowserTabsWindow: Codable, Equatable {
    let processId: Int32
    let windowId: String
    let activeTitle: String
    let mode: String
    let bounds: BrowserTabsBounds
}

struct BrowserTabsBounds: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    func matches(_ other: Self) -> Bool {
        guard width > 0, height > 0, other.width > 0, other.height > 0 else { return false }
        return zip([x, y, width, height], [other.x, other.y, other.width, other.height])
            .allSatisfy { $0.isFinite && $1.isFinite && abs($0 - $1) < 1 }
    }
}

struct BrowserTabsAccessibleWindow {
    let title: String
    let bounds: BrowserTabsBounds
}

enum BrowserTabsProfiles {
    // Chrome's scripting IDs differ from native window IDs. Join both snapshots only when the
    // geometry and active-title match is unique in both directions; never resolve a collision by order.
    static func resolve(_ windows: [BrowserTabsWindow], accessible: [BrowserTabsAccessibleWindow]) -> [String: String] {
        var profiles = [String: String]()
        for window in windows where window.mode == "normal" {
            guard windows.filter({ $0.windowId == window.windowId }).count == 1 else { continue }
            let candidates = accessible.filter { matches(window, $0) }
            guard candidates.count == 1, let candidate = candidates.first,
                  windows.filter({ matches($0, candidate) }).count == 1,
                  let name = profileName(candidate.title, activeTitle: window.activeTitle) else { continue }
            profiles[window.windowId] = name
        }
        return profiles
    }

    private static func matches(_ window: BrowserTabsWindow, _ accessible: BrowserTabsAccessibleWindow) -> Bool {
        !window.activeTitle.isEmpty && window.bounds.matches(accessible.bounds)
            && accessible.title.hasPrefix(window.activeTitle + " - Google Chrome")
    }

    // Chromium's IDS_ACCESSIBLE_WINDOW_TITLE_WITH_PROFILE_FORMAT appends the profile to the browser
    // title. Accept this verified format only; different localized formats and modal titles stay unknown.
    static func profileName(_ title: String, activeTitle: String) -> String? {
        let prefix = activeTitle + " - Google Chrome - "
        guard !activeTitle.isEmpty, title.hasPrefix(prefix) else { return nil }
        let name = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func applying(_ profiles: [String: String], processId: Int32, to tabs: [BrowserTab]) -> [BrowserTab] {
        tabs.map { tab in
            guard tab.browser == .chrome, tab.processId == processId else { return tab }
            var tab = tab
            tab.profileName = profiles[tab.windowId]
            return tab
        }
    }
}
