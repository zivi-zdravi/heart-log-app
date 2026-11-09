import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var r = Recorder.shared
    @State private var profile = Recorder.shared.profileName
    @State private var sessions: [String] = []
    @State private var report = ""
    @State private var selected: String?
    @State private var copied = false
    @State private var backupFile: URL?
    @State private var showSave = false
    @State private var showRestore = false
    @State private var busy = false
    @State private var backupStatus = ""
    @AppStorage("lastBackup") private var lastBackup = 0.0

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.bpm > 0 ? "\(r.bpm)" : "--").font(.system(size: 64, weight: .bold)).monospacedDigit()
                        Text("bpm").foregroundColor(.secondary)
                    }
                    row("Band", r.status)
                    row("Battery", r.battery.map { "\($0)%" } ?? "Unknown")
                    row("Readings", "\(r.readings)")
                    row("Beat timing", r.readings > 0 ? "\(100 * r.withBeatTiming / r.readings)%" : "None yet")
                    if let s = r.startedAt { row("Started", s.formatted(date: .omitted, time: .shortened)) }
                }
                if r.recording {
                    Section {
                        Button("Stop and see report", role: .destructive) {
                            let id = Store.shared.sessions().first
                            r.stop()
                            refresh(id)
                        }
                    } footer: {
                        Text("You can lock the phone. Do not swipe this app away, or recording stops.")
                    }
                } else {
                    Section("New recording") {
                        TextField("Whose band is this?", text: $profile)
                            .onChange(of: profile) { r.profileName = $0 }
                        if r.scanning {
                            ForEach(r.bands.sorted { $0.rssi > $1.rssi }) { b in
                                Button { r.start(b) } label: {
                                    HStack {
                                        Text(b.name)
                                        Spacer()
                                        Text(b.rssi > -60 ? "Very close" : b.rssi > -80 ? "Nearby" : "Far").foregroundColor(.secondary)
                                    }
                                }
                            }
                            if r.bands.isEmpty { Text("Looking. Tap your band to wake it.").foregroundColor(.secondary) }
                            Button("Cancel") { r.stopScan() }
                        } else {
                            Button("Find my band") { r.startScan() }
                        }
                    }
                }
                Section {
                    Button(busy ? "Working" : "Back up now") { backUp() }.disabled(busy)
                    Button("Restore from a backup") { showRestore = true }.disabled(busy)
                    if !backupStatus.isEmpty { Text(backupStatus).font(.footnote) }
                } header: {
                    Text("Backup")
                } footer: {
                    Text(lastBackup > 0 ? "Last backup: \(Date(timeIntervalSince1970: lastBackup).formatted(date: .abbreviated, time: .shortened)). Restoring only adds data." : "No backup yet. Restoring only adds data.")
                }
                if !sessions.isEmpty {
                    Section("Report") {
                        Picker("Recording", selection: Binding(get: { selected ?? "" }, set: { refresh($0) })) {
                            ForEach(sessions, id: \.self) { Text(Report.title($0)).tag($0) }
                        }
                        Text(report).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy report") { UIPasteboard.general.string = report; copied = true }
                        if let id = selected {
                            ShareLink("Save data file", item: Store.shared.samplesURL(id))
                        }
                    }
                }
            }
            .navigationTitle("Heart Log")
            .fileImporter(isPresented: $showRestore, allowedContentTypes: [.data]) { restore($0) }
        }
        .navigationViewStyle(.stack)
        .fileMover(isPresented: $showSave, file: backupFile) { result in
            switch result {
            case .success:
                lastBackup = Date().timeIntervalSince1970
                backupStatus = "Backup saved and checked."
            case .failure(let error):
                backupStatus = "Backup was not saved: \(error.localizedDescription)"
            }
        }
        .onAppear { refresh(nil) }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundColor(.secondary); Spacer(); Text(v) }
    }

    private func backUp() {
        busy = true
        backupStatus = "Preparing backup"
        r.flushActive()
        let profile = r.profileName
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dir = Store.shared.dir
                try Data(profile.utf8).write(to: dir.appendingPathComponent("profile.txt"))
                let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("heart-log-\(stamp).hlbackup")
                try? FileManager.default.removeItem(at: out)
                try BackupArchive.create(from: dir, to: out)
                _ = try BackupArchive.verify(out)
                DispatchQueue.main.async {
                    busy = false
                    backupStatus = "Choose where to save it"
                    backupFile = out
                    showSave = true
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    backupStatus = "Backup failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func restore(_ picked: Result<URL, Error>) {
        guard case .success(let url) = picked else { return }
        busy = true
        backupStatus = "Checking backup"
        r.flushActive()
        var skip = Set<String>()
        if let s = r.activeSession { skip = ["\(s).samples.csv", "\(s).events.csv"] }
        let hasProfile = !r.profileName.isEmpty
        DispatchQueue.global(qos: .userInitiated).async {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try BackupArchive.restore(url, into: Store.shared.dir, skipping: skip)
                let saved = (try? String(contentsOf: Store.shared.dir.appendingPathComponent("profile.txt"), encoding: .utf8)) ?? ""
                DispatchQueue.main.async {
                    if !hasProfile, !saved.isEmpty { r.profileName = saved; profile = saved }
                    busy = false
                    backupStatus = "Restore finished: \(result.added) added, \(result.updated) extended, \(result.kept) already up to date."
                    refresh(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    backupStatus = error.localizedDescription
                }
            }
        }
    }

    private func refresh(_ pick: String?) {
        r.flushActive()
        sessions = Store.shared.sessions()
        copied = false
        selected = pick ?? sessions.first
        guard let id = selected else { report = ""; return }
        report = "Calculating"
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Report.build(id)
            DispatchQueue.main.async { if selected == id { report = text } }
        }
    }
}
