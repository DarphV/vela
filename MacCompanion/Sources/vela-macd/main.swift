import AppKit
import CryptoKit
import Foundation
import Network
import Security

if MacCLI.handle(CommandLine.arguments) { exit(0) }

let repair = CommandLine.arguments.contains("--repair")
let server = VelaMacServer()
server.start(repair: repair)
dispatchMain()

final class VelaMacServer {
    private let queue = DispatchQueue(label: "vela.macd")
    private let store = MacStore()
    private var listener: NWListener?
    private var localListener: NWListener?
    private let port: UInt16 = 8741

    func start(repair: Bool) {
        if repair { store.clearToken() }
        store.ensureDefaults()
        MenuBar.install(store: store)
        let code = store.pairingCode()
        fputs("Vela Mac\nKopplungscode: \(code)\nDatei: \(store.codeURL.path)\n", stdout)
        fflush(stdout)
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Vela Mac", type: "_vela._tcp")
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    fputs("Listener: \(error)\n", stderr)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            startLocalControl()
        } catch {
            fputs("Start fehlgeschlagen: \(error)\n", stderr)
            exit(1)
        }
    }

    private func startLocalControl() {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let localPort = NWEndpoint.Port(rawValue: 8742),
              let local = try? NWListener(using: parameters, on: localPort) else { return }
        local.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        local.start(queue: queue)
        localListener = local
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if let headerEnd = next.range(of: Data("\r\n\r\n".utf8)) {
                let head = next.subdata(in: next.startIndex..<headerEnd.lowerBound)
                let rest = next.subdata(in: headerEnd.upperBound..<next.endIndex)
                self.handle(connection, head: head, rest: rest)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: next)
        }
    }

    private func handle(_ connection: NWConnection, head: Data, rest: Data) {
        guard let text = String(data: head, encoding: .utf8) else {
            connection.cancel()
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        readBody(connection, have: rest, need: length) { [weak self] body in
            guard let self else { return }
            if headers["upgrade"]?.lowercased() == "websocket" {
                self.webSocket(connection, headers: headers, path: path)
                return
            }
            let response = self.route(method: method, path: path, headers: headers, body: body)
            self.sendHTTP(connection, status: response.status, json: response.json)
        }
    }

    private func readBody(_ connection: NWConnection, have: Data, need: Int, done: @escaping (Data) -> Void) {
        if have.count >= need || need == 0 {
            done(Data(have.prefix(need)))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
            var next = have
            if let data { next.append(data) }
            self.readBody(connection, have: next, need: need, done: done)
        }
    }

    private func route(method: String, path: String, headers: [String: String], body: Data) -> (status: Int, json: String) {
        if method == "POST" && path == "/pair" {
            let code = jsonString(body, key: "code") ?? ""
            guard store.consume(code: code), let token = store.issueToken() else {
                return (401, #"{"ok":false,"message":"Code ungültig"}"#)
            }
            return (200, #"{"ok":true,"token":"\#(token)"}"#)
        }
        if path.hasPrefix("/local/") {
            guard headers["x-vela-local"] == store.localSecret else {
                return (401, #"{"ok":false,"message":"Nur lokal"}"#)
            }
            if path == "/local/grant" {
                store.applyGrant(body)
                return (200, store.permissionsJSON())
            }
            if path == "/local/log" { return (200, store.logJSON()) }
            return (404, #"{"ok":false}"#)
        }
        guard authorized(method: method, path: path, headers: headers, body: body) else {
            return (401, #"{"ok":false,"message":"Nicht gekoppelt"}"#)
        }
        switch (method, path) {
        case ("GET", "/status"):
            return (200, #"{"ok":true,"name":"\#(escape(Host.current().localizedName ?? "Mac"))"}"#)
        case ("GET", "/permissions"):
            return (200, store.permissionsJSON())
        case ("POST", "/permissions"):
            store.updatePermissions(body)
            return (200, store.permissionsJSON())
        case ("POST", "/grant"):
            store.applyGrant(body)
            return (200, store.permissionsJSON())
        case ("GET", "/log"):
            return (200, store.logJSON())
        case ("POST", "/unpair"):
            store.clearToken()
            store.revokeStanding()
            return (200, #"{"ok":true,"message":"Getrennt"}"#)
        case ("POST", "/action"):
            return action(body)
        default:
            return (404, #"{"ok":false,"message":"Unbekannt"}"#)
        }
    }

    private func action(_ body: Data) -> (status: Int, json: String) {
        let name = jsonString(body, key: "name") ?? ""
        let value = jsonString(body, key: "value") ?? ""
        guard store.allows(name) else {
            let message = "Diese Berechtigung ist auf dem Mac aus."
            store.appendLog(name: name, value: value, message: message)
            return (200, #"{"ok":false,"message":"\#(escape(message))"}"#)
        }
        let confirmed = jsonBool(body, key: "confirm")
        let clientSession = jsonBool(body, key: "session")
        let standing = store.mode() == "always" || (store.mode() == "session" && store.sessionActive && clientSession)
        if !standing && !confirmed {
            store.appendLog(name: name, value: value, message: "Bestätigung nötig")
            return (403, #"{"ok":false,"needConfirm":true,"message":"Bestätigung nötig"}"#)
        }
        let message = MacActions.run(name: name, value: value)
        store.appendLog(name: name, value: value, message: message)
        return (200, #"{"ok":true,"message":"\#(escape(message))"}"#)
    }

    private func authorized(method: String, path: String, headers: [String: String], body: Data) -> Bool {
        guard let token = store.token,
              let timestamp = headers["x-vela-timestamp"],
              let signature = headers["x-vela-signature"],
              let stamp = TimeInterval(timestamp),
              abs(Date().timeIntervalSince1970 - stamp) < 90 else { return false }
        let payload = Data("\(timestamp)\n\(method)\n\(path)\n".utf8) + body
        let key = SymmetricKey(data: Data(hex: token) ?? Data(token.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return constantTimeEquals(Data(mac).hex, signature.lowercased())
    }

    private func webSocket(_ connection: NWConnection, headers: [String: String], path: String) {
        guard path == "/ws", let key = headers["sec-websocket-key"] else {
            sendHTTP(connection, status: 400, json: #"{"ok":false}"#)
            return
        }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        let accept = Data(digest).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            let hello = #"{"ok":true,"socket":"vela"}"#
            self.sendFrame(connection, text: hello)
        })
    }

    private func sendFrame(_ connection: NWConnection, text: String) {
        let payload = Data(text.utf8)
        var frame = Data([0x81])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendHTTP(_ connection: NWConnection, status: Int, json: String) {
        let reason = status == 200 ? "OK" : status == 101 ? "Switching Protocols" : "Error"
        let body = Data(json.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

enum MacActions {
    static func run(name: String, value: String) -> String {
        switch name {
        case "openApp":
            guard let app = safeName(value) else { return "Ungültiger App-Name." }
            let code = shell("/usr/bin/open", ["-a", app]).0
            return code == 0 ? "\(app) ist geöffnet." : "\(app) ließ sich nicht öffnen."
        case "openURL":
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return "Nur http- und https-Adressen."
            }
            let code = shell("/usr/bin/open", [url.absoluteString]).0
            return code == 0 ? "Adresse geöffnet." : "Adresse ließ sich nicht öffnen."
        case "shortcut":
            guard let shortcut = safeName(value) else { return "Ungültiger Kurzbefehl." }
            let code = shell("/usr/bin/shortcuts", ["run", shortcut]).0
            return code == 0 ? "Kurzbefehl \(shortcut) ist gelaufen." : "Kurzbefehl nicht gefunden."
        case "applescript":
            guard let script = safeName(value) else { return "Ungültiger Skriptname." }
            let file = MacStore.scripts.appendingPathComponent(script + ".scpt")
            guard FileManager.default.fileExists(atPath: file.path) else { return "Skript \(script) liegt nicht im Skriptordner." }
            let code = shell("/usr/bin/osascript", [file.path]).0
            return code == 0 ? "Skript \(script) ist gelaufen." : "Skript ist fehlgeschlagen."
        case "type":
            let text = String(value.prefix(500))
            guard !text.isEmpty else { return "Nichts zu tippen." }
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let code = shell("/usr/bin/osascript", ["-e", "tell application \"System Events\" to keystroke \"\(escaped)\""]).0
            return code == 0 ? "Text ist getippt." : "Tippen braucht Bedienungshilfen."
        case "media":
            let command: String
            switch value {
            case "next": command = "next track"
            case "previous": command = "previous track"
            default: command = "playpause"
            }
            _ = shell("/usr/bin/osascript", ["-e", "tell application \"Music\" to \(command)"])
            return "Medienbefehl gesendet."
        case "volume":
            let command: String
            switch value {
            case "up": command = "set volume output volume ((output volume of (get volume settings)) + 8)"
            case "down": command = "set volume output volume ((output volume of (get volume settings)) - 8)"
            case "mute": command = "set volume with output muted"
            default: command = "set volume output volume 40"
            }
            _ = shell("/usr/bin/osascript", ["-e", command])
            return "Lautstärke geändert."
        case "screenshot":
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Vela-Screenshot.png")
            let code = shell("/usr/sbin/screencapture", ["-x", file.path]).0
            return code == 0 ? "Screenshot liegt auf dem Schreibtisch." : "Bildschirmaufnahme ist nicht erlaubt."
        case "clipboard":
            let output = shell("/usr/bin/pbpaste", []).1
            let clipped = String(output.prefix(2000))
            return clipped.isEmpty ? "Die Zwischenablage ist leer." : clipped
        case "apps":
            let output = shell("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get name of every process whose background only is false"]).1
            return output.isEmpty ? "Keine Apps gefunden." : output.replacingOccurrences(of: ", ", with: "\n")
        default:
            return "Unbekannte Aktion."
        }
    }

    private static func safeName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60,
              trimmed.range(of: #"^[A-Za-z0-9ÄÖÜäöüß ._\-]{1,60}$"#, options: .regularExpression) != nil else { return nil }
        return trimmed
    }

    @discardableResult
    private static func shell(_ launch: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return (1, "") }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

final class MacStore {
    static var root: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VelaMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static var scripts: URL {
        let url = root.appendingPathComponent("scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    var codeURL: URL { Self.root.appendingPathComponent("pairing-code.txt") }
    private var tokenURL: URL { Self.root.appendingPathComponent("token") }
    private var permissionsURL: URL { Self.root.appendingPathComponent("permissions.json") }
    private var logURL: URL { Self.root.appendingPathComponent("actions.json") }
    private var localKeyURL: URL { Self.root.appendingPathComponent("local.key") }
    private let keys = ["openApp", "openURL", "shortcut", "applescript", "type", "media", "volume", "screenshot", "clipboard", "apps"]
    private(set) var sessionActive = false

    var localSecret: String {
        if let existing = try? String(contentsOf: localKeyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let secret = UUID().uuidString
        try? secret.write(to: localKeyURL, atomically: true, encoding: .utf8)
        return secret
    }

    var needsConfirmation: Bool {
        switch mode() {
        case "always": return false
        case "session": return !sessionActive
        default: return true
        }
    }

    func ensureDefaults() {
        if !FileManager.default.fileExists(atPath: permissionsURL.path) {
            var initial: [String: Any] = ["mode": "ask"]
            for key in keys { initial[key] = ["openApp", "media", "volume", "apps"].contains(key) }
            writeConfig(initial)
        }
        _ = localSecret
        _ = Self.scripts
        if token == nil { _ = pairingCode() }
    }

    func pairingCode() -> String {
        if let existing = try? String(contentsOf: codeURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count == 6, token == nil {
            return existing
        }
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        try? code.write(to: codeURL, atomically: true, encoding: .utf8)
        return code
    }

    func consume(code: String) -> Bool {
        let current = (try? String(contentsOf: codeURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard current.count == 6, constantTimeEquals(current, code) else { return false }
        try? FileManager.default.removeItem(at: codeURL)
        return true
    }

    func issueToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }
        let token = Data(bytes).hex
        try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
        return token
    }

    var token: String? {
        let value = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    func clearToken() {
        try? FileManager.default.removeItem(at: tokenURL)
        try? FileManager.default.removeItem(at: codeURL)
        sessionActive = false
    }

    func allows(_ name: String) -> Bool {
        permissions()[name] == true
    }

    func mode() -> String {
        let raw = config()["mode"] as? String ?? "ask"
        return ["ask", "session", "always"].contains(raw) ? raw : "ask"
    }

    func applyGrant(_ body: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        var config = config()
        if let mode = object["mode"] as? String, ["ask", "session", "always"].contains(mode) {
            config["mode"] = mode
            if mode != "session" { sessionActive = false }
        }
        if let session = object["session"] as? Bool {
            sessionActive = session && (config["mode"] as? String) == "session"
        }
        if object["revoke"] as? Bool == true {
            revokeStanding()
            return
        }
        writeConfig(config)
    }

    func revokeStanding() {
        var config = config()
        config["mode"] = "ask"
        sessionActive = false
        writeConfig(config)
    }

    func permissionsJSON() -> String {
        let map = permissions()
        let parts = keys.map { "\"\($0)\":\(map[$0] == true ? "true" : "false")" }
        let session = sessionActive ? "true" : "false"
        return "{\"ok\":true,\"mode\":\"\(mode())\",\"session\":\(session)," + parts.joined(separator: ",") + "}"
    }

    func updatePermissions(_ body: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        var config = config()
        for key in keys {
            if let value = object[key] as? Bool { config[key] = value }
        }
        writeConfig(config)
    }

    func appendLog(name: String, value: String, message: String) {
        var entries = loadLog()
        let stamp = ISO8601DateFormatter().string(from: Date())
        entries.append(["time": stamp, "name": name, "value": String(value.prefix(80)), "message": String(message.prefix(240))])
        if entries.count > 100 { entries.removeFirst(entries.count - 100) }
        if let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted]) {
            try? data.write(to: logURL)
        }
    }

    func logJSON() -> String {
        let entries = loadLog()
        guard let data = try? JSONSerialization.data(withJSONObject: ["ok": true, "entries": entries]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":true,"entries":[]}"#
        }
        return text
    }

    func logText() -> String {
        loadLog().map { entry in
            let time = entry["time"] as? String ?? ""
            let name = entry["name"] as? String ?? ""
            let message = entry["message"] as? String ?? ""
            return "\(time)  \(name)  \(message)"
        }.joined(separator: "\n")
    }

    private func permissions() -> [String: Bool] {
        var map: [String: Bool] = [:]
        for (key, value) in config() {
            if let flag = value as? Bool { map[key] = flag }
        }
        return map
    }

    private func config() -> [String: Any] {
        guard let data = try? Data(contentsOf: permissionsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["mode": "ask"] }
        return object
    }

    private func writeConfig(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) {
            try? data.write(to: permissionsURL)
        }
    }

    private func loadLog() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: logURL),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries
    }
}

enum MacCLI {
    static func handle(_ arguments: [String]) -> Bool {
        let args = Array(arguments.dropFirst())
        guard args.contains("--grant") || args.contains("--revoke") || args.contains("--log")
                || args.contains("--allow") || args.contains("--deny") else { return false }
        let store = MacStore()
        store.ensureDefaults()
        if args.contains("--log") {
            print(store.logText())
            return true
        }
        if args.contains("--revoke") {
            store.revokeStanding()
            post(["revoke": true])
            print("Stehende Freigabe widerrufen. Es wird wieder jedes Mal gefragt.")
            return true
        }
        if let mode = value("--grant", args), ["ask", "session", "always"].contains(mode) {
            store.applyGrant(Data("{\"mode\":\"\(mode)\",\"session\":\(mode == "session" ? "true" : "false")}".utf8))
            post(["mode": mode, "session": mode == "session"])
            print("Modus: \(mode)")
            return true
        }
        if let name = value("--allow", args) ?? value("--deny", args) {
            let on = args.contains("--allow")
            guard let keys = groups[name] else {
                print("Unbekannt. Gruppen: \(groups.keys.sorted().joined(separator: ", "))")
                return true
            }
            var body: [String: Any] = [:]
            for key in keys { body[key] = on }
            store.updatePermissions(try! JSONSerialization.data(withJSONObject: body))
            print("\(name): \(on ? "an" : "aus")")
            return true
        }
        return false
    }

    static let groups = [
        "apps": ["openApp", "openURL", "apps"],
        "typing": ["type"],
        "scripts": ["shortcut", "applescript"],
        "media": ["media", "volume"],
        "screenshot": ["screenshot"],
        "clipboard": ["clipboard"]
    ]

    private static func value(_ flag: String, _ args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func post(_ object: [String: Any]) {
        let store = MacStore()
        guard let url = URL(string: "http://127.0.0.1:8742/local/grant"),
              let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(store.localSecret, forHTTPHeaderField: "X-Vela-Local")
        request.timeoutInterval = 1.5
        let wait = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in wait.signal() }.resume()
        _ = wait.wait(timeout: .now() + 2)
    }
}

enum MenuBar {
    private static var bridge = MenuBridge()

    static func install(store: MacStore) {
        bridge.store = store
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Vela"
        let menu = NSMenu()
        menu.addItem(menuEntry("Jedes Mal fragen", #selector(MenuBridge.ask)))
        menu.addItem(menuEntry("Für diese Sitzung erlauben", #selector(MenuBridge.session)))
        menu.addItem(menuEntry("Immer erlauben", #selector(MenuBridge.always)))
        menu.addItem(.separator())
        menu.addItem(menuEntry("Alles widerrufen", #selector(MenuBridge.revoke)))
        menu.addItem(menuEntry("Protokoll anzeigen", #selector(MenuBridge.showLog)))
        item.menu = menu
        bridge.item = item
    }

    private static func menuEntry(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = bridge
        return entry
    }
}

final class MenuBridge: NSObject {
    var store = MacStore()
    weak var item: NSStatusItem?

    @objc func ask() { store.applyGrant(Data(#"{"mode":"ask","session":false}"#.utf8)) }
    @objc func session() { store.applyGrant(Data(#"{"mode":"session","session":true}"#.utf8)) }
    @objc func always() { store.applyGrant(Data(#"{"mode":"always","session":false}"#.utf8)) }
    @objc func revoke() { store.revokeStanding() }
    @objc func showLog() {
        let alert = NSAlert()
        alert.messageText = "Vela · letzte Aktionen"
        alert.informativeText = store.logText().isEmpty ? "Noch nichts." : store.logText()
        alert.runModal()
    }
}

func jsonString(_ data: Data, key: String) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object[key] as? String
}

func jsonBool(_ data: Data, key: String) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return object[key] as? Bool ?? false
}

func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
}

func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    var diff = a.count ^ b.count
    for i in 0..<max(a.count, b.count) {
        let left = i < a.count ? Int(a[i]) : 0
        let right = i < b.count ? Int(b[i]) : 0
        diff |= left ^ right
    }
    return diff == 0
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        self = Data(bytes)
    }
}
