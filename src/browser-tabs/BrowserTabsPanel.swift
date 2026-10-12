import Carbon.HIToolbox.Events
import Cocoa

final class BrowserTabsPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate,
    NSWindowDelegate {
    private(set) static var instance: BrowserTabsPanel?
    private static var shared: BrowserTabsPanel {
        if let instance {
            return instance
        }
        let panel = BrowserTabsPanel()
        instance = panel
        return panel
    }

    private let collector: BrowserTabsCollecting
    private let search = LauncherSearchField()
    private let searchIcon = TitlesStyle.makeSearchIcon()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var style = TitlesStyle(scale: .medium, isDark: false)
    private var browserIcons = [TabBrowser: NSImage]()
    private var background: NSView!
    private var stack: NSStackView!
    private var header: NSStackView!
    private var footer: NSStackView!
    private var scrollHeight: NSLayoutConstraint!
    private let launcherFooter = LauncherFooterView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(
        title: NSLocalizedString("Refresh", comment: ""),
        target: nil,
        action: nil
    )
    private let automationButton = NSButton(
        title: NSLocalizedString("Automation settings…", comment: ""),
        target: nil,
        action: nil
    )
    private var snapshot = BrowserTabsSnapshot(tabs: [], issues: [])
    private var rows = [BrowserTab]()
    private var generation = 0
    private var collecting = false
    private var activating = false
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    init(collector: BrowserTabsCollecting = BrowserTabsCollector()) {
        self.collector = collector
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 450),
            styleMask: .nonactivatingPanel,
            backing: .buffered,
            defer: false
        )
        title = NSLocalizedString("Browser tabs", comment: "")
        setAccessibilityLabel(title)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        delegate = self
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    @objc static func show() {
        App.hideUi()
        shared.present()
    }

    func present() {
        if isVisible {
            moveSelection(1)
            return
        }
        generation += 1
        let ticket = generation
        header.isHidden = false
        footer.isHidden = false
        automationButton.isHidden = true
        status.isHidden = true
        applyAppearance()
        center()
        makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, isVisible, generation == ticket else { return }
            search.stringValue = ""
            filterRows()
            makeFirstResponder(search)
            refresh()
        }
    }

    func dismiss() {
        guard isVisible else { return }
        generation += 1
        activating = false
        orderOut(nil)
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        dismiss()
        return false
    }

    func windowDidResignKey(_: Notification) {
        guard !collecting, !activating else { return }
        dismiss()
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == kVK_ANSI_R, event.modifierFlags.contains(.command) {
            refresh()
            return nil
        }
        guard event.type == .keyDown, !event.modifierFlags.contains(.command) else { return event }
        switch Int(event.keyCode) {
        case kVK_Tab: moveSelection(event.modifierFlags.contains(.shift) ? -1 : 1)
        case kVK_UpArrow: moveSelection(-1)
        case kVK_DownArrow: moveSelection(1)
        case kVK_Return, kVK_ANSI_KeypadEnter: activateSelection()
        case kVK_Escape: dismiss()
        default: return event
        }
        return nil
    }

    func controlTextDidChange(_: Notification) {
        filterRows()
    }

    func numberOfRows(in _: NSTableView) -> Int {
        rows.count
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let tab = rows[row]
        let identifier = NSUserInterfaceItemIdentifier("browserTab")
        let cell = table.makeView(withIdentifier: identifier, owner: nil) as? BrowserTabCellView ??
            BrowserTabCellView()
        cell.identifier = identifier
        cell.update(tab, icon: browserIcon(tab.browser), style: style)
        return cell
    }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        BrowserTabRowView()
    }

    private func browserIcon(_ browser: TabBrowser) -> NSImage? {
        if let icon = browserIcons[browser] {
            return icon
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.rawValue)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        browserIcons[browser] = icon
        return icon
    }

    private func applyAppearance() {
        style = Appearance.titlesStyle
        appearance = style.appearance
        table.rowHeight = style.rowHeight
        if background == nil {
            setupBackground()
        }
        style.updateBackground(background)
        updatePanelSize()
        table.reloadData()
    }

    private func setupBackground() {
        background = style.makeBackground()
        let content = TitlesStyle.contentHost(background)
        content.addSubview(stack)
        contentView = background
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: TitlesStyle.windowPadding
            ),
            stack.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -TitlesStyle.windowPadding
            ),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: TitlesStyle.windowPadding),
            stack.bottomAnchor.constraint(
                equalTo: content.bottomAnchor,
                constant: -TitlesStyle.windowPadding
            ),
        ])
    }

    private func updatePanelSize() {
        let screen = screen ?? NSScreen.main
        let width = min(TitlesStyle.panelWidth, (screen?.visibleFrame.width ?? 900) * 0.9)
        let extraHeight = (status.isHidden ? 0 : max(30, status.fittingSize.height))
        let height = TitlesStyle.panelHeight(rowsHeight: (style.rowHeight + 1) * CGFloat(max(1, snapshot.tabs.count)),
            screenHeight: screen?.visibleFrame.height ?? 700, statusHeight: extraHeight)
        let oldCenter = NSPoint(x: frame.midX, y: frame.midY)
        scrollHeight.constant = max(
            style.rowHeight,
            height - TitlesStyle.windowPadding * 2 - TitlesStyle.headerHeight - TitlesStyle.footerHeight -
                extraHeight
        )
        setContentSize(NSSize(width: width, height: height))
        if isVisible, let visible = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: min(max(oldCenter.x - width / 2, visible.minX), visible.maxX - width),
                y: min(max(oldCenter.y - height / 2, visible.minY + 12), visible.maxY - height - 12)))
        }
    }

    private func buildContent() {
        search.applyLauncherStyle(placeholder: NSLocalizedString("Search browser tabs…", comment: ""))
        search.delegate = self
        search.setAccessibilityLabel(NSLocalizedString("Search browser tabs", comment: ""))
        refreshButton.isBordered = false
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: refreshButton.title
        )
        refreshButton.imagePosition = .imageOnly
        refreshButton.toolTip = refreshButton.title
        refreshButton.setAccessibilityLabel(refreshButton.title)
        automationButton.isBordered = false
        automationButton.font = .systemFont(ofSize: 11)
        automationButton.contentTintColor = .secondaryLabelColor
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        automationButton.target = self
        automationButton.action = #selector(openAutomationSettings)
        header = NSStackView(views: [searchIcon, search, refreshButton])
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        header.orientation = .horizontal
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        column.width = 700
        column.resizingMask = .autoresizingMask
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.rowHeight = style.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activateClickedRow)
        table.allowsEmptySelection = false
        table.setAccessibilityLabel(NSLocalizedString("Browser tabs", comment: ""))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 0
        launcherFooter.button.title = NSLocalizedString("Switch  ↵", comment: "")
        launcherFooter.button.target = self
        launcherFooter.button.action = #selector(activateSelection)
        footer = NSStackView(views: [automationButton, launcherFooter])
        footer.orientation = .horizontal
        stack = NSStackView(views: [header, scroll, status, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: style.rowHeight * 8)
        header.isHidden = false
        footer.isHidden = false
        automationButton.isHidden = true
        status.isHidden = true
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            header.heightAnchor.constraint(equalToConstant: TitlesStyle.headerHeight),
            searchIcon.widthAnchor.constraint(equalToConstant: 22),
            searchIcon.heightAnchor.constraint(equalToConstant: 22),
            search.heightAnchor.constraint(equalToConstant: 44),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            footer.heightAnchor.constraint(equalToConstant: TitlesStyle.footerHeight),
            launcherFooter.heightAnchor.constraint(equalToConstant: TitlesStyle.footerHeight),
            launcherFooter.widthAnchor.constraint(greaterThanOrEqualTo: footer.widthAnchor, multiplier: 0.65),
            scrollHeight,
        ])
        applyAppearance()
    }

    @objc private func refresh() {
        guard !collecting, !activating else { return }
        collecting = true
        launcherFooter.button.isEnabled = false
        refreshButton.isEnabled = false
        status.stringValue = NSLocalizedString("Reading Safari and Chrome tabs…", comment: "")
        status.isHidden = false
        updatePanelSize()
        let ticket = generation
        collector.collect { [weak self] result in
            guard let self else { return }
            collecting = false
            refreshButton.isEnabled = true
            guard isVisible else { return }
            guard generation == ticket else {
                refresh()
                return
            }
            switch result {
            case let .success(snapshot):
                self.snapshot = snapshot
                filterRows()
            case .failure:
                status.isHidden = false
                header.isHidden = false
                footer.isHidden = false
                automationButton.isHidden = false
                status.stringValue = NSLocalizedString(
                    "Browser tabs could not be read. Check Automation permissions and try Refresh.",
                    comment: ""
                )
            }
            restoreFocusAfterOperation()
        }
    }

    private func restoreFocusAfterOperation() {
        guard isVisible, !isKeyWindow else { return }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(search)
    }

    private func filterRows() {
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].identity : nil
        rows = snapshot.tabs.filter { $0.matches(search.stringValue) }
        updatePanelSize()
        table.reloadData()
        if !rows.isEmpty {
            let index = selected.flatMap { id in rows.firstIndex { $0.identity == id } } ?? 0
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        launcherFooter.button.isEnabled = !rows.isEmpty && !collecting
        guard !collecting else { return }
        if !snapshot.issues.isEmpty {
            status.isHidden = false
            footer.isHidden = false
            automationButton.isHidden = false
            header.isHidden = false
            status.stringValue = snapshot.issues.map(\.message).joined(separator: "\n")
        } else if snapshot.tabs.isEmpty {
            status.isHidden = false
            status.stringValue = NSLocalizedString(
                "No tabs found. Open Safari or Google Chrome, then Refresh.",
                comment: ""
            )
        } else if rows.isEmpty {
            status.isHidden = false
            status.stringValue = NSLocalizedString("No matching tabs.", comment: "")
        } else {
            status.isHidden = true
            footer.isHidden = false
            automationButton.isHidden = true
            status.stringValue = ""
        }
        updatePanelSize()
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty, !activating else { return }
        let row = (max(0, table.selectedRow) + delta + rows.count) % rows.count
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func activateClickedRow() {
        guard rows.indices.contains(table.clickedRow) else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        activateSelection()
    }

    @objc private func activateSelection() {
        guard !activating, !collecting, rows.indices.contains(table.selectedRow) else { return }
        activating = true
        refreshButton.isEnabled = false
        status.stringValue = NSLocalizedString("Switching to tab…", comment: "")
        launcherFooter.button.isEnabled = false
        let ticket = generation
        collector.activate(rows[table.selectedRow]) { [weak self] result in
            guard let self, generation == ticket else { return }
            activating = false
            launcherFooter.button.isEnabled = true
            refreshButton.isEnabled = true
            switch result {
            case .success(true): dismiss()
            case .success(false): status.isHidden = false
                status.stringValue = NSLocalizedString(
                    "This tab changed or closed. Refresh the list and select it again.",
                    comment: ""
                )
            case let .failure(error): status.isHidden = false
                status.stringValue = error.localizedDescription
            }
            updatePanelSize()
            restoreFocusAfterOperation()
        }
    }

    @objc private func openAutomationSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        )
    }
}

private final class BrowserTabRowView: NSTableRowView {
    private let outline = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        outline.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        outline.isHidden = true
        layer?.addSublayer(outline)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    override func drawBackground(in dirtyRect: NSRect) {
        outline.isHidden = !isSelected
        super.drawBackground(in: dirtyRect)
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }

    override func drawSelection(in _: NSRect) {
        outline.frame = NSRect(x: 0, y: 0, width: min(bounds.width, visibleRect.width), height: bounds.height)
        TitlesStyle.applySelection(outline)
        outline.isHidden = false
    }
}

private final class BrowserTabCellView: NSTableCellView {
    private let icon = NSImageView()
    private let browser = NSTextField(labelWithString: "")
    private let label = TileTitleView(font: .systemFont(ofSize: 14), color: .labelColor)
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!
    private var labelHeight: NSLayoutConstraint!
    init() {
        super.init(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.shadow = TitlesStyle.appIconShadow(.gray.withAlphaComponent(0.8))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.font = .systemFont(ofSize: 12)
        browser.textColor = .secondaryLabelColor
        browser.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        addSubview(browser)
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 24)
        iconHeight = icon.heightAnchor.constraint(equalTo: icon.widthAnchor)
        labelHeight = label.heightAnchor.constraint(equalToConstant: 20)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth, iconHeight, labelHeight,
            label.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor,
                constant: TitlesStyle.iconLabelSpacing
            ),
            label.trailingAnchor.constraint(equalTo: browser.leadingAnchor, constant: -12),
            browser.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            browser.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    func update(_ tab: BrowserTab, icon: NSImage?, style: TitlesStyle) {
        self.icon.image = icon
        browser.stringValue = tab.browser.name
        iconWidth.constant = style.iconSize
        label.stringValue = tab.displayTitle
        label.font = style.font
        label.textColor = style.textColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .natural
        paragraph.baseWritingDirection = .leftToRight
        paragraph.lineBreakMode = .byTruncatingTail
        label.attributedStringValue = NSAttributedString(string: tab.displayTitle,
                                                         attributes: [
                                                             .font: style.font,
                                                             .foregroundColor: style.textColor,
                                                             .paragraphStyle: paragraph,
                                                         ])
        labelHeight.constant = label.cell!.cellSize.height
        toolTip = "\(tab.displayTitle)\n\(tab.url)"
        setAccessibilityLabel("\(tab.displayTitle), \(tab.browser.name), \(tab.url)")
    }
}
