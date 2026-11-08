import Foundation

/// Append-only local files. Nothing here ever leaves the phone unless the user shares it.
final class Store {
    static let shared = Store()
    let dir: URL
    private var sampleBuffer: [String] = []
    private var eventBuffer: [String] = []
    private(set) var writeErrors = 0

    private init() {
        dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func samplesURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).samples.csv") }
    func eventsURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).events.csv") }

    func sessions() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".events.csv") }
            .map { String($0.dropLast(".events.csv".count)) }
            .sorted(by: >)
    }

    func addSample(_ session: String, ms: Int64, hr: Int, flags: UInt8, len: Int, rr: [Int]) {
        let rrs = rr.map(String.init).joined(separator: ";")
        sampleBuffer.append("\(ms),\(hr),\(flags),\(len),\(rrs)")
        if sampleBuffer.count >= 20 { flush(session) }
    }

    func addEvent(_ session: String, _ type: String, _ detail: String = "") {
        let clean = detail.replacingOccurrences(of: "\n", with: " ")
        eventBuffer.append("\(Self.nowMs()),\(type),\(clean)")
        flush(session)
    }

    func flush(_ session: String) {
        if append(sampleBuffer, to: samplesURL(session)) { sampleBuffer.removeAll() }
        if append(eventBuffer, to: eventsURL(session)) { eventBuffer.removeAll() }
    }

    private func append(_ lines: [String], to url: URL) -> Bool {
        guard !lines.isEmpty else { return true }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                // Must stay writable while the phone is locked, so not .complete.
                _ = FileManager.default.createFile(atPath: url.path, contents: nil,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
            return true
        } catch {
            writeErrors += 1
            return false
        }
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
