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
        case microphoneDenied
        case permissionNeeded
        case sessionFailed

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable: return "Spracherkennung gerade nicht verfügbar"
            case .noMicrophone: return "Kein Mikrofon gefunden"
            case .microphoneDenied: return "Mikrofon nicht erlaubt"
            case .permissionNeeded: return "Mikrofonfreigabe fehlt noch"
            case .sessionFailed: return "Audiositzung konnte nicht gestartet werden"
            }
        }
    }

    /// (text, isFinal) – called on the main queue.
    var onResult: ((String, Bool) -> Void)?
    /// Called once when a recognition task ends by itself (error, timeout, final).
    var onEnd: ((Error?) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playerReady = false
    private var playbackFormat: AVAudioFormat?
    private var voiceProcessingArmed = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var generation = 0

    private let levelLock = NSLock()
    private var currentLevel: Float = 0
    private var playbackLevel: Float = 0
    private var playbackLevelAt = Date.distantPast

    private(set) var isRunning = false

    /// True when German recognition runs completely on the iPhone.
    var isOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    /// Smoothed mic level 0...1 (prototype formula: (dB + 58) / 40).
    var level: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return currentLevel
    }

    /// Level of the TTS buffers just scheduled, 0 when nothing is playing.
    var speechLevel: Float {
        levelLock.lock()
        let value = playbackLevel
        let stamp = playbackLevelAt
        levelLock.unlock()
        if Date().timeIntervalSince(stamp) > 0.12 { return 0 }
        return value
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
        if isRunning { return }
        stopRecognition()
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            throw ListenerError.permissionNeeded
        case .denied:
            throw ListenerError.microphoneDenied
        @unknown default:
            throw ListenerError.microphoneDenied
        }
        guard AudioSessionManager.activate() else { throw ListenerError.sessionFailed }
        guard let recognizer, recognizer.isAvailable else { throw ListenerError.recognizerUnavailable }

        var lastError: Error = ListenerError.noMicrophone
        for voiceProcessing in [true, false] {
            do {
                try startGraph(hints: hints, voiceProcessing: voiceProcessing, recognizer: recognizer)
                return
            } catch {
                lastError = error
                dismantleGraph()
            }
        }
        throw lastError
    }

    private func startGraph(hints: [String], voiceProcessing: Bool, recognizer: SFSpeechRecognizer) throws {
        if let error = VelaSetVoiceProcessing(engine, voiceProcessing) {
            if voiceProcessing { throw error }
        }
        voiceProcessingArmed = voiceProcessing
        try connectPlayer()

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

        if let error = VelaInstallInputTap(engine, format, { [weak self] buffer in
            req.append(buffer)
            self?.measure(buffer)
        }) {
            throw error
        }
        tapInstalled = true

        if let error = VelaAudioEnginePrepare(engine) { throw error }
        if !engine.isRunning, let error = VelaAudioEngineStart(engine) { throw error }

        generation += 1
        let gen = generation
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self, gen == self.generation else { return }
            if let result {
                self.onResult?(result.bestTranscription.formattedString, result.isFinal)
            }
            if error != nil || (result?.isFinal ?? false) {
                self.generation += 1
                self.onEnd?(error)
            }
        }
        isRunning = true
    }

    func stop() {
        stopRecognition()
        stopSpeechPlayback()
        if engine.isRunning { engine.stop() }
    }

    /// Ends recognition but leaves the engine up so queued speech can finish.
    func stopRecognition() {
        generation += 1
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

    /// Schedules synthesized speech on the same engine the mic uses, so voice processing can cancel the echo.
    @discardableResult
    func scheduleSpeech(_ buffer: AVAudioPCMBuffer, played: @escaping () -> Void) -> Bool {
        do { try connectPlayer() } catch { return false }
        guard let playable = convert(buffer, to: playbackFormat), playable.frameLength > 0 else { return false }
        if !engine.isRunning {
            if VelaAudioEnginePrepare(engine) != nil { return false }
            if VelaAudioEngineStart(engine) != nil { return false }
        }
        if !player.isPlaying { player.play() }
        notePlaybackLevel(Self.rmsLevel(buffer))
        player.scheduleBuffer(playable, completionCallbackType: .dataPlayedBack) { _ in
            played()
        }
        return true
    }

    func stopSpeechPlayback() {
        if playerReady { player.stop() }
        notePlaybackLevel(0)
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

    private func notePlaybackLevel(_ value: Float) {
        levelLock.lock()
        playbackLevel = value
        playbackLevelAt = Date()
        levelLock.unlock()
    }

    private func connectPlayer() throws {
        guard !playerReady else { return }
        engine.attach(player)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let usable = (format.sampleRate > 0 && format.channelCount > 0)
            ? format
            : AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
        guard let usable else { throw ListenerError.sessionFailed }
        playbackFormat = usable
        engine.connect(player, to: engine.mainMixerNode, format: usable)
        playerReady = true
    }

    private func dismantleGraph() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        if playerReady {
            player.stop()
            engine.disconnectNodeOutput(player)
            engine.detach(player)
            playerReady = false
            playbackFormat = nil
        }
        voiceProcessingArmed = false
        isRunning = false
        request = nil
        task = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard let format else { return buffer }
        if buffer.format.sampleRate == format.sampleRate, buffer.format.channelCount == format.channelCount {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / max(buffer.format.sampleRate, 1)
        let frames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 512)) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil || output.frameLength == 0 { return nil }
        return output
    }

    private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(rms + 1e-7)
        return min(1, max(0, (db + 50) / 32))
    }
}
