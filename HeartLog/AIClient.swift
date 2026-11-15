import Foundation
import UIKit

/// Small keychain wrapper for secrets that must never be in backups or files.
enum Keychain {
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    static func set(_ account: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Saved switches for Settings > AI (ai.json, backed up). The server address
/// and pass code are in the keychain.
final class AIStore: ObservableObject {
    static let shared = AIStore()
    static let fileName = "ai.json"
    @Published var settings: AISettings { didSet { JSONFile.write(settings, to: Self.url) } }
    @Published var server: String { didSet { Keychain.set("ai-server", server) } }
    @Published var passcode: String { didSet { Keychain.set("ai-passcode", passcode) } }

    private static var url: URL { Store.shared.dir.appendingPathComponent(fileName) }

    private init() {
        settings = (try? JSONDecoder().decode(AISettings.self, from: Data(contentsOf: Self.url))) ?? AISettings()
        server = Keychain.get("ai-server") ?? ""
        passcode = Keychain.get("ai-passcode") ?? ""
    }

    func reload() {
        settings = (try? JSONDecoder().decode(AISettings.self, from: Data(contentsOf: Self.url))) ?? AISettings()
    }

    var isSetUp: Bool { AIClient.baseURL != nil && !passcode.isEmpty }
}

/// Talks to the family's AI server (over Tailscale). Only the meal text,
/// photo or question and the summaries it needs are sent.
enum AIClient {
    enum Failure: LocalizedError {
        case notSetUp, unreachable, passcode, limit, noKey, busy, server(String)
        var errorDescription: String? {
            switch self {
            case .notSetUp: return "AI isn't set up yet. Add your home server in Settings, AI."
            case .unreachable: return "Can't reach your home server. Is Tailscale on?"
            case .passcode: return "The server didn't accept this phone's pass code. Check it in Settings, AI."
            case .limit: return "This month's AI limit has been reached. It can be raised in Settings, AI."
            case .noKey: return "The home server doesn't have its Claude key yet."
            case .busy: return "Claude is busy right now. Try again in a minute."
            case .server(let m): return m
            }
        }
    }

    struct Status: Decodable {
        struct Mine: Decodable { var requests: Int; var costUsd: Double }
        var person: String
        var admin: Bool
        var month: String
        var requests: Int
        var costUsd: Double
        var limitUsd: Double
        var mine: Mine
        var keySet: Bool
    }

    static var baseURL: URL? {
        var s = AIStore.shared.server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 90
        return URLSession(configuration: c)
    }()

    private static func call<T: Decodable>(_ path: String, body: [String: Any]? = nil, as: T.Type) async throws -> T {
        guard let base = baseURL, !AIStore.shared.passcode.isEmpty else { throw Failure.notSetUp }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = body == nil ? "GET" : "POST"
        req.setValue("Bearer \(AIStore.shared.passcode)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch { throw Failure.unreachable }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        switch code {
        case 200..<300: break
        case 401: throw Failure.passcode
        case 429: throw Failure.limit
        case 503: throw message?.contains("key") == true ? Failure.noKey : Failure.busy
        default: throw Failure.server(message ?? "The home server had a problem (\(code)).")
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw Failure.server("The home server sent something unexpected.") }
    }

    static func status() async throws -> Status { try await call("v1/status", as: Status.self) }

    static func setLimit(_ usd: Double) async throws {
        struct R: Decodable { var limitUsd: Double }
        _ = try await call("v1/limit", body: ["limitUsd": usd], as: R.self)
    }

    static func meal(text: String? = nil, photo: UIImage? = nil, note: String? = nil) async throws -> AIMealResult {
        var body: [String: Any] = ["avoid": MealStore.shared.settings.avoid]
        if let text { body["text"] = text }
        if let note, !note.isEmpty { body["note"] = note }
        if let photo, let jpeg = shrink(photo).jpegData(compressionQuality: 0.7) {
            body["image"] = jpeg.base64EncodedString()
            body["mediaType"] = "image/jpeg"
        }
        return try await call("v1/meal", body: body, as: AIMealResult.self)
    }

    static func ask(question: String, context: [String: Any], history: [(role: String, text: String)]) async throws -> String {
        struct R: Decodable { var answer: String }
        let h = history.map { ["role": $0.role, "text": $0.text] }
        return try await call("v1/ask", body: ["question": question, "context": context, "history": h], as: R.self).answer
    }

    /// Longest side 1280 px: plenty to read a plate, small to send.
    static func shrink(_ image: UIImage) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > 1280 else { return image }
        let s = 1280 / side
        let size = CGSize(width: image.size.width * s, height: image.size.height * s)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
