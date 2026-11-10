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
        .followToday($day)
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
