//
//  VelaBrain.swift
//  Vela
//
//  The "brain" abstraction. Today only DemoBrain exists; the local LLM and
//  RAG retrieval plug in here later without touching the UI.
//

import Foundation

@MainActor
protocol VelaBrain: AnyObject {
    /// Shown in settings / debug, e.g. "Demo" or "Qwen 2.5 1.5B (lokal)".
    var displayName: String { get }
    /// True when the brain runs fully on the device.
    var isOffline: Bool { get }

    /// Answers a question. Implementations must always return sources for
    /// knowledge answers (Vela never answers from documents without citing them).
    func answer(to question: String, history: [ChatMessage]) async -> VelaAnswer
}

/// Placeholder for the real on-device model. Not wired up yet.
///
/// TODO(LLM): Option A – MLX Swift (https://github.com/ml-explore/mlx-swift-examples, `MLXLLM`):
///   - add SPM packages `mlx-swift` + `mlx-swift-examples` (MLXLLM, MLXLMCommon) in project.yml
///   - download e.g. `mlx-community/Qwen2.5-1.5B-Instruct-4bit` or `Llama-3.2-3B-Instruct-4bit`
///     on first launch (not bundled, ~1–2 GB), keep it in Application Support
///   - needs the "Increased Memory Limit" entitlement for 3B models (paid dev account)
/// TODO(LLM): Option B – llama.cpp (GGUF) via its prebuilt `llama.xcframework`.
/// TODO(LLM): Option C – Apple Foundation Models framework (iOS 26, Apple-Intelligence devices).
/// TODO(RAG): before generating, call `KnowledgeStore.search(question)` and put the top passages
///   into the prompt; map them to `VelaSource` so the UI shows the chips.
@MainActor
final class LocalLLMBrain: VelaBrain {
    let displayName = "Lokales Modell (noch nicht eingebaut)"
    let isOffline = true
    private let knowledge: KnowledgeStore

    init(knowledge: KnowledgeStore) {
        self.knowledge = knowledge
    }

    func answer(to question: String, history: [ChatMessage]) async -> VelaAnswer {
        // TODO(RAG): let passages = await knowledge.search(question, limit: 4)
        // TODO(LLM): stream tokens from the model, build blocks + spoken text.
        VelaAnswer(blocks: [.paragraph("Das lokale Sprachmodell ist in dieser Version noch nicht eingebaut.")],
                   spoken: "Das lokale Sprachmodell ist noch nicht eingebaut.",
                   sources: [],
                   isDemo: true)
    }
}
