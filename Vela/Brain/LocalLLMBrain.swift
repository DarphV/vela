//
//  LocalLLMBrain.swift
//  Vela
//
//  On-device Qwen 2.5 1.5B (4-bit) through MLX. Tokens stream into the chat
//  bubble; the caller speaks them sentence by sentence.
//

import Foundation
import MLXLLM
import MLXLMCommon

@MainActor
final class LocalLLMBrain: VelaBrain {
    let displayName = "Qwen 2.5 1.5B"
    let isOffline = true

    private let knowledge: LocalKnowledgeStore
    private let models: ModelStore

    init(knowledge: LocalKnowledgeStore, models: ModelStore) {
        self.knowledge = knowledge
        self.models = models
    }

    func answer(to question: String, history: [ChatMessage]) async -> VelaAnswer {
        await streamAnswer(to: question, history: history) { _ in }
    }

    func streamAnswer(to question: String, history: [ChatMessage], onUpdate: @escaping @MainActor (String) -> Void) async -> VelaAnswer {
        let passages = await knowledge.search(question, limit: 4)
        let prompt = VelaPrompt.user(question: question, history: history, passages: passages, facts: knowledge.facts)
        do {
            let container = try await models.container()
            let session = ChatSession(
                container,
                instructions: VelaPrompt.system,
                generateParameters: GenerateParameters(maxTokens: 420, temperature: 0.6, repetitionPenalty: 1.05)
            )
            var text = ""
            for try await chunk in session.streamResponse(to: prompt) {
                text += chunk
                onUpdate(text)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let visible = trimmed.isEmpty ? "Dazu kann ich gerade nichts Sicheres sagen." : trimmed
            if trimmed.isEmpty { onUpdate(visible) }
            return VelaAnswer(
                blocks: VelaPrompt.blocks(from: visible),
                spoken: VelaPrompt.spoken(from: visible),
                sources: passages.map(\.source),
                isDemo: false
            )
        } catch {
            let message = "Das lokale Modell konnte gerade nicht antworten. \(error.localizedDescription)"
            onUpdate(message)
            return VelaAnswer(blocks: [.paragraph(message)], spoken: "Das lokale Modell konnte gerade nicht antworten.", sources: [], isDemo: false)
        }
    }
}
