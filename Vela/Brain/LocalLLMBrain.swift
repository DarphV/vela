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
        let passages = VelaPrompt.isSmallTalk(question) ? [] : await knowledge.search(question, limit: 3)
        let facts = VelaPrompt.relevantFacts(question: question, from: knowledge.facts)
        let prompt = VelaPrompt.prompt(question: question, passages: passages, facts: facts)
        let prior = VelaPrompt.priorTurns(history: history, question: question)
        do {
            let container = try await models.container()
            let context: [String: any Sendable]? = models.selected.disablesThinking
                ? ["enable_thinking": false as any Sendable]
                : nil
            let text = try await Task.detached(priority: .utility) {
                MLXMemoryLimits.tightenForGeneration()
                defer { MLXMemoryLimits.restoreCache() }
                let turns = prior.map {
                    Chat.Message(role: $0.isUser ? .user : .assistant, content: $0.text)
                }
                let session = ChatSession(
                    container,
                    instructions: VelaPrompt.system,
                    history: turns,
                    generateParameters: GenerateParameters(
                        maxTokens: 320,
                        temperature: 0.7,
                        topP: 0.9,
                        repetitionPenalty: 1.1,
                        repetitionContextSize: 64
                    ),
                    additionalContext: context
                )
                let hideCitations = passages.isEmpty
                var text = ""
                for try await chunk in session.streamResponse(to: prompt) {
                    text += chunk
                    var visible = VelaPrompt.withoutThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if hideCitations { visible = VelaPrompt.withoutCitations(visible) }
                    if !visible.isEmpty {
                        await onUpdate(visible)
                    }
                    // Both models yield so speech buffers are not starved.
                    try? await Task.sleep(nanoseconds: 3_000_000)
                }
                return text
            }.value
            let visible = VelaPrompt.withoutThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = passages.isEmpty ? VelaPrompt.withoutCitations(visible) : visible
            let shown = cleaned.isEmpty ? "Dazu kann ich gerade nichts Sicheres sagen." : cleaned
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
