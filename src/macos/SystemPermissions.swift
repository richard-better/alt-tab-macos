import Cocoa
import notify
import Carbon

// macOS has some privacy restrictions. The user needs to grant certain permissions, app by app, in System Preferences > Security & Privacy
// There is no public API to observe permission changes. tccd posts the Darwin notification `com.apple.tcc.access.changed` right
// after each write to its database, for any app and service, in both directions (measured on macOS 27: ~30ms after the toggle;
// zero spontaneous posts while idle). `sandboxd` subscribes to it in its launchd plist, in copies from 2020 already. We re-read Accessibility and browser Automation
// permissions on each post, coalesced while a check waits to start. A timed-out read gets three bounded retries; resolved checks do no background work.
// We don't listen to the distributed `com.apple.accessibility.api`: System Settings posts it before tccd writes, see `AccessibilityPermission`.
class SystemPermissions {
    static var preStartupPermissionsPassed = false
    private static var notifyToken = NOTIFY_TOKEN_INVALID
    private static var permissionRetry = PermissionCheckRetry()
    private static let pendingCheckLock = NSLock()
    private static var checkIsPending = false

    static func ensurePermissionsAreGranted() {
        #if DEBUG
        if QaLifecycle.enabled { checkPermissionsSoon(); return }
        #endif
        notify_register_dispatch("com.apple.tcc.access.changed", &notifyToken, BackgroundWork.permissionsCheckQueue.strongUnderlyingQueue) { _ in
            checkPermissionsSoon()
        }
        checkPermissionsSoon()
    }

    /// tccd posts once per write, so a burst of writes (a profile install, an app asking for several services) posts
    /// as many times. A check that hasn't started yet will read the latest state anyway, so later requests join it.
    /// The flag clears as the check starts: a write landing during the reads gets a check of its own.
    static func checkPermissionsSoon() {
        guard markCheckPending() else { return }
        BackgroundWork.permissionsCheckQueue.addOperation {
            pendingCheckLock.lock()
            checkIsPending = false
            pendingCheckLock.unlock()
            permissionRetry.begin()
            checkPermissions()
        }
    }

    private static func markCheckPending() -> Bool {
        pendingCheckLock.lock()
        defer { pendingCheckLock.unlock() }
        guard !checkIsPending else { return false }
        checkIsPending = true
        return true
    }

    private static func checkPermissions() {
        AccessibilityPermission.update()
        let automation = BrowserAutomationPermission.update()
        retryUnknownPermissionCheck(automation == nil)
        Logger.debug { "accessibility:\(AccessibilityPermission.status) automation:\(BrowserAutomationPermission.status)" }
        if !preStartupPermissionsPassed {
            checkPermissionsPreStartup()
        } else {
            checkPermissionsPostStartup()
        }
        DispatchQueue.main.async {
            if PermissionsWindow.shared != nil {
                PermissionsWindow.updatePermissionViews()
            }
        }
    }

    private static func retryUnknownPermissionCheck(_ unknown: Bool) {
        guard let delay = permissionRetry.nextDelay(unknown: unknown) else { return }
        let generation = permissionRetry.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            BackgroundWork.permissionsCheckQueue.addOperation {
                guard permissionRetry.generation == generation else { return }
                checkPermissions()
            }
        }
    }

    private static func checkPermissionsPreStartup() {
        if PermissionFlow.isStartupComplete(accessibility: AccessibilityPermission.status, automation: BrowserAutomationPermission.status,
                    setupCompleted: Preferences.browserAutomationSetupCompleted) {
            DispatchQueue.main.async {
                guard !preStartupPermissionsPassed else { return }
                guard PermissionFlow.isStartupComplete(accessibility: AccessibilityPermission.status, automation: BrowserAutomationPermission.status,
                    setupCompleted: Preferences.browserAutomationSetupCompleted) else {
                    checkPermissionsSoon()
                    return
                }
                Preferences.set("browserAutomationSetupCompleted", "true", false)
                preStartupPermissionsPassed = true
                PermissionsWindow.shared?.close()
                App.continueAppLaunchAfterPermissionsAreGranted()
            }
        } else {
            DispatchQueue.main.async {
                App.showPermissionsWindow()
            }
        }
    }

    private static func checkPermissionsPostStartup() {
        if AccessibilityPermission.status == .notGranted {
            Logger.error { "Accessibility permission revoked while Switcheroo was running; restarting" }
            DispatchQueue.main.async { App.restart() }
        }
    }

    /// macOS shows a permission's prompt only while the app has no entry in that list. Once it has one, switched on or
    /// off, the request returns without showing anything, so we open the pane instead. `TCCAccessPreflight` answers 2
    /// while there is no entry, and 0 once there is, either way (measured on macOS 27).
    static func promptOrOpenPane(_ service: String, _ paneUrl: String, _ prompt: @escaping () -> Void) {
        BackgroundWork.permissionsCheckQueue.addOperation {
            let neverAsked = hasNoEntry(service) ?? true
            DispatchQueue.main.async {
                #if DEBUG
                if QaLifecycle.enabled { QaLifecycle.recordPermissionRequest(service, prompt: neverAsked); return }
                #endif
                if neverAsked {
                    prompt()
                } else {
                    NSWorkspace.shared.open(URL(string: paneUrl)!)
                }
            }
        }
    }

    /// Whether the app has no entry in `service`'s list, or nil if TCC can't say. `TCCAccessPreflight` answers 2 while
    /// there is no entry, and 0 once there is, switched on or off (measured on macOS 27).
    static func hasNoEntry(_ service: String) -> Bool? {
        #if DEBUG
        if QaLifecycle.enabled { return QaLifecycle.permission(service == "kTCCServiceAccessibility" ? 2 : 3) }
        #endif
        return tccAccessPreflight.map { $0(service as CFString, nil) == 2 }
    }

    private typealias TCCAccessPreflight = @convention(c) (CFString, CFDictionary?) -> Int32

    private static let tccAccessPreflight: TCCAccessPreflight? = {
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
              let symbol = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: TCCAccessPreflight.self)
    }()
}

class AccessibilityPermission {
    static var status = PermissionStatus.notGranted

    @discardableResult
    static func update() -> PermissionStatus {
        let previous = status
        status = detect()
        if previous == .notGranted, status == .granted, SystemPermissions.preStartupPermissionsPassed {
            AxObserverRegistry.shared.accessibilityPermissionRestored()
        }
        return status
    }

    // `AXIsProcessTrusted` answers from an in-process cache, refreshed when the distributed `com.apple.accessibility.api`
    // arrives. System Settings posts that notification before tccd writes the change, so the refresh can capture the old
    // value, which then sticks until the next post (measured on macOS 27, in both directions). The private
    // `TCCAccessCheckAuditToken` asks tccd each time (~10ms) and is already correct when `com.apple.tcc.access.changed`
    // arrives. It's exported since at least macOS 10.11; we fall back to `AXIsProcessTrusted` if it's ever gone.
    private static func detect() -> PermissionStatus {
        #if DEBUG
        if QaLifecycle.enabled { return QaLifecycle.permission(0) ? .granted : .notGranted }
        #endif
        if let tccAccessCheckAuditToken {
            return tccAccessCheckAuditToken("kTCCServiceAccessibility" as CFString, ownAuditToken, nil) ? .granted : .notGranted
        }
        return AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue(): false] as CFDictionary) ? .granted : .notGranted
    }

    /// The macOS prompt, whose "Open System Settings" button adds AltTab to the Accessibility list
    /// (switched off) and opens the pane on it.
    static func request() {
        SystemPermissions.promptOrOpenPane("kTCCServiceAccessibility", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary)
        }
    }

    private typealias TCCAccessCheckAuditToken = @convention(c) (CFString, audit_token_t, CFDictionary?) -> Bool

    private static let tccAccessCheckAuditToken: TCCAccessCheckAuditToken? = {
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
              let symbol = dlsym(tcc, "TCCAccessCheckAuditToken") else { return nil }
        return unsafeBitCast(symbol, to: TCCAccessCheckAuditToken.self)
    }()

    private static let ownAuditToken: audit_token_t = {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        return token
    }()
}

enum BrowserAutomationPermission {
    static var status = PermissionStatus.notGranted
    private static let collector = BrowserTabsCollector()
    static private(set) var isRequestInProgress = false

    @discardableResult
    static func update() -> PermissionStatus? {
        #if DEBUG
        if QaLifecycle.enabled {
            status = PermissionFlow.automationStatus(results: [QaLifecycle.permission(1) ? 0 : -1744],
                skipped: Preferences.browserAutomationPermissionSkipped)
            return status
        }
        #endif
        let results = BrowserTabsCollector.runningTargets().map { BrowserTabsCollector.permissionStatus($0, askUserIfNeeded: false) }
        guard !results.contains(OSStatus(errAETimeout)) else { return nil }
        status = PermissionFlow.automationStatus(results: results, skipped: Preferences.browserAutomationPermissionSkipped)
        return status
    }

    static func request() {
        guard !isRequestInProgress else { return }
        Preferences.remove("browserAutomationPermissionSkipped", false)
        #if DEBUG
        if QaLifecycle.enabled {
            QaLifecycle.recordPermissionRequest("kTCCServiceAppleEvents", prompt: QaLifecycle.permission(3))
            return
        }
        #endif
        isRequestInProgress = true
        PermissionsWindow.updatePermissionViews()
        collector.requestAutomation { issues, hasRunningBrowser in
            isRequestInProgress = false
            PermissionsWindow.updatePermissionViews()
            if !hasRunningBrowser {
                PermissionsWindow.showAutomationMessage(NSLocalizedString("Open Safari or Chrome, then try again. You can also continue without browser tabs.", comment: ""))
            } else if !issues.isEmpty {
                PermissionsWindow.showAutomationMessage(issues.map(\.message).joined(separator: "\n"))
                if issues.contains(where: { $0.code == Int(errAEEventNotPermitted) }) { openSettings() }
            }
            SystemPermissions.checkPermissionsSoon()
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    static func waive() {
        Preferences.set("browserAutomationPermissionSkipped", "true")
        SystemPermissions.checkPermissionsSoon()
    }
}
