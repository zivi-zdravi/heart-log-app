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
        let rrs = rr.map { "\($0)" }.joined(separator: ";")
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

    /// All readings between two times, across recordings, oldest first. Safe off the main thread.
    func readSamples(from: Int64, to: Int64) -> [Sample] {
        var out: [Sample] = []
        for id in sessions() {
            guard let start = Int64(id.dropFirst()), start <= to else { continue }
            let url = samplesURL(id)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                .map { Int64($0.timeIntervalSince1970 * 1000) } ?? Int64.max
            guard modified >= from, let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in raw.split(separator: "\n") {
                let p = line.split(separator: ",", omittingEmptySubsequences: false)
                guard p.count >= 5, let t = Int64(p[0]), t >= from, t < to, let hr = Int(p[1]) else { continue }
                out.append(Sample(t: t, hr: hr, rr: p[4].split(separator: ";").compactMap { Int($0) }))
            }
        }
        out.sort { $0.t < $1.t }
        return out
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
