import Compression
import Foundation

enum ZipError: LocalizedError {
    case notZip, unsupported, damaged

    var errorDescription: String? {
        switch self {
        case .notZip: return "That file is not a zip file."
        case .unsupported: return "That zip file uses a format Zdravlje can't read."
        case .damaged: return "That zip file is damaged."
        }
    }
}

/// Reads the files inside a standard zip archive, such as WHOOP's data export.
enum ZipReader {
    private static func u16(_ d: Data, _ i: Int) throws -> Int {
        guard i >= 0, i + 2 <= d.count else { throw ZipError.damaged }
        return Int(d[d.startIndex + i]) | Int(d[d.startIndex + i + 1]) << 8
    }

    private static func u32(_ d: Data, _ i: Int) throws -> Int {
        let lo = try u16(d, i)
        let hi = try u16(d, i + 2)
        return lo | hi << 16
    }

    /// File name (inside the archive) to contents. Folders are skipped.
    static func entries(_ data: Data, maxFileSize: Int = 100_000_000) throws -> [String: Data] {
        guard data.count >= 22 else { throw ZipError.notZip }
        var eocd = -1
        var i = data.count - 22
        while i >= max(0, data.count - 65_557) {
            if try u32(data, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = try u16(data, eocd + 10)
        var p = try u32(data, eocd + 16)
        guard count != 0xFFFF, p != 0xFFFF_FFFF else { throw ZipError.unsupported }
        var out: [String: Data] = [:]
        for _ in 0..<count {
            guard try u32(data, p) == 0x0201_4B50 else { throw ZipError.damaged }
            let method = try u16(data, p + 10)
            let compSize = try u32(data, p + 20)
            let size = try u32(data, p + 24)
            let nameLen = try u16(data, p + 28)
            let extraLen = try u16(data, p + 30)
            let commentLen = try u16(data, p + 32)
            let local = try u32(data, p + 42)
            guard p + 46 + nameLen <= data.count else { throw ZipError.damaged }
            let name = String(decoding: data.subdata(in: data.startIndex + p + 46..<data.startIndex + p + 46 + nameLen), as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            if name.hasSuffix("/") { continue }
            guard size <= maxFileSize, compSize != 0xFFFF_FFFF else { throw ZipError.unsupported }
            guard try u32(data, local) == 0x0403_4B50 else { throw ZipError.damaged }
            let localName = try u16(data, local + 26)
            let localExtra = try u16(data, local + 28)
            let start = local + 30 + localName + localExtra
            guard start + compSize <= data.count else { throw ZipError.damaged }
            let raw = data.subdata(in: data.startIndex + start..<data.startIndex + start + compSize)
            switch method {
            case 0:
                out[name] = raw
            case 8:
                if size == 0 { out[name] = Data(); continue }
                var result = Data(count: size)
                let written = result.withUnsafeMutableBytes { dst in
                    raw.withUnsafeBytes { src in
                        compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                                  src.bindMemory(to: UInt8.self).baseAddress!, compSize, nil, COMPRESSION_ZLIB)
                    }
                }
                guard written == size else { throw ZipError.damaged }
                out[name] = result
            default:
                throw ZipError.unsupported
            }
        }
        return out
    }
}

enum CSV {
    /// Splits CSV text into rows, handling quoted fields.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text.unicodeScalars)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(field)
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
                field = ""
            } else {
                field.unicodeScalars.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    static func table(_ data: Data) -> [[String: String]] {
        let all = rows(String(decoding: data, as: UTF8.self))
        guard let header = all.first else { return [] }
        return all.dropFirst().map { r in
            var d: [String: String] = [:]
            for (i, h) in header.enumerated() where i < r.count { d[h] = r[i] }
            return d
        }
    }
}
