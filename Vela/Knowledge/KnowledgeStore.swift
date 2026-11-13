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

enum FactCategory: String, CaseIterable, Identifiable, Hashable {
    case person, preference, project, routine, date, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .person: return "Person"
        case .preference: return "Vorlieben"
        case .project: return "Projekte"
        case .routine: return "Alltag"
        case .date: return "Termine"
        case .other: return "Sonstiges"
        }
    }

    static func parse(_ raw: String) -> FactCategory {
        FactCategory(rawValue: raw.lowercased()) ?? .other
    }
}

struct FactDraft: Hashable {
    var category: FactCategory
    var text: String

    static func parse(_ raw: String) -> [FactDraft] {
        var text = VelaPrompt.withoutThinking(raw)
        text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start <= end else { return [] }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.compactMap { row in
            let body = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count >= 8, body.count <= 180, !body.contains("?") else { return nil }
            return FactDraft(category: FactCategory.parse(row.category), text: body)
        }.prefix(3).map { $0 }
    }

    private struct Row: Decodable {
        var category: String
        var text: String
    }
}

struct MemoryFact: Identifiable, Hashable {
    let id: String
    var text: String
    var category: FactCategory
    var updated: Date
    var source: String
}

struct MemoryChange: Hashable {
    var id: String
    /// Nil when the change created a new fact. Undo then deletes it.
    var previous: MemoryFact?
}

struct KnowledgePassage: Hashable {
    let source: VelaSource
    let text: String
    let score: Float
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
    func rememberIfPersonal(_ text: String) -> MemoryChange?
    func integrate(_ drafts: [FactDraft], source: String) -> [MemoryChange]
    func updateFact(id: String, text: String)
    func forgetFact(id: String)
    func forgetAllFacts()
    func undo(_ change: MemoryChange)
    func profileText() -> String
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
        if VelaPrompt.isSmallTalk(query) { return [] }
        let queryWords = VelaPrompt.contentTokens(query)
        guard !queryWords.isEmpty, !chunkCache.isEmpty else { return [] }
        let queryVector = Embedder.vector(for: query)
        let useVectors = !queryVector.isEmpty && chunkCache.contains { !$0.embedding.isEmpty && $0.embedding.count == queryVector.count }

        var ranked: [(StoredChunk, Float)] = []
        for chunk in chunkCache {
            let shared = queryWords.intersection(VelaPrompt.contentTokens(chunk.text))
            let strong = shared.filter { $0.count >= 5 }
            var cosine: Float = 0
            if useVectors, chunk.embedding.count == queryVector.count {
                cosine = zip(queryVector, chunk.embedding).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            }
            // Two leftover chunks used to pass on any tiny cosine. A hit now needs a real word or a close vector.
            let matches = cosine >= 0.8 || strong.count >= 2 || (!strong.isEmpty && cosine >= 0.62)
            guard matches else { continue }
            let score = max(cosine, Float(strong.count) * 0.25)
            ranked.append((chunk, score))
        }
        ranked.sort { $0.1 > $1.1 }
        return ranked.prefix(max(1, limit)).map { chunk, score in
            KnowledgePassage(source: source(for: chunk, query: query), text: chunk.text, score: score)
        }
    }

    @discardableResult
    func rememberIfPersonal(_ text: String) -> MemoryChange? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= 280 else { return nil }
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
        guard patterns.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) else { return nil }
        let category: FactCategory = trimmed.range(of: #"(?i)\b(hei[sß]e|name|wohne|arbeite|beruf|job|firma)\b"#, options: .regularExpression) != nil ? .person : .preference
        return integrate([FactDraft(category: category, text: trimmed)], source: trimmed).first
    }

    /// Inserts new facts and replaces near-duplicates. Returns the changes a toast can undo.
    func integrate(_ drafts: [FactDraft], source: String) -> [MemoryChange] {
        var changes: [MemoryChange] = []
        for draft in drafts {
            let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 8, text.count <= 180, !text.contains("?") else { continue }
            if let existing = facts.first(where: { nearDuplicate($0.text, text) }) {
                guard existing.text.caseInsensitiveCompare(text) != .orderedSame else { continue }
                let previous = existing
                try? index.updateFact(id: existing.id, text: text, category: draft.category.rawValue)
                changes.append(MemoryChange(id: existing.id, previous: previous))
            } else {
                let id = UUID().uuidString
                try? index.insertFact(id: id, text: text, category: draft.category.rawValue, source: String(source.prefix(180)))
                changes.append(MemoryChange(id: id, previous: nil))
            }
        }
        if !changes.isEmpty { try? reload() }
        return changes
    }

    func updateFact(id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, let fact = facts.first(where: { $0.id == id }) else { return }
        try? index.updateFact(id: id, text: trimmed, category: fact.category.rawValue)
        try? reload()
    }

    func forgetFact(id: String) {
        try? index.deleteFact(id: id)
        try? reload()
    }

    func forgetAllFacts() {
        try? index.deleteAllFacts()
        try? reload()
    }

    func undo(_ change: MemoryChange) {
        if let previous = change.previous {
            try? index.updateFact(id: previous.id, text: previous.text, category: previous.category.rawValue)
        } else {
            try? index.deleteFact(id: change.id)
        }
        try? reload()
    }

    func profileText() -> String {
        let people = facts.filter { $0.category == .person }
        let rest = facts.filter { $0.category != .person }
        var lines: [String] = []
        var count = 0
        for fact in people + rest {
            if lines.count >= 8 || count + fact.text.count > 500 { break }
            lines.append(fact.text)
            count += fact.text.count
        }
        return lines.joined(separator: "\n")
    }

    private func nearDuplicate(_ left: String, _ right: String) -> Bool {
        let a = VelaPrompt.contentTokens(left)
        let b = VelaPrompt.contentTokens(right)
        let union = a.union(b)
        if !union.isEmpty {
            let overlap = Float(a.intersection(b).count) / Float(union.count)
            if overlap >= 0.55 { return true }
        }
        let leftVector = Embedder.vector(for: left)
        let rightVector = Embedder.vector(for: right)
        guard !leftVector.isEmpty, leftVector.count == rightVector.count else { return false }
        let cosine = zip(leftVector, rightVector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return cosine >= 0.86
    }

    private func reload() throws {
        let docs = try index.documents()
        documents = docs.map {
            let pages = $0.pageCount > 1 ? " · \($0.pageCount) Seiten" : ""
            return KnowledgeDocument(id: $0.id, name: $0.name, detail: "\($0.chunkCount) Abschnitte\(pages)", chunkCount: $0.chunkCount)
        }
        let storedFacts = try index.facts()
        facts = storedFacts.map {
            MemoryFact(id: $0.id, text: $0.text, category: FactCategory.parse($0.category), updated: $0.updated, source: $0.source)
        }
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
