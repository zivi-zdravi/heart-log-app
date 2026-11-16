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
            } footer: {
                Text("Turn on only what you want to track. Anything turned off disappears from Today and the Body log screen; what you already logged is kept. Symptoms and cycle tracking come next.")
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
