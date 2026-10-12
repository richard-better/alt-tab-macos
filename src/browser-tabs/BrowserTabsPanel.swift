import Carbon.HIToolbox.Events
import Cocoa

final class BrowserTabsPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
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

    private let collector = BrowserTabsCollector()
    private let search = NSSearchField()
    private let table = NSTableView()
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

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = NSLocalizedString("Browser tabs", comment: "")
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = true
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
        dismiss()
    }

    func handle(_ event: NSEvent) -> NSEvent? {
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
        let title = NSTextField(labelWithString: tab.displayTitle)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: "\(tab.browser.name) · \(tab.url)")
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11)
        detail.lineBreakMode = .byTruncatingMiddle
        let cell = NSStackView(views: [title, detail])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 3
        cell.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        title.widthAnchor.constraint(equalTo: cell.widthAnchor, constant: -16).isActive = true
        detail.widthAnchor.constraint(equalTo: title.widthAnchor).isActive = true
        cell.setAccessibilityLabel("\(tab.displayTitle), \(tab.browser.name), \(tab.url)")
        return cell
    }

    private func buildContent() {
        search.placeholderString = NSLocalizedString("Search tab titles, addresses or browsers", comment: "")
        search.delegate = self
        search.setAccessibilityLabel(NSLocalizedString("Search browser tabs", comment: ""))
        refreshButton.bezelStyle = .rounded
        automationButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        automationButton.target = self
        automationButton.action = #selector(openAutomationSettings)
        let header = NSStackView(views: [search, refreshButton])
        header.orientation = .horizontal
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        column.width = 644
        column.resizingMask = .autoresizingMask
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 50
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activateClickedRow)
        table.allowsEmptySelection = false
        table.setAccessibilityLabel(NSLocalizedString("Browser tabs", comment: ""))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 0
        let help = NSTextField(labelWithString: NSLocalizedString(
            "Tab or arrows to select · Return to switch · Escape to close",
            comment: ""
        ))
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [help, automationButton])
        footer.orientation = .horizontal
        let stack = NSStackView(views: [header, scroll, status, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    @objc private func refresh() {
        guard !collecting, !activating else { return }
        collecting = true
        refreshButton.isEnabled = false
        status.stringValue = NSLocalizedString("Reading Safari and Chrome tabs…", comment: "")
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
                status.stringValue = NSLocalizedString(
                    "Browser tabs could not be read. Check Automation permissions and try Refresh.",
                    comment: ""
                )
            }
        }
    }

    private func filterRows() {
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].identity : nil
        rows = snapshot.tabs.filter { $0.matches(search.stringValue) }
        table.reloadData()
        if !rows.isEmpty {
            let index = selected.flatMap { id in rows.firstIndex { $0.identity == id } } ?? 0
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        guard !collecting else { return }
        if !snapshot.issues.isEmpty {
            status.stringValue = snapshot.issues.map(\.message).joined(separator: "\n")
        } else if snapshot.tabs.isEmpty {
            status.stringValue = NSLocalizedString(
                "No tabs found. Open Safari or Google Chrome, then Refresh.",
                comment: ""
            )
        } else if rows.isEmpty {
            status.stringValue = NSLocalizedString("No matching tabs.", comment: "")
        } else {
            status.stringValue = String(format: NSLocalizedString("%d tabs", comment: ""), rows.count)
        }
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

    private func activateSelection() {
        guard !activating, !collecting, rows.indices.contains(table.selectedRow) else { return }
        activating = true
        refreshButton.isEnabled = false
        status.stringValue = NSLocalizedString("Switching to tab…", comment: "")
        let ticket = generation
        collector.activate(rows[table.selectedRow]) { [weak self] result in
            guard let self, generation == ticket else { return }
            activating = false
            refreshButton.isEnabled = true
            switch result {
            case .success(true): dismiss()
            case .success(false): status.stringValue = NSLocalizedString(
                    "This tab changed or closed. Refresh the list and select it again.",
                    comment: ""
                )
            case let .failure(error): status.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func openAutomationSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        )
    }
}
