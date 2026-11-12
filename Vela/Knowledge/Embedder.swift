//
//  Embedder.swift
//  Vela
//
//  On-device German vectors. NaturalLanguage's contextual model when the
//  asset is already on the iPhone, otherwise the built-in sentence embedding.
//  No download: if neither is available, search falls back to keywords.
//

import Foundation
import NaturalLanguage

enum Embedder {
    static func vector(for text: String) -> [Float] {
        let trimmed = String(text.prefix(1200))
        guard !trimmed.isEmpty else { return [] }
        if let contextual = contextualVector(trimmed), !contextual.isEmpty { return normalize(contextual) }
        if let averaged = wordVector(trimmed), !averaged.isEmpty { return normalize(averaged) }
        return []
    }

    private static func contextualVector(_ text: String) -> [Float]? {
        guard let embedding = NLContextualEmbedding(language: .german) else { return nil }
        guard embedding.hasAvailableAssets else { return nil }
        do {
            try embedding.load()
            let result = try embedding.embeddingResult(for: text, language: .german)
            let dimension = embedding.dimension
            guard dimension > 0 else { return nil }
            var sum = [Double](repeating: 0, count: dimension)
            var samples = 0
            result.enumerateTokenVectors(in: result.string.startIndex..<result.string.endIndex) { vector, _ in
                guard vector.count == dimension else { return true }
                for i in 0..<dimension { sum[i] += vector[i] }
                samples += 1
                return samples < 80
            }
            guard samples > 0 else { return nil }
            return sum.map { Float($0 / Double(samples)) }
        } catch {
            return nil
        }
    }

    private static func wordVector(_ text: String) -> [Float]? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .german) else { return nil }
        let dimension = embedding.dimension
        guard dimension > 0 else { return nil }
        var sum = [Double](repeating: 0, count: dimension)
        var samples = 0
        for word in text.split(whereSeparator: { !$0.isLetter }) {
            guard word.count > 1, let sample = embedding.vector(for: String(word).lowercased()), sample.count == dimension else { continue }
            for i in 0..<dimension { sum[i] += sample[i] }
            samples += 1
            if samples >= 80 { break }
        }
        guard samples > 0 else { return nil }
        return sum.map { Float($0 / Double(samples)) }
    }

    private static func normalize(_ values: [Float]) -> [Float] {
        let length = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard length > 1e-6 else { return values }
        return values.map { $0 / length }
    }
}
