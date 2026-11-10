import Combine
import SwiftUI

struct DaySummary {
    var hasData = false
    var strain = 0.0
    var hrv: Double?
    var resting: Int?
    var calories: Double?
    var coverage = 0.0
    var suggestions: [Metrics.Span] = []

    static func compute(day: Date, settings: AppSettings, activities: [ActivityRecord]) -> DaySummary {
        let start = Int64(day.timeIntervalSince1970 * 1000)
        let dayEnd = Int64((Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day).timeIntervalSince1970 * 1000)
        let now = Store.nowMs()
        let end = min(dayEnd, now)
        guard end > start else { return DaySummary() }
        let samples = Store.shared.readSamples(from: start, to: end)
        var s = DaySummary()
        s.hasData = !samples.isEmpty
        guard s.hasData else { return s }
        let bounds = settings.zoneBounds
        let zones = Metrics.zoneSeconds(samples, bounds)
        s.strain = Metrics.strain(zoneSeconds: zones)
        let hour: Int64 = 3_600_000
        s.hrv = Metrics.hrv(samples.filter { $0.t >= start + 2 * hour && $0.t < start + 6 * hour })
        s.resting = Metrics.restingHR(samples.filter { $0.t < start + 8 * hour })
        s.coverage = zones.reduce(0, +) * 1000 / Double(end - start)
        if let body = settings.body {
            s.calories = Metrics.calories(samples, body: body, bounds: bounds, elapsedMinutes: Double(end - start) / 60_000)
        }
        let taken = activities.map { (start: $0.start, end: $0.end ?? now) }
        s.suggestions = Metrics.detectActivities(samples, threshold: bounds[0]).filter { span in
            span.end < now - 3 * 60_000 && !taken.contains { span.start < $0.end && $0.start < span.end }
        }
        return s
    }
}

struct TodayView: View {
    let openActivity: () -> Void
    let openMeals: () -> Void

    @ObservedObject private var rec = Recorder.shared
    @ObservedObject private var acts = ActivityStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var steps = StepsProvider()
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var summary = DaySummary()
    private let refresh = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if isToday {
                        alerts
                        liveCard
                    }
                    scores
                    ForEach(summary.suggestions, id: \.self) { suggestion($0) }
                    tiles
                    dayActivities
                    if summary.hasData {
                        Text("Band recorded \(Int(summary.coverage * 100))% of \(isToday ? "today so far" : "this day").")
                            .font(.system(size: 13)).foregroundColor(Theme.dim)
                    } else {
                        Text("No band recordings for this day.").font(.system(size: 13)).foregroundColor(Theme.dim)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
                guard abs(v.translation.width) > 60, abs(v.translation.width) > abs(v.translation.height) * 2 else { return }
                move(v.translation.width > 0 ? -1 : 1)
            })
        }
        .task(id: day) { await reload() }
        .onReceive(refresh) { _ in
            if isToday { Task { await reload() } }
        }
        .onReceive(acts.$all.dropFirst()) { _ in Task { await reload() } }
    }

    private func reload() async {
        Recorder.shared.flushActive()
        let d = day
        let st = settings.value
        let list = acts.all
        let result = await Task.detached(priority: .userInitiated) {
            DaySummary.compute(day: d, settings: st, activities: list)
        }.value
        if d == day { summary = result }
        await steps.load(day: d)
    }

    private func move(_ by: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        guard let d = Calendar.current.date(byAdding: .day, value: by, to: day), d <= today else { return }
        day = d
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Button { move(-1) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32)
                    }
                    .foregroundColor(Theme.dim)
                    .accessibilityLabel("Previous day")
                    Text(Theme.dayText.string(from: day)).font(.system(size: 13)).foregroundColor(Theme.dim)
                    Button { move(1) } label: {
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32)
                    }
                    .foregroundColor(isToday ? Theme.track : Theme.dim)
                    .disabled(isToday)
                    .accessibilityLabel("Next day")
                }
                .padding(.leading, -11)
                Text(isToday ? "Today" : Theme.weekday.string(from: day)).font(Theme.display(30)).foregroundColor(Theme.text)
            }
            Spacer()
            NavigationLink { SettingsView() } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Band \(rec.battery.map { "\($0)%" } ?? "--")").foregroundColor(Theme.text)
                    Text(rec.recording ? "Recording" : "Not recording").foregroundColor(rec.recording ? Theme.green : Theme.orange)
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel("Band and settings")
        }
    }

    @ViewBuilder private var alerts: some View {
        if let b = rec.battery, b <= settings.value.lowBattery {
            Card { Text("Band battery is at \(b)%. Charge it soon.").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.orange) }
        }
        if let expiry = Signing.expiry, expiry.timeIntervalSinceNow < 2 * 86_400 {
            Card {
                Text(expiry.timeIntervalSinceNow > 0 ? "App needs re-signing by \(expiry.formatted(date: .abbreviated, time: .shortened))" : "App signing has expired")
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.orange)
                Text("Connect your phone to your computer and run Sideloadly.").font(.system(size: 14)).foregroundColor(Theme.dim)
            }
        }
    }

    private var liveCard: some View {
        Card {
            Text("Heart rate now").font(.system(size: 13)).foregroundColor(Theme.dim)
            Text(rec.recording && rec.bpm > 0 ? "\(rec.bpm)" : "--").font(Theme.display(50)).foregroundColor(Theme.text)
            HStack(spacing: 10) {
                Button(acts.current == nil ? "Start activity" : "Return to activity") {
                    acts.pendingStart = true
                    openActivity()
                }
                .buttonStyle(TintButton(color: Theme.orange))
                Button("Log a meal") { openMeals() }
                    .buttonStyle(TintButton(color: Theme.green))
            }
            .padding(.top, 4)
        }
    }

    private var scores: some View {
        Card {
            VStack(spacing: 12) {
                ScoreRow(label: "Sleep score (estimate)", value: "Coming soon", fraction: nil, color: Theme.blue)
                ScoreRow(label: "Recovery (estimate)", value: "Coming soon", fraction: nil, color: Theme.green)
                ScoreRow(label: "Strain (estimate)", value: summary.hasData ? String(format: "%.1f of 21", summary.strain) : "--",
                         fraction: summary.hasData ? summary.strain / 21 : nil, color: Theme.orange)
            }
        }
    }

    private func suggestion(_ span: Metrics.Span) -> some View {
        Card {
            Text("Looks like an activity, \(Theme.clock(span.start)) to \(Theme.clock(span.end))")
                .font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            HStack(spacing: 10) {
                Button("Save it") { acts.add(type: "Activity", start: span.start, end: span.end) }
                    .buttonStyle(TintButton(color: Theme.green))
                Button("Not an activity") { acts.add(type: "Dismissed", start: span.start, end: span.end, dismissed: true) }
                    .buttonStyle(TintButton(color: Theme.text))
            }
            .padding(.top, 2)
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            Tile(title: "HRV, overnight", value: summary.hrv.map { "\(Int($0.rounded())) ms" } ?? "--", note: summary.hrv == nil ? "Needs 2 to 6 a.m." : nil)
            Tile(title: "Resting heart rate", value: summary.resting.map { "\($0)" } ?? "--")
            Tile(title: "Steps (iPhone)", value: steps.steps.map { $0.formatted() } ?? "--", note: steps.note.isEmpty ? nil : steps.note)
            Tile(title: "Calories burned", value: summary.calories.map { Int($0).formatted() } ?? "--",
                 note: settings.value.body == nil ? "Add your details in Settings" : "Estimate")
        }
    }

    @ViewBuilder private var dayActivities: some View {
        let start = Int64(day.timeIntervalSince1970 * 1000)
        let end = start + 86_400_000
        let list = acts.saved.filter { $0.start >= start && $0.start < end }
        if !list.isEmpty {
            Card {
                Text("Activities").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                ForEach(list) { a in
                    NavigationLink { ActivitySummaryView(id: a.id) } label: { ActivityRow(record: a) }
                }
            }
        }
    }
}
