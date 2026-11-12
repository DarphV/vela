//
//  DocumentReader.swift
//  Vela
//
//  Opens a cited file. PDFs jump to the page the answer came from.
//

import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum ImportTypes {
    static var allowed: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .utf8PlainText, .text]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        if let markdown = UTType("net.daringfireball.markdown") { types.append(markdown) }
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") { types.append(docx) }
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        return types
    }
}

struct DocumentReader: View {
    let url: URL
    let page: Int?
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if url.pathExtension.lowercased() == "pdf" {
                    PDFKitView(url: url, page: page ?? 1)
                } else {
                    ScrollView {
                        Text(plain)
                            .font(.system(size: 16, design: .serif))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .textSelection(.enabled)
                    }
                }
            }
            .background(Color.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Schließen") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var plain: String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "Die Datei konnte nicht gelesen werden."
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL
    let page: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .black
        view.document = PDFDocument(url: url)
        show(page, in: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        show(page, in: view)
    }

    private func show(_ page: Int, in view: PDFView) {
        let index = max(0, page - 1)
        guard let document = view.document, let target = document.page(at: index) else { return }
        view.go(to: target)
    }
}
