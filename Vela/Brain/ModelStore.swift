//
//  ModelStore.swift
//  Vela
//
//  Downloads one mlx-community model into Application Support and keeps the
//  loaded MLX container. Capable phones default to Qwen3-4B-4bit. The 1.5B
//  model stays as the fallback. Switching unloads the weights first, and
//  deleting one model leaves the other on disk.
//
//  MLXLLM and MLXLMCommon live in mlx-swift-lm 2.31.3, which registers
//  model_type "qwen3" and can pass enable_thinking into the chat template.
//

import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon

enum ModelStoreError: LocalizedError {
    case safeMode
    case corrupt
    case notEnoughSpace

    var errorDescription: String? {
        switch self {
        case .safeMode: return "Das Modell hat die App beim letzten Laden beendet."
        case .corrupt: return "Die Modelldatei ist unvollständig und wird neu geladen."
        case .notEnoughSpace: return "Zu wenig freier Speicher für diese KI."
        }
    }
}

enum MLXMemoryLimits {
    /// Keep MLX from holding a huge GPU cache beside the Metal nebula.
    /// The cap grows with the selected model, and never past about 45% of RAM.
    static func apply(for kind: VelaModelKind) {
        GPU.set(cacheLimit: 16 * 1024 * 1024)
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        let headroom = max(900 * 1024 * 1024, physical * 45 / 100)
        GPU.set(memoryLimit: min(kind.memoryLimitBytes, headroom), relaxed: true)
    }

    static func releaseCache() {
        GPU.set(cacheLimit: 0)
        GPU.set(cacheLimit: 16 * 1024 * 1024)
    }
}

@MainActor
final class ModelStore: ObservableObject {
    enum Phase: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var selected: VelaModelKind
    @Published private(set) var phase: Phase = .missing
    @Published private(set) var detail = ""
    @Published private(set) var fraction: Double = 0
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    /// Set when the previous process died while the weights were loading.
    @Published private(set) var safeMode = false
    /// Lowers the Metal visual while weights move onto the GPU.
    var onHeavyWork: ((Bool) -> Void)?

    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    private var downloadTask: Task<Void, Error>?
    /// Bumped whenever a download or load must be ignored.
    private(set) var epoch = 0

    /// Incomplete files from an earlier attempt. A new download continues them.
    var hasPartialDownload: Bool {
        !isInstalled && directorySize(modelDirectory(for: selected)) > 1_048_576
    }

    /// Percent plus megabytes, for the first-launch progress bar.
    var progressText: String {
        let percent = Int((fraction * 100).rounded())
        if totalBytes > 10_000 {
            return "\(percent) % · \(Self.format(completedBytes)) von \(Self.format(totalBytes))"
        }
        return "\(percent) % · ca. \(selected.sizeLabel)"
    }

    var isInstalled: Bool { isInstalled(selected) }

    init() {
        let kind = VelaModelKind.saved ?? VelaModelKind.deviceDefault
        selected = kind
        detail = "ca. \(kind.sizeLabel) · wird einmalig geladen"
        ModelProgressRelay.shared.store = self
        if UserDefaults.standard.bool(forKey: VelaSettings.modelLoadGuardKey) {
            safeMode = true
            phase = .failed("Das Modell hat die App beim letzten Laden beendet.")
            detail = "Sicherheitsmodus · das Modell wird nicht automatisch geladen"
            return
        }
        if hasModelFiles(kind) && !filesLookValid(kind) {
            removeModelFiles(kind)
            phase = .missing
            detail = "Die Modelldatei war beschädigt und wurde entfernt."
            return
        }
        refreshFromDisk()
    }

    func statusLine(for kind: VelaModelKind) -> String {
        if kind == selected {
            if case .downloading = phase { return detail }
            if case .failed(let message) = phase { return message }
        }
        if isInstalled(kind) {
            return "\(kind.blurb) · gespeichert"
        }
        return "\(kind.blurb) · nicht geladen"
    }

    /// Unloads the current weights, then points downloads and loads at `kind`.
    func select(_ kind: VelaModelKind) {
        guard kind != selected else { return }
        abandonInFlight()
        selected = kind
        remember(kind)
        fraction = 0
        completedBytes = 0
        totalBytes = 0
        if safeMode {
            phase = .failed("Das Modell hat die App beim letzten Laden beendet.")
            detail = "Sicherheitsmodus · das Modell wird nicht automatisch geladen"
            return
        }
        refreshFromDisk()
    }

    func download() {
        guard downloadTask == nil, loadTask == nil else { return }
        if !hasFreeSpace(for: selected) {
            let message = "Zu wenig freier Speicher. \(selected.title) braucht etwa \(selected.sizeLabel)."
            phase = .failed(message)
            detail = message
            return
        }
        remember(selected)
        safeMode = false
        UserDefaults.standard.set(false, forKey: VelaSettings.modelLoadGuardKey)
        phase = .downloading(0)
        fraction = 0
        completedBytes = 0
        totalBytes = 0
        detail = "Verbindung …"
        let epoch = self.epoch
        let kind = selected
        downloadTask = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.downloadFiles(kind: kind, epoch: epoch)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.downloadTask?.value
                self.downloadTask = nil
                guard epoch == self.epoch, kind == self.selected else { return }
                if !self.filesLookValid(kind) {
                    self.removeModelFiles(kind)
                    self.phase = .failed("Die Modelldatei ist unvollständig.")
                    self.detail = "Erneut versuchen lädt sie neu."
                    return
                }
                self.phase = .ready
                self.fraction = 1
                self.detail = "Bereit · \(Self.format(self.directorySize(self.modelDirectory(for: kind))))"
            } catch is CancellationError {
                self.downloadTask = nil
            } catch {
                self.downloadTask = nil
                guard epoch == self.epoch else { return }
                self.phase = .failed(error.localizedDescription)
                self.detail = "Download unterbrochen. Erneut versuchen setzt ihn fort."
            }
        }
    }

    func clearSafeModeForRetry() {
        safeMode = false
        UserDefaults.standard.set(false, forKey: VelaSettings.modelLoadGuardKey)
    }

    /// Hides the safe-mode card for this launch. The guard stays set until a load succeeds.
    func dismissSafeModeKeepingGuard() {
        safeMode = false
    }

    func cancelDownload() {
        abandonInFlight()
        if isInstalled {
            phase = .ready
            detail = "Bereit · \(Self.format(directorySize(modelDirectory(for: selected))))"
        } else {
            phase = .missing
            fraction = 0
            detail = "ca. \(selected.sizeLabel) · wird einmalig geladen"
        }
    }

    func delete() {
        let kind = selected
        abandonInFlight()
        endLoadGuard()
        safeMode = false
        removeModelFiles(kind)
        phase = .missing
        fraction = 0
        detail = "ca. \(kind.sizeLabel) · wird einmalig geladen"
    }

    func container() async throws -> ModelContainer {
        if safeMode { throw ModelStoreError.safeMode }
        let kind = selected
        if hasModelFiles(kind) && !filesLookValid(kind) {
            removeModelFiles(kind)
            phase = .missing
            detail = "Die Modelldatei war beschädigt und wurde entfernt."
            throw ModelStoreError.corrupt
        }
        if let container { return container }
        if let loadTask { return try await loadTask.value }
        onHeavyWork?(true)
        beginLoadGuard()
        phase = .downloading(max(fraction, 0.02))
        detail = "Modell wird vorbereitet …"
        let epoch = self.epoch
        let task = Task.detached(priority: .userInitiated) {
            try await ModelStore.loadContainerOffMain(kind)
        }
        loadTask = task
        do {
            let value = try await task.value
            guard epoch == self.epoch, kind == selected else { throw CancellationError() }
            container = value
            loadTask = nil
            endLoadGuard()
            onHeavyWork?(false)
            phase = .ready
            fraction = 1
            detail = "Bereit · \(Self.format(directorySize(modelDirectory(for: kind))))"
            return value
        } catch {
            loadTask = nil
            if epoch == self.epoch {
                container = nil
                endLoadGuard()
                onHeavyWork?(false)
            }
            throw error
        }
    }

    func isInstalled(_ kind: VelaModelKind) -> Bool {
        let directory = modelDirectory(for: kind)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path),
              let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        return items.contains { $0.lastPathComponent.contains("safetensors") }
    }

    /// Downloads the weight files only. The GPU load happens later, off the main thread.
    private func downloadFiles(kind: VelaModelKind, epoch: Int) async throws {
        let hub = Self.hub
        let repo = Hub.Repo(id: kind.repoID)
        _ = try await hub.snapshot(from: repo, matching: ["*.safetensors", "*.json", "tokenizer*", "*.model", "*.txt"]) { progress in
            let fraction = progress.fractionCompleted
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in
                guard epoch == ModelProgressRelay.shared.store?.epoch else { return }
                ModelProgressRelay.shared.apply(fraction: fraction, completed: completed, total: total)
            }
        }
    }

    nonisolated private static func loadContainerOffMain(_ kind: VelaModelKind) async throws -> ModelContainer {
        MLXMemoryLimits.apply(for: kind)
        let configuration = ModelConfiguration(
            id: kind.repoID,
            extraEOSTokens: ["<|im_end|>", "<|endoftext|>"]
        )
        let hub = HubApi(downloadBase: VelaPaths.modelDownloadBase, cache: nil)
        return try await LLMModelFactory.shared.loadContainer(hub: hub, configuration: configuration) { _ in }
    }

    private func abandonInFlight() {
        epoch += 1
        downloadTask?.cancel()
        downloadTask = nil
        loadTask?.cancel()
        loadTask = nil
        container = nil
        MLXMemoryLimits.releaseCache()
        onHeavyWork?(false)
        if !safeMode {
            endLoadGuard()
        }
    }

    private func refreshFromDisk() {
        let kind = selected
        if hasModelFiles(kind) && !filesLookValid(kind) {
            removeModelFiles(kind)
            phase = .missing
            detail = "Die Modelldatei war beschädigt und wurde entfernt."
            return
        }
        if isInstalled(kind) {
            phase = .ready
            fraction = 1
            detail = "Bereit · \(Self.format(directorySize(modelDirectory(for: kind))))"
        } else {
            phase = .missing
            fraction = 0
            detail = "ca. \(kind.sizeLabel) · wird einmalig geladen"
        }
    }

    private func hasFreeSpace(for kind: VelaModelKind) -> Bool {
        let base = VelaPaths.modelDownloadBase
        let values = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage, available > 0 else { return true }
        let already = directorySize(modelDirectory(for: kind))
        let stillNeeded = max(kind.approximateBytes - already, 0) + 400_000_000
        return available > stillNeeded
    }

    private func hasModelFiles(_ kind: VelaModelKind) -> Bool {
        FileManager.default.fileExists(atPath: modelDirectory(for: kind).appendingPathComponent("config.json").path)
    }

    private func filesLookValid(_ kind: VelaModelKind) -> Bool {
        let directory = modelDirectory(for: kind)
        let config = directory.appendingPathComponent("config.json")
        guard fileSize(config) > 32 else { return false }
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return false
        }
        return items.contains { item in
            item.lastPathComponent.contains("safetensors") && fileSize(item) > 5_000_000
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func removeModelFiles(_ kind: VelaModelKind) {
        try? FileManager.default.removeItem(at: modelDirectory(for: kind))
    }

    private func remember(_ kind: VelaModelKind) {
        UserDefaults.standard.set(kind.rawValue, forKey: VelaSettings.modelChoiceKey)
    }

    private func beginLoadGuard() {
        UserDefaults.standard.set(true, forKey: VelaSettings.modelLoadGuardKey)
    }

    private func endLoadGuard() {
        UserDefaults.standard.set(false, forKey: VelaSettings.modelLoadGuardKey)
    }

    private static var hub: HubApi {
        HubApi(downloadBase: VelaPaths.modelDownloadBase, cache: nil)
    }

    private func modelDirectory(for kind: VelaModelKind) -> URL {
        ModelConfiguration(id: kind.repoID).modelDirectory(hub: Self.hub)
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    fileprivate func apply(fraction: Double, completed: Int64, total: Int64) {
        let value = fraction.isFinite ? min(1, max(0, fraction)) : 0
        self.fraction = value
        completedBytes = max(0, completed)
        totalBytes = max(0, total)
        phase = .downloading(value)
        detail = progressText
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

/// The MLX progress callback is not on the main actor. The store registers
/// itself so the callback can update the visible percentage without capturing
/// the store inside the download closure.
@MainActor
final class ModelProgressRelay {
    static let shared = ModelProgressRelay()
    weak var store: ModelStore?

    func apply(fraction: Double, completed: Int64, total: Int64) {
        store?.apply(fraction: fraction, completed: completed, total: total)
    }
}
