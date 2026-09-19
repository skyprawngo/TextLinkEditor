import SwiftUI

private struct AIPanelResizeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var aiPanelIsResizing: Bool {
        get { self[AIPanelResizeKey.self] }
        set { self[AIPanelResizeKey.self] = newValue }
    }
}

