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

// MARK: - Today card

struct BodyLogCard: View {
    @ObservedObject private var store = BodyStore.shared

    var body: some View {
        if store.data.settings.anyOn {
            NavigationLink { BodyLogView() } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Body log").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                        Spacer()
                        Text("Log").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.green)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.dim)
                    }
                    if store.data.settings.bloodPressure {
                        HStack {
                            Text("Blood pressure").foregroundColor(Theme.dim)
                            Spacer()
                            if let r = store.data.bp.first {
                                Text(BodyMath.text(r)).fontWeight(.semibold).foregroundColor(Theme.text)
                                Text(BodyMath.when(r.time, now: Date(), calendar: .current)).foregroundColor(Theme.dim)
                            } else {
                                Text("No readings yet").foregroundColor(Theme.dim)
                            }
                        }
                        .font(.system(size: 14))
                    }
                    if store.data.settings.menopause, let line = SymptomSummary.todayLine(store.data) {
                        HStack {
                            Text("Symptoms").foregroundColor(Theme.dim)
                            Spacer()
                            Text(line).foregroundColor(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .font(.system(size: 14))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Body log screen

struct BodyLogView: View {
    @ObservedObject private var store = BodyStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Body log").font(Theme.display(30)).foregroundColor(Theme.text)
                Text("Tap one to log it. Each opens its own screen with history.").font(.system(size: 14)).foregroundColor(Theme.dim)
                if store.data.settings.bloodPressure {
                    NavigationLink { BPView() } label: {
                        entry(icon: "heart.text.square", color: Theme.orange, title: "Blood pressure",
                              note: store.data.bp.first.map { "Last: \(BodyMath.text($0)), \(Theme.clock($0.time))" } ?? "No readings yet")
                    }
                    .buttonStyle(.plain)
                }
                if store.data.settings.menopause {
                    NavigationLink { SymptomsView() } label: {
                        entry(icon: "thermometer.medium", color: Color(hex: 0xC7A6E8), title: "Symptoms",
                              note: SymptomSummary.todayLine(store.data) ?? store.data.settings.symptoms.joined(separator: ", "))
                    }
                    .buttonStyle(.plain)
                    Text("Quick log, today").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.dim).padding(.top, 4)
                    SymptomQuickLog()
                    Text("Tap +1 each time; the time is saved so it can be lined up with your sleep and heart rate.")
                        .font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                if !store.data.settings.anyOn {
                    Text("Nothing is turned on. Choose what to track in Settings, Body log.").font(.system(size: 14)).foregroundColor(soft)
                }
                NavigationLink { BodySettingsView() } label: {
                    Text("Choose what to track").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.blue).frame(minHeight: 44)
                }
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private func entry(icon: String, color: Color, title: String, note: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 20)).foregroundColor(color).frame(width: 36, height: 36)
                .background(Theme.raised).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.text)
                Text(note).font(.system(size: 13)).foregroundColor(Theme.dim)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.dim)
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
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
                Card {
                    Text("New reading").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                    field("Top (systolic)", $systolic, 0)
                    field("Bottom (diastolic)", $diastolic, 1)
                    field("Pulse (optional)", $pulse, 2)
                    DatePicker("Time", selection: $time, in: ...Date()).font(.system(size: 15)).foregroundColor(Theme.text)
                    ToggleChips(items: BodyMath.bpTags, selected: $tags)
                    if showNote {
                        TextField("Note", text: $note).textFieldStyle(.roundedBorder)
                    } else {
                        Button("+ Note") { showNote = true }.font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.blue).frame(minHeight: 36)
                    }
                    if !problem.isEmpty { Text(problem).font(.system(size: 13)).foregroundColor(Theme.orange) }
                    Button(saved ? "Saved" : "Save reading") { save() }.buttonStyle(SolidButton(color: Theme.green))
                }
                if month.count >= 2 { chart }
                if !store.data.bp.isEmpty {
                    Card {
                        ForEach(Array(store.data.bp.prefix(30).enumerated()), id: \.element.id) { i, r in
                            if i > 0 { Divider().overlay(Theme.track) }
                            readingRow(r)
                        }
                    }
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

    private func field(_ label: String, _ text: Binding<String>, _ tag: Int) -> some View {
        HStack {
            Text(label).font(.system(size: 15)).foregroundColor(Theme.text)
            Spacer()
            TextField("--", text: text).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                .font(.system(size: 20, weight: .semibold)).frame(width: 80).focused($focus, equals: tag)
        }
        .frame(minHeight: 44)
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
        return Card {
            HStack {
                Text("Last 30 days").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Spacer()
                if let a = BodyMath.average(month) { Text("Average \(a.systolic)/\(a.diastolic)").font(.system(size: 13)).foregroundColor(Theme.dim) }
            }
            Chart {
                if let r = sysRange {
                    RectangleMark(xStart: .value("From", first), xEnd: .value("To", last), yStart: .value("Low", r.lowerBound), yEnd: .value("High", r.upperBound))
                        .foregroundStyle(Theme.orange.opacity(0.15))
                }
                if let r = diaRange {
                    RectangleMark(xStart: .value("From", first), xEnd: .value("To", last), yStart: .value("Low", r.lowerBound), yEnd: .value("High", r.upperBound))
                        .foregroundStyle(Theme.blue.opacity(0.15))
                }
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.date), y: .value("mmHg", p.value), series: .value("Kind", p.kind))
                        .foregroundStyle(p.kind == "Top" ? Theme.orange : Theme.blue)
                    PointMark(x: .value("Time", p.date), y: .value("mmHg", p.value))
                        .foregroundStyle(p.kind == "Top" ? Theme.orange : Theme.blue).symbolSize(20)
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel() } }
            .frame(height: 160)
            Text("Shaded bands are your usual range. Top number orange, bottom blue.").font(.system(size: 12)).foregroundColor(Theme.dim)
        }
    }

    private func readingRow(_ r: BPReading) -> some View {
        let d = Date(timeIntervalSince1970: Double(r.time) / 1000)
        let day = Calendar.current.isDateInToday(d) ? "Today" : Calendar.current.isDateInYesterday(d) ? "Yesterday" : Theme.dayText.string(from: d)
        let extra = (r.tags + [r.note].compactMap { $0 }).joined(separator: ", ").lowercased()
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(day), \(Theme.clock(r.time))").font(.system(size: 14)).foregroundColor(Theme.text)
                if !extra.isEmpty { Text(extra).font(.system(size: 12)).foregroundColor(Theme.dim) }
            }
            Spacer()
            Text(BodyMath.text(r)).font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.text)
            if let p = r.pulse { Text("· \(p)").font(.system(size: 14)).foregroundColor(Theme.dim) }
        }
        .frame(minHeight: 44)
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
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = BPReading(id: UUID().uuidString, time: Int64(time.timeIntervalSince1970 * 1000), systolic: s, diastolic: d, pulse: p,
                          tags: BodyMath.bpTags.filter { tags.contains($0) }, note: note.isEmpty ? nil : note)
        store.change { $0.save(r) }
        systolic = ""; diastolic = ""; pulse = ""; self.note = ""; showNote = false; problem = ""; time = Date()
        focus = nil
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
    }
}

/// Tappable chips that wrap onto more lines.
struct ToggleChips: View {
    let items: [String]
    @Binding var selected: Set<String>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                let on = selected.contains(item)
                Button {
                    if on { selected.remove(item) } else { selected.insert(item) }
                } label: {
                    Text(on ? "✓ \(item)" : item).font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundColor(on ? Theme.green : Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .overlay(Capsule().stroke(on ? Theme.green : Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

// MARK: - Settings, Body log

struct BodySettingsView: View {
    @ObservedObject private var store = BodyStore.shared

    private func binding(_ key: WritableKeyPath<BodySettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings[keyPath: key] }, set: { v in var s = store.settings; s[keyPath: key] = v; store.settings = s })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: binding(\.bloodPressure)) { row("Blood pressure", "Readings you enter by hand") }
                Toggle(isOn: binding(\.menopause)) { row("Menopause symptoms", "Hot flashes, night sweats and more") }
            } footer: {
                Text("Turn on only what you want to track. Anything turned off disappears from Today and the Body log screen; what you already logged is kept. Cycle tracking comes next.")
            }
            if store.settings.menopause {
                Section {
                    ToggleChips(items: BodyMath.allSymptoms, selected: Binding(
                        get: { Set(store.settings.symptoms) },
                        set: { v in var st = store.settings; st.symptoms = BodyMath.allSymptoms.filter { v.contains($0) }; store.settings = st }))
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
struct SymptomQuickLog: View {
    @ObservedObject private var store = BodyStore.shared
    @State private var editing: SymptomEvent?

    private var key: String { DayEngine.shared.key(Date()) }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(store.data.settings.symptoms, id: \.self) { name in
                if BodyMath.counted.contains(name) { countRow(name) } else { ratingRow(name) }
            }
        }
        .sheet(item: $editing) { e in EventEditSheet(event: e) }
    }

    private func countRow(_ name: String) -> some View {
        let list = SymptomSummary.todayEvents(store.data, name)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Spacer()
                Text("\(list.count)").font(Theme.display(22)).foregroundColor(Theme.text).monospacedDigit()
                Button {
                    store.change { $0.addEvent(SymptomEvent(id: UUID().uuidString, time: Int64(Date().timeIntervalSince1970 * 1000), name: name)) }
                } label: {
                    Text("+1").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.bg)
                        .frame(width: 56, height: 40).background(Color(hex: 0xC7A6E8)).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Log one \(SymptomSummary.singular(name.lowercased()))")
            }
            if !list.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(list) { e in
                            Button { editing = e } label: {
                                Text(Theme.clock(e.time)).font(.system(size: 12)).foregroundColor(Theme.text)
                                    .padding(.horizontal, 10).frame(minHeight: 30).background(Theme.raised).clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Change the time or delete")
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func ratingRow(_ name: String) -> some View {
        let current = store.data.ratings[key]?[name]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Spacer()
                Text(current.map { BodyMath.levels[$0] } ?? "not logged").font(.system(size: 13)).foregroundColor(Theme.dim)
            }
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { l in
                    Button {
                        let k = key
                        store.change { $0.rate(name, day: k, level: current == l ? nil : l) }
                    } label: {
                        Text("\(l)").font(.system(size: 15, weight: .semibold))
                            .foregroundColor(current == l ? Theme.bg : Theme.text)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(current == l ? Color(hex: 0xC7A6E8) : Theme.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(name), \(BodyMath.levels[l])")
                    .accessibilityAddTraits(current == l ? .isSelected : [])
                }
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

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

struct SymptomsView: View {
    @ObservedObject private var store = BodyStore.shared
    @State private var compare: SweatCompare?

    private var cal: Calendar { .current }

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
                Text("Symptoms").font(Theme.display(30)).foregroundColor(Theme.text)
                Text("Today and last night").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.dim)
                SymptomQuickLog()
                Text("0 none, 1 mild, 2 noticeable, 3 bad. Night-sweat times can be rough; tap a time to change it.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
                NavigationLink { BodySettingsView() } label: {
                    Text("+ Brain fog, mood, headache, other").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.blue).frame(minHeight: 44)
                }
                if store.data.settings.symptoms.contains("Night sweats") { sweatCard }
                if store.data.settings.symptoms.contains("Hot flashes") { flashCard }
                Text("Shown on your phone only. Zdravlje doesn't diagnose; talk with your doctor about anything that worries you.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadCompare() }
    }

    @ViewBuilder private var sweatCard: some View {
        Card {
            Text("Night sweats and your sleep, last 30 nights").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
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
        Card {
            HStack {
                Text("Hot flashes, last 30 days").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Spacer()
                Text("\(total) logged").font(.system(size: 13)).foregroundColor(Theme.dim)
            }
            if total > 0 {
                Chart(days) { d in
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Hot flashes", d.count)).foregroundStyle(Color(hex: 0xC7A6E8))
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
