import Cocoa

final class BrowserTabsCollector {
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
                guard !targets.isEmpty else { return BrowserTabsSnapshot(tabs: [], issues: []) }
                let output = try Self.run(BrowserTabsScripts.collect(targets))
                return try JSONDecoder().decode(BrowserTabsSnapshot.self, from: output)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func activate(_ tab: BrowserTab, completion: @escaping (Result<Bool, Error>) -> Void) {
        queue.async {
            let result = Result { () -> Bool in
                guard let app = NSRunningApplication(processIdentifier: tab.processId),
                      !app.isTerminated, app.bundleIdentifier == tab.browser.rawValue else { return false }
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
