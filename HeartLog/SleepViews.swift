import Charts
import SwiftUI

extension Theme {
    /// Green 67 and up, blue 34 to 66, orange below 34.
    static func level(_ value: Double?) -> Color {
        guard let v = value else { return line }
        switch SleepMath.level(v) {
        case .high: return green
        case .mid: return blue
        case .low: return orange
        }
    }

    static func minutes(_ m: Double) -> String {
        let total = Int(m.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static let shortDay: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEMMMd"); return f }()
    static let monthDay: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd"); return f }()
}

/// Loads a day's record off the main thread.
@MainActor
enum DayLoader {
    static func load(_ day: Date) async -> DayRecord? {
        Recorder.shared.flushActive()
        let s = SettingsStore.shared.value
        return await Task.detached(priority: .userInitiated) { DayEngine.shared.record(day, settings: s) }.value
    }
}

struct DayChevrons: View {
    let text: String
    let canGoForward: Bool
    let move: (Int) -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32)
            }
            .foregroundColor(Theme.dim)
            .accessibilityLabel("Previous")
            Text(text).font(.system(size: 13)).foregroundColor(Theme.dim)
            Button { move(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32)
            }
            .foregroundColor(canGoForward ? Theme.dim : Theme.track)
            .disabled(!canGoForward)
            .accessibilityLabel("Next")
        }
        .padding(.leading, -11)
    }
}

struct SleepView: View {
    @Binding var day: Date
    @State private var record: DayRecord?
    @State private var samples: [Sample] = []
    @State private var loaded = false
    @State private var adjusting = false
    @ObservedObject private var settings = SettingsStore.shared

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var nightOf: Date { Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        DayChevrons(text: "Night of \(Theme.shortDay.string(from: nightOf))", canGoForward: !isToday, move: move)
                        Text("Sleep").font(Theme.display(30)).foregroundColor(Theme.text)
                    }
                    if let r = record, let p = r.sleep {
                        scoreCard(r, p)
                        if !r.isWhoop { chartCard(p) }
                        components(r, p)
                        tiles(r, p)
                    } else if loaded {
                        Card {
                            Text("No sleep found for this night.").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                            Text("Sleep is found from a long stretch of low, steady heart rate. If you slept with the band on, set your bedtime and wake time below.")
                                .font(.system(size: 14)).foregroundColor(Theme.dim)
                        }
                    }
                    if loaded, record?.isWhoop != true {
                        Button("Adjust bedtime or wake time") { adjusting = true }.buttonStyle(TintButton(color: Theme.text))
                    }
                    Text(record?.isWhoop == true
                         ? "This night comes from your WHOOP history, so it shows WHOOP's own numbers."
                         : "Sleep stages aren't shown, because heart rate alone can't measure them reliably. Scores are estimates.")
                        .font(.system(size: 13)).foregroundColor(Theme.dim)
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
        .sheet(isPresented: $adjusting) {
            AdjustSleep(day: day, current: record?.sleep) { Task { await reload() } }
        }
    }

    private func reload() async {
        let d = day
        let r = await DayLoader.load(d)
        var s: [Sample] = []
        if let p = r?.sleep, r?.isWhoop == false {
            s = await Task.detached { Store.shared.readSamples(from: p.onset - 15 * 60_000, to: p.wake + 15 * 60_000) }.value
        }
        guard d == day else { return }
        record = r
        samples = s
        loaded = true
    }

    private func move(_ by: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        guard let d = Calendar.current.date(byAdding: .day, value: by, to: day), d <= today else { return }
        loaded = false
        day = d
    }

    private func scoreCard(_ r: DayRecord, _ p: SleepPeriod) -> some View {
        Card {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.isWhoop ? "Sleep score (WHOOP)" : "Sleep score (estimate)").font(.system(size: 13)).foregroundColor(Theme.dim)
                    Text(r.sleepScore.map { "\(Int($0.rounded()))" } ?? "--").font(Theme.display(60)).foregroundColor(Theme.level(r.sleepScore))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    (Text(Theme.minutes(p.asleepMin)).font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.text) + Text(" asleep"))
                    Text("\(Theme.clock(p.onset)) to \(Theme.clock(p.wake))")
                }
                .font(.system(size: 14)).foregroundColor(Theme.dim)
            }
        }
    }

    private func chartCard(_ p: SleepPeriod) -> some View {
        Card {
            Text("Overnight heart rate").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            HRChart(samples: samples, color: Theme.blue).frame(height: 120)
            HStack {
                Text("\(Theme.clock(p.onset)) asleep")
                Spacer()
                if let lo = p.lowestHR { Text("Lowest \(lo)") }
                Spacer()
                Text("\(Theme.clock(p.wake)) awake")
            }
            .font(.system(size: 12)).foregroundColor(Theme.dim)
        }
    }

    private func components(_ r: DayRecord, _ p: SleepPeriod) -> some View {
        let hours = r.sleepNeedMin.map { min(100, p.asleepMin / max(1, $0) * 100) }
        return Card {
            Text("What went into the score").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            part("Hours vs. needed\(r.sleepNeedMin.map { " (\(Theme.minutes($0)))" } ?? "")", hours)
            part("Consistency", r.consistency)
            part(r.isWhoop ? "Efficiency" : "Efficiency (rough)", p.efficiency)
        }
    }

    private func part(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(value.map { "\(Int($0.rounded()))%" } ?? "--").fontWeight(.semibold)
            }
            .font(.system(size: 14)).foregroundColor(Theme.text)
            Bar(fraction: (value ?? 0) / 100, color: Theme.level(value), height: 8)
        }
    }

    private func tiles(_ r: DayRecord, _ p: SleepPeriod) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            Tile(title: "Sleep debt", value: r.debtMin.map { Theme.minutes($0) } ?? "--")
            Tile(title: "Overnight HRV", value: r.hrv.map { "\(Int($0.rounded())) ms" } ?? "--")
            Tile(title: r.isWhoop ? "Resting heart rate" : "Lowest heart rate", value: (r.isWhoop ? r.rhr : p.lowestHR).map { "\($0)" } ?? "--")
            Tile(title: "Times awake", value: p.awakeEvents.map { "~\($0)" } ?? "--")
        }
    }
}

struct AdjustSleep: View {
    let day: Date
    let current: SleepPeriod?
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var onset = Date()
    @State private var wake = Date()
    private var key: String { DayEngine.shared.key(day) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Fell asleep", selection: $onset)
                    DatePicker("Woke up", selection: $wake)
                } footer: {
                    Text(wake > onset ? "\(Theme.minutes(wake.timeIntervalSince(onset) / 60)) in bed" : "Wake time must be after bedtime.")
                }
                if Overrides.all()[key] != nil {
                    Section {
                        Button("Go back to the detected times", role: .destructive) {
                            Overrides.set(key, nil)
                            done()
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Adjust sleep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Overrides.set(key, Overrides.Window(onset: Int64(onset.timeIntervalSince1970 * 1000), wake: Int64(wake.timeIntervalSince1970 * 1000)))
                        done()
                        dismiss()
                    }
                    .disabled(wake <= onset)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            let cal = Calendar.current
            if let p = current {
                onset = Date(timeIntervalSince1970: Double(p.onset) / 1000)
                wake = Date(timeIntervalSince1970: Double(p.wake) / 1000)
            } else {
                let start = cal.startOfDay(for: day)
                onset = cal.date(byAdding: .hour, value: -1, to: start) ?? start
                wake = cal.date(byAdding: .hour, value: 7, to: start) ?? start
            }
        }
    }
}

struct RecoveryView: View {
    let day: Date
    let record: DayRecord

    private var label: String {
        guard let r = record.recovery else { return "" }
        switch SleepMath.level(r) {
        case .high: return "Ready"
        case .mid: return "Moderate"
        case .low: return "Take it easy"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Theme.dayText.string(from: day)).font(.system(size: 13)).foregroundColor(Theme.dim)
                    Text("Recovery").font(Theme.display(30)).foregroundColor(Theme.text)
                }
                Card {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(record.isWhoop ? "Recovery (WHOOP)" : "Recovery (estimate)").font(.system(size: 13)).foregroundColor(Theme.dim)
                            Text(record.recovery.map { "\(Int($0.rounded()))%" } ?? "--").font(Theme.display(60)).foregroundColor(Theme.level(record.recovery))
                        }
                        Spacer()
                        if !label.isEmpty {
                            Text(label).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.level(record.recovery))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Theme.raised).clipShape(Capsule())
                        }
                    }
                    Bar(fraction: (record.recovery ?? 0) / 100, color: Theme.level(record.recovery))
                    HStack {
                        Text("Take it easy")
                        Spacer()
                        Text("Moderate")
                        Spacer()
                        Text("Ready")
                    }
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                Card {
                    Text("Compared with your last 30 days").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                    compare("Overnight HRV", record.hrv.map { "\(Int($0.rounded())) ms" }, record.usualHRV,
                            better: record.hrv.flatMap { h in record.usualHRV.map { h > $0 * 1.05 } })
                    Divider().overlay(Theme.track)
                    compare("Resting heart rate", record.rhr.map { "\($0)" }, record.usualRHR,
                            better: record.rhr.flatMap { h in record.usualRHR.map { Double(h) < $0 - 1 } })
                    Divider().overlay(Theme.track)
                    compare("Sleep score", record.sleepScore.map { "\(Int($0.rounded()))" }, record.usualSleep,
                            better: record.sleepScore.flatMap { h in record.usualSleep.map { h > $0 + 3 } })
                }
                Card {
                    Text(record.isWhoop
                         ? "This day comes from your WHOOP history, so it shows WHOOP's own score."
                         : "HRV counts most, then sleep. Resting heart rate moves with HRV, so it's shown for context. Higher HRV than usual pushes recovery up. Your 30-day usual includes your WHOOP history.")
                        .font(.system(size: 14)).foregroundColor(Color(hex: 0xC9D3CE)).lineSpacing(3)
                }
                Text("Green means a number is better than usual for you.").font(.system(size: 12)).foregroundColor(Theme.dim)
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private func compare(_ label: String, _ value: String?, _ usual: Double?, better: Bool?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ?? "--").fontWeight(.semibold).foregroundColor(better == true ? Theme.green : Theme.text).frame(width: 70, alignment: .trailing)
            Text(usual.map { "usually \(Int($0.rounded()))" } ?? "").font(.system(size: 13)).foregroundColor(Theme.dim).frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 15)).foregroundColor(Theme.text)
        .frame(minHeight: 40)
    }
}

// MARK: - Trends

struct TrendPoint: Identifiable {
    let id: String
    let date: Date
    let value: Double
    let app: Bool
    let segment: Int
}

struct TrendsView: View {
    enum Range: String, CaseIterable { case week = "Week", month = "Month", year = "Year" }
    @State private var range: Range = .month
    @State private var records: [DayRecord] = []
    @State private var steps: [String: StepsLog.Entry] = [:]
    @State private var loading = true

    private var days: Int { range == .week ? 7 : range == .month ? 30 : 365 }
    private var start: Date { Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date())) ?? Date() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Theme.monthDay.string(from: start)) to \(Theme.monthDay.string(from: Date()))").font(.system(size: 13)).foregroundColor(Theme.dim)
                        Text("Trends").font(Theme.display(30)).foregroundColor(Theme.text)
                    }
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 14) {
                        legend("WHOOP history", filled: false)
                        legend("Zdravlje", filled: true)
                        Text("Gaps: no data")
                    }
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
                    if loading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        chart("Recovery", Theme.green, unit: "%") { $0.recovery }
                        chart("Overnight HRV", Theme.blue, unit: " ms", usual: records.last?.usualHRV) { $0.hrv }
                        chart("Resting heart rate", Theme.orange, unit: "", usual: records.last?.usualRHR) { $0.rhr.map { Double($0) } }
                        chart("Sleep score", Theme.blue, unit: "") { $0.sleepScore }
                        chart("Strain", Theme.orange, unit: "", decimals: 1) { $0.strain }
                        chart("Hours slept", Theme.blue, unit: " h", decimals: 1) { $0.sleep.map { $0.asleepMin / 60 } }
                        stepsChart
                    }
                    Text("Faded lines are WHOOP history. Dots are days Zdravlje calculated from your band.")
                        .font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: range) { await reload() }
    }

    private func reload() async {
        loading = true
        Recorder.shared.flushActive()
        let s = SettingsStore.shared.value
        let from = start
        let list = await Task.detached(priority: .userInitiated) { DayEngine.shared.records(from: from, to: Date(), settings: s) }.value
        records = list
        steps = StepsLog.all()
        loading = false
    }

    private func legend(_ text: String, filled: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(filled ? Theme.text : Theme.line).frame(width: 8, height: 8)
            Text(text)
        }
    }

    private func points(_ value: (DayRecord) -> Double?) -> [TrendPoint] {
        let cal = Calendar.current
        var out: [TrendPoint] = []
        var segment = 0
        var lastDay: Date?
        for r in records {
            guard let v = value(r), let d = date(r.day) else { continue }
            if let l = lastDay, (cal.dateComponents([.day], from: l, to: d).day ?? 0) > 1 { segment += 1 }
            if let prev = out.last, prev.app != !r.isWhoop { segment += 1 }
            out.append(TrendPoint(id: r.day, date: d, value: v, app: !r.isWhoop, segment: segment))
            lastDay = d
        }
        return out
    }

    private func date(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    private func format(_ v: Double, _ decimals: Int) -> String {
        decimals == 0 ? "\(Int(v.rounded()))" : String(format: "%.\(decimals)f", v)
    }

    private func chart(_ title: String, _ color: Color, unit: String, decimals: Int = 0, usual: Double? = nil, _ value: (DayRecord) -> Double?) -> some View {
        let pts = points(value)
        let today = Calendar.current.startOfDay(for: Date())
        let latest = pts.last.flatMap { Calendar.current.isDate($0.date, inSameDayAs: today) ? $0 : nil }
        return TrendCard(title: title, color: color, points: pts, usual: usual, from: start,
                         summary: latest.map { "\(format($0.value, decimals))\(unit) today" + (usual.map { ", usually \(format($0, decimals))" } ?? "") }
                            ?? (pts.isEmpty ? "No data" : ""))
    }

    private var stepsChart: some View {
        let pts: [TrendPoint] = steps.compactMap { k, v in
            guard let d = date(k), d >= start else { return nil }
            return TrendPoint(id: k, date: d, value: Double(v.count), app: true, segment: 0)
        }.sorted { $0.date < $1.date }
        var seg = 0
        var withSegments: [TrendPoint] = []
        for (i, p) in pts.enumerated() {
            if i > 0, (Calendar.current.dateComponents([.day], from: pts[i - 1].date, to: p.date).day ?? 0) > 1 { seg += 1 }
            withSegments.append(TrendPoint(id: p.id, date: p.date, value: p.value, app: true, segment: seg))
        }
        let todayKey = StepsLog.key(Date())
        return TrendCard(title: "Steps", color: Theme.green, points: withSegments, usual: nil, from: start,
                         summary: steps[todayKey].map { "\($0.count.formatted()) today" } ?? (pts.isEmpty ? "From the steps Shortcut" : ""))
    }
}

struct TrendCard: View {
    let title: String
    let color: Color
    let points: [TrendPoint]
    let usual: Double?
    let from: Date
    let summary: String

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Spacer()
                Text(summary).font(.system(size: 13)).foregroundColor(Theme.dim)
            }
            if points.isEmpty {
                Text("Nothing in this range yet").font(.system(size: 13)).foregroundColor(Theme.dim).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Chart {
                    ForEach(points) { p in
                        LineMark(x: .value("Day", p.date), y: .value(title, p.value), series: .value("Segment", p.segment))
                            .foregroundStyle(color.opacity(p.app ? 1 : 0.55))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        if p.app || points.count == 1 {
                            PointMark(x: .value("Day", p.date), y: .value(title, p.value))
                                .foregroundStyle(color)
                                .symbolSize(points.count > 60 ? 12 : 30)
                        }
                    }
                    if let u = usual {
                        RuleMark(y: .value("Usual", u))
                            .foregroundStyle(Theme.line)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartXScale(domain: from...Date())
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
                .frame(height: 110)
                .accessibilityLabel("\(title) over this range")
            }
        }
    }
}
