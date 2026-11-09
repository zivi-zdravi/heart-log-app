import CryptoKit
import Foundation

enum BackupError: LocalizedError {
    case notABackup, corrupt, unexpectedFile, readFailed

    var errorDescription: String? {
        switch self {
        case .notABackup: return "That file is not a Heart Log backup."
        case .corrupt: return "That backup is damaged, so nothing was changed."
        case .unexpectedFile: return "That backup contains an unexpected file, so nothing was changed."
        case .readFailed: return "A file could not be read."
        }
    }
}

struct RestoreResult: Equatable {
    var added = 0
    var updated = 0
    var kept = 0
}

/// One portable file holding every recording. It has a SHA-256 checksum so damage is
/// detected before anything is written. Restoring only adds or extends data.
enum BackupArchive {
    struct Entry { let name: String; let size: UInt64; let offset: UInt64 }

    private static let magic = Data("HLBK1\n".utf8)
    private static let footer = Data("HLEND\n".utf8)
    private static let chunk = 256 * 1024
    private static let tailLength = UInt64(footer.count + SHA256.byteCount)

    static func isAllowed(_ name: String) -> Bool {
        if name == "profile.txt" { return true }
        for suffix in [".samples.csv", ".events.csv"] where name.hasSuffix(suffix) {
            let stem = name.dropLast(suffix.count)
            return stem.first == "s" && stem.count > 1 && stem.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
        }
        return false
    }

    private static func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func number<T: FixedWidthInteger>(_ data: Data, as: T.Type) -> T {
        var result: T = 0
        for (i, byte) in data.enumerated() { result |= T(byte) << (8 * i) }
        return result
    }

    @discardableResult
    static func create(from dir: URL, to out: URL) throws -> Int {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: dir.path).filter(isAllowed).sorted()
        guard fm.createFile(atPath: out.path, contents: nil,
                            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw BackupError.readFailed
        }
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        var hash = SHA256()
        func put(_ data: Data) throws {
            hash.update(data: data)
            try handle.write(contentsOf: data)
        }
        try put(magic)
        for name in names {
            let url = dir.appendingPathComponent(name)
            // Taken once, so a file still being appended to is stored consistently.
            let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            let nameData = Data(name.utf8)
            try put(bytes(UInt32(nameData.count)))
            try put(nameData)
            try put(bytes(size))
            let source = try FileHandle(forReadingFrom: url)
            defer { try? source.close() }
            var left = size
            while left > 0 {
                let want = Int(min(UInt64(chunk), left))
                guard let data = try source.read(upToCount: want), data.count == want else { throw BackupError.readFailed }
                try put(data)
                left -= UInt64(want)
            }
        }
        try handle.write(contentsOf: footer)
        try handle.write(contentsOf: Data(hash.finalize()))
        return names.count
    }

    /// Reads the whole file and returns its contents only if the checksum matches.
    static func verify(_ url: URL) throws -> [Entry] {
        let fm = FileManager.default
        let total = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard total >= UInt64(magic.count) + tailLength else { throw BackupError.notABackup }
        let bodyEnd = total - tailLength
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var offset: UInt64 = 0

        func take(_ count: Int) throws -> Data {
            guard offset + UInt64(count) <= bodyEnd,
                  let data = try handle.read(upToCount: count), data.count == count else { throw BackupError.corrupt }
            hash.update(data: data)
            offset += UInt64(count)
            return data
        }

        let head = try take(magic.count)
        guard head == magic else { throw BackupError.notABackup }
        var entries: [Entry] = []
        while offset < bodyEnd {
            let nameLength = number(try take(4), as: UInt32.self)
            guard nameLength > 0, nameLength <= 128 else { throw BackupError.corrupt }
            guard let name = String(data: try take(Int(nameLength)), encoding: .utf8) else { throw BackupError.corrupt }
            let size = number(try take(8), as: UInt64.self)
            guard size <= bodyEnd - offset else { throw BackupError.corrupt }
            let start = offset
            var left = size
            while left > 0 {
                let want = Int(min(UInt64(chunk), left))
                _ = try take(want)
                left -= UInt64(want)
            }
            entries.append(Entry(name: name, size: size, offset: start))
        }
        guard let tail = try handle.read(upToCount: Int(tailLength)), tail.count == Int(tailLength),
              tail.prefix(footer.count) == footer,
              Data(tail.suffix(SHA256.byteCount)) == Data(hash.finalize()) else { throw BackupError.corrupt }
        // Checked after the checksum, so a damaged name reports as damage.
        guard entries.allSatisfy({ isAllowed($0.name) }) else { throw BackupError.unexpectedFile }
        return entries
    }

    /// Recording files only grow, so a larger copy always contains the smaller one.
    /// Existing data is never shortened, and files in `skipping` are left alone.
    @discardableResult
    static func restore(_ url: URL, into dir: URL, skipping: Set<String> = []) throws -> RestoreResult {
        let entries = try verify(url)
        let fm = FileManager.default
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        var result = RestoreResult()
        for entry in entries {
            let dest = dir.appendingPathComponent(entry.name)
            let exists = fm.fileExists(atPath: dest.path)
            let localSize = exists ? ((try fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.uint64Value ?? 0) : 0
            if skipping.contains(entry.name) || (exists && localSize >= entry.size) {
                result.kept += 1
                continue
            }
            let temp = dir.appendingPathComponent(".restore-\(UUID().uuidString)")
            guard fm.createFile(atPath: temp.path, contents: nil,
                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                throw BackupError.readFailed
            }
            do {
                let out = try FileHandle(forWritingTo: temp)
                defer { try? out.close() }
                try source.seek(toOffset: entry.offset)
                var left = entry.size
                while left > 0 {
                    let want = Int(min(UInt64(chunk), left))
                    guard let data = try source.read(upToCount: want), data.count == want else { throw BackupError.corrupt }
                    try out.write(contentsOf: data)
                    left -= UInt64(want)
                }
                if exists {
                    _ = try fm.replaceItemAt(dest, withItemAt: temp)
                    result.updated += 1
                } else {
                    try fm.moveItem(at: temp, to: dest)
                    result.added += 1
                }
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
        }
        return result
    }
}
