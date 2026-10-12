import Cocoa

class TileUnderLayer: CALayer {
    let focusedLayer = noAnimation { CALayer() }
    let hoveredLayer = noAnimation { CALayer() }

    override init() {
        super.init()
        delegate = NoAnimationDelegate.shared
        for highlightLayer in [focusedLayer, hoveredLayer] {
            highlightLayer.isHidden = true
            addSublayer(highlightLayer)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func updateHighlight(focusedView: TileView?, hoveredView: TileView?) {
        updateLayer(focusedLayer, for: focusedView, isFocused: true)
        updateLayer(hoveredLayer, for: hoveredView, isFocused: false)
    }

    private func updateLayer(_ highlightLayer: CALayer, for view: TileView?, isFocused: Bool) {
        guard let view, view.frame != .zero else {
            highlightLayer.isHidden = true
            return
        }
        let hf = view.highlightFrame
        let rect = CGRect(
            x: view.frame.origin.x + hf.origin.x,
            y: view.frame.origin.y + hf.origin.y,
            width: hf.width,
            height: hf.height
        )
        highlightLayer.frame = rect
        if isFocused, Preferences.effectiveAppearanceStyle(SwitcherSession.activeShortcutIndex) == .titles {
            TitlesStyle.applySelection(
                highlightLayer,
                cornerRadius: Appearance.cellCornerRadius,
                borderWidth: Appearance.highlightBorderWidth
            )
        } else {
            highlightLayer.cornerRadius = Appearance.cellCornerRadius
            highlightLayer.backgroundColor = (isFocused
                ? Appearance.highlightFocusedBackgroundColor
                : Appearance.highlightHoveredBackgroundColor).cgColor
            highlightLayer.borderColor = (isFocused
                ? Appearance.highlightFocusedBorderColor
                : Appearance.highlightHoveredBorderColor).cgColor
            highlightLayer.borderWidth = Appearance.highlightBorderWidth
        }
        highlightLayer.isHidden = false
    }
}
