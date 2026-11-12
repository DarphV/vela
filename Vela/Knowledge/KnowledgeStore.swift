//
//  KnowledgeStore.swift
//  Vela
//
//  Documents, retrieval and the small personal memory.
//  Vectors when NaturalLanguage can embed German, otherwise BM25 keywords.
//

import Foundation

struct KnowledgeDocument: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    var chunkCount: Int
}

struct MemoryFact: Identifiable, Hashable {
    let id: String
    let text: String
}

@MainActor
protocol KnowledgeStore: AnyObject {
    var documents: [KnowledgeDocument] { get }
    var facts: [MemoryFact] { get }
    /// Remembered facts plus indexed passages. Shown in the header chip.
    var memoryCount: Int { get }
    var speechHints: [String] { get }

    func importDocument(at url: URL) async throws -> KnowledgeDocument
    func deleteDocument(id: String)
    func search(_ query: String, limit: Int) async -> [KnowledgePassage]
    func rememberIfPersonal(_ text: String)
    func forgetFact(id: String)
}

@MainActor
final class LocalKnowledgeStore: ObservableObject, KnowledgeStore {
    @Published private(set) var documents: [KnowledgeDocument] = []
    @Published private(set) var facts: [MemoryFact] = []
    @Published private(set) var memoryCount = 0
    @Published private(set) var isImporting = false

    private let index = KnowledgeIndex()
    private var chunkCache: [StoredChunk] = []

    init() {
        do {
            try index.open(at: VelaPaths.indexDatabase)
            try reload()
        } catch {
            documents = []
            facts = []
            memoryCount = 0
        }
    }

    var speechHints: [String] {
        var hints: [String] = []
        for document in documents {
            let name = (document.name as NSString).deletingPathExtension
            if name.count >= 3 { hints.append(String(name.prefix(40))) }
        }
        for chunk in chunkCache where !chunk.heading.isEmpty {
            hints.append(String(chunk.heading.prefix(40)))
        }
        var seen = Set<String>()
        return hints.filter { seen.insert($0.lowercased()).inserted }.prefix(40).map { $0 }
    }

    func importDocument(at url: URL) async throws -> KnowledgeDocument {
        isImporting = true
        defer { isImporting = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.isEmpty ? "txt" : url.pathExtension
        let filename = UUID().uuidString + "." + ext
        let destination = VelaPaths.documents.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)

        let pages = try DocumentText.extract(from: destination)
        let pieces = Chunker.chunks(from: pages)
        guard !pieces.isEmpty else {
            try? FileManager.default.removeItem(at: destination)
            throw DocumentText.Failure.empty
        }

        let id = UUID().uuidString
        let name = url.lastPathComponent
        var stored: [(id: String, page: Int, heading: String, text: String, embedding: [Float])] = []
        stored.reserveCapacity(pieces.count)
        for piece in pieces {
            stored.append((UUID().uuidString, piece.page, piece.heading, piece.text, Embedder.vector(for: piece.text)))
        }
        let record = StoredDocument(id: id, name: name, filename: filename, pageCount: pages.count, chunkCount: stored.count)
        try index.insert(document: record, chunks: stored)
        try reload()
        return documents.first { $0.id == id } ?? KnowledgeDocument(id: id, name: name, detail: "\(stored.count) Abschnitte", chunkCount: stored.count)
    }

    func deleteDocument(id: String) {
        if let filename = try? index.filename(for: id) {
            let url = VelaPaths.documents.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        }
        try? index.deleteDocument(id: id)
        try? reload()
    }

    func search(_ query: String, limit: Int) async -> [KnowledgePassage] {
        let tokens = Self.tokens(query)
        guard !tokens.isEmpty, !chunkCache.isEmpty else { return [] }
        let queryVector = Embedder.vector(for: query)
        let useVectors = !queryVector.isEmpty && chunkCache.contains { !$0.embedding.isEmpty && $0.embedding.count == queryVector.count }
        let keywordScores = bm25(queryTokens: tokens)

        var ranked: [(StoredChunk, Float)] = []
        for chunk in chunkCache {
            let keyword = keywordScores[chunk.id] ?? 0
            var score = keyword
            if useVectors, chunk.embedding.count == queryVector.count {
                let cosine = zip(queryVector, chunk.embedding).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                score = cosine * 0.75 + keyword * 0.25
            }
            if score > 0.01 { ranked.append((chunk, score)) }
        }
        ranked.sort { $0.1 > $1.1 }
        return ranked.prefix(max(1, limit)).map { chunk, score in
            KnowledgePassage(source: source(for: chunk, query: query), text: chunk.text, score: score)
        }
    }

    func rememberIfPersonal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= 280 else { return }
        let patterns = [
            #"(?i)\bmerke dir\b"#,
            #"(?i)\bich hei[sß]e\b"#,
            #"(?i)\bmein name ist\b"#,
            #"(?i)\bich wohne\b"#,
            #"(?i)\bich arbeite\b"#,
            #"(?i)\bich mag\b"#,
            #"(?i)\bich bin (?:der|die|ein|eine)\b"#,
            #"(?i)\bmein(?:e|en|er)? (?:beruf|job|firma|team|abteilung|name)\b"#
        ]
        guard patterns.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) else { return }
        if facts.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) { return }
        let id = UUID().uuidString
        try? index.insertFact(id: id, text: trimmed)
        try? reload()
    }

    func forgetFact(id: String) {
        try? index.deleteFact(id: id)
        try? reload()
    }

    private func reload() throws {
        let docs = try index.documents()
        documents = docs.map {
            let pages = $0.pageCount > 1 ? " · \($0.pageCount) Seiten" : ""
            return KnowledgeDocument(id: $0.id, name: $0.name, detail: "\($0.chunkCount) Abschnitte\(pages)", chunkCount: $0.chunkCount)
        }
        let storedFacts = try index.facts()
        facts = storedFacts.map { MemoryFact(id: $0.id, text: $0.text) }
        chunkCache = try index.chunks()
        memoryCount = facts.count + chunkCache.count
    }

    private func source(for chunk: StoredChunk, query: String) -> VelaSource {
        let isPDF = chunk.filename.lowercased().hasSuffix(".pdf")
        let place = isPDF ? "Seite \(chunk.page)" : (chunk.heading.isEmpty ? "Abschnitt" : chunk.heading)
        let chip = "\(chunk.documentName) · \(place)"
        return VelaSource(
            id: chunk.id,
            chip: chip,
            document: chunk.documentName,
            location: place,
            excerpt: Self.excerpt(chunk.text, query: query),
            fileURL: VelaPaths.documents.appendingPathComponent(chunk.filename),
            page: isPDF ? chunk.page : nil
        )
    }

    private func bm25(queryTokens: [String]) -> [String: Float] {
        let k1: Float = 1.2
        let b: Float = 0.75
        let docs = chunkCache.map { (id: $0.id, tokens: Self.tokens($0.text)) }
        let average = Float(docs.map(\.tokens.count).reduce(0, +)) / Float(max(1, docs.count))
        var documentFrequency: [String: Int] = [:]
        for doc in docs {
            for term in Set(doc.tokens) { documentFrequency[term, default: 0] += 1 }
        }
        let n = Float(docs.count)
        var scores: [String: Float] = [:]
        for doc in docs {
            var frequencies: [String: Int] = [:]
            for token in doc.tokens { frequencies[token, default: 0] += 1 }
            var score: Float = 0
            let length = Float(doc.tokens.count)
            for term in Set(queryTokens) {
                let freq = Float(frequencies[term] ?? 0)
                guard freq > 0 else { continue }
                let df = Float(documentFrequency[term] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let denom = freq + k1 * (1 - b + b * length / max(average, 1))
                score += idf * (freq * (k1 + 1)) / denom
            }
            scores[doc.id] = score
        }
        let peak = scores.values.max() ?? 1
        guard peak > 0 else { return scores }
        return scores.mapValues { $0 / peak }
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
    }

    private static func excerpt(_ text: String, query: String) -> String {
        let words = tokens(query).filter { $0.count >= 4 }
        let lower = text.lowercased()
        var anchor = text.startIndex
        for word in words {
            if let range = lower.range(of: word) {
                anchor = range.lowerBound
                break
            }
        }
        let start = text.index(anchor, offsetBy: -160, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(anchor, offsetBy: 280, limitedBy: text.endIndex) ?? text.endIndex
        var slice = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start != text.startIndex { slice = "… " + slice }
        if end != text.endIndex { slice += " …" }
        for word in words.prefix(2) {
            if let range = slice.range(of: word, options: .caseInsensitive) {
                slice.replaceSubrange(range, with: "==\(slice[range])==")
                break
            }
        }
        return slice
    }
}
