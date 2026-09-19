#!/usr/bin/env python3
"""Exercise the production transcript boundary with real SwiftUI layout updates."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'TextlinkEditor/Views/MainEditor/AIAssistant/Chat/AIChatView.swift').read_text()
boundary = source[source.index('private struct AIChatTranscript:'):]
boundary = boundary.replace('var body: some View {', 'var body: some View {\n        let _ = RenderCounter.bump()', 1)
harness = r'''
import AppKit
import SwiftUI
enum Role { case user, assistant }
enum Category { case chat, inlineEdit }
struct AIMessage: Equatable, Identifiable {
    let id: UUID
    var content: String
    var role: Role = .assistant
    var chatMode: String? = nil
    var isStreaming = false
    var category: Category = .chat
}
enum AIChatMode: String { case conversation; var command: String { "/chat" } }
enum L10n { static func get(_ key: String) -> String { key } }
enum AIWorkspaceEdits { static func exists(id: UUID, project: URL) -> Bool { false } }
@MainActor final class AIAssistantViewModel {
    static let shared = AIAssistantViewModel()
    var collaboration: AIAssistantViewModel { self }
    func submitComment(_ text: String) {}
}
@MainActor enum RenderCounter {
    static var count = 0
    static func bump() { count += 1 }
}
@MainActor final class Fixture: ObservableObject {
    @Published var draft = ""
    @Published var answer = "현재까지 확정된 내용을 정리했습니다."
    @Published var inset: CGFloat = 118
    @Published var conversationID = UUID()
    @Published var historyVisible = true
    @Published var width: CGFloat = 320
    let messageID = UUID()
    let history: [AIMessage] = {
        if let path = ProcessInfo.processInfo.environment["TRANSCRIPT_FIXTURE"],
           let data = FileManager.default.contents(atPath: path),
           let store = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cards = store["cards"] as? [[String: Any]] {
            return cards.flatMap { card in
                ["userMessage", "assistantMessage"].compactMap { key -> AIMessage? in
                    guard let message = card[key] as? [String: Any], let text = message["content"] as? String else { return nil }
                    return .init(id: UUID(), content: text, role: key == "userMessage" ? .user : .assistant)
                }
            }
        }
        return (0..<24).map { index in
        .init(id: UUID(), content: String(repeating: "던전은 탐험가를 학습한다는 소문이 있습니다. 아직 확정되지 않은 설정입니다.\n", count: index % 7 == 0 ? 70 : 3 + index % 13), role: index % 2 == 0 ? .user : .assistant)
        }
    }()
}
struct TestView: View {
    @ObservedObject var fixture: Fixture
    var body: some View {
        VStack {
            AIChatTranscript(messages: fixture.history + [.init(id: fixture.messageID, content: fixture.answer)], conversationID: fixture.conversationID,
                processing: false, bottomInset: fixture.inset, completedRequests: [], project: nil,
                onHistory: {}, onRevision: { _ in }).equatable()
                .offset(x: fixture.historyVisible ? 320 : 0)
            Text(fixture.draft).frame(width: 320, height: 48)
        }.frame(width: fixture.width, height: 600).clipped()
    }
}
@main struct Test {
    @MainActor static func main() {
        let suiteName = "transcript-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let fixture = Fixture()
        let host = NSHostingView(rootView: TestView(fixture: fixture).defaultAppStorage(preferences))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        for _ in 0..<4 { settle() }
        fixture.width = 320
        fixture.historyVisible = false
        for _ in 0..<4 { settle() }
        let baseline = RenderCounter.count
        precondition(baseline > 0)
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        guard let scroll = findScroll(host) else { preconditionFailure("missing transcript scroll view") }
        func isAtBottom() -> Bool {
            guard let document = scroll.documentView else { return false }
            return abs(document.bounds.height - scroll.contentView.bounds.maxY) < 20
        }
        precondition(isAtBottom(), "conversation must initially open at the bottom")
        print("PASS conversation initially opens at the bottom")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        let position = scroll.contentView.bounds.origin.y
        precondition(position > 0, "fixture must be scrolled into the conversation")
        for character in "다음 문장 draft" {
            fixture.draft.append(character); settle()
            precondition(abs(scroll.contentView.bounds.origin.y - position) < 0.5, "typing moved the transcript")
        }
        print("PASS draft keystrokes preserve the scrolled transcript position")
        let beforeResponse = RenderCounter.count
        fixture.answer += " streaming update"
        settle()
        precondition(RenderCounter.count > beforeResponse, "response update was suppressed")
        print("PASS new response content still updates the transcript")
        let beforeHeight = RenderCounter.count
        fixture.inset = 160
        settle()
        precondition(RenderCounter.count > beforeHeight, "composer growth was suppressed")
        precondition(abs(scroll.contentView.bounds.origin.y - position) < 0.5, "composer growth moved the reading position")
        print("PASS real composer height changes still update reserved space")
        fixture.conversationID = UUID()
        for _ in 0..<4 { settle() }
        precondition(isAtBottom(), "switching conversation must return to the bottom")
        print("PASS switching conversation returns to the bottom")
        let beforeTypography = RenderCounter.count
        let previousHeight = scroll.documentView!.bounds.height
        preferences.set(20.0, forKey: "panel.fontSize")
        preferences.set(8.0, forKey: "panel.lineSpacing")
        preferences.set(1.0, forKey: "panel.letterSpacing")
        preferences.set("Helvetica", forKey: "panel.fontName")
        for _ in 0..<8 { settle() }
        precondition(RenderCounter.count > beforeTypography, "typography must refresh even with equatable transcript")
        precondition(scroll.documentView!.bounds.height > previousHeight, "larger typography must affect actual layout")
        print("PASS persisted panel typography updates transcript layout immediately")
        for width: CGFloat in [280, 400, 600, 320] {
            fixture.width = width
            for _ in 0..<4 { settle() }
        }
        let idleCPU = clock()
        let idleRenders = RenderCounter.count
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let consumed = Double(clock() - idleCPU) / Double(CLOCKS_PER_SEC)
        precondition(consumed < 0.5, "idle transcript consumes CPU continuously")
        precondition(RenderCounter.count - idleRenders < 4, "idle layout must settle")
        print("PASS resized transcript settles; idle CPU seconds:", consumed)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='textlinkeditor-transcript-') as directory:
    path = Path(directory)
    (path / 'Test.swift').write_text(harness + '\n' + boundary)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path / 'Test.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True, timeout=60)
