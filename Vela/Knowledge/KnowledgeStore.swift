//
//  KnowledgeStore.swift
//  Vela
//
//  Document knowledge (manuals, work standards) for retrieval-augmented answers.
//  Only the interface + demo data exist in this step.
//

import Foundation

struct KnowledgeDocument: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let detail: String
}

struct KnowledgePassage: Hashable {
    let source: VelaSource
    let text: String
    let score: Float
}

enum KnowledgeError: LocalizedError {
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .notImplemented: return "Der Dokument-Import folgt im nächsten Schritt."
        }
    }
}

@MainActor
protocol KnowledgeStore: AnyObject {
    var documents: [KnowledgeDocument] { get }
    /// Number of remembered facts/passages (header chip "Gedächtnis").
    var memoryCount: Int { get }

    /// TODO(RAG-Import): PDF via PDFKit (`PDFDocument.page(at:).string`), DOCX via
    /// NSAttributedString(docFormat) / unzip, plain text. Split into ~500-token chunks
    /// that keep heading + page number, so every passage can be cited.
    func importDocument(at url: URL) async throws

    /// TODO(RAG-Search): embed chunks on-device (NLContextualEmbedding, iOS 17+, or a small
    /// GGUF/MLX embedding model), store vectors in SQLite, cosine top-k + keyword boost.
    func search(_ query: String, limit: Int) async -> [KnowledgePassage]
}

/// Demo data matching the prototype's "Wissen" list.
@MainActor
final class DemoKnowledgeStore: KnowledgeStore {
    let documents: [KnowledgeDocument] = [
        KnowledgeDocument(name: "Standard QS-12.pdf", detail: "48 Seiten · 312 Abschnitte"),
        KnowledgeDocument(name: "Standard QS-07.pdf", detail: "22 Seiten · 140 Abschnitte"),
        KnowledgeDocument(name: "Standard KS-03.docx", detail: "31 Seiten · 205 Abschnitte"),
        KnowledgeDocument(name: "Betriebshandbuch Anlage 3.pdf", detail: "212 Seiten · 1.104 Abschnitte"),
        KnowledgeDocument(name: "Handbuch.pdf", detail: "96 Seiten · 523 Abschnitte")
    ]

    let memoryCount = 1284

    func importDocument(at url: URL) async throws {
        throw KnowledgeError.notImplemented
    }

    func search(_ query: String, limit: Int) async -> [KnowledgePassage] {
        []
    }
}
