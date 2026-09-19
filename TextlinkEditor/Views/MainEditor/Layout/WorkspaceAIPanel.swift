import SwiftUI

/// Owns panel geometry and drag lifetime, while retaining its content when hidden.
struct WorkspaceAIPanel<Content: View>: View {
    @Binding var preferredWidth: CGFloat
    let layout: WorkspacePanelLayout
    let isVisible: Bool
    let onResizeEnded: (CGFloat) -> Void
    @ViewBuilder let content: () -> Content
    @State private var dragStartWidth: CGFloat?

    private var width: CGFloat { layout.resolve(preferredWidth) }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(AppColors.separator).frame(width: 1)
                .padding(.horizontal, 3)
                .background(PanelResizeCursorRegion())
                .contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = width }
                        let next = layout.draggedWidth(from: dragStartWidth ?? width, translation: value.translation.width)
                        guard preferredWidth != next else { return }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { preferredWidth = next }
                    }
                    .onEnded { _ in
                        onResizeEnded(preferredWidth)
                        dragStartWidth = nil
                    })
            content()
                .frame(width: width)
                .clipped()
                .environment(\.aiPanelIsResizing, dragStartWidth != nil)
        }
        .frame(width: width + WorkspacePanelLayout.dividerWidth)
        .frame(width: isVisible ? width + WorkspacePanelLayout.dividerWidth : 0, alignment: .trailing)
        .clipped()
        .accessibilityHidden(!isVisible)
        .allowsHitTesting(isVisible)
        .onChange(of: isVisible) { _, visible in
            if !visible { dragStartWidth = nil }
        }
        .onDisappear { dragStartWidth = nil }
    }
}
