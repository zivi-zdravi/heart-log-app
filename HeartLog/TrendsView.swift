import Charts
import SwiftUI

enum TrendRange: String, CaseIterable { case week = "Week", month = "Month", year = "Year" }

struct TrendMetric {
    enum WeekStyle { case bars, line }
    let title: String
    let color: Color
    var unit = ""
    var decimals = 0
    var colorize = false
    var fixed: ClosedRange<Double>? = nil
    var minSpan: Double = 10
    var lowerIsBetter = false
    var weekStyle: WeekStyle = .bars
    var night = false
}

private func keyDate(_ key: String) -> Date? {
    let p = key.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
}

private let fullWeekday: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEE"); return f }()
private let monthYear: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMyyyy"); return f }()
private let monthDayF: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd"); return f }()
private let dayOnly: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d"); return f }()
private let yearOnly: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("yyyy"); return f }()

struct TrendsView: View {
    @State private var range: TrendRange = .month
    @State private var records: [DayRecord] = []
    @State private var steps: [String: StepsLog.Entry] = [:]
    @State private var eaten: [String: Double] = [:]
    @State private var goal: Int?
    @State private var loading = true

    private var cal: Calendar { Calendar.current }
    private var today: Date { cal.startOfDay(for: Date()) }
    private var days: Int { range == .week ? 7 : range == .month ? 30 : 365 }
    private var start: Date { cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today }

    private var rangeText: String {
        switch range {
        case .year:
            return "\(monthYear.string(from: start)) to \(monthYear.string(from: today)), weekly averages"
        case .month, .week:
            let sameYear = cal.component(.year, from: start) == cal.component(.year, from: today)
            let sameMonth = sameYear && cal.component(.month, from: start) == cal.component(.month, from: today)
            let a = monthDayF.string(from: start) + (sameYear ? "" : ", \(yearOnly.string(from: start))")
            let b = sameMonth ? dayOnly.string(from: today) : monthDayF.string(from: today)
            return "\(a) to \(b), \(yearOnly.string(from: today))"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(rangeText).font(.system(size: 13)).foregroundColor(Theme.dim)
                        Text("Trends").font(Theme.display(30)).foregroundColor(Theme.text)
                    }
                    Picker("Range", selection: $range) {
                        ForEach(TrendRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if loading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        chart(TrendMetric(title: "Recovery", color: Theme.green, unit: "%", colorize: true, fixed: 0...100)) { $0.recovery }
                        chart(TrendMetric(title: "Overnight HRV", color: Theme.blue, unit: " ms", minSpan: 15, weekStyle: .line, night: true),
                              usual: records.last?.usualHRV) { $0.hrv }
                        chart(TrendMetric(title: "Resting heart rate", color: Theme.orange, minSpan: 10, lowerIsBetter: true, weekStyle: .line, night: true),
                              usual: records.last?.usualRHR) { $0.rhr.map { Double($0) } }
                        chart(TrendMetric(title: "Sleep score", color: Theme.blue, colorize: true, fixed: 0...100, night: true)) { $0.sleepScore }
                        CaloriesTrend(range: range, start: start, today: today, burned: values { $0.calories }, eaten: eatenValues, goal: goal)
                        chart(TrendMetric(title: "Hours slept", color: Theme.blue, unit: " h", decimals: 1, minSpan: 3, night: true)) { $0.sleep.map { $0.asleepMin / 60 } }
                        chart(TrendMetric(title: "Strain", color: Theme.orange, decimals: 1, minSpan: 6)) { $0.strain }
                        TrendChart(metric: TrendMetric(title: "Steps", color: Theme.green, minSpan: 3000), range: range, start: start, today: today,
                                   values: stepValues, usual: nil)
                    }
                    Text("Faded marks are WHOOP history. Bright marks are days Zdravlje calculated from your band.")
                        .font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: range) { await reload() }
    }

    private func reload() async {
        loading = records.isEmpty
        Recorder.shared.flushActive()
        let s = SettingsStore.shared.value
        let from = start
        let list = await Task.detached(priority: .userInitiated) { DayEngine.shared.records(from: from, to: Date(), settings: s) }.value
        records = list
        steps = StepsLog.all()
        var e: [String: Double] = [:]
        for entry in MealStore.shared.data.entries { e[entry.day, default: 0] += entry.nutrients.kcal }
        eaten = e
        if MealStore.shared.settings.setUp {
            let g = await GoalLoader.load()
            goal = g.calories
        } else {
            goal = nil
        }
        loading = false
    }

    private func values(_ v: (DayRecord) -> Double?) -> [TrendValue] {
        records.compactMap { r in
            guard let x = v(r), let d = keyDate(r.day), d >= start else { return nil }
            return TrendValue(date: d, value: x, app: !r.isWhoop)
        }
    }

    private var stepValues: [TrendValue] {
        steps.compactMap { k, e in keyDate(k).flatMap { $0 >= start ? TrendValue(date: $0, value: Double(e.count), app: true) : nil } }
            .sorted { $0.date < $1.date }
    }

    private var eatenValues: [TrendValue] {
        eaten.compactMap { k, v in keyDate(k).flatMap { $0 >= start && v > 0 ? TrendValue(date: $0, value: v, app: true) : nil } }
            .sorted { $0.date < $1.date }
    }

    private func chart(_ m: TrendMetric, usual: Double? = nil, _ value: (DayRecord) -> Double?) -> some View {
        TrendChart(metric: m, range: range, start: start, today: today, values: values(value), usual: usual)
    }
}

private func format(_ v: Double, _ m: TrendMetric) -> String {
    let n = m.decimals == 0 ? Int(v.rounded()).formatted() : String(format: "%.\(m.decimals)f", v)
    return n + m.unit
}

struct TrendChart: View {
    let metric: TrendMetric
    let range: TrendRange
    let start: Date
    let today: Date
    let values: [TrendValue]
    let usual: Double?

    private var cal: Calendar { Calendar.current }
    private func color(_ v: Double) -> Color { metric.colorize ? Theme.level(v) : metric.color }

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(metric.title).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Spacer()
                Text(headline).font(.system(size: 13)).foregroundColor(Theme.dim).multilineTextAlignment(.trailing)
            }
            if !detail.isEmpty { Text(detail).font(.system(size: 13)).foregroundColor(Color(hex: 0xC9D3CE)) }
            if values.isEmpty {
                Text("Nothing in this range yet").font(.system(size: 13)).foregroundColor(Theme.dim).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                plot.frame(height: 130).accessibilityLabel("\(metric.title), \(headline). \(detail)")
                legend
            }
        }
    }

    // MARK: Words

    private var full: [TrendValue] { values.filter { $0.date < today || metric.night } }

    private var headline: String {
        guard !values.isEmpty else { return "No data" }
        switch range {
        case .year:
            return TrendMath.mean(full.map(\.value)).map { "Year average \(format($0, metric))" } ?? ""
        case .month:
            return TrendMath.trailing(values, calendar: cal).last.map { "7-day average \(format($0.value, metric))" } ?? ""
        case .week:
            let avg = TrendMath.mean(full.map(\.value)).map { "Average \(format($0, metric))" } ?? ""
            return usual.map { avg + ", usually \(format($0, metric))" } ?? avg
        }
    }

    private var detail: String {
        guard !values.isEmpty else { return "" }
        let tol = metric.decimals > 0 ? 0.2 : max(1, metric.minSpan / 20)
        switch range {
        case .year:
            let d30 = cal.date(byAdding: .day, value: -30, to: today) ?? today
            let d60 = cal.date(byAdding: .day, value: -60, to: today) ?? today
            let recent = full.filter { $0.date >= d30 }.map(\.value)
            let before = full.filter { $0.date >= d60 && $0.date < d30 }.map(\.value)
            var out = ""
            if recent.count >= 5, before.count >= 5, let a = TrendMath.mean(recent), let b = TrendMath.mean(before) {
                out = "Last 30 days: \(format(a, metric)), \(TrendMath.change(a, b, tolerance: tol)) \(format(b, metric)) the 30 days before."
            }
            if metric.lowerIsBetter { out += (out.isEmpty ? "" : " ") + "Lower is better here." }
            return out
        case .month:
            let t = TrendMath.trailing(values, calendar: cal)
            guard t.count >= 10, let last = t.last else { return usual.map { "Usually \(format($0, metric))." } ?? "" }
            let first = t[min(6, t.count - 1)]
            let word = TrendMath.change(last.value, first.value, tolerance: tol)
            var out = word.prefix(1).uppercased() + word.dropFirst() + " \(format(first.value, metric)) at the start of the month."
            if let u = usual { out += " Usually \(format(u, metric))." }
            if metric.lowerIsBetter { out += " Lower is better here." }
            return out
        case .week:
            if let u = usual {
                let better = values.filter { metric.lowerIsBetter ? $0.value < u : $0.value > u }.count
                return "\(metric.lowerIsBetter ? "Below" : "Above") usual on \(better) of \(values.count) \(metric.night ? "nights" : "days")."
            }
            guard values.count >= 2 else { return "" }
            let sorted = values.sorted { $0.value < $1.value }
            let best = metric.lowerIsBetter ? sorted.first! : sorted.last!
            let worst = metric.lowerIsBetter ? sorted.last! : sorted.first!
            return "Best: \(fullWeekday.string(from: best.date)) (\(format(best.value, metric))). Lowest: \(fullWeekday.string(from: worst.date)) (\(format(worst.value, metric)))."
                .replacingOccurrences(of: "Lowest", with: metric.lowerIsBetter ? "Highest" : "Lowest")
        }
    }

    // MARK: Chart

    private var weeks: [TrendWeek] { TrendMath.weekly(values, calendar: cal) }

    private var yDomain: ClosedRange<Double> {
        if range == .week && metric.weekStyle == .bars {
            if let f = metric.fixed { return f.lowerBound...(f.upperBound * 1.12) }
            return 0...max(1, (values.map(\.value).max() ?? 1) * 1.2)
        }
        if let f = metric.fixed { return f }
        var all: [Double] = values.map(\.value)
        if range == .year { all = weeks.map(\.low) + weeks.map(\.high) }
        if let u = usual { all.append(u) }
        return TrendMath.domain(all, minSpan: metric.minSpan, floor: 0)
    }

    private var xDomain: ClosedRange<Date> {
        let end = cal.date(byAdding: .day, value: 1, to: today) ?? today
        return (range == .week ? start : start)...(range == .year ? today : end)
    }

    @ViewBuilder private var plot: some View {
        switch range {
        case .week: weekPlot
        case .month: monthPlot
        case .year: yearPlot
        }
    }

    private var weekPlot: some View {
        Chart {
            ForEach(values, id: \.date) { v in
                if metric.weekStyle == .bars {
                    BarMark(x: .value("Day", v.date, unit: .day), y: .value(metric.title, v.value), width: .ratio(0.55))
                        .foregroundStyle(color(v.value).opacity(v.app ? 1 : 0.6))
                        .cornerRadius(4)
                        .annotation(position: .top, spacing: 2) { Text(format(v.value, metric).replacingOccurrences(of: metric.unit, with: "")).font(.system(size: 11)).foregroundColor(Theme.text) }
                } else {
                    LineMark(x: .value("Day", v.date, unit: .day), y: .value(metric.title, v.value))
                        .foregroundStyle(metric.color).lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Day", v.date, unit: .day), y: .value(metric.title, v.value))
                        .foregroundStyle(metric.color.opacity(v.app ? 1 : 0.6)).symbolSize(40)
                        .annotation(position: .top, spacing: 4) { Text(format(v.value, metric).replacingOccurrences(of: metric.unit, with: "")).font(.system(size: 11)).foregroundColor(Theme.text) }
                }
            }
            if let u = usual { usualRule(u) }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true) } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
    }

    private var monthPlot: some View {
        let avg = TrendMath.trailing(values, calendar: cal)
        return Chart {
            ForEach(values, id: \.date) { v in
                PointMark(x: .value("Day", v.date, unit: .day), y: .value(metric.title, v.value))
                    .foregroundStyle(color(v.value).opacity(v.app ? 1 : 0.55))
                    .symbolSize(v.app ? 40 : 24)
            }
            ForEach(avg, id: \.date) { v in
                LineMark(x: .value("Day", v.date, unit: .day), y: .value("7-day average", v.value), series: .value("Series", "average"))
                    .foregroundStyle(Theme.text).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
            }
            if let u = usual { usualRule(u) }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: 9)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
    }

    private var yearPlot: some View {
        let w = weeks
        return Chart {
            ForEach(w, id: \.start) { v in
                AreaMark(x: .value("Week", v.start), yStart: .value("Low", v.low), yEnd: .value("High", v.high))
                    .foregroundStyle(metric.color.opacity(0.16)).interpolationMethod(.monotone)
                LineMark(x: .value("Week", v.start), y: .value(metric.title, v.mean))
                    .foregroundStyle(metric.color).lineStyle(StrokeStyle(lineWidth: 2.2)).interpolationMethod(.monotone)
            }
            if let last = w.last {
                PointMark(x: .value("Week", last.start), y: .value(metric.title, last.mean)).foregroundStyle(metric.color).symbolSize(50)
            }
            if let u = usual { usualRule(u) }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartXAxis { AxisMarks(values: .stride(by: .month, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
    }

    private func usualRule(_ u: Double) -> some ChartContent {
        RuleMark(y: .value("Usual", u)).foregroundStyle(Theme.line).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }

    private var legend: some View {
        var items: [(Color, String, Bool)] = []
        switch range {
        case .month:
            items.append((metric.colorize ? Theme.green : metric.color, metric.colorize ? "Each day (colored by level)" : "Each day", false))
            items.append((Theme.text, "7-day average", true))
        case .week:
            if usual != nil { items.append((metric.color, metric.night ? "Each night" : "Each day", false)) }
        case .year:
            items.append((metric.color, "Weekly average", true))
            items.append((metric.color.opacity(0.3), "Range that week", false))
        }
        if usual != nil { items.append((Theme.line, "Usual", true)) }
        return TrendLegend(items: items)
    }
}

struct TrendLegend: View {
    let items: [(Color, String, Bool)]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(items[i].0).frame(width: items[i].2 ? 14 : 8, height: items[i].2 ? 3 : 8)
                    Text(items[i].1)
                }
            }
        }
        .font(.system(size: 12)).foregroundColor(Theme.dim)
    }
}

struct CaloriesTrend: View {
    let range: TrendRange
    let start: Date
    let today: Date
    let burned: [TrendValue]
    let eaten: [TrendValue]
    let goal: Int?

    private var cal: Calendar { Calendar.current }
    private func n(_ v: Double) -> String { Int(v.rounded()).formatted() }
    private var fullBurned: [Double] { burned.filter { $0.date < today }.map(\.value) }
    private var fullEaten: [Double] { eaten.filter { $0.date < today }.map(\.value) }

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Calories").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Spacer()
                Text(headline).font(.system(size: 13)).foregroundColor(Theme.dim).multilineTextAlignment(.trailing)
            }
            Text(detail).font(.system(size: 13)).foregroundColor(Color(hex: 0xC9D3CE))
            if burned.isEmpty && eaten.isEmpty {
                Text("Nothing in this range yet").font(.system(size: 13)).foregroundColor(Theme.dim).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                plot.frame(height: 130).accessibilityLabel("Calories eaten and burned. \(headline). \(detail)")
                TrendLegend(items: legendItems)
            }
        }
    }

    private var legendItems: [(Color, String, Bool)] {
        var items: [(Color, String, Bool)] = [(Theme.green, "Eaten", false), (Theme.orange, "Burned", range != .week)]
        if let g = goal { items.append((Theme.green, "Goal \(g.formatted())", true)) }
        return items
    }

    private var headline: String {
        let b = TrendMath.mean(fullBurned)
        switch range {
        case .week:
            if let e = TrendMath.mean(fullEaten), let b { return "Eaten \(n(e)) a day, burned \(n(b))" }
            return b.map { "Burned \(n($0)) a day" } ?? ""
        case .month: return b.map { "Burned: \(n($0)) a day on average" } ?? ""
        case .year: return b.map { "Burned: about \(n($0)) a day" } ?? ""
        }
    }

    private var detail: String {
        if range == .week {
            let e = eaten.first { cal.isDate($0.date, inSameDayAs: today) }?.value
            let b = burned.first { cal.isDate($0.date, inSameDayAs: today) }?.value
            if e != nil || b != nil { return "Today so far: \(e.map(n) ?? "0") eaten, \(b.map(n) ?? "--") burned." }
        }
        guard let e = TrendMath.mean(fullEaten) else {
            return eaten.isEmpty ? "Eaten shows from when you started logging meals." : "Eaten shows once a full day is logged."
        }
        return "Eaten: \(n(e)) a day over \(fullEaten.count) logged day\(fullEaten.count == 1 ? "" : "s")" + (goal.map { ", goal \($0.formatted())." } ?? ".")
    }

    private var yDomain: ClosedRange<Double> {
        var all = (burned + eaten).map(\.value)
        if let g = goal { all.append(Double(g)) }
        if range == .week { return 0...max(1, (all.max() ?? 1) * 1.15) }
        if range == .year {
            all = TrendMath.weekly(burned, calendar: cal).map(\.mean) + TrendMath.weekly(eaten, calendar: cal).map(\.mean)
            if let g = goal { all.append(Double(g)) }
        }
        let d = TrendMath.domain(all, minSpan: 1000, floor: 0)
        return range == .month ? 0...d.upperBound : d
    }

    private var xDomain: ClosedRange<Date> {
        let end = cal.date(byAdding: .day, value: 1, to: today) ?? today
        return start...(range == .year ? today : end)
    }

    @ViewBuilder private var plot: some View {
        switch range {
        case .week:
            Chart {
                ForEach(burned, id: \.date) { v in
                    BarMark(x: .value("Day", v.date, unit: .day), y: .value("Calories", v.value))
                        .foregroundStyle(by: .value("Kind", "Burned")).position(by: .value("Kind", "Burned")).cornerRadius(3)
                }
                ForEach(eaten, id: \.date) { v in
                    BarMark(x: .value("Day", v.date, unit: .day), y: .value("Calories", v.value))
                        .foregroundStyle(by: .value("Kind", "Eaten")).position(by: .value("Kind", "Eaten")).cornerRadius(3)
                }
                if let g = goal { goalRule(g) }
            }
            .chartForegroundStyleScale(["Burned": Theme.orange, "Eaten": Theme.green])
            .chartLegend(.hidden)
            .chartYScale(domain: yDomain)
            .chartXScale(domain: xDomain)
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true) } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
        case .month:
            Chart {
                ForEach(eaten, id: \.date) { v in
                    BarMark(x: .value("Day", v.date, unit: .day), y: .value("Eaten", v.value), width: .fixed(7))
                        .foregroundStyle(Theme.green).cornerRadius(2)
                }
                ForEach(burned, id: \.date) { v in
                    LineMark(x: .value("Day", v.date, unit: .day), y: .value("Burned", v.value), series: .value("Series", "burned"))
                        .foregroundStyle(Theme.orange).lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let g = goal { goalRule(g) }
            }
            .chartYScale(domain: yDomain)
            .chartXScale(domain: xDomain)
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 9)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
        case .year:
            Chart {
                ForEach(TrendMath.weekly(burned, calendar: cal), id: \.start) { v in
                    LineMark(x: .value("Week", v.start), y: .value("Burned", v.mean), series: .value("Series", "burned"))
                        .foregroundStyle(Theme.orange).lineStyle(StrokeStyle(lineWidth: 2.2)).interpolationMethod(.monotone)
                }
                ForEach(TrendMath.weekly(eaten, calendar: cal), id: \.start) { v in
                    PointMark(x: .value("Week", v.start), y: .value("Eaten", v.mean)).foregroundStyle(Theme.green).symbolSize(40)
                }
                if let g = goal { goalRule(g) }
            }
            .chartYScale(domain: yDomain)
            .chartXScale(domain: xDomain)
            .chartXAxis { AxisMarks(values: .stride(by: .month, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
        }
    }

    private func goalRule(_ g: Int) -> some ChartContent {
        RuleMark(y: .value("Goal", Double(g))).foregroundStyle(Theme.green.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }
}
