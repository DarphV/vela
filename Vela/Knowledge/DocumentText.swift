//
//  DocumentText.swift
//  Vela
//
//  Pulls plain text out of PDF, text, Markdown and DOCX files.
//

import Compression
import Foundation
import PDFKit

struct PageText {
    /// 1-based page. Text and Markdown files use 1.
    var page: Int
    var text: String
}

enum DocumentText {
    enum Failure: LocalizedError {
        case unsupported
        case empty
        case docx

        var errorDescription: String? {
            switch self {
            case .unsupported: return "Dieses Dateiformat kann Vela noch nicht lesen."
            case .empty: return "In der Datei steht kein lesbarer Text."
            case .docx: return "Die Word-Datei konnte nicht gelesen werden."
            }
        }
    }

    static func extract(from url: URL) throws -> [PageText] {
        let ext = url.pathExtension.lowercased()
        let pages: [PageText]
        switch ext {
        case "pdf":
            pages = try pdf(url)
        case "txt", "text", "md", "markdown":
            pages = try plain(url)
        case "docx":
            pages = try docx(url)
        default:
            throw Failure.unsupported
        }
        let kept = pages.map { PageText(page: $0.page, text: normalize($0.text)) }.filter { !$0.text.isEmpty }
        guard !kept.isEmpty else { throw Failure.empty }
        return kept
    }

    private static func pdf(_ url: URL) throws -> [PageText] {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw Failure.empty }
        var pages: [PageText] = []
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            pages.append(PageText(page: index + 1, text: text))
        }
        return pages
    }

    private static func plain(_ url: URL) throws -> [PageText] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return [PageText(page: 1, text: raw)]
    }

    private static func docx(_ url: URL) throws -> [PageText] {
        let data = try Data(contentsOf: url)
        guard let xml = ZipReader.extract(data, path: "word/document.xml") else { throw Failure.docx }
        guard let raw = String(data: xml, encoding: .utf8) else { throw Failure.docx }
        let text = docxToText(raw)
        return [PageText(page: 1, text: text)]
    }

    private static func docxToText(_ xml: String) -> String {
        var s = xml.replacingOccurrences(of: "</w:p>", with: "\n")
        s = s.replacingOccurrences(of: "<w:tab/>", with: "\t")
        s = s.replacingOccurrences(of: "<w:br/>", with: "\n")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        return s
    }

    private static func normalize(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        var blank = false
        for line in lines {
            if line.isEmpty {
                if !blank { out.append("") }
                blank = true
            } else {
                out.append(line)
                blank = false
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Chunker {
    struct Chunk {
        var page: Int
        var heading: String
        var text: String
    }

    /// About 500–800 tokens, with a short overlap so a sentence is not cut in half.
    static func chunks(from pages: [PageText]) -> [Chunk] {
        let targetWords = 560
        let overlapWords = 80
        var results: [Chunk] = []
        var heading = ""
        for page in pages {
            let paragraphs = page.text.components(separatedBy: "\n")
            var buffer: [String] = []
            var words = 0
            func flush() {
                let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.split(whereSeparator: \.isWhitespace).count >= 20 {
                    results.append(Chunk(page: page.page, heading: heading, text: text))
                }
                if overlapWords > 0, !buffer.isEmpty {
                    let tail = tailWords(text, count: overlapWords)
                    buffer = tail.isEmpty ? [] : [tail]
                    words = tail.split(whereSeparator: \.isWhitespace).count
                } else {
                    buffer = []
                    words = 0
                }
            }
            for line in paragraphs {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let found = headingOf(trimmed) { heading = found }
                let count = trimmed.split(whereSeparator: \.isWhitespace).count
                if words > 0, words + count > targetWords { flush() }
                if !trimmed.isEmpty {
                    buffer.append(trimmed)
                    words += count
                } else if !buffer.isEmpty {
                    buffer.append("")
                }
            }
            if words >= 20 { flush() }
        }
        return results
    }

    private static func headingOf(_ line: String) -> String? {
        var text = line
        if text.hasPrefix("#") {
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).trimmingCharacters(in: .whitespaces)
        }
        guard text.count >= 3, text.count <= 80 else { return nil }
        let last = text.last
        if last == "." || last == "," || last == ";" || last == ":" { return nil }
        let letters = text.filter(\.isLetter)
        guard letters.count >= 3 else { return nil }
        let isMarkdown = line.hasPrefix("#")
        let isShortTitle = text.count <= 60 && !text.contains(".") && text == text.uppercased() && letters.count > 4
        if isMarkdown || isShortTitle { return String(text.prefix(80)) }
        return nil
    }

    private static func tailWords(_ text: String, count: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > count else { return text }
        return words.suffix(count).joined(separator: " ")
    }
}

/// Minimal ZIP reader for the single XML part inside a DOCX file.
enum ZipReader {
    static func extract(_ data: Data, path: String) -> Data? {
        guard let entry = centralDirectory(data).first(where: { $0.name == path }) else { return nil }
        let start = entry.localOffset
        guard start + 30 <= data.count else { return nil }
        let nameLen = intAt(data, start + 26, length: 2)
        let extraLen = intAt(data, start + 28, length: 2)
        let payload = start + 30 + nameLen + extraLen
        let end = payload + entry.compressedSize
        guard end <= data.count else { return nil }
        let compressed = data.subdata(in: payload..<end)
        if entry.method == 0 { return compressed }
        guard entry.method == 8 else { return nil }
        return inflate(compressed, uncompressed: entry.uncompressedSize)
    }

    private struct Entry {
        var name: String
        var method: Int
        var compressedSize: Int
        var uncompressedSize: Int
        var localOffset: Int
    }

    private static func centralDirectory(_ data: Data) -> [Entry] {
        guard let eocd = lastSignature(data, 0x06054b50, minLength: 22) else { return [] }
        let count = intAt(data, eocd + 10, length: 2)
        var offset = intAt(data, eocd + 16, length: 4)
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, intAt(data, offset, length: 4) == 0x02014b50 else { break }
            let method = intAt(data, offset + 10, length: 2)
            let compressed = intAt(data, offset + 20, length: 4)
            let uncompressed = intAt(data, offset + 24, length: 4)
            let nameLen = intAt(data, offset + 28, length: 2)
            let extraLen = intAt(data, offset + 30, length: 2)
            let commentLen = intAt(data, offset + 32, length: 2)
            let local = intAt(data, offset + 42, length: 4)
            let nameStart = offset + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= data.count else { break }
            let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8) ?? ""
            entries.append(Entry(name: name, method: method, compressedSize: compressed, uncompressedSize: uncompressed, localOffset: local))
            offset = nameEnd + extraLen + commentLen
        }
        return entries
    }

    private static func lastSignature(_ data: Data, _ signature: UInt32, minLength: Int) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= minLength else { return nil }
        var index = bytes.count - minLength
        let limit = max(0, bytes.count - 66_000)
        while index >= limit {
            let value = UInt32(bytes[index])
                | (UInt32(bytes[index + 1]) << 8)
                | (UInt32(bytes[index + 2]) << 16)
                | (UInt32(bytes[index + 3]) << 24)
            if value == signature { return index }
            if index == 0 { break }
            index -= 1
        }
        return nil
    }

    private static func intAt(_ data: Data, _ offset: Int, length: Int) -> Int {
        var value = 0
        for i in 0..<length {
            value |= Int(data[data.startIndex + offset + i]) << (8 * i)
        }
        return value
    }

    private static func inflate(_ data: Data, uncompressed: Int) -> Data? {
        guard uncompressed > 0, uncompressed < 40_000_000 else { return nil }
        // ZIP stores raw deflate. A zlib header lets the system decoder read it.
        var wrapped = Data([0x78, 0x9C])
        wrapped.append(data)
        let capacity = uncompressed + 64
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let count = wrapped.withUnsafeBytes { raw -> Int in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, capacity, source, wrapped.count, nil, COMPRESSION_ZLIB)
        }
        guard count > 0 else { return nil }
        return Data(bytes: destination, count: min(count, uncompressed))
    }
}
