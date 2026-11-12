//
//  VelaModelKind.swift
//  Vela
//
//  Two on-device models. Capable phones (about 8 GB, such as iPhone 16 Pro Max)
//  default to Qwen3 4B. Everything else stays on Qwen 2.5 1.5B. No 7B.
//

import Foundation

enum VelaModelKind: String, CaseIterable, Identifiable, Sendable {
    case fast
    case smart

    var id: String { rawValue }

    var repoID: String {
        switch self {
        case .fast: return "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        case .smart: return "mlx-community/Qwen3-4B-4bit"
        }
    }

    var title: String {
        switch self {
        case .fast: return "1.5B schnell"
        case .smart: return "4B klug"
        }
    }

    var displayName: String {
        switch self {
        case .fast: return "Qwen 2.5 1.5B"
        case .smart: return "Qwen 3 4B"
        }
    }

    var blurb: String {
        switch self {
        case .fast: return "Qwen 2.5 · etwa 1,0 GB"
        case .smart: return "Qwen 3 · etwa 2,3 GB · ohne Denkmodus"
        }
    }

    var sizeLabel: String {
        switch self {
        case .fast: return "1,0 GB"
        case .smart: return "2,3 GB"
        }
    }

    var approximateBytes: Int64 {
        switch self {
        case .fast: return 1_000_000_000
        case .smart: return 2_300_000_000
        }
    }

    /// Qwen3's chat template thinks unless enable_thinking is false.
    var disablesThinking: Bool { self == .smart }

    /// MLX allocation cap. The 4B weights are about 2.3 GB, so 1.2 GB cannot hold them.
    var memoryLimitBytes: Int {
        switch self {
        case .fast: return 1_200 * 1024 * 1024
        case .smart: return 3_400 * 1024 * 1024
        }
    }

    static var deviceDefault: VelaModelKind {
        ProcessInfo.processInfo.physicalMemory >= 7_500_000_000 ? .smart : .fast
    }

    static var saved: VelaModelKind? {
        guard let raw = UserDefaults.standard.string(forKey: VelaSettings.modelChoiceKey) else { return nil }
        return VelaModelKind(rawValue: raw)
    }
}
