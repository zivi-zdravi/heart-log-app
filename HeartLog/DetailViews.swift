import Charts
import SwiftUI

private let soft = Color(hex: 0xC9D3CE)

private func pageHeader(_ day: Date, _ title: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        Text(Theme.dayText.string(from: day)).font(.system(size: 13)).foregroundColor(Theme.dim)
        Text(title).font(Theme.display(30)).foregroundColor(Theme.text)
    }
}

private func cardTitle(_ text: String) -> some View {
    Text(text).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
}

private func footnote(_ text: String) -> some View {
    Text(text).font(.system(size: 12)).foregroundColor(Theme.dim)
}

private func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

private struct DayValue: Identifiable {
    let day: Date
    let value: Double
    var id: Date { day }
}

private struct DayBurn: Identifiable {
    let day: Date
    let burned: Double?
    let eaten: Double?
    var id: Date { day }
}

// MARK: - Today top card

struct RecoveryRing: View {
    let value: Double?
    var size: CGFloat = 120
    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 12)
            Circle().trim(from: 0, to: CGFloat(min(1, max(0, (value ?? 0) / 100))))
                .stroke(Theme.level(value), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(value.map { "\(Int($0.rounded()))%" } ?? "--").font(Theme.display(30)).foregroundColor(Theme.text)
                Text("recovery").font(.system(size: 12)).foregroundColor(Theme.dim)
            }
        }
        .frame(width: size - 12, height: size - 12)
        .padding(6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "Recovery \(Int($0.rounded())) percent" } ?? "Recovery not available")
    }
}

struct MiniScore: View {
    let title: String
    let value: String
    let fraction: Double?
    let color: Color
    let note: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .font(.system(size: 13)).foregroundColor(Theme.dim)
            Text(value).font(Theme.display(24)).foregroundColor(fraction == nil ? Theme.dim : Theme.text)
            Bar(fraction: fraction ?? 0, color: color, height: 6)
            if let note { Text(note).font(.system(size: 12)).foregroundColor(Theme.dim).lineLimit(1).minimumScaleFactor(0.8) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

// MARK: - HRV and resting heart rate

struct MetricDetailView: View {
    enum Kind { case hrv, rhr }
    let kind: Kind
    let day: Date

    @State private var record: DayRecord?
    @State private var history: [DayValue] = []
    @State private var range: ClosedRange<Double>?
    @State private var night: [DetailMath.Point] = []
    @State private var movers: [String] = []
    @State private var loaded = false

    private var title: String { kind == .hrv ? "HRV" : "Resting heart rate" }
    private var unit: String { kind == .hrv ? "ms" : "bpm" }
    private var color: Color { kind == .hrv ? Theme.blue : Theme.orange }

    private static func value(_ r: DayRecord, _ kind: Kind) -> Double? { kind == .hrv ? r.hrv : r.rhr.map(Double.init) }

    private var current: Double? { record.flatMap { Self.value($0, kind) } }

    private var sentence: String? {
        guard let v = current, let r = range else { return nil }
        if kind == .hrv {
            if v > r.upperBound { return "Above your usual, a good sign your body is rested." }
            if v < r.lowerBound { return "Below your usual. This often follows hard days, short sleep, alcohol or getting sick." }
            return "Within your usual. Higher HRV generally means your body is more rested."
        }
        if v > r.upperBound { return "Higher than usual. This often follows hard days, short sleep, alcohol or getting sick." }
        if v < r.lowerBound { return "Lower than usual, a good sign your body is rested." }
        return "Within your usual. A lower resting heart rate generally means your body is more rested."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pageHeader(day, title)
                Card(accent: color) {
                    Text(kind == .hrv ? "Last night" : "Lowest overnight").font(.system(size: 13)).foregroundColor(Theme.dim)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(current.map { "\(Int($0.rounded()))" } ?? "--").font(Theme.display(50)).foregroundColor(Theme.text)
                        Text(unit).font(.system(size: 16)).foregroundColor(Theme.dim)
                        Spacer()
                        if let r = range {
                            Text("usually \(Int(r.lowerBound.rounded())) to \(Int(r.upperBound.rounded()))")
                                .font(.system(size: 13)).foregroundColor(Theme.dim)
                        }
                    }
                    if let s = sentence { Text(s).font(.system(size: 14)).foregroundColor(soft) }
                    if record?.isWhoop == true { footnote("From your WHOOP history.") }
                }
                if night.count >= 3 {
                    Card(accent: color) {
                        cardTitle("Through the night")
                        Chart(night, id: \.t) { p in
                            LineMark(x: .value("Time", date(p.t)), y: .value(unit, p.value))
                                .foregroundStyle(color).interpolationMethod(.monotone)
                        }
                        .chartYScale(domain: TrendMath.domain(night.map(\.value), minSpan: kind == .hrv ? 20 : 10))
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
                        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
                        .frame(height: 140)
                        .accessibilityLabel("\(title) every 5 minutes while you slept")
                        footnote(kind == .hrv
                                 ? "Every 5 minutes while you slept. The number above is the middle value for the night."
                                 : "Average heart rate every 5 minutes while you slept. The number above is the lowest stretch.")
                    }
                }
                if history.count >= 2 {
                    Card(accent: color) {
                        HStack {
                            cardTitle("Last 30 nights")
                            Spacer()
                            if let w = DetailMath.trendWord(history.map(\.value), tolerance: kind == .hrv ? 2 : 1.5) {
                                Text("trend: \(w)").font(.system(size: 13)).foregroundColor(Theme.dim)
                            }
                        }
                        Chart {
                            if let r = range, let first = history.first?.day, let last = history.last?.day {
                                RectangleMark(xStart: .value("From", first), xEnd: .value("To", last),
                                              yStart: .value("Low", r.lowerBound), yEnd: .value("High", r.upperBound))
                                    .foregroundStyle(Theme.line.opacity(0.35))
                            }
                            ForEach(history) { p in
                                LineMark(x: .value("Night", p.day), y: .value(unit, p.value)).foregroundStyle(Theme.text)
                            }
                            if let last = history.last {
                                PointMark(x: .value("Night", last.day), y: .value(unit, last.value)).foregroundStyle(color)
                            }
                        }
                        .chartYScale(domain: TrendMath.domain(history.map(\.value) + [range?.lowerBound, range?.upperBound].compactMap { $0 },
                                                              minSpan: kind == .hrv ? 15 : 8))
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
                        .frame(height: 140)
                        if range != nil { footnote("Shaded: your usual range.") }
                    }
                }
                Card {
                    cardTitle("What tends to move yours")
                    if movers.isEmpty {
                        Text(loaded ? "Shows once there are enough nights to compare (at least 4 of each kind)." : "Looking through your nights...")
                            .font(.system(size: 14)).foregroundColor(soft)
                    } else {
                        ForEach(movers, id: \.self) { Text($0).font(.system(size: 14)).foregroundColor(soft) }
                    }
                    footnote("From your own nights over the last 30 days.")
                }
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task(id: day) { await load() }
    }

    private func load() async {
        Recorder.shared.flushActive()
        let d = day, k = kind
        let settings = SettingsStore.shared.value
        let result = await Task.detached(priority: .userInitiated) { () -> (DayRecord?, [(Date, Double)], ClosedRange<Double>?, [DetailMath.Point], [String]) in
            let cal = Calendar.current
            var records: [Date: DayRecord] = [:]
            for i in 0...31 {
                guard let x = cal.date(byAdding: .day, value: -i, to: d) else { continue }
                if let r = DayEngine.shared.record(x, settings: settings) { records[x] = r }
            }
            let rec = records[d]
            let days = records.keys.sorted().filter { $0 > (cal.date(byAdding: .day, value: -30, to: d) ?? d) }
            let hist = days.compactMap { x in records[x].flatMap { MetricDetailView.value($0, k) }.map { (x, $0) } }
            let before = hist.filter { $0.0 < d }.map(\.1)
            let usual = DetailMath.usualRange(before)
            var points: [DetailMath.Point] = []
            if let r = rec, r.source == "app", let p = r.sleep {
                let s = Store.shared.readSamples(from: p.onset, to: p.wake)
                points = k == .hrv ? DetailMath.hrvThroughNight(s) : DetailMath.heartRateThroughNight(s)
            }
            let nights = days.compactMap { x -> DetailMath.Night? in
                guard let r = records[x], let v = MetricDetailView.value(r, k) else { return nil }
                let prev = cal.date(byAdding: .day, value: -1, to: x).flatMap { records[$0]?.strain }
                return DetailMath.Night(value: v, prevStrain: prev, asleepMin: r.sleep?.asleepMin)
            }
            let moves = DetailMath.movers(nights, unit: k == .hrv ? "ms" : "bpm", minDiff: k == .hrv ? 3 : 2)
            return (rec, hist, usual, points, moves)
        }.value
        guard d == day else { return }
        record = result.0
        history = result.1.map { DayValue(day: $0.0, value: $0.1) }
        range = result.2
        night = result.3
        movers = result.4
        loaded = true
    }
}

// MARK: - Calories

struct CaloriesDetailView: View {
    let day: Date

    @ObservedObject private var meals = MealStore.shared
    @State private var total: Double?
    @State private var resting: Double?
    @State private var hourly: [Double] = []
    @State private var week: [DayBurn] = []
    @State private var goal: Int?
    @State private var bedtime: Double?
    @State private var noBody = false
    @State private var isWhoop = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var eaten: Double { meals.total(DayEngine.shared.key(day)).kcal }
    private var hasMeals: Bool { !meals.entries(DayEngine.shared.key(day)).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pageHeader(day, "Calories burned")
                Card(accent: Theme.orange) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(total.map { Int($0).formatted() } ?? "--").font(Theme.display(30)).foregroundColor(Theme.text)
                        Spacer()
                        Text(isWhoop ? "WHOOP" : isToday ? "so far today, estimate" : "estimate").font(.system(size: 13)).foregroundColor(Theme.dim)
                    }
                    if let t = total, let r = resting {
                        HStack(alignment: .top) {
                            split("Resting", Int(min(r, t)).formatted(), "just being alive")
                            split("Active", Int(max(0, t - r)).formatted(), "moving, from heart rate")
                        }
                        .padding(.top, 2)
                    }
                    if noBody { Text("Add your height, weight and age in Settings to estimate calories.").font(.system(size: 14)).foregroundColor(soft) }
                }
                if hourly.contains(where: { $0 > 0 }) {
                    Card(accent: Theme.orange) {
                        cardTitle("Hour by hour")
                        Chart(Array(hourly.enumerated()), id: \.offset) { h in
                            BarMark(x: .value("Hour", h.offset), y: .value("Calories", h.element)).foregroundStyle(Theme.orange)
                        }
                        .chartXScale(domain: 0...24)
                        .chartXAxis {
                            AxisMarks(values: [0, 12, 24]) { v in
                                AxisValueLabel { Text(["12 AM", "noon", "midnight"][(v.as(Int.self) ?? 0) / 12]) }
                            }
                        }
                        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
                        .frame(height: 130)
                        if let top = busiest { footnote("Your busiest hour was \(top).") }
                    }
                }
                if hasMeals || goal != nil {
                    Card {
                        cardTitle(isToday ? "Eaten vs burned, today" : "Eaten vs burned")
                        row("Eaten (Meals)", Int(eaten).formatted(), nil)
                        row(isToday ? "Burned so far" : "Burned", total.map { Int($0).formatted() } ?? "--", nil)
                        if isToday, let b = bedtime { row("Likely by bedtime", "about \(MealMath.round50(b).formatted())", nil) }
                        if let g = goal, hasMeals {
                            Text(eaten <= Double(g) ? "On track for your goal of \(g.formatted()) eaten."
                                 : "\(Int(eaten - Double(g)).formatted()) over your goal of \(g.formatted()).")
                                .font(.system(size: 14)).foregroundColor(soft)
                        }
                    }
                }
                if week.contains(where: { $0.burned != nil }) {
                    Card(accent: Theme.orange) {
                        HStack {
                            cardTitle("Last 7 days")
                            Spacer()
                            if let avg = TrendMath.mean(week.compactMap(\.burned)) {
                                Text("average \(Int(avg).formatted())").font(.system(size: 13)).foregroundColor(Theme.dim)
                            }
                        }
                        Chart {
                            ForEach(week) { d in
                                if let b = d.burned {
                                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Burned", b)).foregroundStyle(Theme.orange.opacity(0.8))
                                }
                            }
                            ForEach(week.filter { ($0.eaten ?? 0) > 0 }) { d in
                                LineMark(x: .value("Day", d.day, unit: .day), y: .value("Eaten", d.eaten ?? 0)).foregroundStyle(Theme.green)
                                PointMark(x: .value("Day", d.day, unit: .day), y: .value("Eaten", d.eaten ?? 0)).foregroundStyle(Theme.green)
                            }
                        }
                        .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
                        .frame(height: 140)
                        footnote("Bars: burned. Green line: eaten, on days you logged meals.")
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task(id: day) { await load() }
    }

    private var busiest: String? {
        guard let i = hourly.indices.max(by: { hourly[$0] < hourly[$1] }), hourly[i] > 0 else { return nil }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("ha")
        return f.string(from: day.addingTimeInterval(Double(i) * 3600))
    }

    private func split(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 14)).foregroundColor(Theme.dim)
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.text)
            Text(note).font(.system(size: 12)).foregroundColor(Theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String, _ note: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundColor(Theme.text)
            if let note { Text(note).font(.system(size: 13)).foregroundColor(Theme.dim) }
            Spacer()
            Text(value).fontWeight(.semibold).foregroundColor(Theme.text)
        }
        .font(.system(size: 15))
        .frame(minHeight: 32)
    }

    @MainActor private func load() async {
        Recorder.shared.flushActive()
        let d = day
        let settings = SettingsStore.shared.value
        let mealSettings = meals.settings
        let result = await Task.detached(priority: .userInitiated) { () -> (DayRecord?, [Double], Double?, [(Date, Double?)], Int) in
            let cal = Calendar.current
            let start = ms(d)
            let dayEnd = ms(cal.date(byAdding: .day, value: 1, to: d) ?? d)
            let now = min(Store.nowMs(), dayEnd)
            let rec = DayEngine.shared.record(d, settings: settings)
            var hours: [Double] = []
            var rest: Double?
            if let body = settings.body, rec?.isWhoop != true {
                let s = Store.shared.readDaySamples(from: start, to: now)
                if !s.isEmpty { hours = DetailMath.hourlyCalories(s, dayStart: start, now: now, body: body, bounds: settings.zoneBounds) }
                rest = Metrics.bmrPerMinute(body) * Double(now - start) / 60_000
            }
            let w: [(Date, Double?)] = (0..<7).reversed().compactMap { i in
                guard let x = cal.date(byAdding: .day, value: -i, to: d) else { return nil }
                return (x, DayEngine.shared.record(x, settings: settings)?.calories)
            }
            let g = MealStore.goal(settings: mealSettings, appSettings: settings).calories
            return (rec, hours, rest, w, g)
        }.value
        guard d == day else { return }
        isWhoop = result.0?.isWhoop == true
        total = result.0?.calories ?? (result.1.isEmpty ? nil : result.1.reduce(0, +))
        hourly = result.1
        resting = isWhoop ? nil : result.2
        noBody = settings.body == nil && total == nil
        week = result.3.map { DayBurn(day: $0.0, burned: $0.1, eaten: meals.entries(DayEngine.shared.key($0.0)).isEmpty ? nil : meals.total(DayEngine.shared.key($0.0)).kcal) }
        goal = mealSettings.setUp ? result.4 : nil
        if isToday, let t = total, let body = settings.body {
            let end = ms(Calendar.current.date(byAdding: .day, value: 1, to: d) ?? d)
            bedtime = DetailMath.likelyByBedtime(burned: t, now: Store.nowMs(), dayEnd: end, body: body)
        }
    }
}

// MARK: - Steps

/// Steps progress ring.
struct StepsRing: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 9)
            Circle().trim(from: 0, to: CGFloat(min(1, max(0, fraction))))
                .stroke(Theme.green, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.text)
        }
        .frame(width: 88, height: 88)
        .padding(4)
    }
}

/// The Steps card at the top of Activity. Opens the longer steps history.
struct StepsCard: View {
    /// The day shown; the week bars end on it.
    var day = Calendar.current.startOfDay(for: Date())
    @StateObject private var today = StepsProvider()
    @ObservedObject private var notify = NotifyStore.shared
    @State private var week: [Date: Int] = [:]

    private var goal: Int { max(1, notify.settings.stepGoalCount) }
    private var days: [Date] {
        let cal = Calendar.current
        let t = cal.startOfDay(for: day)
        return (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: t) }
    }

    var body: some View {
        NavigationLink { StepsHistoryView() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isToday ? "Steps today" : "Steps on " + Theme.weekday.string(from: day)).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.dim)
                    Spacer()
                    Text(today.fromBand ? "from your band" : today.note.hasPrefix("From Shortcut") ? "from your Shortcut" : "from your phone").font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                HStack(spacing: 14) {
                    StepsRing(fraction: Double(today.steps ?? 0) / Double(goal))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(today.steps.map { $0.formatted() } ?? "--").font(Theme.display(32)).foregroundColor(Theme.text)
                        Text("of your \(goal.formatted()) goal").font(.system(size: 14)).foregroundColor(Theme.dim)
                        if let s = today.steps { Text(DetailMath.stepsLine(steps: s, goal: goal)).font(.system(size: 13)).foregroundColor(soft) }
                    }
                }
                if !today.fromBand && !today.note.isEmpty && !today.note.hasPrefix("From Shortcut") { footnote(today.note) }
                if week.count >= 2 {
                    HStack {
                        Text("Last 7 days").font(.system(size: 13)).foregroundColor(Theme.dim)
                        Spacer()
                        if let avg = TrendMath.mean(week.values.map(Double.init)) {
                            Text("average \(Int(avg).formatted())").font(.system(size: 13)).foregroundColor(Theme.dim)
                        }
                    }
                    StepsBars(days: days, counts: week, goal: goal, label: .dateTime.weekday(.abbreviated), shortWeek: true)
                        .frame(height: 110)
                    footnote("Dashed line: your goal. Goal reached on \(days.filter { (week[$0] ?? 0) >= goal }.count) of 7 days.")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accentCard(Theme.green, radius: 16)
        }
        .buttonStyle(.plain)
        .task(id: day) { await load() }
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    @MainActor private func load() async {
        await today.load(day: day)
        let end = min(Calendar.current.date(byAdding: .day, value: 1, to: day) ?? Date(), Date())
        var w = await StepsProvider.daily(from: days.first ?? Date(), to: end)
        if let s = today.steps { w[day] = s }
        week = w
    }
}

struct StepsBars: View {
    let days: [Date]
    let counts: [Date: Int]
    let goal: Int
    let label: Date.FormatStyle
    var unit: Calendar.Component = .day
    /// The week view labels days Tu, W, Th ... and "Today".
    var shortWeek = false

    var body: some View {
        Chart {
            ForEach(days, id: \.self) { d in
                BarMark(x: .value("Day", d, unit: unit), y: .value("Steps", counts[d] ?? 0))
                    .foregroundStyle(Theme.blue)
            }
            RuleMark(y: .value("Goal", goal)).foregroundStyle(Theme.dim).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .chartXAxis {
            AxisMarks(values: days.count > 12 ? AxisMarkValues.automatic(desiredCount: 5) : AxisMarkValues.stride(by: unit)) { v in
                AxisValueLabel {
                    if shortWeek, let d = v.as(Date.self) { Text(Self.weekLabel(d)) } else if let d = v.as(Date.self) { Text(d, format: label) }
                }
            }
        }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
    }

    static func weekLabel(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        let names = ["Su", "M", "Tu", "W", "Th", "F", "Sa"]
        return names[Calendar.current.component(.weekday, from: d) - 1]
    }
}

struct StepsHistoryView: View {
    enum Span: String, CaseIterable { case month = "Month", year = "Year" }

    @ObservedObject private var notify = NotifyStore.shared
    @State private var span: Span = .month
    @State private var daily: [Date: Int] = [:]

    private var goal: Int { max(1, notify.settings.stepGoalCount) }
    private var cal: Calendar { Calendar.current }
    private var today: Date { cal.startOfDay(for: Date()) }

    private var monthDays: [Date] { (0..<30).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) } }

    /// The first day of each of the last 12 months.
    private var months: [Date] {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        return (0..<12).reversed().compactMap { cal.date(byAdding: .month, value: -$0, to: first) }
    }

    /// Daily average for each month, over days that have steps.
    private var monthAverages: [Date: Int] {
        var out: [Date: Int] = [:]
        for m in months {
            let v = daily.filter { cal.isDate($0.key, equalTo: m, toGranularity: .month) }.map(\.value)
            if !v.isEmpty { out[m] = v.reduce(0, +) / v.count }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Goal \(goal.formatted()) a day").font(.system(size: 13)).foregroundColor(Theme.dim)
                    Text("Steps").font(Theme.display(30)).foregroundColor(Theme.text)
                }
                Picker("Range", selection: $span) {
                    ForEach(Span.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Card(accent: Theme.green) {
                    if span == .month {
                        let have = monthDays.compactMap { daily[$0] }
                        HStack {
                            cardTitle("Last 30 days")
                            Spacer()
                            if let avg = TrendMath.mean(have.map(Double.init)) {
                                Text("average \(Int(avg).formatted())").font(.system(size: 13)).foregroundColor(Theme.dim)
                            }
                        }
                        StepsBars(days: monthDays, counts: daily, goal: goal, label: .dateTime.month(.abbreviated).day()).frame(height: 160)
                        footnote("Goal reached on \(have.filter { $0 >= goal }.count) of \(have.count) days with steps.")
                    } else {
                        let avgs = monthAverages
                        HStack {
                            cardTitle("Last 12 months")
                            Spacer()
                            Text("daily average").font(.system(size: 13)).foregroundColor(Theme.dim)
                        }
                        StepsBars(days: months, counts: avgs, goal: goal, label: .dateTime.month(.narrow), unit: .month).frame(height: 160)
                        footnote("Each bar is that month's average day.")
                    }
                }
                footnote("Steps come from your band on days it recorded, otherwise from your phone (Apple Health) or your steps Shortcut. The band keeps about 3 weeks. The goal is in Settings, Notifications.")
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { daily = await StepsProvider.daily(from: months.first ?? today, to: today) }
    }
}
