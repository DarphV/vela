//
//  LocalLLMBrain.swift
//  Vela
//
//  On-device Qwen through MLX. Generation runs at utility priority so the
//  audio thread can keep its buffers full. A finished sentence is spoken
//  before the next tokens are produced.
//

import Foundation
import MLXLLM
import MLXLMCommon

@MainActor
final class LocalLLMBrain: VelaBrain {
    var displayName: String { models.selected.displayName }
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

    func streamAnswer(to question: String, history: [ChatMessage], onUpdate: @escaping @MainActor (String) async -> Void) async -> VelaAnswer {
        let passages = await knowledge.search(question, limit: 4)
        let prompt = VelaPrompt.user(question: question, history: history, passages: passages, facts: knowledge.facts)
        do {
            let container = try await models.container()
            let context: [String: any Sendable]? = models.selected.disablesThinking
                ? ["enable_thinking": false as any Sendable]
                : nil
            let throttle = models.selected == .smart
            let text = try await Task.detached(priority: .utility) {
                MLXMemoryLimits.tightenForGeneration()
                defer { MLXMemoryLimits.restoreCache() }
                let session = ChatSession(
                    container,
                    instructions: VelaPrompt.system,
                    generateParameters: GenerateParameters(maxTokens: 420, temperature: 0.6, repetitionPenalty: 1.05),
                    additionalContext: context
                )
                var text = ""
                for try await chunk in session.streamResponse(to: prompt) {
                    text += chunk
                    let visible = VelaPrompt.withoutThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !visible.isEmpty {
                        await onUpdate(visible)
                    }
                    if throttle {
                        try? await Task.sleep(nanoseconds: 4_000_000)
                    }
                }
                return text
            }.value
            let visible = VelaPrompt.withoutThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = visible.isEmpty ? "Dazu kann ich gerade nichts Sicheres sagen." : visible
            if visible.isEmpty { await onUpdate(shown) }
            return VelaAnswer(
                blocks: VelaPrompt.blocks(from: shown),
                spoken: VelaPrompt.spoken(from: shown),
                sources: passages.map(\.source),
                isDemo: false
            )
        } catch {
            let message = "Das lokale Modell konnte gerade nicht antworten. \(error.localizedDescription)"
            await onUpdate(message)
            return VelaAnswer(blocks: [.paragraph(message)], spoken: "Das lokale Modell konnte gerade nicht antworten.", sources: [], isDemo: false)
        }
    }
}
