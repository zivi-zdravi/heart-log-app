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
    let openSleep: (Date) -> Void

    @ObservedObject private var rec = Recorder.shared
    @ObservedObject private var acts = ActivityStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var steps = StepsProvider()
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var summary = DaySummary()
    @State private var record: DayRecord?
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
                    if record?.isWhoop == true && !summary.hasData {
                        Text("From your WHOOP history.").font(.system(size: 13)).foregroundColor(Theme.dim)
                    } else if summary.hasData {
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
        .onAppear { Task { await reload() } }
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
        let r = await DayLoader.load(d)
        if d == day {
            summary = result
            record = r
        }
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
                DayChevrons(text: Theme.dayText.string(from: day), canGoForward: !isToday, move: move)
                Text(isToday ? "Today" : Theme.weekday.string(from: day)).font(Theme.display(30)).foregroundColor(Theme.text)
            }
            Spacer()
            NavigationLink { SettingsView() } label: {
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Image(systemName: batterySymbol).font(.system(size: 16)).foregroundColor(batteryColor)
                        Text(rec.battery.map { "\($0)%" } ?? "--").foregroundColor(Theme.text)
                    }
                    Image(systemName: "gearshape").font(.system(size: 18)).foregroundColor(Theme.dim)
                }
                .frame(minHeight: 32)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel("Band battery \(rec.battery.map { "\($0) percent" } ?? "unknown"). Open settings")
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
                Text("Close Zdravlje, connect your phone to your computer and run Sideloadly. Then reopen Zdravlje.").font(.system(size: 14)).foregroundColor(Theme.dim)
            }
        }
    }

    private var liveCard: some View {
        Card {
            HStack {
                Text("Heart rate now").font(.system(size: 13)).foregroundColor(Theme.dim)
                Spacer()
                if rec.recording {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.green).frame(width: 8, height: 8)
                        Text("Recording")
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.green)
                } else {
                    NavigationLink { SettingsView() } label: {
                        HStack(spacing: 6) {
                            Circle().stroke(Theme.orange, lineWidth: 1.5).frame(width: 8, height: 8)
                            Text("Not recording")
                        }
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.orange)
                    }
                }
            }
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

    private var batterySymbol: String {
        guard let b = rec.battery else { return "battery.0" }
        return b >= 88 ? "battery.100" : b >= 63 ? "battery.75" : b >= 38 ? "battery.50" : b >= 13 ? "battery.25" : "battery.0"
    }

    private var batteryColor: Color {
        guard let b = rec.battery else { return Theme.dim }
        return b <= settings.value.lowBattery ? Theme.orange : Theme.green
    }

    private var strainValue: Double? { record?.strain ?? (summary.hasData ? summary.strain : nil) }

    private var strainTarget: Double? { record?.recovery.map { SleepMath.strainTarget(recovery: $0) } }

    private var strainColor: Color {
        guard let s = strainValue, let t = strainTarget else { return Theme.blue }
        return s <= t ? Theme.green : s <= t + 2 ? Theme.blue : Theme.orange
    }

    private var strainNote: String? {
        guard let s = strainValue, let t = strainTarget else { return nil }
        let target = Int(t.rounded())
        if s <= t { return "In range for \(isToday ? "today's" : "this day's") recovery (up to \(target))" }
        if s <= t + 2 { return "Slightly over the target of \(target)" }
        return "Well past the target of \(target)"
    }

    private func score(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))" } ?? "--" }

    private var scores: some View {
        let r = record
        let whoop = r?.isWhoop == true
        return Card {
            VStack(spacing: 12) {
                Button { openSleep(day) } label: {
                    ScoreRow(label: whoop ? "Sleep score (WHOOP)" : "Sleep score (estimate)", value: score(r?.sleepScore),
                             fraction: r?.sleepScore.map { $0 / 100 }, color: Theme.level(r?.sleepScore))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Sleep")
                NavigationLink {
                    if let r { RecoveryView(day: day, record: r) }
                } label: {
                    ScoreRow(label: whoop ? "Recovery (WHOOP)" : "Recovery (estimate)", value: r?.recovery.map { "\(Int($0.rounded()))%" } ?? "--",
                             fraction: r?.recovery.map { $0 / 100 }, color: Theme.level(r?.recovery))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(r?.recovery == nil)
                VStack(alignment: .leading, spacing: 5) {
                    ScoreRow(label: whoop ? "Strain (WHOOP)" : "Strain (estimate)", value: strainValue.map { String(format: "%.1f of 21", $0) } ?? "--",
                             fraction: strainValue.map { $0 / 21 }, color: strainColor)
                    if let note = strainNote { Text(note).font(.system(size: 12)).foregroundColor(Theme.dim) }
                }
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
        let r = record
        let hrv = r?.hrv ?? summary.hrv
        let rhr = r?.rhr ?? summary.resting
        let cal = r?.calories ?? summary.calories
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            Tile(title: "HRV, overnight", value: hrv.map { "\(Int($0.rounded())) ms" } ?? "--", note: r?.usualHRV.map { "Usually \(Int($0.rounded()))" })
            Tile(title: "Resting heart rate", value: rhr.map { "\($0)" } ?? "--", note: r?.usualRHR.map { "Usually \(Int($0.rounded()))" })
            Tile(title: "Steps (iPhone)", value: steps.steps.map { $0.formatted() } ?? "--", note: steps.note.isEmpty ? nil : steps.note)
            Tile(title: "Calories burned", value: cal.map { Int($0).formatted() } ?? "--",
                 note: whoopOr(settings.value.body == nil && cal == nil ? "Add your details in Settings" : "Estimate"))
        }
    }

    private func whoopOr(_ note: String) -> String { record?.isWhoop == true ? "WHOOP" : note }

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
