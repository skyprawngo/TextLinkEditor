import Foundation
import CryptoKit

enum CollaborationFailure: LocalizedError {
    case unsafePath, conflict, invalidResponse, damagedStore, tooLarge, gitRoot, gitFailed, busy
    var errorDescription: String? {
        L10n.get("collaboration.error." + String(describing: self))
    }
}

enum CollaborationPhase: String, Codable {
    case queued, investigating, proposing, validating, applying, waiting, review, completed, failed, cancelled, reverted
    var title: String { L10n.get("collaboration.phase." + rawValue) }
    var isRunning: Bool { [.investigating, .proposing, .validating, .applying].contains(self) }
}

struct CollaborationAnchor: Codable, Equatable {
    var path: String
    var quote: String
    var surroundingText: String
    var version: String
    var location: Int
    var length: Int
}

struct CollaborationChange: Codable, Identifiable, Equatable {
    var id: String { path }
    var path: String
    var before: String?
    var after: String?
}

struct CollaborationQuestion: Codable, Identifiable, Equatable {
    var id: String
    var question: String
    var evidence: [CollaborationEvidence]
    var options: [String]
    var answer: String?
}

struct CollaborationEvidence: Codable, Equatable {
    var path: String
    var quote: String
}

struct CollaborationEdit: Codable {
    var path: String
    var content: String?
    var reason: String
    var evidence: [CollaborationEvidence]
    var dependsOn: [String]
    var replacements: [TextReplacement]? = nil

    struct TextReplacement: Codable {
        var oldText: String
        var newText: String
    }

    func resolvedContent(base: String?) throws -> String? {
        guard let replacements else { return content } // Older saved/provider proposals.
        guard content == nil, let base, !replacements.isEmpty else { throw CollaborationFailure.invalidResponse }
        let source = base as NSString
        var patches: [(NSRange, String)] = []
        for replacement in replacements {
            guard !replacement.oldText.isEmpty else { throw CollaborationFailure.invalidResponse }
            let range = source.range(of: replacement.oldText, options: .literal)
            guard range.location != NSNotFound else { throw CollaborationFailure.invalidResponse }
            // Include enough surrounding text to identify a repeated passage uniquely.
            let next = range.location + 1
            guard source.range(of: replacement.oldText, options: .literal,
                               range: NSRange(location: next, length: source.length - next)).location == NSNotFound,
                  !patches.contains(where: { NSIntersectionRange($0.0, range).length > 0 }) else {
                throw CollaborationFailure.invalidResponse
            }
            patches.append((range, replacement.newText))
        }
        let result = NSMutableString(string: base)
        for (range, replacement) in patches.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: replacement)
        }
        return result as String
    }
}

struct CollaborationFact: Codable, Identifiable {
    var id: String
    var name: String
    var path: String
    var quote: String
    var status: String
    var storyTime: String
    var revealedFromSceneID: UUID?
    var knownBy: String
    var decision: String
}

struct CollaborationProposal: Codable {
    var summary: String
    var edits: [CollaborationEdit]
    var questions: [CollaborationQuestion]
    var facts: [CollaborationFact]
}

struct CollaborationTaskRecord: Codable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var origin: String
    var instruction: String
    var anchor: CollaborationAnchor?
    var changes: [CollaborationChange]
    var fingerprint: String
    var phase: CollaborationPhase = .queued
    var questions: [CollaborationQuestion] = []
    var summary = ""
    var error: String?
    var proposal: CollaborationProposal?
    var transactionIDs: [UUID] = []
}

struct CollaborationDocument: Codable {
    var version = 1
    var enabled = false
    var paused = false
    var gitEnabled = false
    var canonRoots = ["설정", "인물", "Settings", "Characters", "設定", "登場人物"]
    var protectedPaths: Set<String> = []
    var baseline: [String: String] = [:]
    var tasks: [CollaborationTaskRecord] = []
    var canonVersion = 0
    var lastGitFingerprint: String?
}

struct CollaborationTransaction: Codable, Identifiable {
    var id = UUID()
    var taskID: UUID
    var changes: [CollaborationChange]
    var phase = "prepared"
    var date = Date()
}

enum CollaborationHash {
    static func text(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func changes(_ changes: [CollaborationChange]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(changes.sorted { $0.path < $1.path })
        return text(String(decoding: data, as: UTF8.self))
    }
}
