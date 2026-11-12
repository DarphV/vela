//
//  VelaBrain.swift
//  Vela
//
//  The brain behind voice mode and the glass chat. DemoBrain, the local MLX
//  model and Apple Intelligence all speak this protocol.
//

import Foundation

@MainActor
protocol VelaBrain: AnyObject {
    /// Shown in settings, e.g. "Demo" or "Qwen 2.5 1.5B".
    var displayName: String { get }
    /// True when the brain runs fully on the device.
    var isOffline: Bool { get }

    /// Answers a question. Document answers carry the passages they used.
    func answer(to question: String, history: [ChatMessage]) async -> VelaAnswer

    /// Streams the visible text into `onUpdate` (the whole answer so far, not a single token).
    func streamAnswer(to question: String, history: [ChatMessage], onUpdate: @escaping @MainActor (String) -> Void) async -> VelaAnswer
}

extension VelaBrain {
    func streamAnswer(to question: String, history: [ChatMessage], onUpdate: @escaping @MainActor (String) -> Void) async -> VelaAnswer {
        let answer = await answer(to: question, history: history)
        onUpdate(VelaPrompt.joined(answer))
        return answer
    }
}
