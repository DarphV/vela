//
//  AudioSessionManager.swift
//  Vela
//
//  One audio session for listening + speaking. Activate this before the
//  AVAudioEngine graph is built. voiceChat enables echo cancellation.
//  defaultToSpeaker, Bluetooth A2DP and AirPlay keep playback off the earpiece.
//

import AVFoundation

enum AudioSessionManager {
    @discardableResult
    static func activate() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
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

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Name of the current output (e.g. "Wohnzimmer" for an AirPlay speaker).
    static var currentOutputName: String? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
    }
}
