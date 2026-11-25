import Charts
import SwiftUI

/// Strain for one day, worked out from the recorded heart rate.
struct StrainDay {
    var strain = 0.0
    var line: [StrainMath.Point] = []
    var zoneSeconds = [Double](repeating: 0, count: 6)
    var bounds: [Int] = []
    var target: Double?
    var start: Int64 = 0
    var end: Int64 = 0
    var activities: [(name: String, when: String, strain: Double)] = []
    var rest: Double?
    var usual: (Double, Double)?

    static func load(_ day: Date) async -> StrainDay {
        Recorder.shared.flushActive()
        let settings = SettingsStore.shared.value
        let acts = ActivityStore.shared.saved
        return await Task.detached(priority: .userInitiated) {
            let cal = Calendar.current
            let start = Int64(day.timeIntervalSince1970 * 1000)
            let dayEnd = Int64((cal.date(byAdding: .day, value: 1, to: day) ?? day).timeIntervalSince1970 * 1000)
            let end = min(dayEnd, Store.nowMs())
            var out = StrainDay()
            out.start = start
            out.end = max(end, start)
            out.bounds = settings.zoneBounds
            let rec = DayEngine.shared.record(day, settings: settings)
            out.target = rec?.recovery.map { SleepMath.strainTarget(recovery: $0) }
            guard end > start else { return out }
            let s = Store.shared.readDaySamples(from: start, to: end)
            out.zoneSeconds = Metrics.zoneSeconds(s, out.bounds)
            out.strain = Metrics.strain(zoneSeconds: out.zoneSeconds)
            out.line = StrainMath.timeline(s, bounds: out.bounds, from: start, to: end)
            let mine = acts.filter { $0.start >= start && $0.start < dayEnd && $0.dismissed != true }
            var outside = s
            for a in mine {
                let aEnd = a.end ?? end
                let inside = s.filter { $0.t >= a.start && $0.t <= aEnd }
                outside.removeAll { $0.t >= a.start && $0.t <= aEnd }
                let st = Metrics.strain(zoneSeconds: Metrics.zoneSeconds(inside, out.bounds))
                out.activities.append((a.type, "\(Theme.clock(a.start)) to \(Theme.clock(aEnd))", st))
            }
            if !mine.isEmpty { out.rest = Metrics.strain(zoneSeconds: Metrics.zoneSeconds(outside, out.bounds)) }
            let from = cal.date(byAdding: .day, value: -30, to: day) ?? day
            let to = cal.date(byAdding: .day, value: -1, to: day) ?? day
            let past = DayEngine.shared.records(from: from, to: to, settings: settings).compactMap(\.strain).sorted()
            if past.count >= 5 { out.usual = (past[past.count / 4], past[(past.count * 3) / 4]) }
            return out
        }.value
    }
}

/// Strain so far, climbing through the day, against today's range.
struct StrainLine: View {
    let day: StrainDay
    var height: CGFloat = 150

    private var axisStart: Date {
        let d = Date(timeIntervalSince1970: Double(day.start) / 1000)
        return Calendar.current.date(byAdding: .hour, value: 6, to: d) ?? d
    }
    private var axisEnd: Date {
        let d = Date(timeIntervalSince1970: Double(day.start) / 1000)
        return Calendar.current.date(byAdding: .hour, value: 22, to: d) ?? d
    }

    var body: some View {
        Chart {
            if let t = day.target {
                RectangleMark(xStart: .value("From", axisStart), xEnd: .value("To", axisEnd), yStart: .value("Low", 0), yEnd: .value("Range", t))
                    .foregroundStyle(Theme.green.opacity(0.08))
                RuleMark(y: .value("Range", t)).foregroundStyle(Theme.green.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            ForEach(day.line.filter { Date(timeIntervalSince1970: Double($0.t) / 1000) >= axisStart }, id: \.t) { p in
                LineMark(x: .value("Time", Date(timeIntervalSince1970: Double(p.t) / 1000)), y: .value("Strain", p.strain))
                    .foregroundStyle(Theme.orange).lineStyle(StrokeStyle(lineWidth: 2.5))
            }
        }
        .chartXScale(domain: axisStart...axisEnd)
        .chartYScale(domain: 0...max(max(day.target ?? 10, day.strain) + 2, 6))
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
        .frame(height: height)
    }
}

private func rangeText(_ day: StrainDay, today: Bool) -> String? {
    guard let t = day.target else { return nil }
    let target = Int(t.rounded())
    if day.strain <= t { return "In range for \(today ? "today's" : "this day's") recovery (up to \(target))" }
    if day.strain <= t + 2 { return "Slightly over the target of \(target)" }
    return "Well past the target of \(target)"
}

/// The card on Activity, under Steps.
struct StrainCard: View {
    let day: StrainDay
    let open: () -> Void

    private var isToday: Bool { Calendar.current.isDateInToday(Date(timeIntervalSince1970: Double(day.start) / 1000)) }

    private var early: Bool {
        isToday && Calendar.current.component(.hour, from: Date()) < 9 && day.strain < 3
    }

    var body: some View {
        Button(action: open) {
            Card(accent: Theme.orange) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Strain", systemImage: "chart.line.uptrend.xyaxis").labelStyle(AccentLabel(color: Theme.orange))
                        .font(.system(size: 13)).foregroundColor(Theme.dim)
                    Spacer()
                    Text(String(format: "%.1f", day.strain)).font(.system(size: 20, weight: .semibold)).foregroundColor(Theme.text)
                    Text("of 21").font(.system(size: 12)).foregroundColor(Theme.dim)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.dim)
                }
                StrainLine(day: day, height: 90)
                Text(early ? "Your strain builds through the day." : rangeText(day, today: isToday) ?? "From your heart rate through the day.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Strain")
    }
}

/// The card on Activity, under Strain.
struct CaloriesCard: View {
    let day: Date
    let open: () -> Void
    @State private var total: Double?
    @State private var resting: Double?

    var body: some View {
        Button(action: open) {
            Card(accent: Theme.orange) {
                HStack {
                    Label("Calories burned", systemImage: "flame").labelStyle(AccentLabel(color: Theme.orange))
                        .font(.system(size: 13)).foregroundColor(Theme.dim)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.dim)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(total.map { Int($0).formatted() } ?? "--").font(Theme.display(26)).foregroundColor(Theme.text)
                    Text(Calendar.current.isDateInToday(day) ? "so far today" : "on " + Theme.weekday.string(from: day)).font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                if let t = total, let r = resting {
                    HStack(spacing: 16) {
                        (Text("Resting ") + Text(Int(min(r, t)).formatted()).fontWeight(.semibold).foregroundColor(Theme.text))
                        (Text("Active ") + Text(Int(max(0, t - r)).formatted()).fontWeight(.semibold).foregroundColor(Theme.text))
                    }
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
                } else if SettingsStore.shared.value.body == nil {
                    Text("Add your details in Settings to estimate calories.").font(.system(size: 12)).foregroundColor(Theme.dim)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Calories burned")
        .task(id: day) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in Task { await load() } }
    }

    @MainActor private func load() async {
        Recorder.shared.flushActive()
        let d = day
        let settings = SettingsStore.shared.value
        let r = await Task.detached(priority: .userInitiated) { () -> (Double?, Double?) in
            let start = Int64(d.timeIntervalSince1970 * 1000)
            let now = Store.nowMs()
            let rec = DayEngine.shared.record(d, settings: settings)
            var rest: Double?
            if let body = settings.body, rec?.isWhoop != true { rest = Metrics.bmrPerMinute(body) * Double(now - start) / 60_000 }
            return (rec?.calories, rest)
        }.value
        total = r.0
        resting = r.1
    }
}

/// Strain: lives in Activity.
struct StrainDetailView: View {
    let day: Date
    @State private var data = StrainDay()
    @State private var loaded = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private let zoneColors: [Color] = [Theme.blue, Theme.green, Color(hex: 0xE8C979), Theme.orange, Color(hex: 0xE88F8F)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Theme.dayText.string(from: day)).font(.system(size: 13)).foregroundColor(Theme.dim)
                    Text("Strain").font(Theme.display(30)).foregroundColor(Theme.text)
                }
                Card(accent: Theme.orange) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(loaded ? String(format: "%.1f", data.strain) : "--").font(Theme.display(44)).foregroundColor(Theme.text)
                        Text(isToday ? "of 21, so far today" : "of 21").font(.system(size: 14)).foregroundColor(Theme.dim)
                    }
                    if let r = rangeText(data, today: isToday) {
                        Text(r).font(.system(size: 14)).foregroundColor(data.strain <= (data.target ?? 21) ? Theme.green : Theme.orange)
                    }
                }
                Card(accent: Theme.orange) {
                    Text("Through the day").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                    StrainLine(day: data)
                    Text("Steep parts are when your heart rate was up. The shaded band is \(isToday ? "today's" : "the day's") range.")
                        .font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                Card(accent: Theme.orange) {
                    Text("Time in each zone").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                    let ranges = StrainMath.zoneRanges(data.bounds)
                    ForEach((1...5).reversed(), id: \.self) { z in
                        HStack {
                            Circle().fill(zoneColors[z - 1]).frame(width: 8, height: 8)
                            Text("Zone \(z)").foregroundColor(Theme.text)
                            Text(z - 1 < ranges.count ? ranges[z - 1] : "").foregroundColor(Theme.dim)
                            Spacer()
                            Text("\(Int((data.zoneSeconds[z] / 60).rounded())) min").fontWeight(.semibold).foregroundColor(Theme.text)
                            Text("× \(Int(Metrics.zoneWeights[z]))").foregroundColor(Theme.dim).frame(minWidth: 30, alignment: .trailing)
                        }
                        .font(.system(size: 14)).frame(minHeight: 26)
                    }
                    Text("Minutes times points add up to \(Int(StrainMath.load(data.zoneSeconds).rounded())) points, squeezed onto the 0 to 21 scale. Below \(data.bounds.first ?? 0) beats a minute counts nothing. Zones come from Settings, Heart rate zones.")
                        .font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                if !data.activities.isEmpty {
                    Card(accent: Theme.orange) {
                        Text("What added the most").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                        ForEach(Array(data.activities.sorted { $0.strain > $1.strain }.enumerated()), id: \.offset) { _, a in
                            HStack {
                                Text("\(a.name), \(a.when)").foregroundColor(Theme.text)
                                Spacer()
                                Text(String(format: "%.1f", a.strain)).fontWeight(.semibold).foregroundColor(Theme.text)
                            }
                            .font(.system(size: 14))
                        }
                        if let r = data.rest {
                            HStack {
                                Text("Everything else").foregroundColor(Theme.text)
                                Spacer()
                                Text(String(format: "%.1f", r)).fontWeight(.semibold).foregroundColor(Theme.text)
                            }
                            .font(.system(size: 14))
                        }
                        Text("Each on its own scale, so they don't add up to the day's total.").font(.system(size: 12)).foregroundColor(Theme.dim)
                    }
                }
                if let u = data.usual {
                    Card(accent: Theme.orange) {
                        Text("Against your usual").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                        Text("Your whole days usually end between \(String(format: "%.1f", u.0)) and \(String(format: "%.1f", u.1)) (last 30 days).")
                            .font(.system(size: 14)).foregroundColor(Theme.dim)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task(id: day) {
            data = await StrainDay.load(day)
            loaded = true
        }
    }
}
