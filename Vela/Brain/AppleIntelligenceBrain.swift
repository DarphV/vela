//
//  AppleIntelligenceBrain.swift
//  Vela
//
//  Optional engine: Apple's on-device foundation model (iOS 26, Apple Intelligence).
//  The rest of the app keeps working when the framework or the model is absent.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleIntelligenceStatus {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static var detail: String {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return "Erst ab iOS 26" }
        switch SystemLanguageModel.default.availability {
        case .available:
            return "On-Device · Apple Intelligence"
        case .unavailable(.deviceNotEligible):
            return "Auf diesem iPhone nicht verfügbar"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "In den iOS-Einstellungen einschalten"
        case .unavailable(.modelNotReady):
            return "Modell wird noch vorbereitet"
        case .unavailable(_):
            return "Gerade nicht verfügbar"
        }
        #else
        return "In diesem Build nicht enthalten"
        #endif
    }
}

@MainActor
final class AppleIntelligenceBrain: VelaBrain {
    let displayName = "Apple Intelligence"
    let isOffline = true
    private let knowledge: LocalKnowledgeStore
    var olderSummary = ""

    init(knowledge: LocalKnowledgeStore) {
        self.knowledge = knowledge
    }

    func answer(to question: String, history: [ChatMessage]) async -> VelaAnswer {
        await streamAnswer(to: question, history: history) { _ in }
    }

    func streamAnswer(to question: String, history: [ChatMessage], onUpdate: @escaping @MainActor (String) async -> Void) async -> VelaAnswer {
        let passages = VelaPrompt.isSmallTalk(question) ? [] : await knowledge.search(question, limit: 3)
        let facts = VelaPrompt.relevantFacts(question: question, from: knowledge.facts)
        let instructions = VelaPrompt.instructions(profile: knowledge.profileText(), summary: olderSummary)
        let prompt = VelaPrompt.user(question: question, history: history, passages: passages, facts: facts)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), AppleIntelligenceStatus.isAvailable {
            do {
                let text = try await AppleStream.generate(instructions: instructions, prompt: prompt, onUpdate: onUpdate)
                let visible = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = passages.isEmpty ? VelaPrompt.withoutCitations(visible) : visible
                let shown = cleaned.isEmpty ? "Dazu kann ich gerade nichts Sicheres sagen." : cleaned
                if visible.isEmpty { await onUpdate(shown) }
                return VelaAnswer(blocks: VelaPrompt.blocks(from: shown), spoken: VelaPrompt.spoken(from: shown), sources: passages.map(\.source), isDemo: false)
            } catch {
                let message = "Apple Intelligence konnte gerade nicht antworten."
                await onUpdate(message)
                return VelaAnswer(blocks: [.paragraph(message)], spoken: message, sources: [], isDemo: false)
            }
        }
        #endif
        let message = "Apple Intelligence ist auf diesem iPhone nicht bereit."
        await onUpdate(message)
        return VelaAnswer(blocks: [.paragraph(message)], spoken: message, sources: [], isDemo: false)
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum AppleStream {
    static func generate(instructions: String, prompt: String, onUpdate: @MainActor (String) async -> Void) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let stream = session.streamResponse(to: prompt)
        var latest = ""
        for try await partial in stream {
            latest = partial.content
            await onUpdate(latest)
        }
        return latest
    }
}
#endif
