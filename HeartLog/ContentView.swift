import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject private var r = Recorder.shared
    @State private var profile = Recorder.shared.profileName
    @State private var sessions: [String] = []
    @State private var report = ""
    @State private var selected: String?
    @State private var copied = false

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
        }
        .navigationViewStyle(.stack)
        .onAppear { refresh(nil) }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundColor(.secondary); Spacer(); Text(v) }
    }

    private func refresh(_ pick: String?) {
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
