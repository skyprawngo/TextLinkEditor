import Foundation
import Observation

/// Provider/category-scoped defaults and model capability resolution.
@MainActor @Observable
final class AIModelPreferences {
    var availableModels: [AIModelOption] = []
    private let modelDefaults: UserDefaults
    var modelSelections: [String: String]
    var effortSelections: [String: String]

    func models(for type: AICLIType) -> [AIModelOption] {
        if type == .chatgpt {
            // Older CLI catalogs can omit a documented model that accepts explicit --model.
            // Catalog metadata wins when available; this entry does not imply account entitlement.
            if availableModels.contains(where: { $0.id == "gpt-6-astra" }) { return availableModels }
            return [.init(id: "gpt-6-astra", name: "GPT-6 Astra",
                          efforts: ["low", "medium", "high", "xhigh", "max"])] + availableModels
        }
        return [.init(id: "sonnet", name: "Sonnet", efforts: ["low", "medium", "high", "max"], isDefault: true),
                .init(id: "opus", name: "Opus", efforts: ["low", "medium", "high", "max"]),
                .init(id: "haiku", name: "Haiku", efforts: [])]
    }
    func preferenceKey(_ type: AICLIType, _ category: AIConversationCategory) -> String {
        category == .chat ? type.rawValue : type.rawValue + "." + category.rawValue
    }
    func selectedModel(for type: AICLIType, category: AIConversationCategory = .chat) -> AIModelOption? {
        let selection = modelSelections[preferenceKey(type, category)] ?? ""
        return models(for: type).first { selection.isEmpty ? $0.isDefault : $0.id == selection }
    }
    func selectModel(_ id: String, for type: AICLIType, category: AIConversationCategory = .chat) {
        guard models(for: type).contains(where: { $0.id == id }) else { return }
        modelSelections[preferenceKey(type, category)] = id
        // Retain the user's last effort whenever the new model supports it.
        effortSelections[preferenceKey(type, category)] = requestOptions(for: type, category: category).effort ?? ""
        persistModelPreferences()
    }
    func selectEffort(_ effort: String, for type: AICLIType, category: AIConversationCategory = .chat) {
        guard let model = selectedModel(for: type, category: category), model.efforts.contains(effort) else { return }
        modelSelections[preferenceKey(type, category)] = model.id
        effortSelections[preferenceKey(type, category)] = effort
        persistModelPreferences()
    }
    private func persistModelPreferences() {
        modelDefaults.set(modelSelections, forKey: "ai.modelSelections")
        modelDefaults.set(effortSelections, forKey: "ai.effortSelections")
    }
    func requestOptions(for type: AICLIType, category: AIConversationCategory = .chat) -> AIRequestOptions {
        guard let model = selectedModel(for: type, category: category) else { return AIRequestOptions() }
        let saved = effortSelections[preferenceKey(type, category)] ?? ""
        let effort = model.efforts.contains(saved) ? saved
            : model.defaultEffort.flatMap { model.efforts.contains($0) ? $0 : nil }
                ?? (model.efforts.contains("medium") ? "medium" : model.efforts.first)
        return AIRequestOptions(model: model.id, effort: effort)
    }
    init(modelDefaults: UserDefaults = .standard) {
        self.modelDefaults = modelDefaults
        modelSelections = modelDefaults.dictionary(forKey: "ai.modelSelections") as? [String: String] ?? [:]
        effortSelections = modelDefaults.dictionary(forKey: "ai.effortSelections") as? [String: String] ?? [:]
        // Seed inline preferences once from the prior shared setting, then keep them independent.
        for type in AICLIType.allCases {
            let key = preferenceKey(type, .inlineEdit)
            if modelSelections[key] == nil {
                modelSelections[key] = modelSelections[type.rawValue] ?? ""
                effortSelections[key] = effortSelections[type.rawValue] ?? ""
            }
            let commitKey = preferenceKey(type, .commitMessage)
            if modelSelections[commitKey] == nil {
                modelSelections[commitKey] = modelSelections[type.rawValue] ?? ""
                effortSelections[commitKey] = effortSelections[type.rawValue] ?? ""
            }
        }
        persistModelPreferences()
    }

}
