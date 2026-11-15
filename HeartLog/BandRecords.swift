import Foundation

/// One second of the band's own record (gen5 "v18" historical record): heart
/// rate, beat intervals, wrist motion, the step counter and the band's own
/// sleep/wake state. Times are the BAND's clock (Unix seconds).
///
/// Field layout ported from OpenStrap's protocol package
/// (Gen5V18Decoder in gen5_records.dart, AGPL-3.0; see NOTICE).
struct BandSecond: Equatable {
    var t: Int64
    /// 0 when the band had no plausible reading.
    var hr: Int
    var rr: [Int]
    /// Per-axis gravity means in g, nil when the band's value was unusable.
    var gravity: [Float]?
    var steps: Int
    /// 0 unknown, 1 walk, 2 run; other codes mean "not classified".
    var activity: Int
    /// The band's own state: 0 wake, 1 still, 2 sleep, 3 up.
    var sleepState: Int

    static let recordVersion: UInt8 = 18

    /// Decodes a historical-data frame's inner bytes, or nil for any other record.
    static func decode(_ inner: [UInt8]) -> BandSecond? {
        guard inner.count >= 109, inner[0] == BandPacketType.historicalData, inner[1] == recordVersion else { return nil }
        func u16(_ o: Int) -> Int { Int(inner[o]) | Int(inner[o + 1]) << 8 }
        func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(o)))) }
        func u32(_ o: Int) -> Int64 { Int64(u16(o)) | Int64(u16(o + 2)) << 16 }
        func f32(_ o: Int) -> Float { Float(bitPattern: UInt32(u32(o))) }

        let hrRaw = Int(inner[14])
        var rr: [Int] = []
        let declared = Int(inner[15])
        if declared <= 4 {
            for i in 0..<declared {
                let v = i16(16 + 2 * i)
                if v >= 200 && v <= 2500 { rr.append(v) }
            }
        }
        let g = [f32(37), f32(41), f32(45)]
        let gravityOK = g.allSatisfy { $0.isFinite && abs($0) <= 16 }
        return BandSecond(t: u32(7), hr: (25...230).contains(hrRaw) ? hrRaw : 0, rr: rr,
                          gravity: gravityOK ? g : nil, steps: u16(49), activity: Int(inner[55]),
                          sleepState: Int(inner[73] >> 4) & 0x03)
    }

    // MARK: Storage, 36 bytes a second

    static let size = 36

    func encoded() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: Self.size)
        func put16(_ o: Int, _ v: Int) { b[o] = UInt8(v & 0xFF); b[o + 1] = UInt8((v >> 8) & 0xFF) }
        func put32(_ o: Int, _ v: UInt32) { put16(o, Int(v & 0xFFFF)); put16(o + 2, Int(v >> 16)) }
        put32(0, UInt32(truncatingIfNeeded: t))
        b[4] = UInt8(clamping: hr)
        b[5] = UInt8(min(rr.count, 4))
        for (i, v) in rr.prefix(4).enumerated() { put16(6 + 2 * i, v) }
        if let g = gravity {
            b[14] = 1
            for (i, v) in g.prefix(3).enumerated() { put32(16 + 4 * i, v.bitPattern) }
        }
        put16(28, steps)
        b[30] = UInt8(clamping: activity)
        b[31] = UInt8(clamping: sleepState)
        return b
    }

    static func decodeStored(_ b: ArraySlice<UInt8>) -> BandSecond? {
        guard b.count >= size else { return nil }
        let o = b.startIndex
        func u16(_ i: Int) -> Int { Int(b[o + i]) | Int(b[o + i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
        let n = min(Int(b[o + 5]), 4)
        let rr = (0..<n).map { u16(6 + 2 * $0) }
        let g: [Float]? = b[o + 14] == 1 ? (0..<3).map { Float(bitPattern: u32(16 + 4 * $0)) } : nil
        return BandSecond(t: Int64(u32(0)), hr: Int(b[o + 4]), rr: rr, gravity: g, steps: u16(28),
                          activity: Int(b[o + 30]), sleepState: Int(b[o + 31]))
    }
}

/// Where a history transfer is: the band brackets each batch with these markers
/// (metadata packets). Zdravlje only listens, so it never answers them.
enum BandHistoryMarker: UInt8 {
    case start = 1, end = 2, complete = 3

    init?(_ inner: [UInt8]) {
        guard inner.count > 2, inner[0] == BandPacketType.metadata else { return nil }
        self.init(rawValue: inner[2])
    }
}
