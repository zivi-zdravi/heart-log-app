import Charts
import SwiftUI

/// Body log data (blood pressure for now), kept in body.json and included in backups.
final class BodyStore: ObservableObject {
    static let shared = BodyStore()
    static let fileName = "body.json"

    @Published private(set) var data: BodyData

    private static var url: URL { Store.shared.dir.appendingPathComponent(fileName) }

    private init() {
        data = (try? JSONDecoder().decode(BodyData.self, from: Data(contentsOf: Self.url))) ?? BodyData()
    }

    func reload() {
        let d = (try? JSONDecoder().decode(BodyData.self, from: Data(contentsOf: Self.url))) ?? BodyData()
        if Thread.isMainThread { data = d } else { DispatchQueue.main.async { self.data = d } }
    }

    func change(_ edit: (inout BodyData) -> Void) {
        var d = data
        edit(&d)
        guard d != data else { return }
        data = d
        JSONFile.write(d, to: Self.url)
    }

    var settings: BodySettings {
        get { data.settings }
        set { change { $0.settings = newValue } }
    }
}

private let soft = Color(hex: 0xC9D3CE)

struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let w = rows.map { $0.width }.max() ?? 0
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if extra > width && !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width = r.items.isEmpty ? size.width : r.width + spacing + size.width
            r.height = max(r.height, size.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

/// A pill as wide as its words. Selected pills are outlined in `color`.
struct Pill: View {
    let text: String
    var on = false
    var color: Color = Theme.green
    var dashed = false
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Text(text).font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundColor(on ? color : dashed ? Theme.dim : Theme.text)
                .padding(.horizontal, 12).frame(minHeight: 36)
                .overlay(Capsule().stroke(on ? color : Theme.line, style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Pills you can turn on and off, wrapping onto more lines.
struct ToggleChips: View {
    let items: [String]
    @Binding var selected: Set<String>
    var color: Color = Theme.green

    var body: some View {
        WrapLayout {
            ForEach(items, id: \.self) { item in
                Pill(text: item, on: selected.contains(item), color: color) {
                    if selected.contains(item) { selected.remove(item) } else { selected.insert(item) }
                }
            }
        }
    }
}

// MARK: - Settings, Body log

struct BodySettingsView: View {
    @ObservedObject private var store = BodyStore.shared
    @ObservedObject private var doses = DoseStore.shared
    @ObservedObject private var app = SettingsStore.shared
    @State private var showAll = false

    /// Shown: the ones suggested for this person, anything already on, or everything after "Show all trackers".
    private func shows(_ t: BodyMath.Tracker, on: Bool) -> Bool {
        showAll || on || BodyMath.suggested(female: app.value.female, age: app.value.age).contains(t)
    }
    private var hidesSome: Bool {
        let st = store.settings
        return !(shows(.bloodPressure, on: st.bloodPressure) && shows(.cycle, on: st.cycle) && shows(.menopause, on: st.menopause))
    }

    private func binding(_ key: WritableKeyPath<BodySettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings[keyPath: key] }, set: { v in var s = store.settings; s[keyPath: key] = v; store.settings = s })
    }

    var body: some View {
        Form {
            Section {
                if shows(.bloodPressure, on: store.settings.bloodPressure) {
                    Toggle(isOn: binding(\.bloodPressure)) { row("Blood pressure", "Readings you enter by hand") }
                }
                if shows(.cycle, on: store.settings.cycle) {
                    Toggle(isOn: binding(\.cycle)) { row("Cycle", "Period, flow, symptoms and predictions") }
                }
                if shows(.menopause, on: store.settings.menopause) {
                    Toggle(isOn: binding(\.menopause)) { row("Menopause", "Hot flashes, night sweats and more") }
                }
                Toggle(isOn: Binding(get: { doses.data.medicationsOn }, set: { v in doses.change { $0.medicationsOn = v } })) {
                    row("Medications", "Doses, times and reminders")
                }
                if doses.data.medicationsOn {
                    Toggle(isOn: Binding(get: { doses.data.medicationsInAsk }, set: { v in doses.change { $0.medicationsInAsk = v } })) {
                        row("Include medications in Ask", "Lets Ask see which ones you took each day")
                    }
                }
                if hidesSome {
                    Button("Show all trackers") { showAll = true }.foregroundColor(Theme.blue)
                }
            } footer: {
                Text("Turn on only what you want to track. Anything turned off disappears from Today and the Body log screen; what you already logged is kept.")
            }
            if store.settings.cycle {
                Section {
                    ToggleChips(items: CycleMath.allSymptoms, selected: Binding(
                        get: { Set(store.settings.cycleSymptoms) },
                        set: { v in var st = store.settings; st.cycleSymptoms = CycleMath.allSymptoms.filter { v.contains($0) }; store.settings = st }), color: cyclePink)
                        .padding(.vertical, 6)
                } header: {
                    Text("Cycle symptoms to show")
                } footer: {
                    Text("Hidden ones stay under More on the Cycle screen.")
                }
            }
            if store.settings.menopause {
                Section {
                    ToggleChips(items: BodyMath.allSymptoms, selected: Binding(
                        get: { Set(store.settings.symptoms) },
                        set: { v in var st = store.settings; st.symptoms = BodyMath.allSymptoms.filter { v.contains($0) }; store.settings = st }), color: lilac)
                        .padding(.vertical, 6)
                } header: {
                    Text("Symptoms to show")
                } footer: {
                    Text("Hot flashes, night sweats and palpitations are logged each time. The others get a 0 to 3 rating for the day.")
                }
            }
            Section {
                Toggle(isOn: binding(\.includeInAsk)) { row("Include in Ask", "Lets Ask use your Body log summaries") }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Each person sets these on their own phone. Logged entries stay on the phone and in your backups.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Body log")
    }

    private func row(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(note).font(.system(size: 13)).foregroundColor(Theme.dim)
        }
    }
}

// MARK: - Symptoms

enum SymptomSummary {
    private static var cal: Calendar { .current }
    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Start of the window a counted symptom is shown for: night sweats from 6 PM yesterday, the rest from midnight.
    static func windowStart(_ name: String) -> Int64 {
        let today = cal.startOfDay(for: Date())
        if name == "Night sweats", let evening = cal.date(byAdding: .hour, value: -6, to: today) {
            return Int64(evening.timeIntervalSince1970 * 1000)
        }
        return Int64(today.timeIntervalSince1970 * 1000)
    }

    static func todayEvents(_ data: BodyData, _ name: String) -> [SymptomEvent] {
        let from = windowStart(name)
        return data.events.filter { $0.name == name && $0.time >= from && $0.time <= now() }.sorted { $0.time < $1.time }
    }

    /// "2 night sweats, 1 hot flash" or nil when nothing is logged.
    static func todayLine(_ data: BodyData) -> String? {
        var parts: [String] = []
        for name in data.settings.symptoms where BodyMath.counted.contains(name) {
            let n = todayEvents(data, name).count
            guard n > 0 else { continue }
            let word = name.lowercased()
            parts.append("\(n) \(n == 1 ? singular(word) : word)")
        }
        let key = DayEngine.shared.key(Date())
        for name in data.settings.symptoms where !BodyMath.counted.contains(name) {
            if let l = data.ratings[key]?[name], l > 0 { parts.append("\(name.lowercased()) \(BodyMath.levels[l])") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func singular(_ w: String) -> String {
        if w.hasSuffix("flashes") { return String(w.dropLast(2)) }
        if w.hasSuffix("s") { return String(w.dropLast()) }
        return w
    }
}

/// +1 buttons for counted symptoms and 0 to 3 ratings for the rest, for today.
struct EventEditSheet: View {
    let event: SymptomEvent
    @Environment(\.dismiss) private var dismiss
    @State private var time = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(event.name, selection: $time, in: ...Date())
                Button("Delete", role: .destructive) {
                    BodyStore.shared.change { $0.events.removeAll { $0.id == event.id } }
                    dismiss()
                }
            }
            .navigationTitle("Change time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var e = event
                        e.time = Int64(time.timeIntervalSince1970 * 1000)
                        BodyStore.shared.change { $0.addEvent(e) }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { time = Date(timeIntervalSince1970: Double(event.time) / 1000) }
    }
}

private struct SweatCompare {
    var withN = 0, withoutN = 0
    var score: (Double?, Double?) = (nil, nil)
    var awake: (Double?, Double?) = (nil, nil)
    var asleep: (Double?, Double?) = (nil, nil)
}

private struct FlashDay: Identifiable {
    let day: Date
    let count: Int
    var id: Date { day }
}

// MARK: - Cycle

enum CycleSummary {
    static func line(_ data: BodyData) -> String {
        let cal = Calendar.current
        guard let p = CycleMath.predict(data.flow, today: Date(), cal) else { return "Log your period to start" }
        let today = cal.startOfDay(for: Date())
        let toFrom = CycleMath.days(today, p.nextFrom, cal)
        let toTo = CycleMath.days(today, p.nextTo, cal)
        if (data.flow[CycleMath.key(today, cal)] ?? 0) >= 2 { return "Day \(p.cycleDay), period" }
        if toFrom > 0 { return "Day \(p.cycleDay), period in ~\(toFrom) days" }
        if toTo >= 0 { return "Day \(p.cycleDay), period likely soon" }
        return "Day \(p.cycleDay)"
    }
}

private let cyclePink = Color(hex: 0xF2A7B8)

private let lilac = Color(hex: 0xC7A6E8)
private let lilacBg = Color(hex: 0x2A2433)

// MARK: - Today card

struct BodyLogCard: View {
    @ObservedObject private var store = BodyStore.shared
    @ObservedObject private var doses = DoseStore.shared

    var body: some View {
        if store.data.settings.anyOn || doses.data.medicationsOn {
            Button { AppNav.shared.openLog(body: true) } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "heart.text.square").font(.system(size: 20)).foregroundColor(lilac).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Body log").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                            Spacer()
                            Text("Log").font(.system(size: 14, weight: .semibold)).foregroundColor(lilac)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(lilac)
                        }
                        if store.data.settings.bloodPressure {
                            line("Blood pressure") {
                                if let r = store.data.bp.first {
                                    Text(BodyMath.text(r)).fontWeight(.semibold).foregroundColor(Theme.text)
                                    Text(BodyMath.when(r.time, now: Date(), calendar: .current)).foregroundColor(Theme.dim)
                                } else {
                                    Text("No readings yet").foregroundColor(Theme.dim)
                                }
                            }
                        }
                        if store.data.settings.cycle {
                            line("Cycle") { Text(CycleSummary.line(store.data)).foregroundColor(Theme.text) }
                        }
                        if store.data.settings.menopause, let l = SymptomSummary.todayLine(store.data) {
                            line("Menopause") { Text(l).foregroundColor(Theme.text) }
                        }
                        if doses.data.medicationsOn {
                            let c = DoseMath.counts(doses.data, day: DoseStore.today(), .medication)
                            if c.total > 0 { line("Medications") { Text("\(c.taken) of \(c.total) taken").foregroundColor(Theme.text) } }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accentCard(lilac, radius: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func line<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack {
            Text(label).foregroundColor(Theme.dim)
            Spacer()
            value()
        }
        .font(.system(size: 14))
        .lineLimit(1).minimumScaleFactor(0.8)
    }
}

// MARK: - Body log screen

struct BodyLogView: View {
    /// Inside the Log tab: the Log header on top and no navigation bar.
    var inLog = false
    @ObservedObject private var store = BodyStore.shared
    @ObservedObject private var doses = DoseStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if inLog { LogHeader() } else { Text("Body log").font(Theme.display(30)).foregroundColor(Theme.text) }
                Text("Tap one to log it. Each opens its own screen with history.").font(.system(size: 13)).foregroundColor(Theme.dim)
                let st = store.data.settings
                BodyTiles(items: tileItems)
                if st.menopause {
                    Text("Quick log, today").font(.system(size: 13)).foregroundColor(Theme.dim).padding(.top, 6)
                    QuickLog()
                    Text("Your four come first. Tap +1 each time; the time is saved so it can be lined up with your sleep and heart rate.")
                        .font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                if !st.anyOn && !doses.data.medicationsOn {
                    Text("Nothing is turned on. Choose what to track in Settings, Body log.").font(.system(size: 14)).foregroundColor(soft)
                }
                NavigationLink { BodySettingsView() } label: {
                    Text("Choose what to track").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.blue).frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 20).padding(.top, inLog ? 8 : 20).padding(.bottom, 20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(inLog ? .hidden : .automatic, for: .navigationBar)
    }

    private var tileItems: [BodyTile] {
        let st = store.data.settings
        var out: [BodyTile] = []
        if st.bloodPressure {
            out.append(BodyTile(id: "bp", view: AnyView(NavigationLink { BPView() } label: {
                tile("heart.text.square", Theme.orange, "Blood pressure",
                     store.data.bp.first.map { "Last: \(BodyMath.text($0)), \(Theme.clock($0.time))" } ?? "No readings yet")
            })))
        }
        if st.cycle {
            out.append(BodyTile(id: "cycle", view: AnyView(NavigationLink { CycleView() } label: {
                tile("drop.fill", cyclePink, "Cycle", CycleSummary.line(store.data))
            })))
        }
        if st.menopause {
            out.append(BodyTile(id: "meno", view: AnyView(NavigationLink { MenopauseView() } label: {
                tile("thermometer.medium", lilac, "Menopause", "Hot flashes, night sweats, sleep, joints and more")
            })))
        }
        if doses.data.medicationsOn {
            let c = DoseMath.counts(doses.data, day: DoseStore.today(), .medication)
            out.append(BodyTile(id: "meds", view: AnyView(NavigationLink { MedicationsView() } label: {
                tile("pills", Theme.blue, "Medications", c.total == 0 ? "Set up what you take" : "\(c.taken) of \(c.total) taken today")
            })))
        }
        return out
    }

    private func tile(_ icon: String, _ color: Color, _ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.system(size: 20)).foregroundColor(color)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            Text(note).font(.system(size: 12)).foregroundColor(Theme.dim).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(14)
        .accentCard(color, radius: 14)
        .contentShape(Rectangle())
    }
}

struct BodyTile: Identifiable {
    let id: String
    let view: AnyView
}

/// Tiles two to a row; an odd one out at the end runs full width.
struct BodyTiles: View {
    let items: [BodyTile]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { i in
                HStack(spacing: 10) {
                    items[i].view
                    if i + 1 < items.count { items[i + 1].view }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// One small card of chips: +1 for symptoms you count, one tap logs "mild" for the rest.
struct QuickLog: View {
    @ObservedObject private var store = BodyStore.shared

    private var key: String { DayEngine.shared.key(Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WrapLayout {
                ForEach(store.data.settings.symptoms, id: \.self) { name in
                    if BodyMath.counted.contains(name) {
                        Button {
                            store.change { $0.addEvent(SymptomEvent(id: UUID().uuidString, time: Int64(Date().timeIntervalSince1970 * 1000), name: name)) }
                        } label: {
                            Text("\(BodyMath.shortName(name)) +1").font(.system(size: 14, weight: .semibold)).foregroundColor(lilac)
                                .padding(.horizontal, 14).frame(minHeight: 40)
                                .background(lilacBg).clipShape(Capsule())
                                .overlay(Capsule().stroke(lilac, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Log one \(BodyMath.shortName(name).lowercased())")
                    } else {
                        let level = store.data.ratings[key]?[name] ?? 0
                        Button {
                            let k = key
                            store.change { $0.rate(name, day: k, level: level > 0 ? nil : 1) }
                        } label: {
                            Text(level > 0 ? "\(BodyMath.chipName(name)), \(BodyMath.levels[level])" : BodyMath.chipName(name))
                                .font(.system(size: 14, weight: .semibold)).foregroundColor(level > 0 ? lilac : Theme.text)
                                .padding(.horizontal, 14).frame(minHeight: 40)
                                .overlay(Capsule().stroke(level > 0 ? lilac : Theme.line, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(level > 0 ? .isSelected : [])
                    }
                }
            }
            if let l = SymptomSummary.todayLine(store.data) {
                Text("So far: \(l)").font(.system(size: 13)).foregroundColor(soft)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Blood pressure

private struct BPPoint: Identifiable {
    let id: String
    let date: Date
    let value: Int
    let kind: String
}

struct BPView: View {
    @ObservedObject private var store = BodyStore.shared
    @State private var systolic = ""
    @State private var diastolic = ""
    @State private var pulse = ""
    @State private var time = Date()
    @State private var tags: Set<String> = []
    @State private var note = ""
    @State private var showNote = false
    @State private var problem = ""
    @State private var saved = false
    @FocusState private var focus: Int?

    private var month: [BPReading] { BodyMath.recent(store.data.bp, days: 30, now: Int64(Date().timeIntervalSince1970 * 1000)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Blood pressure").font(Theme.display(30)).foregroundColor(Theme.text)
                Card(accent: Theme.orange) {
                    Text("New reading").font(.system(size: 13)).foregroundColor(Theme.dim)
                    HStack(spacing: 10) {
                        box("Top (systolic)", $systolic, 0)
                        box("Bottom (diastolic)", $diastolic, 1)
                        box("Pulse (optional)", $pulse, 2)
                    }
                    DatePicker("Time", selection: $time, in: ...Date()).font(.system(size: 15)).foregroundColor(Theme.text).padding(.top, 4)
                    ToggleChips(items: BodyMath.bpTags, selected: $tags)
                    if showNote {
                        TextField("Note", text: $note).textFieldStyle(.roundedBorder)
                    } else {
                        Button("+ Note") { showNote = true }.font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.blue).frame(minHeight: 36)
                    }
                    if !problem.isEmpty { Text(problem).font(.system(size: 13)).foregroundColor(Theme.orange) }
                    Button(saved ? "Saved" : "Save reading") { save() }
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.bg)
                        .frame(maxWidth: .infinity, minHeight: 50).background(Theme.green).clipShape(RoundedRectangle(cornerRadius: 12))
                        .buttonStyle(.plain).padding(.top, 4)
                }
                if month.count >= 2 { chart }
                if !store.data.bp.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(store.data.bp.prefix(30).enumerated()), id: \.element.id) { i, r in
                            if i > 0 { Divider().overlay(Theme.track) }
                            readingRow(r)
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                Text("Readings are shown as you entered them. Zdravlje doesn't diagnose; if readings worry you, check with your doctor.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focus = nil } } }
    }

    private func box(_ label: String, _ text: Binding<String>, _ tag: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundColor(Theme.dim).lineLimit(1).minimumScaleFactor(0.7)
            TextField("", text: text).keyboardType(.numberPad).multilineTextAlignment(.center)
                .font(Theme.display(24)).foregroundColor(Theme.text)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Theme.bg)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(focus == tag ? Theme.green : Theme.line, lineWidth: 1))
                .focused($focus, equals: tag)
                .accessibilityLabel(label)
        }
    }

    private var chart: some View {
        let points = month.flatMap { r -> [BPPoint] in
            let d = Date(timeIntervalSince1970: Double(r.time) / 1000)
            return [BPPoint(id: r.id + "s", date: d, value: r.systolic, kind: "Top"),
                    BPPoint(id: r.id + "d", date: d, value: r.diastolic, kind: "Bottom")]
        }
        let sysRange = DetailMath.usualRange(store.data.bp.prefix(60).map { Double($0.systolic) })
        let diaRange = DetailMath.usualRange(store.data.bp.prefix(60).map { Double($0.diastolic) })
        let first = points.map(\.date).min() ?? Date(), last = points.map(\.date).max() ?? Date()
        return Card(accent: Theme.orange) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 30 days").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Spacer()
                if let a = BodyMath.average(month) { Text("Average \(a.systolic)/\(a.diastolic)").font(.system(size: 13)).foregroundColor(Theme.dim) }
            }
            Chart {
                ForEach([sysRange, diaRange].compactMap { $0 }, id: \.lowerBound) { r in
                    RectangleMark(xStart: .value("From", first), xEnd: .value("To", last), yStart: .value("Low", r.lowerBound), yEnd: .value("High", r.upperBound))
                        .foregroundStyle(Theme.track.opacity(0.6))
                }
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.date), y: .value("mmHg", p.value), series: .value("Kind", p.kind))
                        .foregroundStyle(p.kind == "Top" ? Theme.orange : Theme.blue)
                }
            }
            .chartXAxis { AxisMarks(values: [first, last]) { v in AxisValueLabel { Text(axisLabel(v.as(Date.self))) } } }
            .chartYAxis(.hidden)
            .frame(height: 120)
            Text("Shaded bands are your usual range. Top number orange, bottom blue.").font(.system(size: 12)).foregroundColor(Theme.dim)
        }
    }

    private func axisLabel(_ d: Date?) -> String {
        guard let d else { return "" }
        return Calendar.current.isDateInToday(d) ? "Today" : d.formatted(.dateTime.month(.abbreviated).day())
    }

    private func readingRow(_ r: BPReading) -> some View {
        let d = Date(timeIntervalSince1970: Double(r.time) / 1000)
        let cal = Calendar.current
        let day = cal.isDateInToday(d) ? "Today" : cal.isDateInYesterday(d) ? "Yesterday" : d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let extra = (r.tags + [r.note].compactMap { $0 }).joined(separator: ", ").lowercased()
        return HStack(alignment: .firstTextBaseline) {
            (Text("\(day) \(Theme.clock(r.time))").foregroundColor(Theme.text)
             + Text(extra.isEmpty ? "" : "  \(extra)").font(.system(size: 13)).foregroundColor(Theme.dim))
                .lineLimit(2)
            Spacer()
            Text(BodyMath.text(r) + (r.pulse.map { " · \($0)" } ?? "")).fontWeight(.semibold).foregroundColor(Theme.text)
        }
        .font(.system(size: 15))
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Delete reading", role: .destructive) { store.change { $0.bp.removeAll { $0.id == r.id } } }
        }
    }

    private func save() {
        guard let s = Int(systolic), let d = Int(diastolic) else {
            problem = "Enter both numbers."
            return
        }
        let p = pulse.isEmpty ? nil : Int(pulse)
        guard BodyMath.valid(systolic: s, diastolic: d, pulse: p) else {
            problem = "Those numbers don't look right. The top number should be bigger than the bottom."
            return
        }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = BPReading(id: UUID().uuidString, time: Int64(time.timeIntervalSince1970 * 1000), systolic: s, diastolic: d, pulse: p,
                          tags: BodyMath.bpTags.filter { tags.contains($0) }, note: trimmed.isEmpty ? nil : trimmed)
        store.change { $0.save(r) }
        systolic = ""; diastolic = ""; pulse = ""; note = ""; showNote = false; problem = ""; time = Date(); tags = []
        focus = nil
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
    }
}

// MARK: - Menopause

struct MenopauseView: View {
    @ObservedObject private var store = BodyStore.shared
    @State private var compare: SweatCompare?
    @State private var editing: SymptomEvent?

    private var cal: Calendar { .current }
    private var key: String { DayEngine.shared.key(Date()) }
    private var counted: [String] { store.data.settings.symptoms.filter { BodyMath.counted.contains($0) } }
    private var rated: [String] { store.data.settings.symptoms.filter { !BodyMath.counted.contains($0) } }

    private var flashDays: [FlashDay] {
        let today = cal.startOfDay(for: Date())
        return (0..<30).reversed().compactMap { i in
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { return nil }
            let n = store.data.events.filter { $0.name == "Hot flashes" && cal.isDate(Date(timeIntervalSince1970: Double($0.time) / 1000), inSameDayAs: d) }.count
            return FlashDay(day: d, count: n)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Menopause").font(Theme.display(30)).foregroundColor(Theme.text)
                todayCard
                if store.data.settings.symptoms.contains("Night sweats") { sweatCard }
                if store.data.settings.symptoms.contains("Hot flashes") { flashCard }
                Text("Your four are set up for you; others turn on under \"+\". Shown on your phone only. Zdravlje doesn't diagnose; talk with your doctor about anything that worries you.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { e in EventEditSheet(event: e) }
        .task { await loadCompare() }
    }

    private var todayCard: some View {
        Card(accent: lilac) {
            Text("Today and last night").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            if !counted.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(counted, id: \.self) { countTile($0) }
                }
            }
            if !rated.isEmpty {
                Text("How bad, today").font(.system(size: 13)).foregroundColor(Theme.dim).padding(.top, 4)
                ForEach(rated, id: \.self) { ratingRow($0) }
                Text("0 none, 1 mild, 2 noticeable, 3 bad. Night-sweat times can be rough; tap a time to change it.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            }
            NavigationLink { BodySettingsView() } label: {
                Text("+ Brain fog, mood, headache, other").font(.system(size: 13)).foregroundColor(Theme.dim)
                    .padding(.horizontal, 12).frame(minHeight: 34)
                    .overlay(Capsule().stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private func countTile(_ name: String) -> some View {
        let list = SymptomSummary.todayEvents(store.data, name)
        return VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.system(size: 13)).foregroundColor(lilac)
            HStack {
                Text("\(list.count)").font(Theme.display(26)).foregroundColor(Theme.text)
                Spacer()
                Button {
                    store.change { $0.addEvent(SymptomEvent(id: UUID().uuidString, time: Int64(Date().timeIntervalSince1970 * 1000), name: name)) }
                } label: {
                    Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundColor(Theme.bg)
                        .frame(width: 44, height: 44).background(lilac).clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a \(BodyMath.shortName(name).lowercased())")
            }
            if list.isEmpty {
                Text("None yet").font(.system(size: 12)).foregroundColor(Theme.dim)
            } else {
                WrapLayout(spacing: 4) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                        Button { editing = e } label: {
                            Text(Theme.clock(e.time) + (i < list.count - 1 ? "," : "")).font(.system(size: 12)).foregroundColor(Theme.dim).underline()
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Change the time or delete")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(lilacBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func ratingRow(_ name: String) -> some View {
        let current = store.data.ratings[key]?[name]
        return HStack {
            Text(name).font(.system(size: 15)).foregroundColor(Theme.text)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { l in
                    Button {
                        let k = key
                        store.change { $0.rate(name, day: k, level: current == l ? nil : l) }
                    } label: {
                        Text("\(l)").font(.system(size: 13, weight: current == l ? .semibold : .regular))
                            .foregroundColor(current == l ? lilac : Theme.text)
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(current == l ? lilac : Theme.line, lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(name), \(BodyMath.levels[l])")
                    .accessibilityAddTraits(current == l ? .isSelected : [])
                }
            }
        }
        .frame(minHeight: 48)
    }
    @ViewBuilder private var sweatCard: some View {
        Card(accent: lilac) {
            HStack(alignment: .firstTextBaseline) {
                Text("Night sweats and your sleep").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Spacer()
                Text("last 30 nights").font(.system(size: 13)).foregroundColor(Theme.dim)
            }
            if let c = compare, c.withN >= 3, c.withoutN >= 3 {
                HStack {
                    Text("").frame(maxWidth: .infinity, alignment: .leading)
                    Text("With sweats").frame(width: 90, alignment: .trailing)
                    Text("Without").frame(width: 70, alignment: .trailing)
                }
                .font(.system(size: 12)).foregroundColor(Theme.dim)
                compareRow("Sleep score", c.score) { "\(Int($0.rounded()))" }
                compareRow("Times awake", c.awake) { "\(Int($0.rounded()))" }
                compareRow("Asleep", c.asleep) { Theme.duration($0 * 60) }
                if let a = c.asleep.0, let b = c.asleep.1 {
                    let diff = Int((b - a).rounded())
                    Text("\(c.withN) nights with sweats, \(c.withoutN) without." + (diff >= 10 ? " Sweats cost you about \(diff) minutes of sleep a night." : ""))
                        .font(.system(size: 13)).foregroundColor(Color(hex: 0xC9D3CE))
                }
            } else {
                Text("Shows once you have at least 3 nights with sweats and 3 without, with the band on.")
                    .font(.system(size: 14)).foregroundColor(Color(hex: 0xC9D3CE))
            }
        }
    }

    private func compareRow(_ label: String, _ v: (Double?, Double?), _ f: (Double) -> String) -> some View {
        HStack {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Text(v.0.map(f) ?? "--").fontWeight(.semibold).frame(width: 90, alignment: .trailing)
            Text(v.1.map(f) ?? "--").fontWeight(.semibold).frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 15)).foregroundColor(Theme.text).frame(minHeight: 32)
    }

    @ViewBuilder private var flashCard: some View {
        let days = flashDays
        let total = days.map(\.count).reduce(0, +)
        Card(accent: lilac) {
            Text("Hot flashes, last 30 days").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            if total > 0 {
                Chart(days) { d in
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Hot flashes", d.count)).foregroundStyle(lilac)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
                .frame(height: 120)
                let since = Int64((cal.date(byAdding: .day, value: -30, to: Date()) ?? Date()).timeIntervalSince1970 * 1000)
                if let h = BodyMath.busiestHours(store.data.events.filter { $0.name == "Hot flashes" && $0.time >= since }.map(\.time), calendar: cal) {
                    Text("Most often between \(BodyMath.hourText(h)) and \(BodyMath.hourText(h + 3)).")
                        .font(.system(size: 13)).foregroundColor(Color(hex: 0xC9D3CE))
                }
            } else {
                Text("Nothing logged yet. Tap +1 when one starts.").font(.system(size: 14)).foregroundColor(Color(hex: 0xC9D3CE))
            }
        }
    }

    private func loadCompare() async {
        let events = store.data.events.filter { $0.name == "Night sweats" }
        let settings = SettingsStore.shared.value
        let result = await Task.detached(priority: .userInitiated) { () -> SweatCompare in
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let sweatNights = Set(events.map { BodyMath.nightKey($0.time, calendar: cal) })
            var with: [DayRecord] = [], without: [DayRecord] = []
            for i in 0..<30 {
                guard let d = cal.date(byAdding: .day, value: -i, to: today),
                      let r = DayEngine.shared.record(d, settings: settings), r.sleep != nil else { continue }
                if sweatNights.contains(r.day) { with.append(r) } else { without.append(r) }
            }
            func m(_ rs: [DayRecord], _ f: (DayRecord) -> Double?) -> Double? { TrendMath.mean(rs.compactMap(f)) }
            var c = SweatCompare()
            c.withN = with.count
            c.withoutN = without.count
            c.score = (m(with) { $0.sleepScore }, m(without) { $0.sleepScore })
            c.awake = (m(with) { $0.sleep?.awakeEvents.map(Double.init) }, m(without) { $0.sleep?.awakeEvents.map(Double.init) })
            c.asleep = (m(with) { $0.sleep?.asleepMin }, m(without) { $0.sleep?.asleepMin })
            return c
        }.value
        compare = result
    }
}


// MARK: - Cycle

struct CycleView: View {
    @ObservedObject private var store = BodyStore.shared
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var showMore = false
    @State private var showMood = false
    @State private var recoveryNote: String?

    private static let moods = ["Calm", "Happy", "Low", "Anxious", "Irritable"]

    private var cal: Calendar { .current }
    /// The month grid starts on Monday, like the mockup.
    private var grid: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c }
    private var prediction: CycleMath.Prediction? { CycleMath.predict(store.data.flow, today: Date(), cal) }
    private var selectedKey: String { CycleMath.key(selected, cal) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cycle").font(Theme.display(30)).foregroundColor(Theme.text)
                summaryCard
                calendarCard
                dayCard
                patternsCard
                Text("Each person picks which symptoms show; hidden ones stay under More. Predictions are estimates from your own logs, not birth control.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRecovery() }
    }

    @ViewBuilder private var summaryCard: some View {
        Card(accent: cyclePink) {
            if let p = prediction {
                HStack(alignment: .firstTextBaseline) {
                    Text("Day \(p.cycleDay)").font(Theme.display(28)).foregroundColor(Theme.text)
                    Spacer()
                    Text(p.fromHistory ? "your cycles: \(p.shortest) to \(p.longest) days" : "a typical cycle, for now")
                        .font(.system(size: 13)).foregroundColor(Theme.dim)
                }
                (Text("Next period likely ") + Text("\(short(p.nextFrom)) to \(short(p.nextTo))").bold() + Text("."))
                    .font(.system(size: 14)).foregroundColor(soft)
                Text((p.fromHistory ? "A range, from your last \(min(6, CycleMath.lengths(CycleMath.starts(store.data.flow, cal), cal).count)) cycles."
                      : "Gets more accurate once you've logged 3 cycles.")
                     + " With band temperature (after the history download), Zdravlje can also show when ovulation likely happened.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            } else {
                Text("Log the first day of your period below and Zdravlje will start counting.").font(.system(size: 15)).foregroundColor(Theme.text)
            }
        }
    }

    private func short(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }

    private var calendarCard: some View {
        let g = grid
        let symbols = g.veryShortWeekdaySymbols
        let first = g.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        let range = g.range(of: .day, in: .month, for: month) ?? 1..<31
        let offset = (g.component(.weekday, from: month) - g.firstWeekday + 7) % 7
        let cells: [Date?] = Array(repeating: nil, count: offset) + range.compactMap { g.date(byAdding: .day, value: $0 - 1, to: month) }
        return Card(accent: cyclePink) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide))).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.text)
                if g.component(.year, from: month) != g.component(.year, from: Date()) {
                    Text(month.formatted(.dateTime.year())).font(.system(size: 14)).foregroundColor(Theme.dim)
                }
                Spacer()
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 40, height: 36) }
                    .accessibilityLabel("Previous month")
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 40, height: 36) }
                    .accessibilityLabel("Next month")
            }
            .foregroundColor(Theme.dim)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, w in
                    Text(w).font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
                    if let d { dayCell(d) } else { Color.clear.frame(height: 34) }
                }
            }
            Text("Filled: period days you logged. Dashed: likely next period.").font(.system(size: 12)).foregroundColor(Theme.dim)
        }
    }

    private func shiftMonth(_ by: Int) {
        if let m = cal.date(byAdding: .month, value: by, to: month) { month = m }
    }

    private func dayCell(_ d: Date) -> some View {
        let k = CycleMath.key(d, cal)
        let f = store.data.flow[k] ?? 0
        let predicted = prediction.map { d >= $0.nextFrom && d <= $0.nextTo } ?? false
        let isSel = cal.isDate(d, inSameDayAs: selected)
        let future = d > Date()
        let shape = RoundedRectangle(cornerRadius: 8)
        return Button { if !future { selected = cal.startOfDay(for: d) } } label: {
            Text("\(cal.component(.day, from: d))")
                .font(.system(size: 13, weight: isSel ? .semibold : .regular))
                .foregroundColor(f >= 2 ? Theme.bg : future && !predicted ? Theme.dim : Theme.text)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(shape.fill(f >= 2 ? cyclePink : f == 1 ? cyclePink.opacity(0.3) : Color.clear))
                .overlay(shape.stroke(cyclePink, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).opacity(predicted && f < 2 ? 1 : 0))
                .overlay(shape.stroke(Theme.text, lineWidth: 2).opacity(isSel ? 1 : 0))
        }
        .buttonStyle(.plain)
        .frame(height: 34)
        .accessibilityLabel("\(d.formatted(date: .abbreviated, time: .omitted))\(f > 0 ? ", \(CycleMath.flowNames[f])" : "")\(predicted ? ", likely period" : "")")
    }

    private var dayCard: some View {
        let f = store.data.flow[selectedKey] ?? 0
        let notes = store.data.cycleNotes[selectedKey] ?? []
        let shown = store.data.settings.cycleSymptoms
        let hidden = CycleMath.allSymptoms.filter { !shown.contains($0) }
        let list = shown + (showMore ? hidden : [])
        let mood = notes.first { $0.hasPrefix("Mood") }
        return Card(accent: cyclePink) {
            Text(cal.isDateInToday(selected) ? "Today" : selected.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            Text("Period").font(.system(size: 13)).foregroundColor(Theme.dim).padding(.top, 2)
            WrapLayout {
                ForEach(0..<5, id: \.self) { i in
                    Pill(text: CycleMath.flowNames[i], on: f == i, color: cyclePink) {
                        let k = selectedKey
                        store.change { $0.flow[k] = i == 0 ? nil : i }
                    }
                }
            }
            Text("Symptoms").font(.system(size: 13)).foregroundColor(Theme.dim).padding(.top, 6)
            WrapLayout {
                ForEach(list, id: \.self) { name in
                    if name == "Mood" {
                        Pill(text: mood.map { $0 + " ›" } ?? "Mood ›", on: mood != nil, color: cyclePink) { showMood.toggle() }
                    } else {
                        Pill(text: name, on: notes.contains(name), color: cyclePink) { toggle(name) }
                    }
                }
                if !hidden.isEmpty {
                    Pill(text: showMore ? "Fewer" : "More", dashed: true) { showMore.toggle() }
                }
            }
            if showMood && list.contains("Mood") {
                WrapLayout {
                    ForEach(Self.moods, id: \.self) { m in
                        Pill(text: m, on: mood == "Mood: \(m)", color: cyclePink) { setMood(m, current: mood) }
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    private func toggle(_ name: String) {
        let k = selectedKey
        store.change { d in
            var n = d.cycleNotes[k] ?? []
            if let i = n.firstIndex(of: name) { n.remove(at: i) } else { n.append(name) }
            d.cycleNotes[k] = n.isEmpty ? nil : n
        }
    }

    private func setMood(_ m: String, current: String?) {
        let k = selectedKey
        let value = "Mood: \(m)"
        store.change { d in
            var n = (d.cycleNotes[k] ?? []).filter { !$0.hasPrefix("Mood") }
            if current != value { n.append(value) }
            d.cycleNotes[k] = n.isEmpty ? nil : n
        }
    }

    private var patternsCard: some View {
        let st = CycleMath.starts(store.data.flow, cal)
        let before = CycleMath.beforePeriod(store.data.cycleNotes, starts: st, cal)
        return Card(accent: cyclePink) {
            Text("Patterns").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            if st.count < 3 {
                Text("Appears once there are 3 logged cycles.").font(.system(size: 12)).foregroundColor(Theme.dim)
            } else {
                if !before.isEmpty {
                    Text("\(listText(before)) show\(before.count == 1 ? "s" : "") up in the 5 days before your period in most of your recent cycles.")
                        .font(.system(size: 14)).foregroundColor(soft)
                }
                if let r = recoveryNote { Text(r).font(.system(size: 14)).foregroundColor(soft) }
                if before.isEmpty && recoveryNote == nil {
                    Text("Nothing stands out yet.").font(.system(size: 14)).foregroundColor(soft)
                }
            }
        }
    }

    private func listText(_ v: [String]) -> String {
        let l = v.map { $0.lowercased() }
        let joined = l.count <= 1 ? l.joined() : l.dropLast().joined(separator: ", ") + " and " + l.last!
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// Recovery in the 3 days before a period against other days, over the last 90 days.
    private func loadRecovery() async {
        let st = CycleMath.starts(store.data.flow, cal)
        guard st.count >= 3 else { return }
        let settings = SettingsStore.shared.value
        let note = await Task.detached(priority: .userInitiated) { () -> String? in
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            var pre: Set<String> = []
            for s in st { for i in 1...3 { if let d = cal.date(byAdding: .day, value: -i, to: s) { pre.insert(CycleMath.key(d, cal)) } } }
            var a: [Double] = [], b: [Double] = []
            for i in 0..<90 {
                guard let d = cal.date(byAdding: .day, value: -i, to: today),
                      let r = DayEngine.shared.record(d, settings: settings)?.recovery else { continue }
                if pre.contains(CycleMath.key(d, cal)) { a.append(r) } else { b.append(r) }
            }
            guard a.count >= 5, b.count >= 10, let ma = TrendMath.mean(a), let mb = TrendMath.mean(b) else { return nil }
            let diff = Int((mb - ma).rounded())
            if diff >= 5 { return "Recovery runs about \(diff) points lower in the 3 days before your period." }
            if diff <= -5 { return "Recovery runs about \(-diff) points higher in the 3 days before your period." }
            return nil
        }.value
        recoveryNote = note
    }
}


/// The Log tab: what you enter yourself. Meals and the Body log, with a
/// switch when both are on.
struct LogTab: View {
    @ObservedObject private var nav = AppNav.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var store = BodyStore.shared
    @ObservedObject private var doses = DoseStore.shared

    private var showBody: Bool {
        let meals = settings.value.mealsOn, body = store.data.settings.anyOn || doses.data.medicationsOn
        if !meals { return true }
        if !body { return false }
        return nav.logBody
    }

    var body: some View {
        NavigationStack {
            if showBody { BodyLogView(inLog: true) } else { MealsView(inLog: true) }
        }
    }
}

/// "Log" with the Ask button, and the Meals or Body switch when both are on.
struct LogHeader: View {
    @ObservedObject private var nav = AppNav.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var store = BodyStore.shared
    @ObservedObject private var doses = DoseStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScreenTitle(title: "Log", topic: nav.logBody ? .body : .meals)
            if settings.value.mealsOn && (store.data.settings.anyOn || doses.data.medicationsOn) {
                Picker("Show", selection: $nav.logBody) {
                    Text("Meals").tag(false)
                    Text("Body").tag(true)
                }
                .pickerStyle(.segmented)
            }
        }
    }
}
