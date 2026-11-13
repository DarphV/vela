//
//  VoiceOutput.swift
//  Vela
//
//  Speech output. Streaming replies are synthesized to PCM and scheduled back
//  to back on the shared audio engine, so one phrase starts as the previous
//  one ends. If buffer playback cannot be scheduled, utterances are queued
//  on AVSpeechSynthesizer with no pre/post delay.
//

import AVFoundation
import Foundation

private final class SynthBox {
    private let lock = NSLock()
    private var chunks: [AVAudioPCMBuffer] = []
    private var done = false
    var onFirst: (([AVAudioPCMBuffer]) -> Void)?

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if !done { chunks.append(buffer) }
        lock.unlock()
    }

    var buffers: [AVAudioPCMBuffer] {
        lock.lock()
        let copy = chunks
        lock.unlock()
        return copy
    }

    func finish(_ buffers: [AVAudioPCMBuffer]) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        let callback = onFirst
        onFirst = nil
        lock.unlock()
        callback?(buffers)
    }
}

final class VoiceOutput: NSObject, AVSpeechSynthesizerDelegate {
    /// Called on the main queue when speech starts.
    var onStart: (() -> Void)?
    /// Called on the main queue when speech ends. `cancelled` is true after stop().
    var onFinish: ((_ cancelled: Bool) -> Void)?
    /// Engine that also owns the microphone, so echo cancellation has a reference.
    weak var playback: SpeechListener?

    private let synthesizer = AVSpeechSynthesizer()
    private let audioQueue = DispatchQueue(label: "de.barczewski.vela.speech", qos: .userInteractive)
    private var epoch = 0
    private var pending = 0
    private var openWrites = 0
    private var epochs: [ObjectIdentifier: Int] = [:]
    private var bufferPathFailed = false
    private var chain: Task<Void, Never> = Task {}
    private let synthLock = NSLock()
    private var synthFinish: (([AVAudioPCMBuffer]) -> Void)?
    private let levelLock = NSLock()
    private var level: Float = 0
    private var levelAt = Date.distantPast

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    var isSpeaking: Bool { synthesizer.isSpeaking || pending > 0 || openWrites > 0 }

    /// Includes an in-flight `write` so the turn is not closed before the first buffer arrives.
    var hasPending: Bool { pending > 0 || openWrites > 0 || synthesizer.isSpeaking }

    /// Real output level 0...1 from the PCM just handed to the player.
    var outputLevel: Float {
        levelLock.lock()
        let value = level
        let stamp = levelAt
        levelLock.unlock()
        if Date().timeIntervalSince(stamp) > 0.25 { return 0 }
        return value
    }

    /// Replaces anything currently spoken. Used for the voice preview.
    func speak(_ text: String, voiceID: String) {
        stop()
        Task { await playSentence(text, voiceID: voiceID) }
    }

    /// Speaks one finished sentence: synthesize the whole line, then schedule the buffers.
    /// Sentences wait their turn, so synthesis never overlaps the previous sentence's synthesis.
    func playSentence(_ text: String, voiceID: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let previous = chain
        let task = Task { @MainActor [weak self] in
            await previous.value
            await self?.performSentence(trimmed, voiceID: voiceID)
        }
        chain = task
        await task.value
    }

    /// Queues a sentence without waiting. Prefer `playSentence` when generation must pause first.
    func enqueue(_ text: String, voiceID: String) {
        Task { await playSentence(text, voiceID: voiceID) }
    }

    private func performSentence(_ text: String, voiceID: String) async {
        if bufferPathFailed {
            enqueueUtterance(makeUtterance(text, voiceID: voiceID))
            return
        }
        let token = epoch
        openWrites += 1
        onStart?()
        let pieces = await collectBuffers(text, voiceID: voiceID, token: token)
        guard token == epoch else {
            openWrites = max(0, openWrites - 1)
            return
        }
        openWrites = max(0, openWrites - 1)
        guard !pieces.isEmpty, let merged = Self.merge(pieces) else {
            failBuffers(token: token, text: text, voiceID: voiceID)
            return
        }
        rememberLevel(Self.level(of: merged))
        let slices = Self.slices(of: merged, frames: 9_600)
        let played: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.bufferPlayed(token: token) }
        }
        let scheduled = await schedule(slices, played: played)
        guard token == epoch else { return }
        if scheduled == 0 {
            failBuffers(token: token, text: text, voiceID: voiceID)
        } else {
            pending += scheduled
        }
    }

    /// Collects every PCM buffer for the sentence before anything is scheduled.
    private func collectBuffers(_ text: String, voiceID: String, token: Int) async -> [AVAudioPCMBuffer] {
        let utterance = makeUtterance(text, voiceID: voiceID)
        return await withCheckedContinuation { continuation in
            let box = SynthBox()
            box.onFirst = { buffers in
                continuation.resume(returning: buffers)
            }
            synthLock.lock()
            synthFinish = { buffers in
                box.finish(buffers)
            }
            synthLock.unlock()
            synthesizer.write(utterance) { [weak self] buffer in
                guard let self else {
                    box.finish([])
                    return
                }
                self.audioQueue.async {
                    guard token == self.epoch else {
                        box.finish([])
                        return
                    }
                    if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0, let copy = Self.copy(pcm) {
                        box.append(copy)
                    } else {
                        box.finish(box.buffers)
                    }
                }
            }
        }
    }

    private func schedule(_ buffers: [AVAudioPCMBuffer], played: @escaping () -> Void) async -> Int {
        await withCheckedContinuation { continuation in
            audioQueue.async { [weak self] in
                let count = self?.playback?.playPrepared(buffers, played: played) ?? 0
                continuation.resume(returning: count)
            }
        }
    }

    func stop() {
        epoch += 1
        pending = 0
        openWrites = 0
        epochs.removeAll()
        rememberLevel(0)
        synthLock.lock()
        let finish = synthFinish
        synthFinish = nil
        synthLock.unlock()
        finish?([])
        playback?.stopSpeechPlayback()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: Voices

    /// Installed German voices, best quality first.
    static func germanVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("de") }
            .sorted { a, b in
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra > rb }
                if a.language != b.language { return a.language == "de-DE" }
                return a.name < b.name
            }
    }

    static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Erweitert"
        default: return "Standard"
        }
    }

    static func resolveVoice(id: String) -> AVSpeechSynthesisVoice? {
        if !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        return germanVoices().first ?? AVSpeechSynthesisVoice(language: "de-DE")
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.onStart?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.completeUtterance(utterance, cancelled: false)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.completeUtterance(utterance, cancelled: true)
        }
    }

    private func makeUtterance(_ text: String, voiceID: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceOutput.resolveVoice(id: voiceID)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        utterance.prefersAssistiveTechnologySettings = false
        return utterance
    }

    private func enqueueUtterance(_ utterance: AVSpeechUtterance) {
        epochs[ObjectIdentifier(utterance)] = epoch
        pending += 1
        synthesizer.speak(utterance)
    }

    private func completeUtterance(_ utterance: AVSpeechUtterance, cancelled: Bool) {
        let key = ObjectIdentifier(utterance)
        guard epochs[key] == epoch else { return }
        epochs[key] = nil
        pending = max(0, pending - 1)
        finishIfIdle(token: epoch, cancelled: cancelled)
    }

    private func bufferPlayed(token: Int) {
        guard token == epoch else { return }
        pending = max(0, pending - 1)
        finishIfIdle(token: token, cancelled: false)
    }

    private func finishIfIdle(token: Int, cancelled: Bool) {
        guard token == epoch, pending == 0, openWrites == 0 else { return }
        rememberLevel(0)
        onFinish?(cancelled)
    }

    private func failBuffers(token: Int, text: String, voiceID: String) {
        guard token == epoch else { return }
        bufferPathFailed = true
        playback?.stopSpeechPlayback()
        pending = 0
        enqueueUtterance(makeUtterance(text, voiceID: voiceID))
    }

    private func rememberLevel(_ value: Float) {
        levelLock.lock()
        level = value
        levelAt = Date()
        levelLock.unlock()
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
            return copy
        }
        if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
            return copy
        }
        return nil
    }

    private static func merge(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard frames > 0, let merged = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        merged.frameLength = AVAudioFrameCount(frames)
        guard let destination = merged.floatChannelData else { return buffers.count == 1 ? first : nil }
        var offset = 0
        let channels = Int(first.format.channelCount)
        for buffer in buffers {
            guard buffer.format.sampleRate == first.format.sampleRate,
                  buffer.format.channelCount == first.format.channelCount,
                  let source = buffer.floatChannelData else { continue }
            let count = Int(buffer.frameLength)
            for channel in 0..<channels {
                destination[channel].advanced(by: offset).update(from: source[channel], count: count)
            }
            offset += count
        }
        merged.frameLength = AVAudioFrameCount(offset)
        return merged.frameLength > 0 ? merged : nil
    }

    /// Several scheduled buffers, so the player is not waiting on the next synthesis.
    private static func slices(of buffer: AVAudioPCMBuffer, frames: Int) -> [AVAudioPCMBuffer] {
        let total = Int(buffer.frameLength)
        guard total > frames, let source = buffer.floatChannelData else { return [buffer] }
        var slices: [AVAudioPCMBuffer] = []
        let channels = Int(buffer.format.channelCount)
        var offset = 0
        while offset < total {
            let count = min(frames, total - offset)
            guard let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
                  let destination = slice.floatChannelData else { break }
            slice.frameLength = AVAudioFrameCount(count)
            for channel in 0..<channels {
                destination[channel].update(from: source[channel].advanced(by: offset), count: count)
            }
            slices.append(slice)
            offset += count
        }
        return slices.isEmpty ? [buffer] : slices
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        let stride = max(count / 400, 1)
        var used = 0
        var index = 0
        while index < count {
            let sample = channel[index]
            sum += sample * sample
            used += 1
            index += stride
        }
        guard used > 0 else { return 0 }
        let rms = (sum / Float(used)).squareRoot()
        let db = 20 * log10(rms + 1e-7)
        return min(1, max(0, (db + 50) / 32))
    }
}
