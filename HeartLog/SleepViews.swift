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
    @ObservedObject private var nav = AppNav.shared
    @State private var record: DayRecord?
    @State private var samples: [Sample] = []
    @State private var loaded = false
    @State private var adjusting = false
    @State private var showAlarm = false
    @ObservedObject private var alarm = AlarmStore.shared
    @State private var band: BandDay?
    @State private var pastAsleep: [Double] = []
    @State private var pastDeep: [Double] = []
    @State private var pastResp: [Double] = []
    @State private var usualWakeMin: Double?
    @ObservedObject private var settings = SettingsStore.shared

    @State private var phone: [PhoneUse.Span] = []
    @State private var adjusted: Overrides.Window?
    private var stages: [BandStage]? {
        guard let raw = band?.stages, !raw.isEmpty else { return nil }
        let st = PhoneUse.apply(phone, to: raw)
        if let o = adjusted { return StageMath.clip(st, onset: o.onset, wake: o.wake) }
        return st
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var nightOf: Date { Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day }

    var body: some View {
        NavigationStack(path: $nav.sleepPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        DayChevrons(text: "Night of \(Theme.shortDay.string(from: nightOf))", canGoForward: !isToday, move: move)
                        ScreenTitle(title: "Sleep", topic: .sleep)
                    }
                    if let r = record, let p = r.sleep {
                        scoreCard(r, p)
                        heartTiles(r)
                        if let st = stages {
                            hypnogram(st)
                            stageTotals(st)
                        } else if !r.isWhoop {
                            chartCard(p)
                        }
                        recoveryCard(r)
                        againstUsual(r, p)
                        tiles(r, p)
                    } else if loaded {
                        Card {
                            Text("No sleep found for this night.").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                            Text("Sleep is found from a long stretch of low, steady heart rate. If you slept with the band on, set your bedtime and wake time below.")
                                .font(.system(size: 14)).foregroundColor(Theme.dim)
                        }
                    }
                    Button(alarm.next.map { "Band alarm · \(AlarmView.dayTime($0))" } ?? "Band alarm · Off") { showAlarm = true }
                        .buttonStyle(TintButton(color: Theme.text))
                    if loaded, record?.isWhoop != true {
                        Button("Adjust bedtime or wake time") { adjusting = true }.buttonStyle(TintButton(color: Theme.text))
                    }
                    Text(footnote)
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
            .appPages()
        }
        .task(id: day) { await reload() }
        .followToday($day)
        .sheet(isPresented: $showAlarm) {
            NavigationStack {
                AlarmView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAlarm = false } } }
            }
        }
        .sheet(isPresented: $adjusting) {
            AdjustSleep(day: day, current: record?.sleep) { Task { await reload() } }
        }
    }

    private var footnote: String {
        if record?.isWhoop == true && stages == nil {
            return "This night comes from your WHOOP history, so it shows WHOOP's own numbers."
        }
        if stages != nil {
            let from = band?.source == "openstrap" ? " This night's stages were imported from OpenStrap, and its bedtime and wake time come from them."
                : band?.source == "zdravlje" ? " Zdravlje worked out this night's stages itself from the band's own record, and its bedtime and wake time come from them." : ""
            let onPhone = adjusted != nil ? " You set this night's bedtime and wake time yourself, so time outside them counts as awake."
                : phone.isEmpty ? "" : " Time you spent on your phone counts as awake."
            return "Stages are estimated from your band's heart rate, beat timing and movement, so they show as ranges instead of exact minutes. Scores are estimates.\(onPhone)\(from)"
        }
        return "No sleep stages for this night yet. For now they come from OpenStrap: export from OpenStrap, then in Zdravlje go to Settings, Import OpenStrap export. Once Zdravlje downloads from the band itself, they'll show on their own. Scores are estimates."
    }

    private func reload() async {
        let d = day
        let r = await DayLoader.load(d)
        var s: [Sample] = []
        if let p = r?.sleep, r?.isWhoop == false {
            s = await Task.detached { Store.shared.readSamples(from: p.onset - 15 * 60_000, to: p.wake + 15 * 60_000) }.value
        }
        let settingsNow = SettingsStore.shared.value
        let past: (asleep: [Double], deep: [Double], wake: Double?, band: BandDay?, resp: [Double]) = await Task.detached {
            let cal = Calendar.current
            let key = DayEngine.shared.key(d)
            let from = cal.date(byAdding: .day, value: -28, to: d) ?? d
            let to = cal.date(byAdding: .day, value: -1, to: d) ?? d
            let records = DayEngine.shared.records(from: from, to: to, settings: settingsNow)
            let asleep = records.compactMap { $0.sleep?.asleepMin }
            let wakes = records.suffix(14).compactMap { $0.sleep }.map { p -> Double in
                let w = Date(timeIntervalSince1970: Double(p.wake) / 1000)
                let c = cal.dateComponents([.hour, .minute], from: w)
                return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
            }
            let bandDays = BandHistoryStore.shared.days
            let deep = (1...28).compactMap { cal.date(byAdding: .day, value: -$0, to: d) }
                .compactMap { bandDays[DayEngine.shared.key($0)]?.stageMinutes[.deep] }
            return (asleep, deep, SleepMath.median(wakes), bandDays[key], records.compactMap(\.respRate))
        }.value
        let dayStart = Int64(Calendar.current.startOfDay(for: d).timeIntervalSince1970 * 1000)
        let phoneSpans = await Task.detached { PhoneUse.read(from: dayStart - 6 * 3_600_000, to: dayStart + 14 * 3_600_000) }.value
        guard d == day else { return }
        record = r
        samples = s
        band = past.band
        phone = phoneSpans
        adjusted = Overrides.all()[DayEngine.shared.key(d)]
        pastAsleep = past.asleep
        pastDeep = past.deep
        pastResp = past.resp
        usualWakeMin = past.wake
        loaded = true
    }

    private func move(_ by: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        guard let d = Calendar.current.date(byAdding: .day, value: by, to: day), d <= today else { return }
        loaded = false
        day = d
    }

    private func scoreCard(_ r: DayRecord, _ p: SleepPeriod) -> some View {
        Card(accent: Theme.blue) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.isWhoop ? "Sleep score (WHOOP)" : "Sleep score (estimate)").font(.system(size: 13)).foregroundColor(Theme.dim)
                    Text(r.sleepScore.map { "\(Int($0.rounded()))" } ?? "--").font(Theme.display(60)).foregroundColor(Theme.level(r.sleepScore))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    (Text(Theme.minutes(p.asleepMin)).font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.text) + Text(" asleep"))
                    Text("\(Theme.clock(p.onset)) to \(Theme.clock(p.wake))")
                    if p.inBedMin > 0 { Text("\(Int(p.efficiency.rounded()))% of \(Theme.minutes(p.inBedMin)) in bed") }
                }
                .font(.system(size: 14)).foregroundColor(Theme.dim)
            }
        }
    }

    private func chartCard(_ p: SleepPeriod) -> some View {
        Card(accent: Theme.blue) {
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

    private static let deepBlue = Color(hex: 0x6E97D6)

    private func stageColor(_ k: BandStage.Kind) -> Color {
        switch k {
        case .wake: return Theme.orange
        case .rem: return Theme.green
        case .light: return Theme.blue
        case .deep: return Self.deepBlue
        }
    }

    private func stageName(_ k: BandStage.Kind) -> String {
        switch k {
        case .wake: return "Awake"
        case .rem: return "REM"
        case .light: return "Light"
        case .deep: return "Deep"
        }
    }

    private func hypnogram(_ st: [BandStage]) -> some View {
        let first = st.first?.start ?? 0
        let last = st.last?.end ?? 0
        return Card {
            Text("Through the night").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            Chart {
                ForEach(Array(st.enumerated()), id: \.offset) { item in
                    RectangleMark(xStart: .value("Start", Date(timeIntervalSince1970: Double(item.element.start) / 1000)),
                                  xEnd: .value("End", Date(timeIntervalSince1970: Double(item.element.end) / 1000)),
                                  y: .value("Stage", stageName(item.element.kind)),
                                  height: .fixed(18))
                        .foregroundStyle(stageColor(item.element.kind))
                        .cornerRadius(3)
                }
            }
            .chartYScale(domain: ["Awake", "REM", "Light", "Deep"])
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in AxisValueLabel().foregroundStyle(Theme.dim) }
            }
            .frame(height: 150)
            .accessibilityLabel("Sleep stage timeline from \(Theme.clock(first)) to \(Theme.clock(last))")
            HStack {
                Text(Theme.clock(first))
                Spacer()
                Text(Theme.clock(first + (last - first) / 2))
                Spacer()
                Text(Theme.clock(last))
            }
            .font(.system(size: 12)).foregroundColor(Theme.dim)
            Text("Longest unbroken stretch \(Theme.minutes(StageMath.longestStretch(st))). Wake-ups shorter than about 5 minutes don't show.")
                .font(.system(size: 12)).foregroundColor(Theme.dim)
        }
    }

    private func stageTotals(_ st: [BandStage]) -> some View {
        var totals = BandDay(day: "", source: "", stages: st).stageMinutes
        totals[.wake] = StageMath.awakeDuringSleep(st)
        return Card {
            Text("Stage totals").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            ForEach([BandStage.Kind.deep, .rem, .light, .wake], id: \.self) { k in
                let m = totals[k] ?? 0
                HStack {
                    Circle().fill(stageColor(k)).frame(width: 9, height: 9)
                    Text(stageName(k))
                    Spacer()
                    Text(StageMath.range(k, minutes: m).map { "\(Theme.minutes($0.low)) to \(Theme.minutes($0.high))" } ?? Theme.minutes(m))
                        .fontWeight(.semibold)
                }
                .font(.system(size: 14)).foregroundColor(Theme.text)
            }
            Text("Each stage shows a range rather than one exact number, because a wrist band can't measure stages precisely. Awake time is measured directly, so it's a single figure, counted from first falling asleep to the final wake.")
                .font(.system(size: 12)).foregroundColor(Theme.dim)
        }
    }

    private func againstUsual(_ r: DayRecord, _ p: SleepPeriod) -> some View {
        let usualSleep = StageMath.usualRange(pastAsleep)
        let deepMin = stages.map { BandDay(day: "", source: "", stages: $0).stageMinutes[.deep] ?? 0 }
        let usualDeep = StageMath.usualRange(pastDeep, minimum: 3)
        return Card {
            HStack(spacing: 4) {
                Text("Against your usual").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                if !pastAsleep.isEmpty { Text("(\(pastAsleep.count) nights)").font(.system(size: 15)).foregroundColor(Theme.dim) }
            }
            usualRow("Total sleep", value: Theme.minutes(p.asleepMin), marker: (p.asleepMin, p.asleepMin), usual: usualSleep,
                     note: usualSleep.map { (u: StageMath.Range) -> String in
                         let span = "(\(Theme.minutes(u.low)) to \(Theme.minutes(u.high)))"
                         switch StageMath.compare(p.asleepMin, to: u) {
                         case 1: return "\(Theme.minutes(p.asleepMin - u.high)) more than usual \(span)"
                         case -1: return "\(Theme.minutes(u.low - p.asleepMin)) less than usual \(span)"
                         default: return "Within your usual \(span)"
                         }
                     } ?? "Building your usual: \(pastAsleep.count) of 5 nights")
            if let d = deepMin, let range = StageMath.range(.deep, minutes: d) {
                usualRow("Deep sleep", value: "\(Theme.minutes(range.low)) to \(Theme.minutes(range.high))", marker: (range.low, range.high), usual: usualDeep,
                         note: usualDeep.map { (u: StageMath.Range) -> String in
                             let span = "(\(Theme.minutes(u.low)) to \(Theme.minutes(u.high)))"
                             if range.low > u.high { return "More than usual \(span)" }
                             if range.high < u.low { return "Less than usual \(span)" }
                             return "Too close to your usual to call \(span)"
                         } ?? "Building your usual: \(pastDeep.count) of 3 nights")
            }
            if let b = r.respRate {
                let usualResp = StageMath.usualRange(pastResp)
                let lo = min(b, usualResp?.low ?? b) - 3, hi = max(b, usualResp?.high ?? b) + 3
                usualRow("Breathing rate", value: String(format: "%.1f a minute", b), marker: (b, b), usual: usualResp,
                         note: usualResp.map { (u: StageMath.Range) -> String in
                             let span = String(format: "(%.1f to %.1f)", u.low, u.high)
                             switch StageMath.compare(b, to: u, minMargin: 0.5) {
                             case 1: return String(format: "%.1f higher than usual %@", b - u.high, span)
                             case -1: return String(format: "%.1f lower than usual %@", u.low - b, span)
                             default: return "Within your usual \(span)"
                             }
                         } ?? "Building your usual: \(pastResp.count) of 5 nights",
                         axis: lo...hi)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Slept through your time in bed")
                    Spacer()
                    Text("\(Int(p.efficiency.rounded()))%").fontWeight(.semibold)
                }
                .font(.system(size: 14)).foregroundColor(Theme.text)
                Bar(fraction: p.efficiency / 100, color: Theme.green, height: 8)
            }
        }
    }

    private func usualRow(_ label: String, value: String, marker: (Double, Double), usual: StageMath.Range?, note: String,
                          axis: ClosedRange<Double>? = nil) -> some View {
        let bottom = axis?.lowerBound ?? 0
        let top = axis?.upperBound ?? max(marker.1, usual?.high ?? 0) * 1.25
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(value).fontWeight(.semibold)
            }
            .font(.system(size: 14)).foregroundColor(Theme.text)
            GeometryReader { g in
                let w = g.size.width
                let x: (Double) -> CGFloat = { v in top > bottom ? CGFloat(min(1, max(0, (v - bottom) / (top - bottom)))) * w : 0 }
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    if let u = usual {
                        Capsule().fill(Theme.line).frame(width: max(4, x(u.high) - x(u.low))).offset(x: x(u.low))
                    }
                    Capsule().fill(Theme.blue.opacity(marker.0 == marker.1 ? 1 : 0.7))
                        .frame(width: max(4, x(marker.1) - x(marker.0))).offset(x: x(marker.0) - (marker.0 == marker.1 ? 2 : 0))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            Text(note).font(.system(size: 12)).foregroundColor(Theme.dim)
        }
    }

    /// Tonight's targets: wake at your usual time, go to bed early enough to meet your need.
    private var targets: (bed: Int64, wake: Int64)? {
        guard isToday, let wakeMin = usualWakeMin, let need = record?.sleepNeedMin else { return nil }
        let cal = Calendar.current
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) else { return nil }
        let wake = tomorrow.addingTimeInterval(wakeMin * 60)
        let bed = wake.addingTimeInterval(-need * 60)
        return (Int64(bed.timeIntervalSince1970 * 1000), Int64(wake.timeIntervalSince1970 * 1000))
    }

    /// The two overnight numbers recovery is built from, each opening its page.
    private func heartTiles(_ r: DayRecord) -> some View {
        HStack(spacing: 10) {
            Button { nav.sleepPath.append(.hrv(day)) } label: {
                Tile(title: "HRV, overnight", value: r.hrv.map { "\(Int($0.rounded())) ms" } ?? "--", note: r.usualHRV.map { "Usually \(Int($0.rounded()))" }, opens: true, accent: Theme.blue, icon: "waveform.path.ecg")
            }
            Button { nav.sleepPath.append(.rhr(day)) } label: {
                Tile(title: "Resting heart rate", value: r.rhr.map { "\($0)" } ?? "--", note: r.usualRHR.map { "Usually \(Int($0.rounded()))" }, opens: true, accent: Theme.orange, icon: "heart")
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func recoveryCard(_ r: DayRecord) -> some View {
        if r.recovery != nil {
            Button { nav.sleepPath.append(.recovery(day)) } label: {
                Card(accent: Theme.green) {
                    HStack(spacing: 14) {
                        VStack(spacing: 0) {
                            Text(r.recovery.map { "\(Int($0.rounded()))%" } ?? "--").font(Theme.display(28)).foregroundColor(Theme.level(r.recovery))
                            Text("recovery").font(.system(size: 11)).foregroundColor(Theme.dim)
                        }
                        .frame(minWidth: 70)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(DetailMath.recoveryHeadline(r.recovery)).font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.text)
                            Text(DetailMath.recoveryReason(recovery: r.recovery, hrv: r.hrv, usualHRV: r.usualHRV, rhr: r.rhr, usualRHR: r.usualRHR))
                                .font(.system(size: 13)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.dim)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Recovery")
        }
    }

    private func tiles(_ r: DayRecord, _ p: SleepPeriod) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            Tile(title: isToday ? "Tonight's need" : "Sleep need", value: r.sleepNeedMin.map { Theme.minutes($0) } ?? "--", accent: Theme.blue, icon: "bed.double")
            Tile(title: "Sleep debt", value: r.debtMin.map { Theme.minutes($0) } ?? "--", accent: Theme.blue, icon: "hourglass")
            if let t = targets {
                Tile(title: "Target bedtime", value: Theme.clock(t.bed), accent: Theme.blue, icon: "moon")
                Tile(title: "Target wake", value: Theme.clock(t.wake), accent: Theme.blue, icon: "sun.max")
            } else {
                Tile(title: "Breathing rate", value: r.respRate.map { String(format: "%.1f", $0) } ?? "--", note: "per minute", accent: Theme.blue, icon: "lungs")
                let wakeUps = stages.map { StageMath.wakeUps($0) } ?? p.awakeEvents
                Tile(title: "Times awake", value: wakeUps.map { stages != nil ? "\($0)" : "~\($0)" } ?? "--", accent: Theme.blue, icon: "eye")
            }
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
                Card(accent: Theme.level(record.recovery)) {
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
                    NavigationLink { MetricDetailView(kind: .hrv, day: day) } label: { detailRow("HRV through the night and last 30 nights") }
                    Divider().overlay(Theme.track)
                    NavigationLink { MetricDetailView(kind: .rhr, day: day) } label: { detailRow("Resting heart rate through the night") }
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

    private func detailRow(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 15)).foregroundColor(Theme.text)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.dim)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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

/// When a screen is showing today and the date changes (the app keeps running overnight to record),
/// move it to the new today. A screen showing an earlier day stays put.
struct FollowToday: ViewModifier {
    @Binding var day: Date
    @State private var knownToday = Calendar.current.startOfDay(for: Date())
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .onAppear(perform: check)
            .onReceive(tick) { _ in check() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in check() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in check() }
    }

    private func check() {
        let now = Calendar.current.startOfDay(for: Date())
        guard now != knownToday else { return }
        if Calendar.current.isDate(day, inSameDayAs: knownToday) { day = now }
        knownToday = now
    }
}

extension View {
    func followToday(_ day: Binding<Date>) -> some View { modifier(FollowToday(day: day)) }
}
