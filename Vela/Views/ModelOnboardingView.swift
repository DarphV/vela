//
//  ModelOnboardingView.swift
//  Vela
//
//  First launch: the offline model is about 1 GB and is not on the phone yet.
//  The home screen stays named Vela; this card only explains the one-time download.
//

import SwiftUI

struct ModelOnboardingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            ScrollView {
                card
                    .padding(.horizontal, 22)
                    .padding(.vertical, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onChange(of: model.models.phase) { _, phase in
            if phase == .ready { model.finishModelOnboarding() }
        }
        .accessibilityAddTraits(.isModal)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("VELA")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .tracking(3.2)
                .foregroundStyle(Theme.wordmark)
                .frame(maxWidth: .infinity)

            Text("Offline-KI laden")
                .velaText(28, weight: .semibold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            Text("Vela antwortet auf dem iPhone. Dafür wird die KI einmalig geladen, etwa 1 GB. Danach bleiben die Fragen auf dem Gerät. Am besten über WLAN.")
                .velaText(16)
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            wifiNote

            if isDownloading {
                progressBlock
            } else {
                primaryButton
            }

            if case .failed = model.models.phase {
                Text(model.models.detail)
                    .velaText(14)
                    .foregroundStyle(Color.rgba(255, 196, 160))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if AppleIntelligenceStatus.isAvailable {
                Button {
                    Haptics.light()
                    model.useAppleIntelligenceFromOnboarding()
                } label: {
                    Text("Stattdessen Apple Intelligence")
                        .velaText(15.5, weight: .semibold)
                        .foregroundStyle(Color.rgba(185, 160, 255))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Keine eigene Modelldatei. Apple Intelligence muss auf diesem iPhone bereit sein.")
            }
        }
        .padding(24)
        .velaGlass(RoundedRectangle(cornerRadius: 28, style: .continuous), tint: Theme.sheetTint)
    }

    private var wifiNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi")
                .velaText(14, weight: .semibold)
                .foregroundStyle(Theme.cyan)
            Text("Empfohlen: WLAN")
                .velaText(14, weight: .medium)
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    private var isDownloading: Bool {
        if case .downloading = model.models.phase { return true }
        return false
    }

    private var primaryTitle: String {
        if case .failed = model.models.phase { return "Erneut versuchen" }
        if model.models.hasPartialDownload { return "Weiterladen" }
        return "Jetzt laden"
    }

    private var primaryButton: some View {
        Button {
            Haptics.light()
            model.models.download()
        } label: {
            Text(primaryTitle)
                .velaText(17, weight: .semibold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.accentGradient, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(model.models.hasPartialDownload
            ? "Setzt den angefangenen Download fort."
            : "Lädt etwa 1 GB. Ein Abbruch kann später fortgesetzt werden.")
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: model.models.fraction)
                .tint(Theme.violet)
                .accessibilityLabel("Download")
                .accessibilityValue(model.models.progressText)
            Text(model.models.progressText)
                .velaText(14, weight: .medium)
                .foregroundStyle(.white.opacity(0.8))
            Button("Laden abbrechen") { model.models.cancelDownload() }
                .velaText(14, weight: .medium)
                .foregroundStyle(Color.rgba(185, 160, 255))
                .frame(minHeight: 44, alignment: .leading)
        }
    }
}

struct ModelSafeModeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text("Sicherheitsmodus")
                    .velaText(28, weight: .semibold)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text("Das Modell hat die App beim letzten Laden beendet. Es wird nicht automatisch geladen.")
                    .velaText(16)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Haptics.light()
                    model.retryModelLoad()
                } label: {
                    Text("Erneut versuchen")
                        .velaText(17, weight: .semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.accentGradient, in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    model.continueInTextMode()
                } label: {
                    Text("Im Textmodus weiter")
                        .velaText(15.5, weight: .semibold)
                        .foregroundStyle(Color.rgba(185, 160, 255))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .velaGlass(RoundedRectangle(cornerRadius: 28, style: .continuous), tint: Theme.sheetTint)
            .padding(.horizontal, 22)
        }
    }
}
