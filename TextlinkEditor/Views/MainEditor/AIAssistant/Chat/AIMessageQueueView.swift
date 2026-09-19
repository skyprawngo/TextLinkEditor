import SwiftUI

/// A bounded tray above the composer. Drag identity is private to this tray, so
/// dropping arbitrary text from another app cannot submit or reorder messages.
struct AIMessageQueueView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let messages: [AIQueuedMessage]
    let isProcessing: Bool
    let steeringMessageID: UUID?
    let onRemove: (UUID) -> Void
    let onRecover: (UUID) -> Void
    let onSteer: (UUID) -> Void
    let onMove: (UUID, UUID) -> Void
    let onResume: () -> Void
    @State private var draggedID: UUID?

    var body: some View {
        if !messages.isEmpty {
            VStack(spacing: 3) {
                HStack {
                    Text(L10n.get("ai.queue.title") + " · \(messages.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !isProcessing {
                        Button(L10n.get("ai.queue.resume"), action: onResume).buttonStyle(.borderless)
                    }
                }.padding(.horizontal, 10).padding(.top, 8)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(messages) { message in
                            row(message)
                                .queueReordering(id: message.id, draggedID: $draggedID,
                                                 reduceMotion: reduceMotion, move: onMove)
                        }
                    }
                }
                .frame(height: CGFloat(min(messages.count, 4)) * 36)
            }
            .padding(.bottom, 6)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary, lineWidth: 1))
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    private func row(_ message: AIQueuedMessage) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Text(message.text).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(message.text)
            if steeringMessageID == message.id { ProgressView().controlSize(.mini) }
            Button { onSteer(message.id) } label: { Image(systemName: "arrow.turn.down.right") }
                .help(L10n.get("ai.queue.steer"))
                .accessibilityLabel(L10n.get("ai.queue.steer"))
                .disabled(!isProcessing || steeringMessageID != nil)
            Button { onRemove(message.id) } label: { Image(systemName: "trash") }
                .help(L10n.get("ai.queue.delete"))
                .accessibilityLabel(L10n.get("ai.queue.delete"))
                .disabled(steeringMessageID == message.id)
            Menu {
                Button(L10n.get("ai.queue.recover")) { onRecover(message.id) }
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    if index > 0 { Button(L10n.get("ai.queue.up")) { onMove(message.id, messages[index - 1].id) } }
                    if index + 1 < messages.count { Button(L10n.get("ai.queue.down")) { onMove(message.id, messages[index + 1].id) } }
                }
            } label: { Image(systemName: "ellipsis") }
            .menuIndicator(.hidden).fixedSize()
            .disabled(steeringMessageID == message.id)
            .help(L10n.get("ai.queue.recover"))
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .contentShape(Rectangle())
    }
}
