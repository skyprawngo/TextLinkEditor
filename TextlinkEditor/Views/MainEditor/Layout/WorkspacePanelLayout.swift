import Foundation

/// One geometry contract for both rendering and dragging. Preferred width is persisted;
/// temporary window constraints affect only the resolved width.
struct WorkspacePanelLayout {
    static let dividerWidth: CGFloat = 7
    static let minimumEditorWidth: CGFloat = 360
    static let minimumAIWidth: CGFloat = 280
    static let maximumAIWidth: CGFloat = 600

    let windowWidth: CGFloat
    let sidebarWidth: CGFloat
    let sidebarVisible: Bool

    var maximumWidth: CGFloat {
        min(Self.maximumAIWidth, max(Self.minimumAIWidth,
            windowWidth - (sidebarVisible ? sidebarWidth : 0) - Self.dividerWidth - Self.minimumEditorWidth))
    }

    func resolve(_ preferred: CGFloat) -> CGFloat {
        min(maximumWidth, max(Self.minimumAIWidth, preferred.isFinite ? preferred : Self.minimumAIWidth))
    }

    func draggedWidth(from initial: CGFloat, translation: CGFloat) -> CGFloat {
        resolve(resolve(initial - translation).rounded())
    }
}
