import CoreBluetooth
import Foundation

/// The band's private channel, alongside the standard heart rate broadcast on
/// the same Bluetooth connection.
///
/// Phase 1 (this file): a read-only handshake. On every connect it opens the
/// command channel, says HELLO, and reads the band's clock. Nothing here
/// changes anything on the band, so it is safe while OpenStrap is also
/// connected. History download, events and the alarm come in later phases.
///
/// Recorder forwards the relevant CoreBluetooth callbacks; all calls arrive on
/// the main queue (Recorder's central runs there).
final class BandLink: ObservableObject {
    static let shared = BandLink()

    enum State: Equatable {
        case notFound    // no private service on this band (e.g. a chest strap)
        case opening     // service found, setting up
        case waiting     // commands sent, waiting for replies
        case answering   // the band replied to us
        case noAnswer    // channel open but nothing came back in time
    }

    @Published private(set) var state: State = .notFound
    @Published private(set) var generation: BandGeneration?
    /// Band clock minus phone clock, in seconds. Alarms are armed against this.
    @Published private(set) var clockOffset: Int?
    @Published private(set) var lastAnswer: Date?

    /// Recorder supplies its event logger so link activity lands in the session log.
    var log: ((String, String) -> Void)?

    /// Service UUIDs to request during discovery, for both band generations.
    let serviceUUIDs: [CBUUID] = [
        CBUUID(string: BandGeneration.gen5.serviceUUID),
        CBUUID(string: BandGeneration.gen4.serviceUUID),
    ]

    private weak var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyUUID: CBUUID?
    private var reassembler: BandFrameReassembler?
    /// Our own sequence numbers start high to stay clear of other apps'
    /// traffic, which iOS also delivers to us on a shared connection.
    private var sequence: UInt8 = 0xA0
    /// Commands we sent and are waiting on, by opcode.
    private var pending: [UInt8: Date] = [:]
    private var handshakeToken = 0

    // MARK: Forwarded callbacks

    /// Call for each discovered service. Returns true if it was the band's private service.
    @discardableResult
    func didDiscover(service s: CBService, on p: CBPeripheral) -> Bool {
        guard let g = BandGeneration.fromServiceUUID(s.uuid.uuidString) else { return false }
        generation = g
        peripheral = p
        state = .opening
        reassembler = BandFrameReassembler(generation: g)
        notifyUUID = CBUUID(string: g.commandNotifyUUID)
        p.discoverCharacteristics([CBUUID(string: g.commandWriteUUID), CBUUID(string: g.commandNotifyUUID)], for: s)
        return true
    }

    /// Call when a service's characteristics are discovered. Returns true if handled here.
    @discardableResult
    func didDiscoverCharacteristics(for s: CBService, on p: CBPeripheral) -> Bool {
        guard let g = generation, s.uuid == CBUUID(string: g.serviceUUID) else { return false }
        for c in s.characteristics ?? [] {
            if c.uuid == CBUUID(string: g.commandWriteUUID) {
                writeCharacteristic = c
            } else if c.uuid == notifyUUID {
                p.setNotifyValue(true, for: c)
            }
        }
        return true
    }

    /// Call from peripheral(_:didUpdateNotificationStateFor:error:).
    func didUpdateNotificationState(for c: CBCharacteristic, error: Error?) {
        guard c.uuid == notifyUUID else { return }
        if let error {
            log?("band_link", "subscribe failed: \(error.localizedDescription)")
            state = .noAnswer
            return
        }
        if c.isNotifying { startHandshake() }
    }

    /// Returns true if this characteristic belongs to the private channel.
    func handles(_ c: CBCharacteristic) -> Bool { c.uuid == notifyUUID }

    /// Call with every notification from the command-reply characteristic.
    func didReceive(_ data: Data) {
        guard let reassembler else { return }
        for frame in reassembler.feed([UInt8](data)) {
            guard frame.valid else {
                log?("band_link", "bad frame")
                continue
            }
            guard let reply = BandCommandReply(frame), pending.removeValue(forKey: reply.opcode) != nil else {
                continue // another app's traffic, or not a command reply
            }
            lastAnswer = Date()
            state = .answering
            if let band = reply.clockSeconds {
                clockOffset = Int(band) - Int(Date().timeIntervalSince1970)
                log?("band_clock", "offset \(clockOffset!)s")
            } else {
                log?("band_reply", "op \(reply.opcode) status \(reply.status)")
            }
        }
    }

    /// Call when the connection drops or recording stops.
    func reset() {
        handshakeToken += 1
        peripheral = nil
        writeCharacteristic = nil
        notifyUUID = nil
        reassembler = nil
        pending.removeAll()
        if state != .notFound { state = .opening }
    }

    /// Call when discovery finished and no private service was found.
    func markNotFound() {
        if generation == nil { state = .notFound }
    }

    // MARK: Handshake

    private func startHandshake() {
        guard let g = generation else { return }
        handshakeToken += 1
        let token = handshakeToken
        state = .waiting
        // Pauses mirror the official app's own bootstrap timing on gen5.
        let first: Double = g == .gen5 ? 0.6 : 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + first) { [weak self] in
            guard let self, token == self.handshakeToken else { return }
            self.send(BandOpcode.hello(g)) { BandCommand.hello(sequence: $0, generation: g) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, token == self.handshakeToken else { return }
                self.send(BandOpcode.getClock) { BandCommand.getClock(sequence: $0, generation: g) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, token == self.handshakeToken, self.state == .waiting else { return }
                self.state = .noAnswer
                self.log?("band_link", "no answer")
            }
        }
    }

    private func send(_ opcode: UInt8, _ make: (UInt8) -> [UInt8]) {
        guard let p = peripheral, let c = writeCharacteristic, p.state == .connected else { return }
        let frame = make(sequence)
        sequence = sequence == 0xFF ? 0xA0 : sequence + 1
        guard !frame.isEmpty else { return }
        pending[opcode] = Date()
        p.writeValue(Data(frame), for: c, type: .withResponse)
    }
}

extension BandLink.State {
    var label: String {
        switch self {
        case .notFound: return "Not available on this device"
        case .opening: return "Opening"
        case .waiting: return "Waiting for the band"
        case .answering: return "Connected"
        case .noAnswer: return "No answer"
        }
    }
}
