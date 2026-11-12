//
//  SpeechListener.swift
//  Vela
//
//  German speech recognition (SFSpeechRecognizer, on-device when available)
//  plus a live microphone level for the visuals.
//
//  Plain class on purpose: the audio tap runs on a realtime audio thread and must
//  not be actor-isolated. Recognition callbacks arrive on the main queue
//  (SFSpeechRecognizer.queue defaults to OperationQueue.main).
//

import AVFoundation
import Foundation
import Speech

final class SpeechListener {
    enum ListenerError: LocalizedError {
        case recognizerUnavailable
        case noMicrophone

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable: return "Spracherkennung gerade nicht verfügbar"
            case .noMicrophone: return "Kein Mikrofon gefunden"
            }
        }
    }

    /// (text, isFinal) – called on the main queue.
    var onResult: ((String, Bool) -> Void)?
    /// Called once when a recognition task ends by itself (error, timeout, final).
    var onEnd: ((Error?) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var generation = 0

    private let levelLock = NSLock()
    private var currentLevel: Float = 0

    private(set) var isRunning = false

    /// True when German recognition runs completely on the iPhone.
    var isOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    /// Smoothed mic level 0...1 (prototype formula: (dB + 58) / 40).
    var level: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return currentLevel
    }

    // MARK: Permissions

    static func requestPermissions() async -> Bool {
        let speechOK: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Start / stop

    func start(hints: [String] = []) throws {
        stop()
        guard let recognizer, recognizer.isAvailable else { throw ListenerError.recognizerUnavailable }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerError.noMicrophone }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        let terms = hints.filter { !$0.isEmpty }
        if !terms.isEmpty {
            req.contextualStrings = Array(terms.prefix(40))
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            self?.measure(buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }

        generation += 1
        let gen = generation
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self, gen == self.generation else { return }
            if let result {
                self.onResult?(result.bestTranscription.formattedString, result.isFinal)
            }
            if error != nil || (result?.isFinal ?? false) {
                self.generation += 1   // report the end only once
                self.onEnd?(error)
            }
        }
        isRunning = true
    }

    func stop() {
        generation += 1
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRunning = false
        setLevel(0)
    }

    // MARK: Level

    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n {
            let v = channel[i]
            sum += v * v
        }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(rms + 1e-7)
        setLevel(min(1, max(0, (db + 58) / 40)))
    }

    private func setLevel(_ value: Float) {
        levelLock.lock()
        currentLevel = value
        levelLock.unlock()
    }
}
