import Cocoa

/// The setup flow requires Accessibility and offers optional per-browser Automation.
/// Closing before setup completes quits explicitly; the window has no close box.
class PermissionsWindow: NSWindow {
    static let contentWidth = CGFloat(470)
    private static let contentInset = CGFloat(22)
    static var shared: PermissionsWindow!
    /// Whether this launch displayed the permissions flow.
    static private(set) var wasWalkedThisLaunch = false
    override var canBecomeKey: Bool { SecondaryWindows.canBecomeKey }

    private var accessibilityView: PermissionView!
    private var automationView: PermissionView!
    private var primaryButton: NSButton!
    private var waiveView: NSView!
    private let automationMessage = NSTextField(wrappingLabelWithString: "")

    convenience init() {
        self.init(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        delegate = self
        setupWindow()
        setupView()
        Self.shared = self
        Self.updatePermissionViews()
    }

    #if DEBUG
    /// Set by `QaSurfaces` to photograph the window as someone who has not granted anything sees it. Every
    /// permission check calls `updatePermissionViews`, so setting the views once would not hold.
    static var qaForcedStatus: PermissionStatus?
    #endif

    static func updatePermissionViews() {
        guard let window = Self.shared else { return }
        #if DEBUG
        if let forced = qaForcedStatus {
            window.render(forced, forced)
            return
        }
        #endif
        window.render(AccessibilityPermission.status, BrowserAutomationPermission.status)
    }

    static func grantBrowserAutomation() {
        App.showPermissionsWindow()
        BrowserAutomationPermission.request()
    }

    static func showAutomationMessage(_ text: String) {
        shared?.automationMessage.stringValue = text
        shared?.automationMessage.isHidden = false
        shared?.resizeToFit()
    }

    static func show() {
        guard !Self.shared.isVisible else { return }
        Logger.debug { "" }
        wasWalkedThisLaunch = true
        Self.shared.center()
        App.shared.activate(ignoringOtherApps: true)
        Self.shared.makeKeyAndOrderFront(nil)
        SystemPermissions.checkPermissionsSoon()
    }

    private func setupWindow() {
        applySecondaryWindowChrome(NSLocalizedString("Switcheroo requires some permissions", comment: "Permissions window title"))
        isMovableByWindowBackground = true
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            standardWindowButton($0)?.isHidden = true
        }
    }

    private func setupView() {
        let content = NSStackView(views: [makeHeader(), makeAccessibilityView(), makeAutomationView(), makeAutomationMessage()])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.setHuggingPriority(.defaultHigh, for: .vertical)
        let bar = makeBottomBar()
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubviews([content, bar])
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.contentInset),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.contentInset),
            bar.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 18),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            accessibilityView.widthAnchor.constraint(equalTo: content.widthAnchor),
            automationView.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        contentView = root
    }

    private func makeHeader() -> NSView {
        let iconSize = NSSize(width: 50, height: 50)
        let icon = LightImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.updateContents(.cgImage(App.appIcon), iconSize)
        icon.fit(iconSize.width, iconSize.height)
        let text = NSTextField(wrappingLabelWithString: title)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = .systemFont(ofSize: 19.5, weight: .semibold)
        let header = NSStackView(views: [icon, text])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.spacing = 14
        header.alignment = .centerY
        return header
    }

    private func makeAccessibilityView() -> NSView {
        accessibilityView = PermissionView(
            1,
            Self.accessibilityPermissionName(),
            NSLocalizedString("Switcheroo requires this permission to focus windows for you.", comment: "Permissions window"),
            .accessibility)
        return accessibilityView
    }

    /// macOS 27 renamed the Accessibility list "Device Control and Data Access". The card keeps its first half: Grant
    /// lands the user on the list, so it only has to be recognizable there, and "Data Access" would promise more than
    /// AltTab uses. The translations are the first half of Apple's own, from the Privacy & Security pane.
    private static func accessibilityPermissionName() -> String {
        if #available(macOS 27.0, *) {
            return NSLocalizedString("Device Control", comment: "Name of the Accessibility permission since macOS 27: the first half of \"Device Control and Data Access\", as System Settings shows it")
        }
        return NSLocalizedString("Accessibility", comment: "")
    }

    private func makeAutomationView() -> NSView {
        automationView = PermissionView(
            2,
            NSLocalizedString("Browser Automation", comment: ""),
            NSLocalizedString("Allow Switcheroo to read and switch tabs in Safari and Chrome. macOS asks separately for each running browser. This is optional for window switching.", comment: "Permissions window"),
            .automation,
            onGrantAfterSkip: { Self.grantBrowserAutomation() })
        return automationView
    }

    private func makeAutomationMessage() -> NSView {
        automationMessage.translatesAutoresizingMaskIntoConstraints = false
        automationMessage.font = .systemFont(ofSize: 12)
        automationMessage.textColor = .secondaryLabelColor
        automationMessage.isHidden = true
        automationMessage.widthAnchor.constraint(equalToConstant: Self.contentWidth - Self.contentInset * 2).isActive = true
        return automationMessage
    }

    private func makeBottomBar() -> NSView {
        let quit = Button(String(format: NSLocalizedString("Quit %@", comment: "%@ is Switcheroo"), App.name)) { _ in
            App.shared.terminate(nil)
        }
        quit.attributedTitle = NSAttributedString(string: quit.title, attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
        ])
        primaryButton = Button(NSLocalizedString("Grant permission", comment: "Permissions window button")) { [weak self] _ in
            self?.performPrimaryAction()
        }
        primaryButton.keyEquivalent = "\r"
        waiveView = makeWaiveView()
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 12).isActive = true
        let bar = PermissionsBottomBar(views: [quit, spacer, waiveView, primaryButton])
        // The spacer is the gap: the stack's spacing on both of its sides made the bar 11pt wider than the window
        bar.setCustomSpacing(0, after: quit)
        bar.setCustomSpacing(0, after: spacer)
        return bar
    }

    private func makeWaiveView() -> NSView {
        let link = Button(NSLocalizedString("Set up later", comment: "Permissions window")) { _ in
            BrowserAutomationPermission.waive()
        }
        link.isBordered = false
        link.attributedTitle = NSAttributedString(string: link.title, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11.5),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        let stack = NSStackView(views: [link])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 2
        return stack
    }

    private func performPrimaryAction() {
        switch PermissionFlow.primaryAction(accessibility: AccessibilityPermission.status, automation: BrowserAutomationPermission.status) {
            case .grant: grantLiveStep()
            case .close: close()
        }
    }

    private func grantLiveStep() {
        guard let step = PermissionFlow.liveStep(accessibility: AccessibilityPermission.status, automation: BrowserAutomationPermission.status) else { return }
        Logger.debug { "\(step)" }
        switch step {
            case .accessibility: AccessibilityPermission.request()
            case .automation: BrowserAutomationPermission.request()
        }
    }

    private func render(_ accessibility: PermissionStatus, _ automation: PermissionStatus) {
        accessibilityView.update(PermissionFlow.state(of: .accessibility, accessibility: accessibility, automation: automation), accessibility,
            offersGrantAfterSkip: PermissionFlow.offersGrantAfterSkip(.accessibility, accessibility: accessibility, automation: automation))
        automationView.update(PermissionFlow.state(of: .automation, accessibility: accessibility, automation: automation), automation,
            offersGrantAfterSkip: PermissionFlow.offersGrantAfterSkip(.automation, accessibility: accessibility, automation: automation))
        waiveView.isHidden = !PermissionFlow.showsWaiveOption(accessibility: accessibility, automation: automation)
        primaryButton.isEnabled = !BrowserAutomationPermission.isRequestInProgress
        primaryButton.title = PermissionFlow.primaryAction(accessibility: accessibility, automation: automation) == .close
            ? NSLocalizedString("Close", comment: "Permissions window button")
            : NSLocalizedString("Grant permission", comment: "Permissions window button")
        if automation != .notGranted { automationMessage.isHidden = true }
        resizeToFit()
    }

    private func resizeToFit() {
        contentView!.layoutSubtreeIfNeeded()
        setContentSize(contentView!.fittingSize)
    }

    override func close() {
        hideAppIfLastWindowIsClosed()
        super.close()
    }
}

extension PermissionsWindow: NSWindowDelegate {
    /// Cmd-W follows the explicit Quit action until setup completes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !SystemPermissions.preStartupPermissionsPassed else { return true }
        Logger.debug { "accessibility:\(AccessibilityPermission.status), automation:\(BrowserAutomationPermission.status)" }
        App.shared.terminate(self)
        return false // prevent the close; termination will close everything once
    }
}

/// The bar holding the two exits: a hairline above it and a recessed fill, so it reads as window
/// chrome rather than as part of the steps.
private class PermissionsBottomBar: NSView {
    private let stack: NSStackView

    init(views: [NSView]) {
        stack = NSStackView(views: views)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.alignment = .centerY
        stack.spacing = 16
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        ])
    }

    func setCustomSpacing(_ spacing: CGFloat, after view: NSView) {
        stack.setCustomSpacing(spacing, after: view)
    }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}
