protocol EffectView: NSView {
    func updateAppearance(cornerRadius: CGFloat)
    /// Where `TilesView` places its content (scroll view, search field, empty-state label).
    /// For `NSVisualEffectView` that's the view itself; for `NSGlassEffectView` it's `contentView`,
    /// the only place Apple guarantees rendering for embedded views.
    var hostView: NSView { get }
}

extension EffectView {
    func updateAppearance() { updateAppearance(cornerRadius: Appearance.windowCornerRadius) }
}

@available(macOS 26.0, *)
extension NSGlassEffectView: EffectView {
    func updateAppearance(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        // Left rectangular, the clip set in `makeGlassEffectView` draws a straight outline outside the
        // glass shape on macOS 27 (#5757). Set here, not there: cached views are reused across style
        // and size changes.
        layer!.cornerRadius = cornerRadius
    }

    var hostView: NSView { contentView! }
}

class FrostedGlassEffectView: NSVisualEffectView, EffectView {
    var hostView: NSView { self }

    convenience init() {
        self.init(frame: .zero)
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        updateAppearance()
    }

    func updateAppearance(cornerRadius: CGFloat) {
        material = Appearance.material
        updateRoundedCorners(cornerRadius)
    }

    /// using layer!.cornerRadius works but the corners are aliased; this custom approach gives smooth rounded corners
    /// see https://stackoverflow.com/a/29386935/2249756
    private func updateRoundedCorners(_ cornerRadius: CGFloat) {
        if cornerRadius == 0 {
            maskImage = nil
        } else {
            let edgeLength = 2.0 * cornerRadius + 1.0
            let mask = NSImage(size: NSSize(width: edgeLength, height: edgeLength), flipped: false) { rect in
                let bezierPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
                NSColor.black.set()
                bezierPath.fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
            mask.resizingMode = .stretch
            maskImage = mask
        }
    }
}

/// The App Icons style uses the private `set_variant:` on `NSGlassEffectView` to get the macOS
/// Cmd-Tab-like clear glass look. `style = .clear` alone renders nearly fully transparent, so the
/// variant is what makes the panel visible. Lives here as a free helper (no NSGlassEffectView subclass).
enum LiquidGlass {
    private static let setVariantSelector = NSSelectorFromString("set_variant:")
    private typealias SetVariantFn = @convention(c) (AnyObject, Selector, Int) -> Void

    static let canUsePrivateLook: Bool = {
        if #available(macOS 26.0, *) {
            return class_getInstanceMethod(object_getClass(NSGlassEffectView()), setVariantSelector) != nil
        }
        return false
    }()

    @available(macOS 26.0, *)
    static func applyClearVariant(_ view: NSGlassEffectView) {
        guard let method = class_getInstanceMethod(object_getClass(view), setVariantSelector) else { return }
        let f = unsafeBitCast(method_getImplementation(method), to: SetVariantFn.self)
        f(view, setVariantSelector, 3)
    }
}

extension LauncherBackgroundView: EffectView {
    var hostView: NSView { self }
    func updateAppearance(cornerRadius: CGFloat) {
        layer?.cornerRadius = cornerRadius
        TitlesStyle.applyScrim(self, isDark: Appearance.currentTheme == .dark)
    }
}

enum EffectViewKind {
    case launcher
    case frosted
    case liquidGlassRegular
    case liquidGlassClear
}

func requiredEffectViewKind() -> EffectViewKind {
    if Preferences.effectiveAppearanceStyle(SwitcherSession.activeShortcutIndex) == .titles { return .launcher }
    if #available(macOS 26.0, *) {
        if Preferences.effectiveAppearanceStyle(SwitcherSession.activeShortcutIndex) == .appIcons,
           LiquidGlass.canUsePrivateLook {
            return .liquidGlassClear
        }
        return .liquidGlassRegular
    }
    return .frosted
}

@available(macOS 26.0, *)
private func makeGlassEffectView(clear: Bool) -> NSGlassEffectView {
    let glass = TitlesStyle.makeGlassView()
    glass.style = clear ? .clear : .regular
    if clear {
        LiquidGlass.applyClearVariant(glass)
    }
    glass.updateAppearance()
    return glass
}

func makeEffectView(for kind: EffectViewKind) -> EffectView {
    if kind == .launcher { return LauncherBackgroundView(isDark: Appearance.currentTheme == .dark) }
    if #available(macOS 26.0, *) {
        switch kind {
            case .liquidGlassClear:
                return makeGlassEffectView(clear: true)
            case .liquidGlassRegular:
                if Preferences.effectiveAppearanceStyle(SwitcherSession.activeShortcutIndex) == .appIcons {
                    Logger.error {
                        let os = ProcessInfo.processInfo.operatingSystemVersion
                        return "Private API set_variant is no longer available. macOS version: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
                    }
                }
                return makeGlassEffectView(clear: false)
            case .launcher, .frosted:
                break
        }
    }
    return FrostedGlassEffectView()
}
