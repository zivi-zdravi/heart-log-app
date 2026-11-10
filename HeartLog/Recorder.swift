import CoreBluetooth
import Foundation
import UIKit

struct FoundBand: Identifiable {
    let id: UUID
    let name: String
    var rssi: Int
    let peripheral: CBPeripheral
}

/// Listen-only client for the standard Bluetooth Heart Rate and Battery services.
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()

    private let hrService = CBUUID(string: "180D")
    private let hrChar = CBUUID(string: "2A37")
    private let batService = CBUUID(string: "180F")
    private let batChar = CBUUID(string: "2A19")

    @Published var bpm = 0
    @Published var status = "Not connected"
    @Published var battery: Int?
    @Published var bands: [FoundBand] = []
    @Published var scanning = false
    @Published var recording = false
    @Published var readings = 0
    @Published var withBeatTiming = 0
    @Published var startedAt: Date?

    private var central: CBCentralManager!
    private var band: CBPeripheral?
    private var batteryCharacteristic: CBCharacteristic?
    private let defaults = UserDefaults.standard
    private var session: String? {
        get { defaults.string(forKey: "session") }
        set { defaults.set(newValue, forKey: "session") }
    }
    private var savedBand: UUID? {
        get { defaults.string(forKey: "band").flatMap { UUID(uuidString: $0) } }
        set { defaults.set(newValue?.uuidString, forKey: "band") }
    }
    var activeSession: String? { session }
    func flushActive() { if let s = session { Store.shared.flush(s) } }
    var profileName: String {
        get { SettingsStore.shared.value.profileName }
        set { SettingsStore.shared.value.profileName = newValue }
    }

    /// The last few hours of readings, kept in memory for live screens. Main thread only.
    private(set) var recent: [Sample] = []

    func didLaunch(background: Bool) {
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "heartlog.central"])
        if let s = session {
            recording = true
            startedAt = Double(s.dropFirst()).map { Date(timeIntervalSince1970: $0 / 1000) }
            log("launch", background ? "background" : "foreground")
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.log("background") }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.log("foreground") }
        nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in self?.log("locked") }
        nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in self?.log("unlocked") }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.log("terminating") }
    }

    private func log(_ type: String, _ detail: String = "") {
        if let s = session { Store.shared.addEvent(s, type, detail) }
    }

    func startScan() {
        guard central.state == .poweredOn else { status = "Turn on Bluetooth"; return }
        bands = central.retrieveConnectedPeripherals(withServices: [hrService]).map {
            FoundBand(id: $0.identifier, name: $0.name ?? "Unnamed device", rssi: 0, peripheral: $0)
        }
        scanning = true
        central.scanForPeripherals(withServices: [hrService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    func start(_ chosen: FoundBand) {
        stopScan()
        let id = "s\(Store.nowMs())"
        session = id
        startedAt = Date()
        readings = 0
        withBeatTiming = 0
        recording = true
        savedBand = chosen.id
        log("start", "\(profileName)|\(chosen.name)")
        band = chosen.peripheral
        chosen.peripheral.delegate = self
        status = "Connecting"
        central.connect(chosen.peripheral, options: nil)
    }

    func stop() {
        log("stop")
        if let s = session { Store.shared.flush(s) }
        recording = false
        session = nil
        startedAt = nil
        if let b = band { central.cancelPeripheralConnection(b) }
        band = nil
        batteryCharacteristic = nil
        bpm = 0
        status = "Not connected"
    }

    private func resume() {
        guard recording else { return }
        if band == nil, let id = savedBand {
            band = central.retrievePeripherals(withIdentifiers: [id]).first
        }
        guard let b = band else { status = "Band not found"; log("resume_failed"); return }
        b.delegate = self
        if b.state == .connected {
            b.discoverServices([hrService, batService])
        } else {
            status = "Waiting for band"
            central.connect(b, options: nil)  // Never times out; iOS completes it when the band is in range.
        }
    }

    private func handleHR(_ data: Data) {
        guard data.count >= 2, let s = session else { return }
        let bytes = [UInt8](data)
        let flags = bytes[0]
        var i = 1
        var hr = 0
        if flags & 0x01 != 0 {
            guard bytes.count >= 3 else { return }
            hr = Int(bytes[1]) | Int(bytes[2]) << 8
            i = 3
        } else {
            hr = Int(bytes[1])
            i = 2
        }
        if flags & 0x08 != 0 { i += 2 }
        var rr: [Int] = []
        if flags & 0x10 != 0 {
            while i + 1 < bytes.count {
                let raw = Int(bytes[i]) | Int(bytes[i + 1]) << 8
                rr.append(raw * 1000 / 1024)
                i += 2
            }
        }
        let now = Store.nowMs()
        Store.shared.addSample(s, ms: now, hr: hr, flags: flags, len: bytes.count, rr: rr)
        recent.append(Sample(t: now, hr: hr, rr: rr))
        if recent.count > 16_000 { recent.removeFirst(2_000) }
        bpm = hr
        readings += 1
        if !rr.isEmpty { withBeatTiming += 1 }
        if readings % 600 == 0, let c = batteryCharacteristic, let b = band { b.readValue(for: c) }
    }
}

extension Recorder: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        log("restored")
        if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            band = p
            p.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("bluetooth_state", String(central.state.rawValue))
        if central.state == .poweredOn { resume() } else if recording { status = "Bluetooth is off" }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unnamed device"
        if let i = bands.firstIndex(where: { $0.id == p.identifier }) {
            bands[i].rssi = rssi.intValue
        } else {
            bands.append(FoundBand(id: p.identifier, name: name, rssi: rssi.intValue, peripheral: p))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        log("connected", p.name ?? "")
        status = p.name ?? "Connected"
        p.delegate = self
        p.discoverServices([hrService, batService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("connect_failed", error?.localizedDescription ?? "")
        if recording { status = "Retrying"; central.connect(p, options: nil) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard recording else { return }
        log("disconnected", error?.localizedDescription ?? "")
        status = "Waiting for band"
        central.connect(p, options: nil)
    }
}

extension Recorder: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            p.discoverCharacteristics(s.uuid == hrService ? [hrChar] : [batChar], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.uuid == hrChar {
                p.setNotifyValue(true, for: c)
            } else if c.uuid == batChar {
                batteryCharacteristic = c
                p.readValue(for: c)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let data = c.value else { return }
        if c.uuid == hrChar {
            handleHR(data)
        } else if c.uuid == batChar, let v = data.first {
            battery = Int(v)
            log("battery", String(v))
        }
    }
}
