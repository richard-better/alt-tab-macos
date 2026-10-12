import Cocoa

struct TitlesStyle {
    enum Scale {
        case small, medium, large
    }

    static let windowPadding = CGFloat(8)
    static let windowCornerRadius = CGFloat(26)
    static let rowCornerRadius = CGFloat(10)
    static let rowPadding = CGFloat(6)
    static let selectionBorderWidth = CGFloat(0)
    static var selectionBackground: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .white.withAlphaComponent(0.10)
                : .black.withAlphaComponent(0.09)
        }
    }

    static var selectionBorder: NSColor {
        .clear
    }

    static func applySelection(
        _ layer: CALayer,
        cornerRadius: CGFloat = rowCornerRadius,
        borderWidth: CGFloat = selectionBorderWidth
    ) {
        layer.cornerRadius = cornerRadius
        layer.backgroundColor = selectionBackground.cgColor
        layer.borderColor = selectionBorder.cgColor
        layer.borderWidth = borderWidth
    }

    static func appIconShadow(_ color: NSColor?) -> NSShadow? {
        guard let color else { return nil }
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.4)
        shadow.shadowOffset = NSSize(width: 0.1, height: 1)
        shadow.shadowBlurRadius = 2
        return shadow
    }

    let scale: Scale
    let isDark: Bool
    var iconSize: CGFloat {
        switch scale {
        case .small: return 22
        case .medium: return 26
        case .large: return 28
        }
    }

    var fontSize: CGFloat {
        switch scale {
        case .small: return 12
        case .medium: return 13
        case .large: return 14
        }
    }

    var font: NSFont {
        .systemFont(ofSize: fontSize)
    }

    static let panelWidth = CGFloat(750)
    static func panelHeight(rowsHeight: CGFloat, screenHeight: CGFloat, statusHeight: CGFloat = 0, showsSearch: Bool = true, showsFooter: Bool = true) -> CGFloat {
        min(max(38, rowsHeight) + (showsSearch ? headerHeight : 0) + (showsFooter ? footerHeight : 0) + windowPadding * 2 + statusHeight, max(150, screenHeight - 24))
    }
    static let headerHeight = CGFloat(56)
    static let footerHeight = CGFloat(52)
    static let iconLabelSpacing = CGFloat(10)
    static var listTop: CGFloat {
        headerHeight
    }

    var rowHeight: CGFloat {
        iconSize + Self.rowPadding * 2
    }

    var textColor: NSColor {
        Self.textColor(isDark: isDark)
    }

    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
    }

    static func textColor(isDark: Bool) -> NSColor {
        isDark ? .white.withAlphaComponent(0.85) : .black.withAlphaComponent(0.8)
    }

    func makeBackground() -> NSView { LauncherBackgroundView(isDark: isDark) }

    @available(macOS 26.0, *)
    static func makeGlassView() -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.style = .regular
        // Glass only renders embedded views inside contentView.
        glass.contentView = NSView()
        glass.cornerRadius = windowCornerRadius
        glass.wantsLayer = true
        // Clip at the glass corners to avoid a rectangular shadow on macOS 27.
        glass.layer?.cornerRadius = windowCornerRadius
        glass.layer?.masksToBounds = true
        glass.layer?.cornerCurve = .continuous
        return glass
    }

    static func applyScrim(_ host: NSView, isDark: Bool) {
        let scrim = host.subviews.compactMap { $0 as? LauncherScrimView }.first ?? LauncherScrimView()
        if scrim.superview == nil { host.addSubview(scrim, positioned: .above, relativeTo: host.subviews.first) }
        scrim.frame = host.bounds
        scrim.autoresizingMask = [.width, .height]
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = (isDark ? NSColor.black.withAlphaComponent(0.40) : NSColor.white.withAlphaComponent(0.55)).cgColor
        scrim.isHidden = false
        scrim.needsDisplay = true
    }

    static func hideScrim(_ host: NSView) {
        host.subviews.compactMap { $0 as? LauncherScrimView }.first?.isHidden = true
    }

    func updateBackground(_ background: NSView) {
        Self.applyScrim(Self.contentHost(background), isDark: isDark)
        if let visualEffect = background as? NSVisualEffectView {
            visualEffect.material = NSVisualEffectView.Material(rawValue: isDark ? 2 : 8)!
        }
    }

    static func contentHost(_ background: NSView) -> NSView {
        if #available(macOS 26.0, *),
           let glass = background as? NSGlassEffectView {
            return glass.contentView!
        }
        return background
    }
}

private final class LauncherScrimView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

}

private final class LauncherSearchCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let height = cellSize.height
        return NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect { drawingRect(forBounds: rect) }
    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }
    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, event: event)
    }
}

final class LauncherSearchField: NSTextField {
    var beginEditing: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = LauncherSearchCell(textCell: "")
        isEditable = true
        isSelectable = true
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Class only supports programmatic initialization") }
    func applyLauncherStyle(placeholder: String) {
        placeholderString = placeholder
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 20)
        textColor = .labelColor
        usesSingleLineMode = true
    }
    override func mouseDown(with event: NSEvent) {
        beginEditing?()
        super.mouseDown(with: event)
    }
}

class LauncherBackgroundView: NSView {
    private var backdrop: NSView!
    init(isDark: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = TitlesStyle.windowCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        if #available(macOS 26.0, *) {
            backdrop = TitlesStyle.makeGlassView()
        } else {
            let effect = NSVisualEffectView()
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.material = .hudWindow
            backdrop = effect
        }
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        TitlesStyle.applyScrim(self, isDark: isDark)
    }
    override func layout() {
        super.layout()
        backdrop.frame = bounds
        subviews.compactMap { $0 as? LauncherScrimView }.forEach { $0.frame = bounds }
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Class only supports programmatic initialization") }
}

extension TitlesStyle {
    static func makeSearchIcon() -> NSImageView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        return icon
    }
}

final class LauncherFooterView: NSView {
    let button = NSButton(title: "", target: nil, action: nil)
    override init(frame: NSRect) {
        super.init(frame: frame)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.wantsLayer = true
        button.layer?.cornerRadius = 18
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    override func layout() {
        super.layout()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.layer?.backgroundColor = (dark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.09)).cgColor
        button.layer?.borderColor = (dark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.10)).cgColor
        button.layer?.borderWidth = 1
        let width = button.intrinsicContentSize.width + 28
        button.frame = NSRect(
            x: bounds.width - width - 4,
            y: (bounds.height - 36) / 2,
            width: width,
            height: 36
        )
    }
}
