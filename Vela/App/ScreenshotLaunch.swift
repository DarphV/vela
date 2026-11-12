//
//  ScreenshotLaunch.swift
//  Vela
//
//  CI launches the simulator with `--vela-screenshot <kind>` and grabs the frame.
//  The real app never sets this.
//

import Foundation

enum ScreenshotLaunch {
    enum Kind: String {
        case voiceNebula = "voice-0"
        case voiceBlackHole = "voice-1"
        case voiceNebulaDisk = "voice-2"
        case chat
        case settings
    }

    static var kind: Kind? {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--vela-screenshot"), flag + 1 < args.count else { return nil }
        return Kind(rawValue: args[flag + 1])
    }
}
