import Foundation

/// UI text. The English text is the key; `Resources/tr.lproj/Localizable.strings` has the Turkish. macOS picks the
/// language: Turkish when it comes first among the user's languages (or is chosen for Papiro in System Settings →
/// General → Language & Region), English otherwise. macOS's own menu items follow the same choice.
func L(_ s: String) -> String { NSLocalizedString(s, comment: "") }

/// A UI text with values put in (`%@`, `%d`).
func L(_ s: String, _ args: CVarArg...) -> String { String(format: NSLocalizedString(s, comment: ""), arguments: args) }

import AppKit

extension NSMenuItem {
    /// Keep this item's picture in the menu: macOS 27 hides menu item pictures unless asked (the colour swatches
    /// and the left panel's icons carry meaning).
    func keepImageVisible() {
        if #available(macOS 27.0, *) { preferredImageVisibility = .visible }
    }
}
