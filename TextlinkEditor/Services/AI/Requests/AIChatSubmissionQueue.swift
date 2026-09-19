import Foundation
import Observation

/// Owns pending submissions and their acceptance boundary. The caller owns
/// inference and persistence; a failed dispatch never removes the pending item.
@MainActor @Observable
final class AIChatSubmissionQueue {
    private(set) var messages: [AIQueuedMessage] = []
    private var isPaused = false
    private var steering: Steering?
    var steeringMessageID: UUID? { steering?.messageID }

    private struct Steering {
        let token: UUID
        let messageID: UUID
    }

    func enqueue(_ message: AIQueuedMessage) {
        messages.append(message)
        resume()
    }

    func next(project: URL?, provider: AICLIType, isBusy: Bool) -> AIQueuedMessage? {
        guard !isPaused, !isBusy, steering == nil, let next = messages.first,
              next.project == project, next.provider == provider else { return nil }
        return next
    }

    func resume() { isPaused = false }
    func pause() { isPaused = true }
    func didFinishResponse(successfully: Bool) { isPaused = !successfully }
    func cancel() { pause(); steering = nil }
    func clear() { messages = []; cancel() }
    func removeConversation(_ id: UUID) { messages.removeAll { $0.conversationID == id } }

    func message(_ id: UUID) -> AIQueuedMessage? { messages.first { $0.id == id } }
    func recoverableMessage(_ id: UUID) -> AIQueuedMessage? {
        guard steeringMessageID != id else { return nil }
        return message(id)
    }

    func remove(_ id: UUID) {
        guard steeringMessageID != id else { return }
        messages.removeAll { $0.id == id }
    }

    func didDispatch(_ id: UUID) { messages.removeAll { $0.id == id } }

    func move(_ id: UUID, to target: UUID) {
        guard id != target, let from = messages.firstIndex(where: { $0.id == id }),
              let to = messages.firstIndex(where: { $0.id == target }) else { return }
        let message = messages.remove(at: from)
        messages.insert(message, at: to)
    }

    /// Replace the recovered slot with a displaced draft as one synchronous change.
    @discardableResult
    func recover(_ id: UUID, replacingWith draft: AIQueuedMessage?) -> AIQueuedMessage? {
        guard steeringMessageID != id, let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        let recovered = messages.remove(at: index)
        if let draft { messages.insert(draft, at: index) }
        return recovered
    }

    /// A distinct operation token prevents a late acknowledgement of an old
    /// attempt from consuming the same message after cancellation and retry.
    func beginSteering(_ id: UUID) -> UUID? {
        guard steering == nil else { return nil }
        let token = UUID()
        steering = Steering(token: token, messageID: id)
        return token
    }

    func ownsSteering(_ token: UUID) -> Bool { steering?.token == token }

    @discardableResult
    func finishSteering(_ token: UUID, accepted: Bool) -> Bool {
        guard let current = steering, current.token == token else { return false }
        if accepted { didDispatch(current.messageID) }
        steering = nil
        return true
    }
}
