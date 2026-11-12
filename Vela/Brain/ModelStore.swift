//
//  ModelStore.swift
//  Vela
//
//  Downloads mlx-community/Qwen2.5-1.5B-Instruct-4bit once, into Application
//  Support, and keeps the loaded MLX container. The weights are the only
//  thing Vela fetches from the network.
//
//  MLXLLM and MLXLMCommon live in mlx-swift-lm (they moved out of
//  mlx-swift-examples). 2.31.3 is the last release whose tools version
//  matches the Xcode 26.3 runner and still exposes HubApi with a chosen
//  download folder, so the model can be deleted again.
//

import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon

enum ModelStoreError: LocalizedError {
    case safeMode
    case corrupt

    var errorDescription: String? {
        switch self {
        case .safeMode: return "Das Modell hat die App beim letzten Laden beendet."
        case .corrupt: return "Die Modelldatei ist unvollständig und wird neu geladen."
        }
    }
}

enum MLXMemoryLimits {
    /// Keep MLX from holding a huge GPU cache beside the Metal nebula.
    static func apply() {
        GPU.set(cacheLimit: 16 * 1024 * 1024)
        GPU.set(memoryLimit: 1_200 * 1024 * 1024, relaxed: true)
    }
}

@MainActor
final class ModelStore: ObservableObject {
    static let repoID = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    static let approximateBytes: Int64 = 1_000_000_000

    enum Phase: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .missing
    @Published private(set) var detail = "ca. 1,0 GB · wird einmalig geladen"
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
    private let configuration = ModelConfiguration(
        id: ModelStore.repoID,
        extraEOSTokens: ["<|im_end|>", "<|endoftext|>"]
    )

    /// Incomplete files from an earlier attempt. A new download continues them.
    var hasPartialDownload: Bool {
        !isInstalled && directorySize(modelDirectory) > 1_048_576
    }

    /// Percent plus megabytes, for the first-launch progress bar.
    var progressText: String {
        let percent = Int((fraction * 100).rounded())
        if totalBytes > 10_000 {
            return "\(percent) % · \(Self.format(completedBytes)) von \(Self.format(totalBytes))"
        }
        return "\(percent) % · ca. 1,0 GB"
    }

    var isInstalled: Bool {
        let directory = modelDirectory
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path),
              let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        return items.contains { $0.lastPathComponent.contains("safetensors") }
    }

    init() {
        ModelProgressRelay.shared.store = self
        if UserDefaults.standard.bool(forKey: VelaSettings.modelLoadGuardKey) {
            safeMode = true
            phase = .failed("Das Modell hat die App beim letzten Laden beendet.")
            detail = "Sicherheitsmodus · das Modell wird nicht automatisch geladen"
            return
        }
        if hasModelFiles && !filesLookValid() {
            removeModelFiles()
            phase = .missing
            detail = "Die Modelldatei war beschädigt und wurde entfernt."
            return
        }
        if isInstalled {
            phase = .ready
            detail = "Bereit · \(Self.format(directorySize(modelDirectory)))"
        }
    }

    func download() {
        guard downloadTask == nil, loadTask == nil else { return }
        safeMode = false
        phase = .downloading(0)
        fraction = 0
        completedBytes = 0
        totalBytes = 0
        detail = "Verbindung …"
        downloadTask = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.downloadFiles()
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.downloadTask?.value
                self.downloadTask = nil
                if !self.filesLookValid() {
                    self.removeModelFiles()
                    self.phase = .failed("Die Modelldatei ist unvollständig.")
                    self.detail = "Erneut versuchen lädt sie neu."
                    return
                }
                self.phase = .ready
                self.fraction = 1
                self.detail = "Bereit · \(Self.format(self.directorySize(self.modelDirectory)))"
            } catch is CancellationError {
                self.downloadTask = nil
            } catch {
                self.downloadTask = nil
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
        downloadTask?.cancel()
        downloadTask = nil
        loadTask?.cancel()
        loadTask = nil
        if isInstalled {
            phase = .ready
            detail = "Bereit · \(Self.format(directorySize(modelDirectory)))"
        } else {
            phase = .missing
            fraction = 0
            detail = "ca. 1,0 GB · wird einmalig geladen"
        }
    }

    func delete() {
        downloadTask?.cancel()
        downloadTask = nil
        loadTask?.cancel()
        loadTask = nil
        container = nil
        endLoadGuard()
        safeMode = false
        try? FileManager.default.removeItem(at: modelDirectory)
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let items = try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.localizedCaseInsensitiveContains("huggingface")
                || item.lastPathComponent.localizedCaseInsensitiveContains("hub") {
                try? FileManager.default.removeItem(at: item)
            }
        }
        phase = .missing
        fraction = 0
        detail = "ca. 1,0 GB · wird einmalig geladen"
    }

    func container() async throws -> ModelContainer {
        if safeMode { throw ModelStoreError.safeMode }
        if hasModelFiles && !filesLookValid() {
            removeModelFiles()
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
        let task = Task.detached(priority: .userInitiated) {
            try await ModelStore.loadContainerOffMain()
        }
        loadTask = task
        do {
            let value = try await task.value
            container = value
            loadTask = nil
            endLoadGuard()
            onHeavyWork?(false)
            phase = .ready
            fraction = 1
            detail = "Bereit · \(Self.format(directorySize(modelDirectory)))"
            return value
        } catch {
            loadTask = nil
            container = nil
            endLoadGuard()
            onHeavyWork?(false)
            throw error
        }
    }

    /// Downloads the weight files only. The GPU load happens later, off the main thread.
    private func downloadFiles() async throws {
        let hub = HubApi(downloadBase: VelaPaths.modelDownloadBase, cache: nil)
        let repo = Hub.Repo(id: Self.repoID)
        _ = try await hub.snapshot(from: repo, matching: ["*.safetensors", "*.json", "tokenizer*", "*.model", "*.txt"]) { progress in
            let fraction = progress.fractionCompleted
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in
                ModelProgressRelay.shared.apply(fraction: fraction, completed: completed, total: total)
            }
        }
    }

    private static func loadContainerOffMain() async throws -> ModelContainer {
        MLXMemoryLimits.apply()
        let configuration = ModelConfiguration(
            id: repoID,
            extraEOSTokens: ["<|im_end|>", "<|endoftext|>"]
        )
        let hub = HubApi(downloadBase: VelaPaths.modelDownloadBase, cache: nil)
        return try await LLMModelFactory.shared.loadContainer(hub: hub, configuration: configuration) { _ in }
    }

    private var hasModelFiles: Bool {
        FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("config.json").path)
    }

    private func filesLookValid() -> Bool {
        let directory = modelDirectory
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

    private func removeModelFiles() {
        try? FileManager.default.removeItem(at: modelDirectory)
    }

    private func beginLoadGuard() {
        UserDefaults.standard.set(true, forKey: VelaSettings.modelLoadGuardKey)
    }

    private func endLoadGuard() {
        UserDefaults.standard.set(false, forKey: VelaSettings.modelLoadGuardKey)
    }

    private var modelDirectory: URL {
        configuration.modelDirectory(hub: HubApi(downloadBase: VelaPaths.modelDownloadBase, cache: nil))
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
