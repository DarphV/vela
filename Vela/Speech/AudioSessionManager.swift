//
//  AudioSessionManager.swift
//  Vela
//
//  Listening keeps voiceChat so the microphone path can cancel echo.
//  Playback switches to spokenAudio and does not run that processing on
//  the speaker. A larger IO buffer gives the voice room when the GPU is busy.
//

import AVFoundation

enum AudioSessionManager {
    /// About 30 ms. Long enough to ride out a GPU spike, short enough to stay responsive.
    static let ioBufferDuration: TimeInterval = 0.03

    @discardableResult
    static func activate() -> Bool {
        activateListening()
    }

    /// Microphone path. voiceChat stays here, and only here.
    @discardableResult
    static func activateListening() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try? session.setPreferredIOBufferDuration(ioBufferDuration)
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true, options: [])
            return true
        } catch {
            print("[Vela] AudioSession-Fehler: \(error)")
            return false
        }
    }

    /// Speaker path used while Vela talks and the microphone is not running.
    @discardableResult
    static func activateSpeaking() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try? session.setPreferredIOBufferDuration(ioBufferDuration)
            try session.setCategory(.playback,
                                    mode: .spokenAudio,
                                    options: [.allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true, options: [])
            return true
        } catch {
            return activateSpokenFallback()
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Hardware rate after the session is active. The player uses this exact rate.
    static var outputFormat: AVAudioFormat? {
        let session = AVAudioSession.sharedInstance()
        let rate = session.sampleRate > 0 ? session.sampleRate : 48_000
        let channels = AVAudioChannelCount(max(1, min(session.outputNumberOfChannels, 2)))
        return AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)
    }

    /// Name of the current output (e.g. "Wohnzimmer" for an AirPlay speaker).
    static var currentOutputName: String? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
    }

    private static func activateSpokenFallback() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try? session.setPreferredIOBufferDuration(ioBufferDuration)
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true, options: [])
            return true
        } catch {
            print("[Vela] AudioSession-Fehler: \(error)")
            return false
        }
    }
}
