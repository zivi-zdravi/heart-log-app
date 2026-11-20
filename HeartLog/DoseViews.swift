import SwiftUI

/// Supplements and medications, saved as doses.json (included in backups).
final class DoseStore: ObservableObject {
    static let shared = DoseStore()
    static let fileName = "doses.json"

    @Published private(set) var data: DoseData

    private static var url: URL { Store.shared.dir.appendingPathComponent(fileName) }

    private init() {
        data = (try? JSONDecoder().decode(DoseData.self, from: Data(contentsOf: Self.url))) ?? DoseData()
    }

    func reload() {
        let d = (try? JSONDecoder().decode(DoseData.self, from: Data(contentsOf: Self.url))) ?? DoseData()
        if Thread.isMainThread { data = d } else { DispatchQueue.main.async { self.data = d } }
    }

    func change(_ edit: (inout DoseData) -> Void) {
        var d = data
        edit(&d)
        guard d != data else { return }
        data = d
        JSONFile.write(d, to: Self.url)
    }

    static func today() -> String { DayEngine.shared.key(Date()) }

    func toggle(_ item: String, day: String = DoseStore.today()) {
        change {
            var t = $0.taken[day] ?? [:]
            if t[item] != nil { t[item] = nil } else { t[item] = Store.nowMs() }
            $0.taken[day] = t
        }
    }

    func takeAll(_ slot: DoseSlot, day: String = DoseStore.today()) {
        change {
            var t = $0.taken[day] ?? [:]
            for i in slot.items where t[i.id] == nil { t[i.id] = Store.nowMs() }
            $0.taken[day] = t
        }
    }

    /// Double-tap: checks off whichever group or item is due. Returns it.
    @discardableResult
    func markDue(now: Date = Date()) -> DoseSlot? {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let day = DayEngine.shared.key(now)
        guard let slot = DoseMath.due(data, day: day, minute: minute) else { return nil }
        takeAll(slot, day: day)
        return slot
    }

    func save(_ item: DoseItem) {
        change {
            $0.items.removeAll { $0.id == item.id }
            $0.items.append(item)
        }
    }

    func delete(item id: String) { change { $0.items.removeAll { $0.id == id } } }

    func save(_ g: DoseGroup) {
        change {
            $0.groups.removeAll { $0.id == g.id }
            $0.groups.append(g)
        }
    }

    /// Deleting a group keeps its items, each on its own at the group's time.
    func delete(group g: DoseGroup) {
        change {
            for i in $0.items.indices where $0.items[i].group == g.id {
                $0.items[i].group = nil
                $0.items[i].time = g.time
                $0.items[i].reminder = g.reminder
            }
            $0.groups.removeAll { $0.id == g.id }
        }
    }
}

private extension DoseKind {
    var color: Color { self == .supplement ? Theme.green : Theme.blue }
    var plural: String { self == .supplement ? "Supplements" : "Medications" }
    var single: String { self == .supplement ? "supplement" : "medication" }
}

private struct CheckCircle: View {
    let on: Bool
    let color: Color
    var body: some View {
        ZStack {
            Circle().stroke(on ? color : Color(hex: 0x55666A), lineWidth: 2).frame(width: 24, height: 24)
            if on {
                Circle().fill(color).frame(width: 24, height: 24)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.bg)
            }
        }
    }
}

/// One group or lone item, with its items to check off.
private struct SlotRows: View {
    let slot: DoseSlot
    let kind: DoseKind
    @ObservedObject private var store = DoseStore.shared

    private var day: String { DoseStore.today() }

    var body: some View {
        let done = DoseMath.allTaken(store.data, day: day, slot)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(slot.isGroup ? slot.name : DoseMath.timeText(slot.time)).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                    HStack(spacing: 4) {
                        Image(systemName: slot.reminder == .off ? "bell.slash" : "bell").font(.system(size: 11))
                        Text(slot.isGroup ? DoseMath.timeText(slot.time) : slot.reminder == .off ? "No reminder" : "Reminder \(slot.reminder.short.lowercased())")
                    }
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                Spacer()
                if slot.items.count > 1 {
                    if done {
                        let last = slot.items.compactMap { store.data.taken[day]?[$0.id] }.max()
                        Text("All taken\(last.map { " \(Theme.clock($0))" } ?? "")").font(.system(size: 13)).foregroundColor(kind.color)
                    } else {
                        Button("Take all") { store.takeAll(slot) }
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(kind.color)
                            .padding(.horizontal, 12).frame(minHeight: 32)
                            .background(kind.color.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            ForEach(slot.items) { i in
                let on = DoseMath.isTaken(store.data, day: day, item: i.id)
                Button { store.toggle(i.id) } label: {
                    HStack(spacing: 10) {
                        CheckCircle(on: on, color: kind.color)
                        (Text(i.name).foregroundColor(Theme.text) + Text("  \(DoseMath.doseText(i))").foregroundColor(Theme.dim))
                            .font(.system(size: 14))
                        if let k = i.kcal, k > 0 { Text("\(Int(k)) cal").font(.system(size: 12)).foregroundColor(kind.color) }
                        Spacer()
                    }
                    .frame(minHeight: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(i.name), \(DoseMath.doseText(i)), \(on ? "taken" : "not taken")")
            }
        }
    }
}

/// Meals: the Supplements card. Body log: the Medications page body.
struct DoseList: View {
    let kind: DoseKind
    @ObservedObject private var store = DoseStore.shared

    var body: some View {
        let slots = DoseMath.slots(store.data, kind)
        let c = DoseMath.counts(store.data, day: DoseStore.today(), kind)
        Card(accent: kind.color) {
            HStack {
                Label(kind.plural, systemImage: "pills").labelStyle(AccentLabel(color: kind.color)).font(.system(size: 13)).foregroundColor(Theme.dim)
                Spacer()
                if c.total > 0 { Text("\(c.taken) of \(c.total) today").font(.system(size: 13)).foregroundColor(Theme.dim) }
            }
            if slots.isEmpty {
                Text("Add what you take once, with its dose and time. Then check it off each day.").font(.system(size: 14)).foregroundColor(Theme.dim)
            }
            ForEach(Array(slots.enumerated()), id: \.element.id) { n, s in
                if n > 0 { Divider().background(Theme.line) }
                SlotRows(slot: s, kind: kind)
            }
            NavigationLink { DoseManageView(kind: kind) } label: {
                Text(slots.isEmpty ? "Add \(kind.plural.lowercased())" : "Manage \(kind.plural.lowercased())")
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(kind.color).frame(minHeight: 40)
            }
        }
    }
}

/// Body log: Medications page.
struct MedicationsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Medications").font(Theme.display(30)).foregroundColor(Theme.text)
                DoseList(kind: .medication)
                Text("Reminders are set for each group, or for a medication on its own, under Manage medications.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Set up groups and items for one kind.
struct DoseManageView: View {
    let kind: DoseKind
    @ObservedObject private var store = DoseStore.shared
    @State private var editingItem: DoseItem?
    @State private var editingGroup: DoseGroup?

    var body: some View {
        Form {
            let groups = store.data.groups.filter { $0.kind == kind }.sorted { $0.time < $1.time }
            Section {
                ForEach(groups) { g in
                    Button { editingGroup = g } label: {
                        HStack {
                            Text(g.name).foregroundColor(Theme.text)
                            Spacer()
                            let n = store.data.items.filter { $0.group == g.id }.count
                            Text("\(DoseMath.timeText(g.time)), \(n) \(n == 1 ? "item" : "items")").foregroundColor(Theme.dim)
                        }
                    }
                }
                Button("New group") { editingGroup = DoseGroup(kind: kind, name: "", time: 8 * 60) }.foregroundColor(kind.color)
            } header: {
                Text("Groups")
            } footer: {
                Text("A group is things you take together, like a morning stack. It has one time and one reminder.")
            }
            Section(kind.plural) {
                ForEach(store.data.items.filter { $0.kind == kind }) { i in
                    Button { editingItem = i } label: {
                        HStack {
                            Text(i.name).foregroundColor(Theme.text)
                            Text(DoseMath.doseText(i)).foregroundColor(Theme.dim)
                            Spacer()
                            Text(store.data.groups.first { $0.id == i.group }?.name ?? DoseMath.timeText(i.time)).foregroundColor(Theme.dim)
                        }
                    }
                }
                Button("Add a \(kind.single)") {
                    editingItem = DoseItem(kind: kind, name: "", amount: 1, unit: kind == .supplement ? "capsule" : "tablet",
                                           group: groups.first?.id)
                }
                .foregroundColor(kind.color)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(kind.plural)
        .sheet(item: $editingItem) { i in DoseItemEditor(item: i) }
        .sheet(item: $editingGroup) { g in DoseGroupEditor(group: g) }
    }
}

private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
    Binding(get: {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minutes.wrappedValue) * 60)
    }, set: { d in
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    })
}

struct DoseItemEditor: View {
    @State var item: DoseItem
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DoseStore.shared
    @State private var amountText = ""
    @State private var kcalText = ""

    private var isNew: Bool { !store.data.items.contains { $0.id == item.id } }
    private var groups: [DoseGroup] { store.data.groups.filter { $0.kind == item.kind }.sorted { $0.time < $1.time } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $item.name)
                    HStack {
                        Text("Dose")
                        TextField("1", text: $amountText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        Picker("", selection: $item.unit) { ForEach(DoseMath.units, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                    }
                    if item.kind == .supplement {
                        HStack {
                            Text("Calories (optional)")
                            TextField("0", text: $kcalText).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        }
                    }
                } footer: {
                    if item.kind == .supplement { Text("Calories count toward your day in Meals when you check it off.") }
                }
                Section("When") {
                    Picker("Take with", selection: $item.group) {
                        ForEach(groups) { g in Text(g.name).tag(Optional(g.id)) }
                        Text("On its own").tag(String?.none)
                    }
                    if item.group == nil {
                        DatePicker("Time", selection: timeBinding($item.time), displayedComponents: .hourAndMinute)
                        NavigationLink {
                            RoutePicker(title: "Reminder", detail: "Reminder for \(item.name.isEmpty ? "this \(item.kind == .supplement ? "supplement" : "medication")" : item.name)", route: $item.reminder, phoneOnly: false)
                        } label: {
                            HStack { Text("Reminder"); Spacer(); Text(item.reminder.label).foregroundColor(Theme.dim) }
                        }
                    }
                }
                if !isNew {
                    Section { Button("Delete", role: .destructive) { store.delete(item: item.id); dismiss() } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(isNew ? "Add" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        item.amount = Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? item.amount
                        item.kcal = item.kind == .supplement ? Double(kcalText) : nil
                        item.name = item.name.trimmingCharacters(in: .whitespaces)
                        store.save(item)
                        dismiss()
                    }
                    .disabled(item.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                amountText = DoseMath.doseText(item).components(separatedBy: " ").first ?? ""
                kcalText = item.kcal.map { String(Int($0)) } ?? ""
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct DoseGroupEditor: View {
    @State var group: DoseGroup
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DoseStore.shared

    private var isNew: Bool { !store.data.groups.contains { $0.id == group.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, like Morning stack", text: $group.name)
                    DatePicker("Time", selection: timeBinding($group.time), displayedComponents: .hourAndMinute)
                    NavigationLink {
                        RoutePicker(title: "Reminder", detail: "Reminder for \(group.name.isEmpty ? "this group" : group.name)", route: $group.reminder, phoneOnly: false)
                    } label: {
                        HStack { Text("Reminder"); Spacer(); Text(group.reminder.label).foregroundColor(Theme.dim) }
                    }
                } footer: {
                    Text("Quiet hours apply. If you've already checked the group off, there's no reminder that day.")
                }
                if !isNew {
                    Section {
                        Button("Delete group", role: .destructive) { store.delete(group: group); dismiss() }
                    } footer: {
                        Text("Its items stay, each on its own at this time.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(isNew ? "New group" : "Edit group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        group.name = group.name.trimmingCharacters(in: .whitespaces)
                        store.save(group)
                        dismiss()
                    }
                    .disabled(group.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
