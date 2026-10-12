import Cocoa
import ApplicationServices

extension BrowserTabsCollector {
    func collectProfiles(_ windows: [BrowserTabsWindow], completion: @escaping (Int32, [String: String]) -> Void) {
        for (pid, windows) in Dictionary(grouping: windows, by: \.processId) {
            guard windows.contains(where: { $0.mode == "normal" }) else { continue }
            AXCallScheduler.shared.schedule(key: "browser-tab-profiles-\(pid)", pid: pid, scan: true) {
                guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: pid),
                      !app.isTerminated, app.bundleIdentifier == TabBrowser.chrome.rawValue else { return }
                let profiles = BrowserTabsProfiles.resolve(windows, accessible: Self.accessibleWindows(pid))
                DispatchQueue.main.async { completion(pid, profiles) }
            }
        }
    }

    // Optional labels have a short per-call timeout and a total read budget. A busy browser keeps its
    // tabs usable; these reads never queue ahead of collection or activation and are not retried.
    private static func accessibleWindows(_ pid: Int32) -> [BrowserTabsAccessibleWindow] {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        var result = [BrowserTabsAccessibleWindow]()
        for window in windows {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            AXUIElementSetMessagingTimeout(window, 0.15)
            var values: CFArray?
            let attributes = [kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
            guard AXUIElementCopyMultipleAttributeValues(window, attributes, [], &values) == .success,
                  let values = values as? [Any], values.count == 3,
                  let title = values[0] as? String,
                  CFGetTypeID(values[1] as CFTypeRef) == AXValueGetTypeID(),
                  CFGetTypeID(values[2] as CFTypeRef) == AXValueGetTypeID() else { return [] }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(values[1] as! AXValue, .cgPoint, &point),
                  AXValueGetValue(values[2] as! AXValue, .cgSize, &size) else { return [] }
            result.append(BrowserTabsAccessibleWindow(title: title, bounds: BrowserTabsBounds(
                x: point.x, y: point.y, width: size.width, height: size.height)))
        }
        return ProcessInfo.processInfo.systemUptime < deadline ? result : []
    }
}
