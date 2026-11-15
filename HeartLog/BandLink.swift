import CoreBluetooth
import Foundation

/// The band's private channel, alongside the standard heart rate broadcast on
/// the same Bluetooth connection.
///
/// On every connect it opens the command channel, says HELLO and reads the
/// band's clock. It also keeps the next wake alarm from the weekly schedule
/// on the band. Commands go through BandProtocol's guarded builder, which
/// refuses anything that could erase data or change firmware.
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

    enum AlarmStatus: Equatable {
        case idle
        case sending
        case saved
        case failed(String)
    }

    @Published private(set) var state: State = .notFound
    @Published private(set) var generation: BandGeneration?
    /// Band clock minus phone clock, in seconds. Alarms are armed against this.
    @Published private(set) var clockOffset: Int?
    @Published private(set) var lastAnswer: Date?
    @Published private(set) var alarmStatus: AlarmStatus = .idle

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
    private var eventsUUID: CBUUID?
    private var reassembler: BandFrameReassembler?
    private var eventReassembler: BandFrameReassembler?
    private var lastTapActed: Double?
    private var lastAlarmFired: Date?
    /// Our own sequence numbers start high to stay clear of other apps'
    /// traffic, which iOS also delivers to us on a shared connection.
    private var sequence: UInt8 = 0xA0
    /// Replies we're waiting on, by opcode.
    private var pending: [UInt8: (BandCommandReply) -> Void] = [:]
    private var handshakeToken = 0
    private var lastTick = Date.distantPast
    private var lastAlarmAttempt = Date.distantPast
    private var alarmInFlight = false

    var ready: Bool { state == .answering && writeCharacteristic != nil && peripheral?.state == .connected }

    // MARK: Forwarded callbacks

    /// Call for each discovered service. Returns true if it was the band's private service.
    @discardableResult
    func didDiscover(service s: CBService, on p: CBPeripheral) -> Bool {
        guard let g = BandGeneration.fromServiceUUID(s.uuid.uuidString) else { return false }
        generation = g
        peripheral = p
        state = .opening
        reassembler = BandFrameReassembler(generation: g)
        eventReassembler = BandFrameReassembler(generation: g)
        notifyUUID = CBUUID(string: g.commandNotifyUUID)
        eventsUUID = CBUUID(string: g.eventsUUID)
        p.discoverCharacteristics([CBUUID(string: g.commandWriteUUID), CBUUID(string: g.commandNotifyUUID), CBUUID(string: g.eventsUUID)], for: s)
        return true
    }

    /// Call when a service's characteristics are discovered. Returns true if handled here.
    @discardableResult
    func didDiscoverCharacteristics(for s: CBService, on p: CBPeripheral) -> Bool {
        guard let g = generation, s.uuid == CBUUID(string: g.serviceUUID) else { return false }
        for c in s.characteristics ?? [] {
            if c.uuid == CBUUID(string: g.commandWriteUUID) {
                writeCharacteristic = c
            } else if c.uuid == notifyUUID || c.uuid == eventsUUID {
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
    func handles(_ c: CBCharacteristic) -> Bool { c.uuid == notifyUUID || c.uuid == eventsUUID }

    /// Call with every notification from the private channel's characteristics.
    func didReceive(_ data: Data, from c: CBCharacteristic) {
        let isEvents = c.uuid == eventsUUID
        guard let r = isEvents ? eventReassembler : reassembler else { return }
        for frame in r.feed([UInt8](data)) {
            guard frame.valid else {
                log?("band_link", "bad frame")
                continue
            }
            if frame.packetType == BandPacketType.event {
                handleEvent(frame)
                continue
            }
            guard let reply = BandCommandReply(frame), let handler = pending.removeValue(forKey: reply.opcode) else {
                continue // another app's traffic, or not a command reply
            }
            lastAnswer = Date()
            if state != .answering {
                state = .answering
                planAlarm(force: true)
                enableEventsIfNeeded()
            }
            handler(reply)
        }
    }

    /// Call when the connection drops or recording stops.
    func reset() {
        handshakeToken += 1
        peripheral = nil
        writeCharacteristic = nil
        notifyUUID = nil
        reassembler = nil
        eventReassembler = nil
        eventsUUID = nil
        pending.removeAll()
        alarmInFlight = false
        if state != .notFound { state = .opening }
    }

    /// Call when discovery finished and no private service was found.
    func markNotFound() {
        if generation == nil { state = .notFound }
    }

    /// Call often (Recorder calls it with each heart rate reading). Checks the
    /// alarm about once a minute: after one fires, the next one goes on.
    func tick() {
        NotifyEngine.shared.bandHeard()
        guard Date().timeIntervalSince(lastTick) >= 60 else { return }
        lastTick = Date()
        planAlarm(force: false)
        NotifyEngine.shared.tick()
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
            self.send(BandOpcode.hello(g), BandCommand.hello(sequence: self.sequence, generation: g)) { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, token == self.handshakeToken else { return }
                self.readClock { _ in }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, token == self.handshakeToken, self.state == .waiting else { return }
                self.state = .noAnswer
                self.log?("band_link", "no answer")
            }
        }
    }

    private func readClock(_ done: @escaping (Bool) -> Void) {
        guard let g = generation else { return done(false) }
        send(BandOpcode.getClock, BandCommand.getClock(sequence: sequence, generation: g)) { [weak self] reply in
            guard let self else { return }
            if let band = reply.clockSeconds {
                self.clockOffset = Int(band) - Int(Date().timeIntervalSince1970)
                self.log?("band_clock", "offset \(self.clockOffset!)s")
                done(true)
            } else {
                done(false)
            }
        }
    }

    // MARK: Events and double-tap

    private func handleEvent(_ frame: BandFrame) {
        let inner = frame.inner
        guard inner.count >= 8 else { return }
        let id = UInt16(inner[2]) | (UInt16(inner[3]) << 8)
        let ts = UInt32(inner[4]) | (UInt32(inner[5]) << 8) | (UInt32(inner[6]) << 16) | (UInt32(inner[7]) << 24)
        guard id < 256 else { return }
        switch UInt8(id) {
        case BandEventID.doubleTap:
            let now = Date().timeIntervalSince1970
            let alarm = AlarmStore.shared.armed?.wake ?? AlarmStore.shared.next
            guard TapGuard.shouldAct(tapBandSec: ts, now: now, clockOffset: clockOffset,
                                     lastActed: lastTapActed, alarm: alarm, alarmFired: lastAlarmFired) else {
                log?("tap_ignored", "")
                return
            }
            lastTapActed = now
            log?("tap", WaterStore.shared.tapAction.rawValue)
            WaterStore.shared.performTap()
        case BandEventID.alarmFired:
            lastAlarmFired = Date()
            log?("alarm_fired", "")
        case BandEventID.chargingOn, BandEventID.chargingOff:
            // Only events happening now, not ones replayed from the band's memory.
            let age = Date().timeIntervalSince1970 - (Double(ts) - Double(clockOffset ?? 0))
            let on = id == UInt16(BandEventID.chargingOn)
            log?("charger", on ? "on" : "off")
            Recorder.shared.setCharging(on)
            if abs(age) < 60 { NotifyEngine.shared.charger(on: on) }
        default:
            break
        }
    }

    /// Asks the band to send its events (double-tap, charger) when a tap
    /// action or the charger notification is on.
    private func enableEventsIfNeeded() {
        let wanted = WaterStore.shared.tapAction != .nothing || NotifyStore.shared.settings.charger != .off
        guard ready, let g = generation, wanted else { return }
        send(BandOpcode.sendEventPackets, BandCommand.sendEventPackets(sequence: sequence, enabled: true, generation: g)) { [weak self] reply in
            self?.log?("events_on", "status \(reply.status)")
        }
    }

    func tapActionChanged() { enableEventsIfNeeded() }
    func eventsNeedChanged() { enableEventsIfNeeded() }

    // MARK: Alarm

    /// Call when the schedule is edited.
    func alarmScheduleChanged() {
        lastAlarmAttempt = .distantPast
        planAlarm(force: true)
    }

    /// Puts the schedule's next alarm on the band, or clears the band's alarm
    /// when nothing is scheduled. Does nothing when the band already holds the
    /// right one.
    private func planAlarm(force: Bool) {
        guard ready, !alarmInFlight else { return }
        let store = AlarmStore.shared
        let target = store.next
        let armed = store.armed
        if let target {
            if let a = armed, a.confirmed, abs(a.wake.timeIntervalSince(target)) < 1 {
                alarmStatus = .saved
                return
            }
        } else {
            if armed == nil { alarmStatus = .idle; return }
        }
        // A failed attempt is retried every five minutes, not every minute.
        guard force || Date().timeIntervalSince(lastAlarmAttempt) >= 300 else { return }
        lastAlarmAttempt = Date()
        if let target { arm(target) } else { clearAlarm() }
    }

    private func arm(_ wake: Date) {
        guard let g = generation else { return }
        alarmInFlight = true
        alarmStatus = .sending
        let go: (Int) -> Void = { [weak self] offset in
            guard let self else { return }
            // The band fires on its own clock, so convert to its frame.
            let strapTime = wake.addingTimeInterval(TimeInterval(offset))
            let frame = (try? BandCommand.build(sequence: self.sequence, opcode: BandOpcode.setAlarmTime,
                                                payload: BandAlarm.setBody(strapTime, generation: g), generation: g)) ?? []
            self.send(BandOpcode.setAlarmTime, frame) { [weak self] reply in
                guard let self else { return }
                self.alarmInFlight = false
                if reply.succeeded {
                    AlarmStore.shared.armed = .init(wake: wake, confirmed: true)
                    self.alarmStatus = .saved
                    self.log?("alarm_set", "\(Int(wake.timeIntervalSince1970))")
                } else {
                    self.alarmStatus = .failed("The band didn't accept the alarm (status \(reply.status)).")
                    self.log?("alarm_refused", "status \(reply.status)")
                }
            }
            self.timeout(BandOpcode.setAlarmTime)
        }
        if let offset = clockOffset, abs(offset) <= 60 {
            go(offset)
        } else {
            // Clock unknown or far off: set it from the phone, then read it back.
            let frame = (try? BandCommand.build(sequence: sequence, opcode: BandOpcode.setClock,
                                                payload: BandAlarm.setClockBody(Date()), generation: g)) ?? []
            send(BandOpcode.setClock, frame) { [weak self] _ in
                self?.readClock { [weak self] ok in
                    guard let self else { return }
                    if ok, let offset = self.clockOffset, abs(offset) <= 60 {
                        go(offset)
                    } else {
                        self.alarmInFlight = false
                        self.alarmStatus = .failed("Couldn't line up the band's clock.")
                    }
                }
            }
            timeout(BandOpcode.setClock)
        }
    }

    private func clearAlarm() {
        guard let g = generation else { return }
        alarmInFlight = true
        alarmStatus = .sending
        let frame = (try? BandCommand.build(sequence: sequence, opcode: BandOpcode.disableAlarm,
                                            payload: BandAlarm.disableBody(g), generation: g)) ?? []
        send(BandOpcode.disableAlarm, frame) { [weak self] reply in
            guard let self else { return }
            self.alarmInFlight = false
            if reply.succeeded {
                AlarmStore.shared.armed = nil
                self.alarmStatus = .idle
                self.log?("alarm_cleared", "")
            } else {
                self.alarmStatus = .failed("The band didn't clear the alarm (status \(reply.status)).")
            }
        }
        timeout(BandOpcode.disableAlarm)
    }

    /// A short pulse for a notification routed to the band.
    func buzz(_ reason: String) {
        guard ready, let g = generation else { return }
        let b = BandAlarm.testBuzz(g)
        let frame = (try? BandCommand.build(sequence: sequence, opcode: b.opcode, payload: b.body, generation: g)) ?? []
        send(b.opcode, frame) { [weak self] reply in
            self?.log?("buzz", "\(reason) status \(reply.status)")
        }
    }

    /// A short buzz on the wrist, to check the band hears Zdravlje.
    func testBuzz() {
        guard ready, let g = generation else { return }
        let b = BandAlarm.testBuzz(g)
        let frame = (try? BandCommand.build(sequence: sequence, opcode: b.opcode, payload: b.body, generation: g)) ?? []
        send(b.opcode, frame) { [weak self] reply in
            self?.log?("test_buzz", "status \(reply.status)")
        }
    }

    /// If no reply arrives, stop waiting so the next attempt can run.
    private func timeout(_ opcode: UInt8) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.pending.removeValue(forKey: opcode) != nil else { return }
            self.alarmInFlight = false
            if self.alarmStatus == .sending { self.alarmStatus = .failed("The band didn't answer. It will try again.") }
        }
    }

    // MARK: Sending

    private func send(_ opcode: UInt8, _ frame: [UInt8], reply: @escaping (BandCommandReply) -> Void) {
        guard let p = peripheral, let c = writeCharacteristic, p.state == .connected, !frame.isEmpty else { return }
        sequence = sequence == 0xFF ? 0xA0 : sequence + 1
        pending[opcode] = reply
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
