import Cocoa

struct TitlesStyle {
    enum Scale {
        case small, medium, large
    }

    static let windowPadding = CGFloat(18)
    static let windowCornerRadius = CGFloat(23)
    static let rowCornerRadius = CGFloat(10)
    static let rowPadding = CGFloat(7)
    static let selectionBorderWidth = CGFloat(2)
    static var selectionBackground: NSColor {
        .systemAccentColor.withAlphaComponent(0.2)
    }

    static var selectionBorder: NSColor {
        .systemAccentColor
    }

    let scale: Scale
    let isDark: Bool
    var iconSize: CGFloat {
        switch scale {
        case .small: return 18
        case .medium: return 24
        case .large: return 30
        }
    }

    var fontSize: CGFloat {
        switch scale {
        case .small: return 13
        case .medium: return 14
        case .large: return 16
        }
    }

    var font: NSFont {
        if #available(macOS 26.0, *) {
            return .systemFont(ofSize: fontSize, weight: .medium)
        }
        return .systemFont(ofSize: fontSize)
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

    func makeBackground() -> NSView {
        if #available(macOS 26.0, *) {
            return Self.makeGlassView()
        }
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = NSVisualEffectView.Material(rawValue: isDark ? 2 : 8)!
        view.wantsLayer = true
        view.layer?.cornerRadius = Self.windowCornerRadius
        view.layer?.masksToBounds = true
        return view
    }

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

    func updateBackground(_ background: NSView) {
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
