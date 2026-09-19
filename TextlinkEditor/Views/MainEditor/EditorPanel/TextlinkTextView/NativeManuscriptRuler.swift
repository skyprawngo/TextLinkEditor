import AppKit

/// Global ruler geometry, independent of each document's typography overrides.
enum EditorRulerAppearance {
    static let store = UserDefaults(suiteName: "com.loreweave.settings") ?? .standard
    static let widthKey = "editorRuler.width"
    static let defaultWidth = 58.0
    static let widthRange = 40.0...120.0
    static func bounded(_ width: Double) -> Double {
        width.isFinite ? min(widthRange.upperBound, max(widthRange.lowerBound, width)) : defaultWidth
    }
}

final class NativeManuscriptRuler: NSRulerView {
    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = EditorRulerAppearance.bounded(EditorRulerAppearance.store.object(forKey: EditorRulerAppearance.widthKey) as? Double ?? EditorRulerAppearance.defaultWidth)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = scrollView?.documentView as? NativeManuscriptTextView else { return }
        view.backgroundColor.setFill(); bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for (row, fragment) in view.visibleManuscriptLines() {
            let point = convert(NSPoint(x: 0, y: fragment.minY + view.textContainerOrigin.y), from: view)
            let documentRow = row + (view.windowedDocument?.firstRow ?? 0)
            let label = "\(documentRow + 1)" as NSString
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 8, y: point.y + max(0, (fragment.height - label.size(withAttributes: attributes).height) / 2)), withAttributes: attributes)
            if view.modifiedLines.contains(documentRow) {
                NSColor.systemOrange.setFill()
                NSRect(x: 2, y: point.y, width: 3, height: max(12, fragment.height)).fill()
            }
        }
    }
}

