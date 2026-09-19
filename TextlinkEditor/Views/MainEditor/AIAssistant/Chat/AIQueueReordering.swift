import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// UI owns pointer transitions and animation; the submission queue owns order.
    func queueReordering(id: UUID, draggedID: Binding<UUID?>, reduceMotion: Bool,
                         move: @escaping (UUID, UUID) -> Void) -> some View {
        onDrag {
            draggedID.wrappedValue = id
            let provider = NSItemProvider()
            let identity = Data(id.uuidString.utf8)
            provider.registerDataRepresentation(forTypeIdentifier: QueueDragContent.type.identifier,
                visibility: .ownProcess) { completion in
                completion(identity, nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [QueueDragContent.type], delegate: QueueDropDelegate(id: id,
            draggedID: draggedID, reduceMotion: reduceMotion, move: move))
    }
}

private enum QueueDragContent {
    static let type = UTType(exportedAs: "com.textlinkeditor.chat-queue-item")
}

private struct QueueDropDelegate: DropDelegate {
    let id: UUID
    @Binding var draggedID: UUID?
    let reduceMotion: Bool
    let move: (UUID, UUID) -> Void
    func validateDrop(info: DropInfo) -> Bool {
        draggedID != nil && info.hasItemsConforming(to: [QueueDragContent.type])
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropEntered(info: DropInfo) {
        guard let source = draggedID, source != id else { return }
        // Update the real ordering as the pointer crosses each row. Stable IDs
        // let the displaced rows slide into the vacated slots in either direction.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            move(source, id)
        }
    }
    func performDrop(info: DropInfo) -> Bool {
        guard draggedID != nil else { return false }
        // Ordering was already updated during the drag; do not move it a second time.
        draggedID = nil
        return true
    }
}
