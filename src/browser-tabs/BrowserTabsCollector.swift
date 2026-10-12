import Carbon
import Cocoa

protocol BrowserTabsCollecting {
    func collect(_ completion: @escaping (Result<BrowserTabsSnapshot, Error>) -> Void)
    func activate(_ tab: BrowserTab, completion: @escaping (Result<Bool, Error>) -> Void)
}

final class BrowserTabsCollector: BrowserTabsCollecting {
    private let queue = DispatchQueue(label: "alt-tab.browser-tabs", qos: .userInitiated)
    func collect(_ completion: @escaping (Result<BrowserTabsSnapshot, Error>) -> Void) {
        queue.async {
            let result = Result { () -> BrowserTabsSnapshot in
                let running = NSWorkspace.shared.runningApplications
                let targets = running.compactMap { app -> BrowserTabsTarget? in
                    guard let id = app.bundleIdentifier,
                          let browser = TabBrowser(rawValue: id) else { return nil }
                    return BrowserTabsTarget(browser: browser, processId: app.processIdentifier)
                }.sorted { ($0.browser.rawValue, $0.processId) < ($1.browser.rawValue, $1.processId) }
                return try Self.collectSnapshot(targets)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func activate(_ tab: BrowserTab, completion: @escaping (Result<Bool, Error>) -> Void) {
        queue.async {
            let result = Result { () -> Bool in
                guard let app = NSRunningApplication(processIdentifier: tab.processId),
                      !app.isTerminated, app.bundleIdentifier == tab.browser.rawValue else { return false }
                let permission = Self.requestPermission(BrowserTabsTarget(
                    browser: tab.browser,
                    processId: tab.processId
                ))
                if permission == errAEEventNotPermitted {
                    throw CollectionError.permissionDenied(tab.browser)
                }
                guard permission == noErr else { throw CollectionError.failed }
                let output = try Self.run(BrowserTabsScripts.activate(tab))
                let response = try JSONDecoder().decode(BrowserTabActivation.self, from: output)
                if response.code == -1743 {
                    throw CollectionError.permissionDenied(tab.browser)
                }
                return response.activated
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func collectSnapshot(
        _ targets: [BrowserTabsTarget],
        requestPermission: (BrowserTabsTarget) -> OSStatus = requestPermission,
        executeScript: (String) throws -> Data = run
    ) throws -> BrowserTabsSnapshot {
        var issues = [BrowserTabsIssue]()
        let permitted = targets.filter { target in
            let status = requestPermission(target)
            guard status != noErr else { return true }
            issues.append(BrowserTabsIssue(browser: target.browser, code: Int(status)))
            return false
        }
        guard !permitted.isEmpty else { return BrowserTabsSnapshot(tabs: [], issues: issues) }
        let output = try executeScript(BrowserTabsScripts.collect(permitted))
        let snapshot = try JSONDecoder().decode(BrowserTabsSnapshot.self, from: output)
        return BrowserTabsSnapshot(tabs: snapshot.tabs, issues: issues + snapshot.issues)
    }

    /// Consent can wait on the user indefinitely. Request it on the collector queue before starting
    /// the child process's timeout, so approving a prompt never leaves an already-terminated script.
    private static func requestPermission(_ target: BrowserTabsTarget) -> OSStatus {
        let descriptor = NSAppleEventDescriptor(processIdentifier: target.processId)
        return AEDeterminePermissionToAutomateTarget(descriptor.aeDesc, typeWildCard, typeWildCard, true)
    }

    private static func run(_ script: String) throws -> Data {
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        deadline.schedule(deadline: .now() + 8)
        deadline.setEventHandler {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        deadline.resume()
        defer { deadline.cancel() }
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else { throw CollectionError.failed }
        return data
    }

    enum CollectionError: LocalizedError {
        case failed
        case permissionDenied(TabBrowser)
        var errorDescription: String? {
            switch self {
            case .failed: return "Browser automation did not finish. Check Automation permissions and try refreshing."
            case let .permissionDenied(browser): return BrowserTabsIssue(
                    browser: browser,
                    code: -1743
                ).message
            }
        }
    }
}
