import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var r = Recorder.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var weight = ""
    @State private var feet = ""
    @State private var inches = ""
    @State private var showZoneInfo = false
    @State private var showStepsHelp = false
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
            Section {
                labeled("Name") { TextField("Your name", text: $settings.value.profileName).multilineTextAlignment(.trailing) }
            } header: {
                Text("Profile")
            } footer: {
                Text("Changes save automatically.")
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
                if showZoneInfo {
                    Text("These two numbers set your five heart rate zones, which drive the zone bars and strain. Max is the highest your heart gets in an all-out effort. Resting is your usual low when relaxed. The defaults match your old WHOOP zones, so most people never change them.")
                        .font(.footnote).foregroundColor(Theme.dim)
                }
                Stepper("Max heart rate: \(settings.value.maxHR)", value: $settings.value.maxHR, in: 140...220)
                Stepper("Resting heart rate (for zones): \(settings.value.restingForZones)", value: $settings.value.restingForZones, in: 35...100)
                row("Zones start at", settings.value.zoneBounds.map { "\($0)" }.joined(separator: ", "))
            } header: {
                HStack {
                    Text("Heart rate zones")
                    Spacer()
                    Button { showZoneInfo.toggle() } label: {
                        Image(systemName: showZoneInfo ? "info.circle.fill" : "info.circle").font(.system(size: 18))
                    }
                    .accessibilityLabel("What are these?")
                }
            }

            Section {
                labeled("Weight") {
                    TextField("0", text: $weight).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                    Text("lb").foregroundColor(Theme.dim)
                }
                .onChange(of: weight) { v in settings.value.weightKg = Double(v).map { $0 * 0.45359237 } }
                labeled("Height") {
                    TextField("0", text: $feet).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 36)
                    Text("ft").foregroundColor(Theme.dim)
                    TextField("0", text: $inches).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 36)
                    Text("in").foregroundColor(Theme.dim)
                }
                .onChange(of: feet) { _ in saveHeight() }
                .onChange(of: inches) { _ in saveHeight() }
                labeled("Age") {
                    TextField("0", text: $age).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70)
                }
                .onChange(of: age) { v in settings.value.age = Int(v) }
                Picker("Sex", selection: $settings.value.female) {
                    Text("Female").tag(Bool?.some(true))
                    Text("Male").tag(Bool?.some(false))
                }
                .pickerStyle(.segmented)
            } header: {
                Text("For calorie estimates")
            } footer: {
                Text("Stays on this phone. Calories are estimates from heart rate.")
            }

            Section("Meals") {
                NavigationLink("Goal, avoid list and food database") { MealsSettingsView() }
            }
            Section("Steps") {
                row("Last update from Shortcut", StepsLog.lastUpdate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "None yet")
                Button("How to set up the steps Shortcut") { showStepsHelp = true }
            }

            Section {
                Button(busy ? "Working" : "Back up now") { backUp() }.disabled(busy)
                Button("Restore from a backup") { showRestore = true }.disabled(busy)
                NavigationLink("Import WHOOP history") { ImportView() }
                if !backupStatus.isEmpty { Text(backupStatus).font(.footnote) }
            } header: {
                Text("Backup")
            } footer: {
                Text(lastBackup > 0 ? "Last backup: \(Date(timeIntervalSince1970: lastBackup).formatted(date: .abbreviated, time: .shortened)). Restoring only adds data." : "No backup yet. Restoring only adds data.")
            }

            Section {
                row("Band firmware", r.firmware ?? (r.infoMissing ? "Not reported by the band" : "Read when the band connects"))
                if let h = r.hardware { row("Band hardware", h) }
                row("Zdravlje version", (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "--")
            } header: {
                Text("About")
            } footer: {
                Text("Read straight from the band, without the WHOOP app. Firmware 50.43 or later is reported to block reading the band's stored history without a membership. Zdravlje uses the heart rate broadcast, which isn't affected.")
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
        .sheet(isPresented: $showStepsHelp) { StepsHelp() }
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
            if let cm = settings.value.heightCm {
                let total = Int((cm / 2.54).rounded())
                feet = String(total / 12)
                inches = String(total % 12)
            }
            age = settings.value.age.map { "\($0)" } ?? ""
            refresh(nil)
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label)
            Spacer()
            content()
        }
    }

    private func saveHeight() {
        let f = Int(feet) ?? 0
        let i = Int(inches) ?? 0
        settings.value.heightCm = (f > 0 || i > 0) ? Double(f * 12 + i) * 2.54 : nil
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
                if result.deferred.contains("history.json"), let h = try BackupArchive.extract(url, name: "history.json") {
                    HistoryStore.shared.merge(json: h)
                } else {
                    HistoryStore.shared.reload()
                }
                if result.deferred.contains("overrides.json"), let o = try BackupArchive.extract(url, name: "overrides.json") {
                    Overrides.merge(o)
                }
                let meals = try result.deferred.contains("meals.json") ? BackupArchive.extract(url, name: "meals.json") : nil
                DayEngine.shared.invalidateAll()
                DispatchQueue.main.async {
                    var merged = 0
                    if let data = activities { merged = ActivityStore.shared.merge(data) } else { ActivityStore.shared.load() }
                    SettingsStore.shared.reload()
                    if let m = meals { MealStore.shared.merge(m) } else { MealStore.shared.reload() }
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
    @State private var sleepDay = Calendar.current.startOfDay(for: Date())

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Theme.card)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $tab) {
            TodayView(openActivity: { tab = 1 }, openMeals: { tab = 4 }, openSleep: { day in
                sleepDay = day
                tab = 2
            })
                .tabItem { Label("Today", systemImage: "sun.max") }.tag(0)
            ActivityTab()
                .tabItem { Label("Activity", systemImage: "figure.walk") }.tag(1)
            SleepView(day: $sleepDay)
                .tabItem { Label("Sleep", systemImage: "moon") }.tag(2)
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.bar") }.tag(3)
            MealsView()
                .tabItem { Label("Meals", systemImage: "fork.knife") }.tag(4)
        }
        .tint(Theme.orange)
    }
}

struct StepsHelp: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Make the Shortcut") {
                    Text("1. Open the Shortcuts app, tap +, and name it Zdravlje Steps.")
                    Text("2. Add the action Find Health Samples. Set Type to Steps, and add a filter: Start Date is Today.")
                    Text("3. Add Calculate Statistics. Tap its first setting and choose Sum, and make sure it uses the Health Samples from step 2.")
                    Text("4. Add Log Steps in Zdravlje. Tap Steps, choose Select Variable, and pick Sum (the result of step 3).")
                    Text("5. Run it once. Allow Health access when asked, then check that Today shows your steps.")
                }
                Section("Run it automatically") {
                    Text("1. In Shortcuts, go to Automation and tap +.")
                    Text("2. Choose Time of Day, for example 12:00 PM, and set it to Run Immediately.")
                    Text("3. Pick Zdravlje Steps. Repeat for 6:00 PM and 11:55 PM if you want updates through the day.")
                }
                Section {
                    Text("Steps come from your iPhone, so they count when it's with you. Each run replaces today's number.")
                        .foregroundColor(Theme.dim)
                }
            }
            .navigationTitle("Steps Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
