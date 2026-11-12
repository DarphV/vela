//
//  KnowledgeIndex.swift
//  Vela
//
//  SQLite index of documents, chunks and personal facts.
//

import Foundation
import SQLite3

struct StoredDocument {
    var id: String
    var name: String
    var filename: String
    var pageCount: Int
    var chunkCount: Int
}

struct StoredChunk {
    var id: String
    var documentID: String
    var documentName: String
    var filename: String
    var page: Int
    var heading: String
    var text: String
    var embedding: [Float]
}

struct StoredFact {
    var id: String
    var text: String
}

final class KnowledgeIndex {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func open(at url: URL) throws {
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            throw error("Die Wissensdatenbank konnte nicht geöffnet werden.")
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec("""
        CREATE TABLE IF NOT EXISTS documents (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            filename TEXT NOT NULL,
            page_count INTEGER NOT NULL,
            created REAL NOT NULL
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS chunks (
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            page INTEGER NOT NULL,
            heading TEXT NOT NULL,
            text TEXT NOT NULL,
            embedding BLOB,
            FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS facts (
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            created REAL NOT NULL
        );
        """)
    }

    func documents() throws -> [StoredDocument] {
        var rows: [StoredDocument] = []
        try query("""
        SELECT d.id, d.name, d.filename, d.page_count,
               (SELECT COUNT(*) FROM chunks c WHERE c.document_id = d.id)
        FROM documents d ORDER BY d.created DESC
        """, read: { statement in
            rows.append(StoredDocument(
                id: self.text(statement, 0),
                name: self.text(statement, 1),
                filename: self.text(statement, 2),
                pageCount: Int(sqlite3_column_int(statement, 3)),
                chunkCount: Int(sqlite3_column_int(statement, 4))
            ))
        })
        return rows
    }

    func chunks() throws -> [StoredChunk] {
        var rows: [StoredChunk] = []
        try query("""
        SELECT c.id, c.document_id, d.name, d.filename, c.page, c.heading, c.text, c.embedding
        FROM chunks c JOIN documents d ON d.id = c.document_id
        """, read: { statement in
            rows.append(StoredChunk(
                id: self.text(statement, 0),
                documentID: self.text(statement, 1),
                documentName: self.text(statement, 2),
                filename: self.text(statement, 3),
                page: Int(sqlite3_column_int(statement, 4)),
                heading: self.text(statement, 5),
                text: self.text(statement, 6),
                embedding: self.floats(statement, 7)
            ))
        })
        return rows
    }

    func facts() throws -> [StoredFact] {
        var rows: [StoredFact] = []
        try query("SELECT id, text FROM facts ORDER BY created DESC", read: { statement in
            rows.append(StoredFact(id: self.text(statement, 0), text: self.text(statement, 1)))
        })
        return rows
    }

    func insert(document: StoredDocument, chunks: [(id: String, page: Int, heading: String, text: String, embedding: [Float])]) throws {
        try exec("BEGIN")
        do {
            try run("INSERT INTO documents (id, name, filename, page_count, created) VALUES (?, ?, ?, ?, ?)") { statement in
                self.bind(statement, 1, document.id)
                self.bind(statement, 2, document.name)
                self.bind(statement, 3, document.filename)
                sqlite3_bind_int(statement, 4, Int32(document.pageCount))
                sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            }
            for chunk in chunks {
                try run("INSERT INTO chunks (id, document_id, page, heading, text, embedding) VALUES (?, ?, ?, ?, ?, ?)") { statement in
                    self.bind(statement, 1, chunk.id)
                    self.bind(statement, 2, document.id)
                    sqlite3_bind_int(statement, 3, Int32(chunk.page))
                    self.bind(statement, 4, chunk.heading)
                    self.bind(statement, 5, chunk.text)
                    self.bind(statement, 6, chunk.embedding)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func deleteDocument(id: String) throws {
        try run("DELETE FROM documents WHERE id = ?") { statement in
            self.bind(statement, 1, id)
        }
    }

    func filename(for id: String) throws -> String? {
        var name: String?
        try query("SELECT filename FROM documents WHERE id = ?") { statement in
            self.bind(statement, 1, id)
        } read: { statement in
            name = self.text(statement, 0)
        }
        return name
    }

    func insertFact(id: String, text: String) throws {
        try run("INSERT INTO facts (id, text, created) VALUES (?, ?, ?)") { statement in
            self.bind(statement, 1, id)
            self.bind(statement, 2, text)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        }
    }

    func deleteFact(id: String) throws {
        try run("DELETE FROM facts WHERE id = ?") { statement in
            self.bind(statement, 1, id)
        }
    }

    private func query(_ sql: String, bind bindBlock: ((OpaquePointer) -> Void)? = nil, read: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error("Abfrage fehlgeschlagen.")
        }
        defer { sqlite3_finalize(statement) }
        bindBlock?(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            read(statement)
        }
    }

    private func run(_ sql: String, bind bindBlock: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error("Speichern fehlgeschlagen.")
        }
        defer { sqlite3_finalize(statement) }
        bindBlock(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error("Speichern fehlgeschlagen.") }
    }

    private func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "SQLite"
            sqlite3_free(message)
            throw error(text)
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ values: [Float]) {
        guard !values.isEmpty else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = values.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), transient)
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func floats(_ statement: OpaquePointer, _ index: Int32) -> [Float] {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else { return [] }
        let count = Int(sqlite3_column_bytes(statement, index)) / MemoryLayout<Float>.size
        let buffer = bytes.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    private func error(_ message: String) -> NSError {
        NSError(domain: "VelaKnowledge", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
