import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var r = Recorder.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var weight = ""
    @State private var height = ""
    @State private var age = ""
    @State private var sessions: [String] = []
    @State private var report = ""
    @State private var selected: String?
    @State private var copied = false
    @State private var backupFile: URL?
    @State private var showSave = false
    @State private var showRestore = false
    @State private var busy = false
    @State private var backupStatus = ""
    @State private var confirmStop = false
    @AppStorage("lastBackup") private var lastBackup = 0.0

    var body: some View {
        List {
            Section("Profile") {
                TextField("Your name", text: $settings.value.profileName)
            }

            Section {
                row("Battery", r.battery.map { "\($0)%" } ?? "Unknown")
                row("Connection", r.recording ? r.status : "Not recording")
                Stepper("Low battery warning at \(settings.value.lowBattery)%", value: $settings.value.lowBattery, in: 5...50, step: 5)
                if r.recording {
                    Button("Stop recording", role: .destructive) { confirmStop = true }
                } else if r.scanning {
                    ForEach(r.bands.sorted { $0.rssi > $1.rssi }) { b in
                        Button { r.start(b) } label: {
                            HStack {
                                Text(b.name)
                                Spacer()
                                Text(b.rssi > -60 ? "Very close" : b.rssi > -80 ? "Nearby" : "Far").foregroundColor(Theme.dim)
                            }
                        }
                    }
                    if r.bands.isEmpty { Text("Looking. Tap your band to wake it.").foregroundColor(Theme.dim) }
                    Button("Cancel") { r.stopScan() }
                } else {
                    Button("Find my band and start recording") { r.startScan() }
                }
            } header: {
                Text("Band")
            } footer: {
                Text("Recording keeps going with the phone locked. Swiping the app away stops it.")
            }

            Section {
                Stepper("Max heart rate: \(settings.value.maxHR)", value: $settings.value.maxHR, in: 140...220)
                Stepper("Resting heart rate: \(settings.value.restingForZones)", value: $settings.value.restingForZones, in: 35...100)
                row("Zones start at", settings.value.zoneBounds.map { "\($0)" }.joined(separator: ", "))
            } header: {
                Text("Heart rate zones")
            } footer: {
                Text("Zones use 40, 60, 70, 80 and 90% of the range between these two numbers.")
            }

            Section {
                TextField("Weight (lb)", text: $weight).keyboardType(.decimalPad)
                    .onChange(of: weight) { v in settings.value.weightKg = Double(v).map { $0 * 0.45359237 } }
                TextField("Height (inches)", text: $height).keyboardType(.decimalPad)
                    .onChange(of: height) { v in settings.value.heightCm = Double(v).map { $0 * 2.54 } }
                TextField("Age", text: $age).keyboardType(.numberPad)
                    .onChange(of: age) { v in settings.value.age = Int(v) }
                Picker("Calorie formula", selection: $settings.value.female) {
                    Text("Not set").tag(Bool?.none)
                    Text("Female").tag(Bool?.some(true))
                    Text("Male").tag(Bool?.some(false))
                }
            } header: {
                Text("For calorie estimates")
            } footer: {
                Text("Stays on this phone. Calories are estimates from heart rate.")
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

            if let expiry = Signing.expiry {
                Section("App signing") {
                    row(expiry > Date() ? "Re-sign by" : "Expired", expiry.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if !sessions.isEmpty {
                Section("Recording report") {
                    Picker("Recording", selection: Binding(get: { selected ?? "" }, set: { refresh($0) })) {
                        ForEach(sessions, id: \.self) { Text(Report.title($0)).tag($0) }
                    }
                    Text(report).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy report") {
                        UIPasteboard.general.string = report
                        copied = true
                    }
                    if let id = selected { ShareLink("Save data file", item: Store.shared.samplesURL(id)) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Settings")
        .confirmationDialog("Stop recording?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) {
                let id = r.activeSession
                r.stop()
                refresh(id)
            }
        } message: {
            Text("Nothing is recorded until you start again.")
        }
        .fileImporter(isPresented: $showRestore, allowedContentTypes: [.data]) { restore($0) }
        .fileMover(isPresented: $showSave, file: backupFile) { result in
            switch result {
            case .success:
                lastBackup = Date().timeIntervalSince1970
                backupStatus = "Backup saved and checked."
            case .failure(let error):
                backupStatus = "Backup was not saved: \(error.localizedDescription)"
            }
        }
        .onAppear {
            weight = settings.value.weightKg.map { String(Int(($0 / 0.45359237).rounded())) } ?? ""
            height = settings.value.heightCm.map { String(Int(($0 / 2.54).rounded())) } ?? ""
            age = settings.value.age.map { "\($0)" } ?? ""
            refresh(nil)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundColor(Theme.dim)
            Spacer()
            Text(v)
        }
    }

    private func backUp() {
        busy = true
        backupStatus = "Preparing backup"
        r.flushActive()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("heart-log-\(stamp).hlbackup")
                try? FileManager.default.removeItem(at: out)
                try BackupArchive.create(from: Store.shared.dir, to: out)
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
        DispatchQueue.global(qos: .userInitiated).async {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try BackupArchive.restore(url, into: Store.shared.dir, skipping: skip)
                let activities = try result.deferred.contains("activities.json") ? BackupArchive.extract(url, name: "activities.json") : nil
                DispatchQueue.main.async {
                    var merged = 0
                    if let data = activities { merged = ActivityStore.shared.merge(data) } else { ActivityStore.shared.load() }
                    SettingsStore.shared.reload()
                    busy = false
                    backupStatus = "Restore finished: \(result.added) added, \(result.updated) extended, \(result.kept) already up to date, \(merged) activities merged."
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
        guard let id = selected else {
            report = ""
            return
        }
        report = "Calculating"
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Report.build(id)
            DispatchQueue.main.async { if selected == id { report = text } }
        }
    }
}

struct RootView: View {
    @State private var tab = 0

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Theme.card)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $tab) {
            TodayView(openActivity: { tab = 1 }, openMeals: { tab = 4 })
                .tabItem { Label("Today", systemImage: "sun.max") }.tag(0)
            ActivityTab()
                .tabItem { Label("Activity", systemImage: "figure.walk") }.tag(1)
            ComingSoon(title: "Sleep", note: "Sleep score, sleep timing and overnight trends are the next update. Your band is already recording the data they need.")
                .tabItem { Label("Sleep", systemImage: "moon") }.tag(2)
            ComingSoon(title: "Trends", note: "Weekly, monthly and yearly charts, including your imported WHOOP history, come with the sleep update.")
                .tabItem { Label("Trends", systemImage: "chart.bar") }.tag(3)
            ComingSoon(title: "Meals", note: "Meal logging, calories eaten and macros are coming after the sleep update.")
                .tabItem { Label("Meals", systemImage: "fork.knife") }.tag(4)
        }
        .tint(Theme.orange)
    }
}
