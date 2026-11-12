//
//  VisualDriver.swift
//  Vela
//
//  Per-frame animation state for the Metal visuals. 1:1 port of the prototype's
//  `tick()` (app.js): amplitude, rotation speed, energy, zoom and brightness are
//  smoothed toward targets that depend on the conversation state and mode.
//
//  Deliberately a plain class (no actor isolation): it is written from SwiftUI on the
//  main thread and read by the MTKView draw loop, which also runs on the main thread.
//

import Foundation

enum VelaState: String {
    case idle, listening, thinking, speaking

    /// German status label shown in voice mode (prototype: LABEL).
    var label: String {
        switch self {
        case .listening: return "Ich höre zu"
        case .thinking: return "Ich denke nach"
        case .speaking: return "Ich spreche"
        case .idle: return "Bereit"
        }
    }

    /// Rotation speed of the visual (prototype: SPEED).
    var speed: Float {
        switch self {
        case .listening: return 0.10
        case .thinking: return 0.85
        case .speaking: return 0.22
        case .idle: return 0.08
        }
    }
}

enum VelaMode: Equatable {
    case voice, chat
}

/// Visual designs selectable in the settings. Raw values match the shader index.
enum VelaDesign: Int, CaseIterable, Identifiable {
    case nebula = 0
    case blackHoleClassic = 1
    case blackHoleNebula = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .nebula: return "Nebula"
        case .blackHoleClassic: return "Schwarzes Loch\nklassisch"
        case .blackHoleNebula: return "Schwarzes Loch\nNebula"
        }
    }
}

final class VisualDriver {
    // Targets (written by the app model / SwiftUI)
    var state: VelaState = .idle
    var mode: VelaMode = .voice
    var design: Int = 0
    var micActive = false
    var reduceMotion = false
    /// While the language model is moving onto the GPU, the visual stays cheap.
    var heavyWork = false
    /// Returns the current microphone level 0...1 (read every frame while listening).
    var levelProvider: (() -> Float)?

    /// Static drivers (settings thumbnails) never advance.
    let isStatic: Bool
    private let staticDesign: Int

    // Smoothed values
    private(set) var time: Float = 0
    private(set) var phase: Float = 0
    private(set) var amp: Float = 0
    private(set) var energy: Float = 0
    private(set) var zoom: Float = 1
    private(set) var bright: Float = 1
    private var speedCur: Float = 0.1
    private var chatT: Float = 0

    init() {
        isStatic = false
        staticDesign = 0
    }

    private init(thumbnailDesign d: Int) {
        isStatic = true
        staticDesign = d
        design = d
        // Same parameters the prototype used for its settings thumbnails.
        time = 3
        phase = 1
        amp = 0.1
        energy = 0
        zoom = d == 1 ? 1.2 : 1.05
        bright = 1.05
    }

    static func thumbnail(design: Int) -> VisualDriver {
        VisualDriver(thumbnailDesign: design)
    }

    /// Advances the animation by `dt` seconds and returns shader uniforms
    /// (res and px are filled in by the renderer).
    func step(dt rawDt: Float) -> VelaUniforms {
        let d = isStatic ? staticDesign : max(0, min(2, design))
        if !isStatic {
            let dt = min(0.05, max(0, rawDt))
            let rm: Float = reduceMotion ? 0.45 : 1
            time += dt * rm

            var ampT: Float
            switch state {
            case .speaking:
                let live = levelProvider?() ?? 0
                ampT = live > 0.02 ? live * 0.95 : (0.05 + 0.02 * sin(time * 1.3))
            case .listening:
                ampT = micActive ? (levelProvider?() ?? 0) * 0.9 : 0.04 + 0.03 * sin(time * 1.3)
            case .thinking:
                ampT = 0.12 + 0.05 * sin(time * 6)
            case .idle:
                ampT = 0.04 + 0.03 * sin(time * 1.3)
            }
            ampT *= rm
            // Listening stays close to the mic; speaking is audible but not frantic.
            if state == .speaking { ampT *= 0.72 }
            if state == .listening { ampT *= 0.8 }
            amp = damp(amp, toward: ampT, dt: dt, rate: ampT > amp ? 7 : 4)

            let sp = state.speed * rm
            speedCur = damp(speedCur, toward: sp, dt: dt, rate: 2.4)
            phase += dt * speedCur

            let energyT: Float = state == .thinking ? 1 : 0
            energy = damp(energy, toward: energyT, dt: dt, rate: 2.2)

            let zoomT: Float = mode == .chat ? (d == 1 ? 1.55 : 1.3) : 1
            zoom = damp(zoom, toward: zoomT, dt: dt, rate: 2.6)

            let brightT: Float = state == .thinking ? 1.1 : (state == .speaking ? 1.04 : 1)
            bright = damp(bright, toward: brightT, dt: dt, rate: 2.4)

            let chatTarget: Float = mode == .chat ? 1 : 0
            chatT = damp(chatT, toward: chatTarget, dt: dt, rate: 2.2)
        }

        var u = VelaUniforms()
        u.time = time
        u.phase = phase
        u.amp = amp
        u.energy = energy
        u.zoom = zoom
        u.bright = bright
        u.design = Float(d)
        u.k = d == 1 ? 0.19 : 0.84
        u.rs = d == 1 ? 0.25 : 0.22
        return u
    }

    /// Point size relative to the drawable width. Full-screen: 1/stageWidth,
    /// chat avatar: the prototype rendered a 110 pt canvas at 0.6 point scale,
    /// thumbnails: width/260.
    func pointRelative(viewWidth: Float) -> Float {
        if isStatic { return 1.0 / 260.0 }
        let full = 1.0 / max(viewWidth, 1)
        let chat: Float = 0.6 / 110.0
        return full + (chat - full) * chatT
    }

    /// Frame-rate independent ease. `rate` is how quickly the value catches the target.
    private func damp(_ value: Float, toward target: Float, dt: Float, rate: Float) -> Float {
        let t = 1 - exp(-rate * dt)
        return value + (target - value) * t
    }

    /// Synthetic speech envelope used while Vela speaks (prototype: voiceEnv).
    /// TODO: replace with the real output level once TTS renders into AVAudioEngine.
    static func voiceEnvelope(_ t: Float) -> Float {
        let syl = max(0, sin(t * 2 * .pi * 4.2 + sin(t * 1.7) * 2.2))
        let g = sin(t * 2 * .pi * 0.55 + sin(t * 0.9) * 1.6)
        let word = min(1, max(0, (g + 0.25) / 0.55))
        let s = sin(t * 2.9)
        return pow(syl, 0.6) * word * (0.55 + 0.45 * s * s)
    }
}
