import Cocoa

extension TileTitleView {
    convenience init(font: NSFont) {
        self.init(font: font, color: Appearance.fontColor)
    }

    /// Re-apply appearance-baked font/color so a recycled instance survives an appearance change
    /// without being reallocated (which would free this tooltip owner; see TileView.reapplyAppearance).
    func reapplyAppearance() {
        font = Appearance.font
        textColor = Appearance.fontColor
        fixHeight()
    }

    /// One line, always: `TilesView.labelLineHeight()` says why the label's own content must not decide.
    func fixHeight() {
        frame.size.height = TilesView.labelLineHeight()
    }

    func updateTruncationModeIfNeeded() {
        let newLineBreakMode = getTruncationMode()
        if lineBreakMode != newLineBreakMode {
            lineBreakMode = newLineBreakMode
        }
    }

    private func getTruncationMode() -> NSLineBreakMode {
        if Preferences.titleTruncation == .end {
            return .byTruncatingTail
        }
        if Preferences.titleTruncation == .middle {
            return .byTruncatingMiddle
        }
        return .byTruncatingHead
    }
}
