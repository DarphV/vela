//
//  MacLink.swift
//  Vela
//
//  Finds the Mac companion on the local network, pairs with the 6-digit code,
//  and signs later requests with the shared token.
//

import CryptoKit
import Foundation
import Network
import Security

struct MacPeer: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var host: String
    var port: Int
}

enum MacGrantMode: String {
    case ask, session, always
}

struct MacLogEntry: Identifiable, Hashable {
    let id = UUID()
    var time: String
    var name: String
    var message: String
}

struct MacAction: Identifiable {
    let id = UUID()
    var name: String
    var value: String
    var summary: String
    var risky: Bool
}

enum MacCapabilities {
    static let groups: [(key: String, title: String, names: [String])] = [
        ("apps", "Apps öffnen", ["openApp", "openURL", "apps"]),
        ("typing", "Tippen/Tastatur", ["type"]),
        ("scripts", "Skripte/Kurzbefehle", ["shortcut", "applescript"]),
        ("media", "Medien/Lautstärke", ["media", "volume"]),
        ("screenshot", "Screenshot", ["screenshot"]),
        ("clipboard", "Zwischenablage", ["clipboard"])
    ]
}

enum MacToolRouter {
    static func match(_ raw: String) -> MacAction? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        guard lower.contains("mac") || lower.contains("rechner") else { return nil }
        if let url = capture(text, #"(https?://\S+)"#) {
            return MacAction(name: "openURL", value: url, summary: "Adresse auf dem Mac öffnen", risky: true)
        }
        if lower.contains("kurzbefehl"), let name = capture(text, #"(?i)kurzbefehl\s+(.+?)(?:\s+auf dem (?:mac|rechner))?$"#) {
            return MacAction(name: "shortcut", value: name, summary: "Kurzbefehl „\(name)“ auf dem Mac", risky: true)
        }
        if lower.contains("skript"), let name = capture(text, #"(?i)skript\s+(.+?)(?:\s+auf dem (?:mac|rechner))?$"#) {
            return MacAction(name: "applescript", value: name, summary: "Skript „\(name)“ auf dem Mac", risky: true)
        }
        if lower.contains("tippe") || lower.contains("schreib"), let typed = capture(text, #"(?i)(?:tippe|schreibe?)\s+(?:auf dem (?:mac|rechner)\s+)?[„"']?(.+?)[“"']?$"#) {
            return MacAction(name: "type", value: typed, summary: "Text auf dem Mac tippen", risky: true)
        }
        if lower.contains("screenshot") || lower.contains("bildschirmfoto") {
            return MacAction(name: "screenshot", value: "", summary: "Screenshot vom Mac", risky: true)
        }
        if lower.contains("zwischenablage") || lower.contains("clipboard") {
            return MacAction(name: "clipboard", value: "", summary: "Zwischenablage vom Mac lesen", risky: true)
        }
        if lower.contains("welche apps") || lower.contains("was läuft") || lower.contains("laufende") {
            return MacAction(name: "apps", value: "", summary: "Laufende Apps auf dem Mac", risky: false)
        }
        if lower.contains("lauter") { return MacAction(name: "volume", value: "up", summary: "Mac lauter", risky: false) }
        if lower.contains("leiser") { return MacAction(name: "volume", value: "down", summary: "Mac leiser", risky: false) }
        if lower.contains("stumm") { return MacAction(name: "volume", value: "mute", summary: "Mac stumm", risky: false) }
        if lower.contains("nächster") { return MacAction(name: "media", value: "next", summary: "Nächster Titel auf dem Mac", risky: false) }
        if lower.contains("vorheriger") { return MacAction(name: "media", value: "previous", summary: "Vorheriger Titel auf dem Mac", risky: false) }
        if lower.contains("pause") || lower.contains("wiedergabe") || lower.contains("play") {
            return MacAction(name: "media", value: "toggle", summary: "Wiedergabe auf dem Mac", risky: false)
        }
        if let app = capture(text, #"(?i)(?:öffne|starte)\s+(?:die\s+|den\s+|das\s+)?(.+?)\s+auf dem (?:mac|rechner)"#) {
            return MacAction(name: "openApp", value: app, summary: "\(app) auf dem Mac öffnen", risky: false)
        }
        return nil
    }

    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let hit = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[hit]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class MacConnection: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var peers: [MacPeer] = []
    @Published private(set) var status = "Nicht verbunden"
    @Published var pairedName: String = UserDefaults.standard.string(forKey: "vela.mac.name") ?? ""
    @Published var permissions: [String: Bool] = [:]
    @Published var mode: MacGrantMode = .ask
    @Published var sessionActive = false
    @Published var log: [MacLogEntry] = []

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private var host = UserDefaults.standard.string(forKey: "vela.mac.host") ?? ""
    private var port = UserDefaults.standard.integer(forKey: "vela.mac.port")

    var isPaired: Bool { TokenBox.load() != nil && !host.isEmpty && port > 0 }

    override init() {
        super.init()
        browser.delegate = self
        if isPaired {
            status = "Gekoppelt mit \(pairedName.isEmpty ? host : pairedName)"
            Task { await refreshPermissions() }
        }
    }

    func startSearch() {
        peers = []
        status = "Suche im lokalen Netz …"
        browser.stop()
        browser.searchForServices(ofType: "_vela._tcp.", inDomain: "local.")
    }

    func pair(with peer: MacPeer, code: String) async -> String {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["code": code])
            let data = try await send(peer: peer, method: "POST", path: "/pair", body: body, signed: false)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let token = object?["token"] as? String else { return "Kopplung abgelehnt." }
            TokenBox.save(token)
            await MainActor.run {
                self.host = peer.host
                self.port = peer.port
                self.pairedName = peer.name
                self.status = "Gekoppelt mit \(peer.name)"
            }
            UserDefaults.standard.set(peer.host, forKey: "vela.mac.host")
            UserDefaults.standard.set(peer.port, forKey: "vela.mac.port")
            UserDefaults.standard.set(peer.name, forKey: "vela.mac.name")
            await refreshPermissions()
            await refreshLog()
            return "Gekoppelt mit \(peer.name)."
        } catch {
            return "Kopplung fehlgeschlagen."
        }
    }

    func unpair() async {
        if isPaired { _ = try? await signed(method: "POST", path: "/unpair", body: Data("{}".utf8)) }
        TokenBox.delete()
        UserDefaults.standard.removeObject(forKey: "vela.mac.host")
        UserDefaults.standard.removeObject(forKey: "vela.mac.port")
        UserDefaults.standard.removeObject(forKey: "vela.mac.name")
        await MainActor.run {
            self.host = ""
            self.port = 0
            self.pairedName = ""
            self.permissions = [:]
            self.mode = .ask
            self.sessionActive = false
            self.log = []
            self.status = "Nicht verbunden"
        }
    }

    func isOn(_ name: String) -> Bool { permissions[name] == true }

    /// Standing permission skips the iPhone prompt. The Mac still checks the same mode.
    func needsConfirmation(_ name: String) -> Bool {
        guard isOn(name) else { return false }
        switch mode {
        case .always: return false
        case .session: return !sessionActive
        case .ask: return true
        }
    }

    func perform(_ action: MacAction, confirm: Bool) async -> String {
        guard isPaired else { return "Zuerst den Mac unter Einstellungen koppeln." }
        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "name": action.name, "value": action.value, "confirm": confirm, "session": sessionActive
            ])
            let (data, status) = try await signedStatus(method: "POST", path: "/action", body: body)
            if status == 403 {
                sessionActive = false
                return "CONFIRM"
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            await refreshLog()
            return object?["message"] as? String ?? "Erledigt."
        } catch {
            sessionActive = false
            return "Der Mac antwortet nicht."
        }
    }

    func setMode(_ next: MacGrantMode) async {
        mode = next
        sessionActive = next == .session
        let body = try? JSONSerialization.data(withJSONObject: ["mode": next.rawValue, "session": next == .session])
        if let body, isPaired { _ = try? await signedStatus(method: "POST", path: "/grant", body: body) }
        if next != .session { sessionActive = false }
        if next == .session { sessionActive = true }
    }

    func revokeAll() async {
        mode = .ask
        sessionActive = false
        if isPaired { _ = try? await signedStatus(method: "POST", path: "/grant", body: Data(#"{"revoke":true}"#.utf8)) }
    }

    func refreshLog() async {
        guard isPaired, let (data, _) = try? await signedStatus(method: "GET", path: "/log", body: Data()),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["entries"] as? [[String: Any]] else { return }
        let parsed = entries.suffix(100).map { entry in
            MacLogEntry(time: entry["time"] as? String ?? "", name: entry["name"] as? String ?? "", message: entry["message"] as? String ?? "")
        }
        await MainActor.run { self.log = parsed.reversed() }
    }

    func setGroup(_ key: String, _ value: Bool) async {
        guard let group = MacCapabilities.groups.first(where: { $0.key == key }) else { return }
        for name in group.names { permissions[name] = value }
        guard isPaired else { return }
        var body: [String: Any] = [:]
        for name in group.names { body[name] = value }
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            _ = try? await signedStatus(method: "POST", path: "/permissions", body: data)
        }
    }

    func groupOn(_ key: String) -> Bool {
        guard let group = MacCapabilities.groups.first(where: { $0.key == key }) else { return false }
        return group.names.allSatisfy { permissions[$0] == true }
    }

    func setPermission(_ key: String, _ value: Bool) async {
        permissions[key] = value
        guard isPaired else { return }
        var body = permissions
        body[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            _ = try? await signed(method: "POST", path: "/permissions", body: data)
        }
    }

    func refreshPermissions() async {
        guard isPaired, let data = try? await signed(method: "GET", path: "/permissions", body: Data()) else { return }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var flags: [String: Bool] = [:]
            for (key, value) in object {
                if let flag = value as? Bool { flags[key] = flag }
            }
            let parsedMode = MacGrantMode(rawValue: object["mode"] as? String ?? "ask") ?? .ask
            let snapshot = flags
            await MainActor.run {
                self.permissions = snapshot
                self.mode = parsedMode
            }
        }
    }

    private func signed(method: String, path: String, body: Data) async throws -> Data {
        let (data, _) = try await signedStatus(method: method, path: path, body: body)
        return data
    }

    private func signedStatus(method: String, path: String, body: Data) async throws -> (Data, Int) {
        guard let token = TokenBox.load() else { throw URLError(.userAuthenticationRequired) }
        return try await send(host: host, port: port, method: method, path: path, body: body, token: token)
    }

    private func send(peer: MacPeer, method: String, path: String, body: Data, signed: Bool) async throws -> Data {
        let (data, status) = try await send(host: peer.host, port: peer.port, method: method, path: path, body: body, token: signed ? TokenBox.load() : nil)
        guard (200...299).contains(status) else { throw URLError(.badServerResponse) }
        return data
    }

    private func send(host: String, port: Int, method: String, path: String, body: Data, token: String?) async throws -> (Data, Int) {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        request.timeoutInterval = 8
        if let token {
            let stamp = String(Int(Date().timeIntervalSince1970))
            var payload = Data("\(stamp)\n\(method)\n\(path)\n".utf8)
            payload.append(body)
            let key = SymmetricKey(data: Data(hex: token) ?? Data(token.utf8))
            let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
            request.setValue(stamp, forHTTPHeaderField: "X-Vela-Timestamp")
            request.setValue(Data(mac).hex, forHTTPHeaderField: "X-Vela-Signature")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http.statusCode)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? ""
        guard !host.isEmpty, sender.port > 0 else { return }
        let peer = MacPeer(name: sender.name, host: host, port: sender.port)
        DispatchQueue.main.async {
            if !self.peers.contains(peer) { self.peers.append(peer) }
            self.status = self.peers.isEmpty ? "Kein Mac gefunden" : "\(self.peers.count) Mac gefunden"
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        DispatchQueue.main.async { self.status = "Suche nicht möglich" }
    }
}

private enum TokenBox {
    private static let account = "vela.mac.token"

    static func save(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8)
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count.isMultiple(of: 2) else { return nil }
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
