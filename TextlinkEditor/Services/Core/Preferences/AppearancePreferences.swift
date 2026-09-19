import Foundation

/// Shared defaults for the editor toolbar; separate from manuscript typography.
enum EditorToolbarAppearance {
    static let store = UserDefaults(suiteName: "com.loreweave.settings") ?? .standard
    static let iconSizeKey = "editorToolbar.iconSize"
    static let numberSizeKey = "editorToolbar.numberSize"
    static let heightKey = "editorToolbar.height"
    static let defaultIconSize = 11.0
    static let defaultNumberSize = 11.0
    static let defaultHeight = 32.0
    static let sizeRange = 10.0...20.0
    static let heightRange = 32.0...64.0
    static func bounded(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

/// Shared defaults for the project explorer's text and symbols.
enum SidebarAppearance {
    static let store = UserDefaults.standard
    static let textSizeKey = "sidebar.textSize"
    static let iconSizeKey = "sidebar.iconSize"
    static let defaultTextSize = 12.0
    static let defaultIconSize = 13.0
    static let textSizeRange: ClosedRange<Double> = 10...18
    static let iconSizeRange: ClosedRange<Double> = 10...20
    static func bounded(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}
