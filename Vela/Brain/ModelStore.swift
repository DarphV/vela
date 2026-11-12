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
import MLXLLM
import MLXLMCommon

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

    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
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
        if isInstalled {
            phase = .ready
            detail = "Bereit · \(Self.format(directorySize(modelDirectory)))"
        }
    }

    func download() {
        guard loadTask == nil else { return }
        phase = .downloading(0)
        fraction = 0
        completedBytes = 0
        totalBytes = 0
        detail = "Verbindung …"
        loadTask = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.load(reporting: true)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                self.container = try await self.loadTask?.value
                self.loadTask = nil
                self.phase = .ready
                self.fraction = 1
                self.detail = "Bereit · \(Self.format(self.directorySize(self.modelDirectory)))"
            } catch is CancellationError {
                self.loadTask = nil
            } catch {
                self.loadTask = nil
                self.container = nil
                self.phase = .failed(error.localizedDescription)
                self.detail = "Download unterbrochen. Erneut versuchen setzt ihn fort."
            }
        }
    }

    func cancelDownload() {
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
        loadTask?.cancel()
        loadTask = nil
        container = nil
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
        if let container { return container }
        if let loadTask { return try await loadTask.value }
        phase = .downloading(max(fraction, 0.02))
        detail = isInstalled ? "Modell wird vorbereitet …" : detail
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.load(reporting: !self.isInstalled)
        }
        loadTask = task
        do {
            let value = try await task.value
            container = value
            loadTask = nil
            phase = .ready
            fraction = 1
            detail = "Bereit · \(Self.format(directorySize(modelDirectory)))"
            return value
        } catch {
            loadTask = nil
            throw error
        }
    }

    private func load(reporting: Bool) async throws -> ModelContainer {
        let hub = HubApi(downloadBase: VelaPaths.modelDownloadBase, cache: nil)
        return try await LLMModelFactory.shared.loadContainer(hub: hub, configuration: configuration) { progress in
            guard reporting else { return }
            let fraction = progress.fractionCompleted
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in
                ModelProgressRelay.shared.apply(fraction: fraction, completed: completed, total: total)
            }
        }
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
