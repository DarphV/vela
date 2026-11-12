//
//  AudioSessionManager.swift
//  Vela
//
//  One audio session for listening + speaking. `.allowAirPlay` and
//  `.allowBluetoothA2DP` keep Vela's voice on AirPlay speakers (HomePod as
//  AirPlay target), Bluetooth speakers and AirPods while the iPhone mic listens.
//

import AVFoundation

enum AudioSessionManager {
    private static var configured = false

    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            if !configured {
                // voiceChat turns on echo cancellation so Vela can keep listening while she speaks.
                try session.setCategory(.playAndRecord,
                                        mode: .voiceChat,
                                        options: [.defaultToSpeaker, .allowAirPlay, .allowBluetooth])
                configured = true
            }
            try session.setActive(true, options: [])
        } catch {
            print("[Vela] AudioSession-Fehler: \(error)")
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
