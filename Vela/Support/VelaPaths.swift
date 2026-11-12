//
//  VelaPaths.swift
//  Vela
//
//  Everything Vela stores stays in Application Support, on the device.
//

import Foundation

enum VelaPaths {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory(base.appendingPathComponent("Vela", isDirectory: true))
    }

    /// Hugging Face snapshot root for the on-device model.
    static var modelDownloadBase: URL {
        directory(root.appendingPathComponent("Models", isDirectory: true))
    }

    static var documents: URL {
        directory(root.appendingPathComponent("Documents", isDirectory: true))
    }

    static var indexDatabase: URL {
        root.appendingPathComponent("knowledge.sqlite")
    }

    @discardableResult
    private static func directory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
