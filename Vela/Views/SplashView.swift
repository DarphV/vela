//
//  SplashView.swift
//  Vela
//
//  "Vela – Dein Wissen · Offline" intro (prototype: #splash). The visual runs
//  behind it; the splash fades out after ~3.7 s or on tap.
//

import SwiftUI

struct SplashView: View {
    let onFinish: () -> Void

    @State private var wordIn = false
    @State private var tagIn = false
    @State private var fadingOut = false
    @State private var finished = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RadialGradient(colors: [Color.black.opacity(0.25), Color.black.opacity(0.7)],
                               center: UnitPoint(x: 0.5, y: 0.43), startRadius: 0, endRadius: geo.size.height * 0.5)
                VStack(spacing: 16) {
                    Text("Vela")
                        .font(.system(size: 68, weight: .thin, design: .rounded))
                        .tracking(wordIn ? 68 * 0.28 : 68 * 0.7)
                        .padding(.leading, 68 * 0.28)
                        .foregroundStyle(Theme.wordmark)
                        .shadow(color: Color.rgba(160, 110, 255, 0.55), radius: wordIn ? 16 : 0)
                        .blur(radius: wordIn ? 0 : 10)
                        .opacity(wordIn ? 1 : 0)
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: wordIn ? 72 : 8, height: 1)
                        .opacity(tagIn ? 0.8 : 0)
                    Text("DEIN WISSEN · OFFLINE")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .tracking(13 * 0.42)
                        .foregroundStyle(.white.opacity(0.55))
                        .offset(y: tagIn ? 0 : 8)
                        .opacity(tagIn ? 1 : 0)
                }
                .offset(y: -geo.size.height * 0.07)
            }
        }
        .ignoresSafeArea()
        .opacity(fadingOut ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 1.8).delay(0.15)) { wordIn = true }
            withAnimation(.easeOut(duration: 1.4).delay(0.9)) { tagIn = true }
            try? await Task.sleep(for: .milliseconds(2700))
            withAnimation(.easeInOut(duration: 1.0)) { fadingOut = true }
            try? await Task.sleep(for: .milliseconds(1000))
            finish()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Vela – Dein Wissen, offline")
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }
}
