//
//  SourceSheet.swift
//  Vela
//
//  Shows where an answer comes from: document, location and the quoted passage
//  with highlighted key phrases (prototype: #srcSheet).
//

import SwiftUI

struct SourceSheet: View {
    let source: VelaSource
    let onOpenDocument: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var showReader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Quelle") { dismiss() }

            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .velaText(18)
                    .frame(width: 40, height: 48)
                    .background(LinearGradient(colors: [Color.rgba(150, 110, 255, 0.35), Color.rgba(60, 180, 255, 0.2)],
                                               startPoint: .top, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.document)
                        .velaText(16, weight: .semibold)
                    Text(source.location)
                        .velaText(13)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.bottom, 12)

            Text(RichText.highlighted(source.excerpt))
                .font(.system(size: 14.5, design: .serif))
                .lineSpacing(5)
                .foregroundStyle(.white.opacity(0.8))
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))

            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Text("Schließen")
                        .velaText(15, weight: .medium)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                }
                Button(action: openDocument) {
                    Text("Im Dokument öffnen")
                        .velaText(15, weight: .medium)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(LinearGradient(colors: [Color.rgba(142, 99, 255, 0.85), Color.rgba(67, 201, 255, 0.75)],
                                                   startPoint: .leading, endPoint: .trailing), in: Capsule())
                        .shadow(color: Color.rgba(130, 100, 255, 0.4), radius: 9)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.top, 14)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .presentationDetents([.medium, .large])
        .velaSheetStyle()
        .fullScreenCover(isPresented: $showReader) {
            if let url = source.fileURL {
                DocumentReader(url: url, page: source.page, title: source.document)
            }
        }
    }

    private func openDocument() {
        if let url = source.fileURL, FileManager.default.fileExists(atPath: url.path) {
            showReader = true
        } else {
            onOpenDocument()
        }
    }
}

/// Sheet title row with round close button (prototype: .sheet h2 + .x).
struct SheetHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .velaText(22, weight: .semibold)
                .tracking(-0.3)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .velaText(12, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Schließen")
        }
        .padding(.bottom, 14)
    }
}

extension View {
    /// Frosted dark sheet like the prototype (.sheet: blur 30 px + rgba(18,15,30,.72)).
    func velaSheetStyle() -> some View {
        self
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(34)
            .presentationBackground {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Theme.sheetTint
                }
            }
            .preferredColorScheme(.dark)
    }
}
