//
//  VoiceModeView.swift
//  Vela
//
//  Full-screen voice mode overlay: status line, sub line, mic toggle and the
//  "Tippen für Textmodus" hint. Tapping anywhere switches to the Glas-Chat.
//  No waveform lines – the visual itself reacts to the voice.
//

import SwiftUI

struct VoiceModeView: View {
    @EnvironmentObject var model: AppModel
    let layout: StageLayout

    var body: some View {
        let L = layout
        let statusTop = L.centerY + L.stage * 0.405
        ZStack(alignment: .topLeading) {
            // Tap target: whole screen
            Color.black.opacity(0.001)
                .frame(width: L.width, height: L.height)
                .position(x: L.width / 2, y: L.y(L.height / 2))
                .onTapGesture { model.toChat() }
                .accessibilityLabel("Zum Textmodus wechseln")
                .accessibilityAddTraits(.isButton)

            StatusLine(state: model.state)
                .frame(width: L.width)
                .position(x: L.width / 2, y: L.y(statusTop + 23))
                .allowsHitTesting(false)

            Text(model.subline)
                .velaText(12.5)
                .tracking(0.3)
                .foregroundStyle(.white.opacity(0.38))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 32)
                .frame(width: L.width)
                .position(x: L.width / 2, y: L.y(statusTop + 54 + 9))
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.25), value: model.subline)

            Button {
                model.toggleMic()
            } label: {
                Image(systemName: model.micEnabled ? "mic" : "mic.slash")
                    .velaText(18, weight: .regular)
                    .foregroundStyle(.white.opacity(model.micEnabled ? 1 : 0.75))
                    .frame(width: 46, height: 46)
                    .velaChip(Circle(), highlighted: model.micEnabled && model.state == .listening)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.micEnabled ? "Mikrofon ausschalten" : "Mikrofon einschalten")
            .position(x: L.width / 2, y: L.y(L.height - L.sab - 82 - 23))

            HintRow()
                .position(x: L.width / 2, y: L.y(L.height - L.sab - 26 - 24))
                .allowsHitTesting(false)
        }
    }
}

/// "Ich höre zu ..." with gradient dots pulsing like the prototype's CSS animation.
private struct StatusLine: View {
    let state: VelaState

    var body: some View {
        HStack(spacing: 0) {
            Text(state.label)
                .foregroundStyle(.white.opacity(0.94))
                .id(state)
                .transition(.opacity.combined(with: .offset(y: 6)))
            PulsingDots()
        }
        .velaText(38, weight: .thin)
        .tracking(-0.2)
        .shadow(color: Color.rgba(160, 120, 255, 0.25), radius: 15)
        .animation(.easeInOut(duration: 0.35), value: state)
    }
}

private struct PulsingDots: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 0) {
                Text(" ")
                ForEach(0..<3, id: \.self) { i in
                    Text(".")
                        .opacity(Self.opacity(t: t - Double(i) * 0.18))
                }
            }
            .fontWeight(.light)
            .foregroundStyle(LinearGradient(colors: [Color.rgba(159, 123, 255), Color.rgba(215, 182, 255)],
                                            startPoint: .leading, endPoint: .trailing))
        }
    }

    /// keyframes: 0 %, 80 %, 100 % → 0.25, 40 % → 1 (period 1.4 s)
    static func opacity(t: Double) -> Double {
        let p = (t / 1.4).truncatingRemainder(dividingBy: 1)
        let x = p < 0 ? p + 1 : p
        if x < 0.4 { return 0.25 + 0.75 * (x / 0.4) }
        if x < 0.8 { return 1 - 0.75 * ((x - 0.4) / 0.4) }
        return 0.25
    }
}

private struct HintRow: View {
    @State private var bob = false

    var body: some View {
        VStack(spacing: 6) {
        HStack(spacing: 14) {
            LinearGradient(colors: [.clear, .white.opacity(0.22)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 64, height: 1)
            Text("Tippen für Textmodus")
                .velaText(14)
                .tracking(0.2)
                .foregroundStyle(.white.opacity(0.5))
            LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 64, height: 1)
        }
        Image(systemName: "chevron.down")
            .velaText(12, weight: .semibold)
            .foregroundStyle(Color.rgba(183, 155, 255).opacity(0.65))
            .offset(y: bob ? 3 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { bob = true }
            }
        }
    }
}
