import XCTest

/// Golden vectors were computed with an independent Python implementation
/// (zlib CRC32, bitwise CRC8/CRC16) and cross-checked against the OpenStrap
/// protocol package's documented vector: CRC16 of header aa 01 08 00 00 01 = 0x71E6.
final class BandProtocolTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    // MARK: CRCs

    func testCRC16DocumentedVector() {
        XCTAssertEqual(BandCRC.crc16Modbus(hex("aa0108000001")), 0x71E6)
    }

    func testCRC8LengthBytes() {
        XCTAssertEqual(BandCRC.crc8([0x08, 0x00]), 0xA8)
    }

    func testCRC32MatchesZlib() {
        XCTAssertEqual(BandCRC.crc32([0, 0, 0, 0]), 0x2144_DF1C)
        XCTAssertEqual(BandCRC.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: Command frames

    func testGen5Hello() {
        XCTAssertEqual(BandCommand.hello(sequence: 0, generation: .gen5), hex("aa0108000001e6712300910101549e8c"))
    }

    func testGen5BatteryLevel() {
        XCTAssertEqual(BandCommand.getBatteryLevel(sequence: 7, generation: .gen5), hex("aa0108000001e67123071a009233a126"))
    }

    func testGen5HistoryRequestHasEmptyBody() {
        XCTAssertEqual(BandCommand.sendHistoricalData(sequence: 2, generation: .gen5), hex("aa0108000001e6712302160075bedf8c"))
    }

    func testGen4Hello() {
        XCTAssertEqual(BandCommand.hello(sequence: 0, generation: .gen4), hex("aa0800a823002300ada86a2d"))
    }

    func testBlockedOpcodesAreRefused() {
        for op: UInt8 in [0x0F, 0x19, 0x1D, 0x20, 0x8E, 0x99, 0x9A, 120] {
            XCTAssertThrowsError(try BandCommand.build(sequence: 0, opcode: op, payload: [], generation: .gen5)) { error in
                XCTAssertEqual(error as? BandProtocolError, .blockedOpcode(op))
            }
        }
    }

    func testHistoryAckNeedsEightByteToken() {
        XCTAssertThrowsError(try BandCommand.historyResultOK(sequence: 0, token: [1, 2, 3], generation: .gen5))
        let frame = try? BandCommand.historyResultOK(sequence: 3, token: [1, 2, 3, 4, 5, 6, 7, 8], generation: .gen5)
        XCTAssertNotNil(frame)
        let parsed = BandFraming.parseFrame(frame!, generation: .gen5)!
        XCTAssertTrue(parsed.valid)
        XCTAssertEqual(parsed.opcode, BandOpcode.historicalDataResult)
        XCTAssertEqual(Array(parsed.body.prefix(9)), [0x01, 1, 2, 3, 4, 5, 6, 7, 8])
    }

    // MARK: Parsing

    func testParsesInboundGen5FrameWithStrapDirectionMarker() {
        // Strap→host frames carry direction bytes 01 00; parsing must accept them.
        let f = BandFraming.parseFrame(hex("aa010c00010027112400910100000000935f44f3"), generation: .gen5)
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.decodable)
        XCTAssertEqual(f!.packetType, BandPacketType.commandResponse)
        XCTAssertEqual(f!.opcode, 0x91)
    }

    func testCorruptPayloadIsFlaggedNotDropped() {
        var raw = BandCommand.hello(sequence: 0, generation: .gen5)
        raw[9] ^= 0xFF
        let f = BandFraming.parseFrame(raw, generation: .gen5)
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.headerCRCOK)
        XCTAssertFalse(f!.payloadCRCOK)
        XCTAssertFalse(f!.valid)
    }

    func testOtherFrameRevisionIsIntactButNotDecodable() {
        // Rebuild a valid frame with revision byte 0x02 and a recomputed header CRC.
        var raw = BandCommand.hello(sequence: 0, generation: .gen5)
        raw[1] = 0x02
        let c = BandCRC.crc16Modbus(Array(raw[0..<6]))
        raw[6] = UInt8(c & 0xFF)
        raw[7] = UInt8(c >> 8)
        let f = BandFraming.parseFrame(raw, generation: .gen5)!
        XCTAssertTrue(f.valid)
        XCTAssertFalse(f.decodable)
    }

    // MARK: Reassembly

    func testReassemblesFrameSplitAcrossNotifications() {
        let frame = BandCommand.getBatteryLevel(sequence: 7, generation: .gen5)
        let r = BandFrameReassembler(generation: .gen5)
        XCTAssertTrue(r.feed(Array(frame[0..<3])).isEmpty)
        XCTAssertTrue(r.feed(Array(frame[3..<11])).isEmpty)
        let out = r.feed(Array(frame[11...]))
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].valid)
        XCTAssertEqual(out[0].opcode, BandOpcode.getBatteryLevel)
    }

    func testReassemblesBackToBackFramesInOneChunk() {
        let a = BandCommand.hello(sequence: 0, generation: .gen5)
        let b = BandCommand.getBatteryLevel(sequence: 1, generation: .gen5)
        let out = BandFrameReassembler(generation: .gen5).feed(a + b)
        XCTAssertEqual(out.map(\.opcode), [0x91, BandOpcode.getBatteryLevel])
    }

    func testSkipsLeadingGarbageIncludingStrayStartBytes() {
        // A stray 0xAA whose "header" fails its CRC must not swallow the real frame.
        let frame = BandCommand.hello(sequence: 0, generation: .gen5)
        let r = BandFrameReassembler(generation: .gen5)
        let out = r.feed([0x13, 0xAA, 0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] + frame)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].valid)
        XCTAssertGreaterThan(r.resyncedBytes, 0)
    }

    func testPayloadContainingStartByteIsNotSplit() {
        let frame = try! BandCommand.build(sequence: 0xAA, opcode: BandOpcode.sendEventPackets, payload: [0xAA, 0xAA], generation: .gen5)
        let out = BandFrameReassembler(generation: .gen5).feed(frame)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].valid)
        XCTAssertEqual(out[0].sequence, 0xAA)
    }

    // MARK: Replies

    private func reply(op: UInt8, status: UInt8, body: [UInt8]) -> BandCommandReply? {
        let inner: [UInt8] = [BandPacketType.commandResponse, 0x05, op, 0xA1, status] + body
        let raw = BandFraming.buildFrame(inner: inner, generation: .gen5)
        return BandFraming.parseFrame(raw, generation: .gen5).flatMap(BandCommandReply.init)
    }

    func testClockReplyReadsSecondsAfterStatus() {
        let t: UInt32 = 1_794_691_881 // 2026-11-14
        let le = [UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8(t >> 24)]
        let r = reply(op: BandOpcode.getClock, status: 1, body: le + [0, 0])
        XCTAssertEqual(r?.requestSequence, 0xA1)
        XCTAssertEqual(r?.clockSeconds, t)
    }

    func testFailedClockReplyIsIgnored() {
        let t: UInt32 = 1_794_691_881
        let le = [UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8(t >> 24)]
        XCTAssertNil(reply(op: BandOpcode.getClock, status: 2, body: le)?.clockSeconds)
    }

    func testImplausibleClockIsIgnored() {
        XCTAssertNil(reply(op: BandOpcode.getClock, status: 1, body: [1, 0, 0, 0])?.clockSeconds)
    }

    func testCommandFrameIsNotAReply() {
        let f = BandFraming.parseFrame(BandCommand.hello(sequence: 0, generation: .gen5), generation: .gen5)!
        XCTAssertNil(BandCommandReply(f))
    }

    // MARK: GATT

    func testGen5UUIDs() {
        XCTAssertEqual(BandGeneration.gen5.serviceUUID, "fd4b0001-cce1-4033-93ce-002d5875f58a")
        XCTAssertEqual(BandGeneration.gen5.dataUUID, "fd4b0005-cce1-4033-93ce-002d5875f58a")
        XCTAssertEqual(BandGeneration.fromServiceUUID("FD4B0001-CCE1-4033-93CE-002D5875F58A"), .gen5)
        XCTAssertEqual(BandGeneration.fromServiceUUID("0000180d-0000-1000-8000-00805f9b34fb"), nil)
    }
}
