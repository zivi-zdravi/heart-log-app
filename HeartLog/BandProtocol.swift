// BandProtocol.swift — the WHOOP band's private-channel wire format.
//
// Pure framing layer: CRCs, frame envelope, reassembly, command building.
// No Bluetooth I/O lives here; Recorder stays the owner of the connection.
//
// Ported from the OpenStrap project's protocol package
// (github.com/OpenStrap/protocol, revision fbadb5b) under AGPL-3.0 — see the
// NOTICE file. Byte-verified against independently computed golden vectors
// in BandProtocolTests.
//
// Vocabulary: gen4 = WHOOP 4.0 (GATT base 6108…), gen5 = WHOOP 5.0 / MG
// (GATT base fd4b…). The MG band is gen5. The inner payload format is shared
// across generations; only the header envelope differs.
//
// Frame layout:
//   gen4: [0xAA][u16 LE declared][crc8 of the 2 length bytes]
//   gen5: [0xAA][rev 0x01][u16 LE declared][dir 2B][crc16-modbus of bytes 0..5, LE]
//   then: [inner, zero-padded to a 4-byte boundary][u32 LE crc32 of padded inner]
//   declared = padded inner length + 4 (counts the trailing CRC32).
//
// gen5 direction bytes: host→strap commands carry [0x00, 0x01]; every
// strap→host frame carries [0x01, 0x00]. They are a direction marker, not a
// validity gate — inbound parsing must NOT reject on them.

import Foundation

// MARK: - Generation

enum BandGeneration {
    case gen4
    case gen5

    var headerLength: Int { self == .gen5 ? 8 : 4 }

    /// GATT UUIDs. Same low-nibble map on both generations:
    /// x0001 service, x0002 command write, x0003 command responses (notify),
    /// x0004 events (notify), x0005 data/history (notify), x0007 crash logs.
    var gattBase: String { self == .gen5 ? "fd4b" : "6108" }
    var serviceUUID: String { uuid(1) }
    var commandWriteUUID: String { uuid(2) }
    var commandNotifyUUID: String { uuid(3) }
    var eventsUUID: String { uuid(4) }
    var dataUUID: String { uuid(5) }
    var memfaultUUID: String { uuid(7) }

    private func uuid(_ low: Int) -> String {
        let suffix = self == .gen5 ? "cce1-4033-93ce-002d5875f58a" : "8d6d-82b8-614a-1c8cb0f8dcc6"
        let lowHex = String(low, radix: 16)
        return gattBase + String(repeating: "0", count: max(0, 4 - lowHex.count)) + lowHex + "-" + suffix
    }

    /// Identify the generation from an advertised service UUID, if it is a band.
    static func fromServiceUUID(_ s: String) -> BandGeneration? {
        let lower = s.lowercased()
        if lower.hasPrefix("fd4b") { return .gen5 }
        if lower.hasPrefix("6108") { return .gen4 }
        return nil
    }
}

// MARK: - CRCs

enum BandCRC {
    /// CRC-8, poly 0x07, init 0 (gen4 header check, over the 2 length bytes).
    static func crc8(_ data: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for b in data {
            crc ^= b
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }

    /// CRC-16/MODBUS: init 0xFFFF, reflected poly 0xA001, no final XOR
    /// (gen5 header check, over header bytes 0..5, stored LE at 6..7).
    static func crc16Modbus(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in data {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    private static let crc32Table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    /// Standard zlib/IEEE CRC-32 (payload trailer on both generations).
    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc = crc32Table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Frame

/// One parsed frame. `inner` is the padded inner content:
/// inner[0] packet type, inner[1] sequence, inner[2] opcode, body after.
struct BandFrame {
    let inner: [UInt8]
    let headerCRCOK: Bool
    let payloadCRCOK: Bool
    /// gen5 frames carry a revision byte; this decoder reads rev-1 layouts.
    /// A frame can pass both CRCs at another revision — its field offsets
    /// would be wrong, so treat it as intact-but-unreadable, never drop it.
    let revisionOK: Bool

    /// Both CRCs passed: the bytes arrived intact.
    var valid: Bool { headerCRCOK && payloadCRCOK }
    /// Intact AND a revision this decoder can read field offsets for.
    var decodable: Bool { valid && revisionOK }

    var packetType: UInt8 { inner.count > 0 ? inner[0] : 0 }
    var sequence: UInt8 { inner.count > 1 ? inner[1] : 0 }
    var opcode: UInt8 { inner.count > 2 ? inner[2] : 0 }
    var body: [UInt8] { inner.count > 3 ? Array(inner[3...]) : [] }
}

/// Packet type byte (inner[0]).
enum BandPacketType {
    static let command: UInt8 = 0x23
    static let commandResponse: UInt8 = 0x24
    static let realtimeData: UInt8 = 0x28
    static let realtimeRawData: UInt8 = 0x2B
    static let historicalData: UInt8 = 0x2F
    static let event: UInt8 = 0x30
    static let metadata: UInt8 = 0x31
    static let consoleLogs: UInt8 = 0x32
}

// MARK: - Framing

enum BandFraming {
    /// Zero-pad to a 4-byte boundary. The CRC32 covers the padded form.
    static func pad4(_ data: [UInt8]) -> [UInt8] {
        let pad = (4 - data.count % 4) % 4
        return pad == 0 ? data : data + [UInt8](repeating: 0, count: pad)
    }

    static func buildHeader(declared: Int, generation: BandGeneration) -> [UInt8] {
        if generation == .gen4 {
            var h: [UInt8] = [0xAA, UInt8(declared & 0xFF), UInt8((declared >> 8) & 0xFF), 0]
            h[3] = BandCRC.crc8([h[1], h[2]])
            return h
        }
        // Outbound command direction marker [0x00, 0x01] — this builder only
        // ever makes host→strap frames.
        var h: [UInt8] = [0xAA, 0x01, UInt8(declared & 0xFF), UInt8((declared >> 8) & 0xFF), 0x00, 0x01, 0, 0]
        let c = BandCRC.crc16Modbus(Array(h[0..<6]))
        h[6] = UInt8(c & 0xFF)
        h[7] = UInt8(c >> 8)
        return h
    }

    /// Wrap inner content in a complete wire frame.
    static func buildFrame(inner: [UInt8], generation: BandGeneration) -> [UInt8] {
        let padded = pad4(inner)
        let declared = padded.count + 4
        var out = buildHeader(declared: declared, generation: generation)
        out += padded
        let c32 = BandCRC.crc32(padded)
        out += [UInt8(c32 & 0xFF), UInt8((c32 >> 8) & 0xFF), UInt8((c32 >> 16) & 0xFF), UInt8((c32 >> 24) & 0xFF)]
        return out
    }

    static func declaredLength(_ raw: [UInt8], generation: BandGeneration) -> Int? {
        let off = generation == .gen5 ? 2 : 1
        guard raw.count >= off + 2 else { return nil }
        return Int(raw[off]) | (Int(raw[off + 1]) << 8)
    }

    static func headerCRCValid(_ raw: [UInt8], generation: BandGeneration) -> Bool {
        if generation == .gen4 {
            guard raw.count >= 4 else { return false }
            return raw[3] == BandCRC.crc8([raw[1], raw[2]])
        }
        guard raw.count >= 8 else { return false }
        let want = UInt16(raw[6]) | (UInt16(raw[7]) << 8)
        return BandCRC.crc16Modbus(Array(raw[0..<6])) == want
    }

    /// Parse one complete frame. Returns nil when too short or not a frame at
    /// all (bad SOF / impossible length); returns a BandFrame with failed CRC
    /// flags when the bytes are frame-shaped but corrupt.
    static func parseFrame(_ raw: [UInt8], generation: BandGeneration) -> BandFrame? {
        let headerLen = generation.headerLength
        guard raw.count >= headerLen + 4, raw[0] == 0xAA else { return nil }
        guard let declared = declaredLength(raw, generation: generation), declared >= 4 else { return nil }
        guard raw.count >= headerLen + declared else { return nil }
        let headerOK = headerCRCValid(raw, generation: generation)
        let inner = Array(raw[headerLen..<(headerLen + declared - 4)])
        let s = headerLen + declared - 4
        let stored = UInt32(raw[s]) | (UInt32(raw[s + 1]) << 8) | (UInt32(raw[s + 2]) << 16) | (UInt32(raw[s + 3]) << 24)
        let payloadOK = stored == BandCRC.crc32(inner)
        let revOK = generation == .gen4 || raw[1] == 0x01
        return BandFrame(inner: inner, headerCRCOK: headerOK, payloadCRCOK: payloadOK, revisionOK: revOK)
    }
}

// MARK: - Reassembler

/// Length-based frame reassembler. BLE notifications split frames at arbitrary
/// boundaries, and payloads legitimately contain 0xAA, so reassembly goes by
/// the declared length, never by scanning for the start byte alone.
/// One instance per BLE session (a session speaks one generation).
final class BandFrameReassembler {
    private var buffer: [UInt8] = []
    let generation: BandGeneration
    /// Bytes dropped while hunting for a plausible frame start.
    private(set) var resyncedBytes = 0

    /// A corrupted length byte could otherwise park the reassembler waiting
    /// forever for a frame that never completes. Real band frames are far
    /// smaller than this.
    static let maxDeclared = 4096

    init(generation: BandGeneration) {
        self.generation = generation
    }

    func reset() {
        buffer.removeAll()
        resyncedBytes = 0
    }

    /// Feed raw notification bytes; returns every complete frame carved out.
    /// Invalid (CRC-failed) frames are returned too — the caller decides, and
    /// a history batch containing any invalid frame must never be ACKed,
    /// because the ACK lets the band erase that batch.
    func feed(_ chunk: [UInt8]) -> [BandFrame] {
        buffer += chunk
        var frames: [BandFrame] = []
        while true {
            // Hunt for a start byte.
            if let first = buffer.firstIndex(of: 0xAA) {
                if first > 0 {
                    resyncedBytes += first
                    buffer.removeFirst(first)
                }
            } else {
                resyncedBytes += buffer.count
                buffer.removeAll()
                break
            }
            let headerLen = generation.headerLength
            if buffer.count < headerLen { break } // wait for a full header
            guard let declared = BandFraming.declaredLength(buffer, generation: generation) else { break }
            if declared < 4 || declared > Self.maxDeclared || !BandFraming.headerCRCValid(buffer, generation: generation) {
                // Not a real frame start — drop this 0xAA and hunt again.
                resyncedBytes += 1
                buffer.removeFirst()
                continue
            }
            let total = headerLen + declared
            if buffer.count < total { break } // wait for the rest
            if let frame = BandFraming.parseFrame(Array(buffer[0..<total]), generation: generation) {
                frames.append(frame)
            }
            buffer.removeFirst(total)
        }
        return frames
    }
}

// MARK: - Commands

enum BandProtocolError: Error, Equatable {
    case blockedOpcode(UInt8)
    case badArgument(String)
}

/// Command opcodes (inner[2] of a 0x23 COMMAND). Shared across generations
/// except where a gen5 replacement is noted.
enum BandOpcode {
    static let linkValid: UInt8 = 0x01
    static let getBatteryLevel: UInt8 = 0x1A
    static let abortHistoricalTransmits: UInt8 = 0x14
    static let sendHistoricalData: UInt8 = 0x16
    static let historicalDataResult: UInt8 = 0x17
    static let setReadPointer: UInt8 = 0x21
    static let getDataRange: UInt8 = 0x22
    static let sendEventPackets: UInt8 = 0x30
    static let setAlarmTime: UInt8 = 0x42
    static let getAlarmTime: UInt8 = 0x43
    static let runAlarm: UInt8 = 0x44
    static let disableAlarm: UInt8 = 0x45
    static let enterHighFreqSync: UInt8 = 0x60
    static let exitHighFreqSync: UInt8 = 0x61
    static let stopHaptics: UInt8 = 0x7A

    /// Clock read/write. Shared by both generations: OpenStrap physically
    /// confirmed gen5 answers these; the gen5-only 146/147 values seen in
    /// some notes are unverified and deprecated there.
    static let setClock: UInt8 = 0x0A
    static let getClock: UInt8 = 0x0B

    static func hello(_ g: BandGeneration) -> UInt8 { g == .gen5 ? 0x91 : 0x23 }
    static func runHapticPattern(_ g: BandGeneration) -> UInt8 { g == .gen5 ? 0x13 : 0x4F }

    /// Opcodes that are never sent, enforced in code rather than by
    /// discipline. These erase data, break the pairing, reboot the band,
    /// start firmware updates, or latch battery-draining persistent modes.
    static let blocked: Set<UInt8> = [
        0x0F, // FORGET_BONDS — drops the pairing, no undo
        0x19, // FORCE_TRIM — wrong value discards unsynced records
        0x1D, // REBOOT
        0x20, // POWER_CYCLE
        0x24, 0x25, 0x26, // gen4 device-update trio
        0x8E, 0x8F, 0x90, // gen5 device-update trio
        0x99, // persistent optical save — stuck-LED battery drain
        0x9A, // persistent IMU save
        120,  // SET_FF_VALUE — config writes, off-limits for now
    ]
}

enum BandCommand {
    /// Generic command frame: inner = [0x23][seq][opcode][payload…].
    /// Refuses the blocked opcodes unconditionally.
    static func build(sequence: UInt8, opcode: UInt8, payload: [UInt8], generation: BandGeneration) throws -> [UInt8] {
        guard !BandOpcode.blocked.contains(opcode) else {
            throw BandProtocolError.blockedOpcode(opcode)
        }
        let inner: [UInt8] = [BandPacketType.command, sequence, opcode] + payload
        return BandFraming.buildFrame(inner: inner, generation: generation)
    }

    /// HELLO — gen5 opcode 0x91 body [0x01]; gen4 opcode 0x23 body [0x00].
    static func hello(sequence: UInt8, generation: BandGeneration) -> [UInt8] {
        let body: [UInt8] = generation == .gen5 ? [0x01] : [0x00]
        return (try? build(sequence: sequence, opcode: BandOpcode.hello(generation), payload: body, generation: generation)) ?? []
    }

    static func getClock(sequence: UInt8, generation: BandGeneration) -> [UInt8] {
        (try? build(sequence: sequence, opcode: BandOpcode.getClock, payload: [0x00], generation: generation)) ?? []
    }

    static func getBatteryLevel(sequence: UInt8, generation: BandGeneration) -> [UInt8] {
        (try? build(sequence: sequence, opcode: BandOpcode.getBatteryLevel, payload: [0x00], generation: generation)) ?? []
    }

    /// Ask the band to stream its stored history (0x2F records follow on the
    /// data characteristic). gen5 takes an empty body; gen4 takes [0x00].
    static func sendHistoricalData(sequence: UInt8, generation: BandGeneration) -> [UInt8] {
        let body: [UInt8] = generation == .gen5 ? [] : [0x00]
        return (try? build(sequence: sequence, opcode: BandOpcode.sendHistoricalData, payload: body, generation: generation)) ?? []
    }

    /// Positive batch ACK: body = [0x01] + the 8-byte token from the batch's
    /// HistoryEnd metadata marker. Sending this lets the band ERASE the batch
    /// from its flash — only call it when every frame of the batch validated.
    static func historyResultOK(sequence: UInt8, token: [UInt8], generation: BandGeneration) throws -> [UInt8] {
        guard token.count == 8 else {
            throw BandProtocolError.badArgument("batch token must be 8 bytes, got \(token.count)")
        }
        return try build(sequence: sequence, opcode: BandOpcode.historicalDataResult, payload: [0x01] + token, generation: generation)
    }

    static func abortHistoricalTransmits(sequence: UInt8, generation: BandGeneration) -> [UInt8] {
        (try? build(sequence: sequence, opcode: BandOpcode.abortHistoricalTransmits, payload: [0x00], generation: generation)) ?? []
    }

    /// Toggle the band's event pushes (double-tap and friends). The body is a
    /// bare state byte — this opcode takes no revision prefix.
    static func sendEventPackets(sequence: UInt8, enabled: Bool, generation: BandGeneration) -> [UInt8] {
        (try? build(sequence: sequence, opcode: BandOpcode.sendEventPackets, payload: [enabled ? 0x01 : 0x00], generation: generation)) ?? []
    }

    static func enterHighFreqSync(sequence: UInt8, generation: BandGeneration) -> [UInt8] {
        (try? build(sequence: sequence, opcode: BandOpcode.enterHighFreqSync, payload: [0x00], generation: generation)) ?? []
    }

    static func exitHighFreqSync(sequence: UInt8, generation: BandGeneration) -> [UInt8] {
        (try? build(sequence: sequence, opcode: BandOpcode.exitHighFreqSync, payload: [0x00], generation: generation)) ?? []
    }
}

/// A reply to one of our commands (packet type 0x24).
/// Layout: inner = [0x24][seq][opcode][echoed request seq][status][body…].
/// Status 1 means success. Check it before trusting the body: a failed reply
/// can leave stale bytes where the body would be.
struct BandCommandReply {
    let opcode: UInt8
    let requestSequence: UInt8
    let status: UInt8
    let body: [UInt8]

    var succeeded: Bool { status == 1 }

    init?(_ frame: BandFrame) {
        guard frame.decodable, frame.packetType == BandPacketType.commandResponse, frame.inner.count >= 5 else { return nil }
        opcode = frame.inner[2]
        requestSequence = frame.inner[3]
        status = frame.inner[4]
        body = frame.inner.count > 5 ? Array(frame.inner[5...]) : []
    }

    /// The band's clock in Unix seconds, from a successful GET_CLOCK reply.
    /// Returns nil for anything implausible rather than guessing, because
    /// alarms are later armed against this value.
    var clockSeconds: UInt32? {
        guard opcode == BandOpcode.getClock, succeeded, body.count >= 4 else { return nil }
        let v = UInt32(body[0]) | (UInt32(body[1]) << 8) | (UInt32(body[2]) << 16) | (UInt32(body[3]) << 24)
        // 2020-01-01 to 2040-01-01.
        return (1_577_836_800...2_208_988_800).contains(v) ? v : nil
    }
}

/// Band event ids (packet type 0x30).
enum BandEventID {
    /// The wearer double-tapped the band. Gesture actions must apply BOTH
    /// guards: ignore taps older than ~6 s (history drains replay old taps
    /// with old timestamps) and debounce ~2 s (one physical tap can emit more
    /// than one event). Skip the recency check when the band timestamp is
    /// implausible (unset clock), and never act from a background drain.
    static let doubleTap: UInt8 = 14
    static let alarmSet: UInt8 = 56
    static let alarmFired: UInt8 = 57
    static let alarmAutoDisabled: UInt8 = 59
}
