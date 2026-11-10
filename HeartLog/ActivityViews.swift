import SwiftUI

struct ActivityStats {
    var zoneSeconds = [Double](repeating: 0, count: 6)
    var avg: Int?
    var max: Int?
    var strain = 0.0
    var calories: Double?
    var samples: [Sample] = []

    static func make(_ s: [Sample], settings: AppSettings, start: Int64, end: Int64) -> ActivityStats {
        var out = ActivityStats()
        let bounds = settings.zoneBounds
        out.samples = s
        out.zoneSeconds = Metrics.zoneSeconds(s, bounds)
        out.avg = Metrics.average(s)
        out.max = Metrics.maxHR(s)
        out.strain = Metrics.strain(zoneSeconds: out.zoneSeconds)
        if let body = settings.body {
            out.calories = Metrics.calories(s, body: body, bounds: bounds, elapsedMinutes: Double(end - start) / 60_000)
        }
        return out
    }
}

struct ActivityRow: View {
    let record: ActivityRecord
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.type).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Text("\(Theme.dayText.string(from: Date(timeIntervalSince1970: Double(record.start) / 1000))), \(Theme.clock(record.start)) to \(Theme.clock(record.end ?? record.start))")
                    .font(.system(size: 13)).foregroundColor(Theme.dim)
            }
            Spacer()
            Text(Theme.duration(Double((record.end ?? record.start) - record.start) / 1000, showSeconds: true))
                .font(.system(size: 15)).monospacedDigit().foregroundColor(Theme.text)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.dim)
        }
        .frame(minHeight: 44)
    }
}

struct ActivityTab: View {
    @ObservedObject private var acts = ActivityStore.shared
    @State private var picking = false
    @State private var showLive = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Activity").font(Theme.display(30)).foregroundColor(Theme.text)
                    if let current = acts.current {
                        Button("Return to \(current.type)") { showLive = true }.buttonStyle(TintButton(color: Theme.orange))
                    } else {
                        Button("Start activity") { picking = true }.buttonStyle(TintButton(color: Theme.orange))
                    }
                    if acts.saved.isEmpty {
                        Text("Finished activities, and ones you save from suggestions on Today, show up here.")
                            .font(.system(size: 14)).foregroundColor(Theme.dim)
                    } else {
                        Card {
                            ForEach(acts.saved) { a in
                                NavigationLink { ActivitySummaryView(id: a.id) } label: { ActivityRow(record: a) }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $picking) {
            TypePicker { type in
                acts.start(type)
                picking = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showLive = true }
            }
        }
        .fullScreenCover(isPresented: $showLive) { LiveActivityView() }
        .onReceive(acts.$pendingStart) { pending in
            guard pending else { return }
            DispatchQueue.main.async {
                acts.pendingStart = false
                if acts.current != nil { showLive = true } else { picking = true }
            }
        }
    }
}

struct TypePicker: View {
    let choose: (String) -> Void
    var body: some View {
        NavigationStack {
            List(ActivityStore.types, id: \.self) { type in
                Button(type) { choose(type) }.foregroundColor(Theme.text).frame(minHeight: 44)
            }
            .navigationTitle("What are you doing?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

struct LiveActivityView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var rec = Recorder.shared
    @ObservedObject private var acts = ActivityStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var loaded: [Sample] = []
    @State private var now = Date()
    @State private var finishedID: String?
    @State private var confirmCancel = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let id = finishedID {
                NavigationStack {
                    ActivitySummaryView(id: id)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                }
            } else if let a = acts.current {
                live(a)
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .onReceive(timer) { now = $0 }
    }

    private func samples(_ a: ActivityRecord) -> [Sample] {
        let after = loaded.last?.t ?? (a.start - 1)
        return loaded + rec.recent.filter { $0.t > after && $0.t >= a.start }
    }

    private func live(_ a: ActivityRecord) -> some View {
        let s = samples(a)
        let bounds = settings.value.zoneBounds
        let zones = Metrics.zoneSeconds(s, bounds)
        let hr = rec.bpm
        let zone = Metrics.zone(hr, bounds)
        return VStack(spacing: 16) {
            HStack {
                Text(a.type)
                Spacer()
                Text("Band \(rec.battery.map { "\($0)%" } ?? "--")")
            }
            .font(.system(size: 15)).foregroundColor(Theme.dim)
            VStack(spacing: 0) {
                Text("Time").font(.system(size: 15)).foregroundColor(Theme.dim)
                Text(Theme.duration(now.timeIntervalSince1970 - Double(a.start) / 1000, showSeconds: true)).font(Theme.display(44)).monospacedDigit()
            }
            VStack(spacing: 6) {
                Text(rec.recording && hr > 0 ? "\(hr)" : "--").font(Theme.display(110)).monospacedDigit()
                Text(zone == 0 ? "Below zone 1" : "Zone \(zone)").font(.system(size: 16, weight: .semibold))
            }
            HRChart(samples: s, color: Theme.orange).frame(height: 90)
            ZoneBars(seconds: zones, bounds: bounds)
            HStack {
                Text("Average \(Metrics.average(s).map { "\($0)" } ?? "--")")
                Spacer()
                Text("Max \(Metrics.maxHR(s).map { "\($0)" } ?? "--")")
                Spacer()
                Text("Strain " + String(format: "%.1f", Metrics.strain(zoneSeconds: zones)))
            }
            .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
            Button("Finish activity") {
                acts.finish(a.id)
                finishedID = a.id
            }
            .buttonStyle(SolidButton(color: Theme.orange))
            Button("Discard activity") { confirmCancel = true }
                .font(.system(size: 15)).foregroundColor(Theme.dim).frame(minHeight: 44)
        }
        .foregroundColor(Theme.text)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .confirmationDialog("Discard this activity?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                acts.remove(a.id)
                dismiss()
            }
        } message: {
            Text("Your heart rate readings are kept. Only the activity label is removed.")
        }
        .task(id: a.id) {
            Recorder.shared.flushActive()
            let start = a.start
            loaded = await Task.detached(priority: .userInitiated) { Store.shared.readSamples(from: start, to: Store.nowMs()) }.value
        }
    }
}

struct ActivitySummaryView: View {
    let id: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var acts = ActivityStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var stats: ActivityStats?
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        if let a = acts.all.first(where: { $0.id == id }) {
            let end = a.end ?? Store.nowMs()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Theme.dayText.string(from: Date(timeIntervalSince1970: Double(a.start) / 1000))), \(Theme.clock(a.start)) to \(Theme.clock(end))")
                            .font(.system(size: 13)).foregroundColor(Theme.dim)
                        Text(a.type).font(Theme.display(30)).foregroundColor(Theme.text)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        Tile(title: "Strain", value: stats.map { String(format: "%.1f", $0.strain) } ?? "--")
                        Tile(title: "Average", value: stats?.avg.map { "\($0)" } ?? "--")
                        Tile(title: "Calories", value: stats?.calories.map { Int($0).formatted() } ?? "--")
                    }
                    Card {
                        Text("Heart rate").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                        HRChart(samples: stats?.samples ?? [], color: Theme.orange).frame(height: 110)
                        if let m = stats?.max { Text("Max \(m)").font(.system(size: 13)).foregroundColor(Theme.dim) }
                    }
                    Card {
                        Text("Time in zones").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                        ZoneBars(seconds: stats?.zoneSeconds ?? [Double](repeating: 0, count: 6), bounds: settings.value.zoneBounds)
                    }
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(ActivityStore.types, id: \.self) { t in
                                Button(t) { acts.update(id) { $0.type = t } }
                            }
                        } label: {
                            Text("Change activity")
                                .font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.text)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Theme.raised)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
                        }
                        Button("Edit times") { editing = true }.buttonStyle(TintButton(color: Theme.text))
                    }
                    Button("Delete activity") { confirmDelete = true }
                        .font(.system(size: 15)).foregroundColor(Theme.orange).frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .task(id: "\(a.start)-\(end)") {
                Recorder.shared.flushActive()
                let st = settings.value
                let s0 = a.start
                stats = await Task.detached(priority: .userInitiated) {
                    ActivityStats.make(Store.shared.readSamples(from: s0, to: end), settings: st, start: s0, end: end)
                }.value
            }
            .sheet(isPresented: $editing) { EditTimes(record: a) }
            .confirmationDialog("Delete this activity?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    acts.remove(id)
                    dismiss()
                }
            } message: {
                Text("Your heart rate readings are kept. Only the activity label is removed.")
            }
        } else {
            Text("This activity was deleted.").foregroundColor(Theme.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg.ignoresSafeArea())
        }
    }
}

struct EditTimes: View {
    let record: ActivityRecord
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var end = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Start", selection: $start)
                DatePicker("End", selection: $end, in: start...)
            }
            .navigationTitle("Edit times")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let s = Int64(start.timeIntervalSince1970 * 1000)
                        let e = Int64(end.timeIntervalSince1970 * 1000)
                        ActivityStore.shared.update(record.id) {
                            $0.start = s
                            $0.end = max(e, s + 60_000)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                start = Date(timeIntervalSince1970: Double(record.start) / 1000)
                end = Date(timeIntervalSince1970: Double(record.end ?? Store.nowMs()) / 1000)
            }
        }
        .presentationDetents([.medium])
    }
}
