import SwiftUI

/// The band alarm: a weekly schedule, with the next wake kept on the band.
/// Built from the approved Alarm mockup.
struct AlarmView: View {
    @ObservedObject private var store = AlarmStore.shared
    @ObservedObject private var link = BandLink.shared
    @State private var editing: Int?
    @State private var pickerTime = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Alarm").font(Theme.display(30)).foregroundColor(Theme.text)
                Text("Buzzes on your wrist. The band keeps the alarm itself, so it fires even if your phone is off.")
                    .font(.system(size: 14)).foregroundColor(Theme.dim)
                nextCard
                scheduleCard
                Card {
                    HStack {
                        Text("Smart wake").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                        Spacer()
                        Text("Coming later").font(.system(size: 14)).foregroundColor(Theme.dim)
                    }
                    Text("Buzz up to 20 minutes early, at a lighter moment. Needs morning stage estimates, so it arrives with the band history download.")
                        .font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                Button("Test the buzz") { link.testBuzz() }
                    .buttonStyle(TintButton(color: Theme.text))
                    .disabled(!link.ready)
                if let next = store.next {
                    Button("Cancel the next alarm") { store.schedule.skipThrough = next }
                        .buttonStyle(TintButton(color: Theme.orange))
                }
                Text("Zdravlje sends the next alarm to the band and waits for the band to confirm it saved. The band holds one alarm at a time, so after it fires, Zdravlje sends the next one. If another app also sets the band's alarm, the two will overwrite each other.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) { timeSheet }
    }

    // MARK: Next alarm

    private var nextCard: some View {
        Card {
            Text("NEXT").font(.system(size: 12, weight: .semibold)).tracking(1).foregroundColor(Theme.dim)
            if let next = store.next {
                Text(Self.dayTime(next)).font(Theme.display(40)).foregroundColor(Theme.text)
                Text(Self.relative(next)).font(.system(size: 14)).foregroundColor(Theme.dim)
                statusChip(for: next)
            } else {
                Text("Off").font(Theme.display(40)).foregroundColor(Theme.text)
                Text(store.schedule.anyOn ? "Nothing scheduled in the next week." : "Turn on a day below to set an alarm.")
                    .font(.system(size: 14)).foregroundColor(Theme.dim)
            }
        }
    }

    @ViewBuilder
    private func statusChip(for next: Date) -> some View {
        let onBand = store.armed.map { $0.confirmed && abs($0.wake.timeIntervalSince(next)) < 1 } ?? false
        if onBand {
            chip("Saved on the band", color: Theme.green)
            Text("The band confirmed it has this alarm.").font(.system(size: 12)).foregroundColor(Theme.dim)
        } else if case .failed(let why) = link.alarmStatus {
            chip("Not saved yet", color: Theme.orange)
            Text(why).font(.system(size: 12)).foregroundColor(Theme.dim)
        } else if link.alarmStatus == .sending {
            chip("Sending to the band", color: Theme.dim)
        } else {
            chip("Not saved yet", color: Theme.orange)
            Text(link.ready ? "Sending shortly." : "It will be sent when the band connects. Make sure Zdravlje is recording.")
                .font(.system(size: 12)).foregroundColor(Theme.dim)
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    // MARK: Weekly schedule

    private var scheduleCard: some View {
        Card {
            ForEach(0..<7, id: \.self) { i in
                HStack {
                    Text(AlarmSchedule.weekdayNames[i])
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(store.schedule.days[i].on ? Theme.text : Theme.dim)
                        .frame(width: 48, alignment: .leading)
                    Button(AlarmSchedule.label(minutes: store.schedule.days[i].minutes)) { startEditing(i) }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(store.schedule.days[i].on ? Theme.text : Theme.dim)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                        .accessibilityLabel("Change \(AlarmSchedule.weekdayNames[i]) wake time")
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.schedule.days[i].on },
                        set: { on in
                            store.schedule.days[i].on = on
                            store.schedule.skipThrough = nil
                        }))
                        .labelsHidden()
                        .tint(Theme.green)
                        .accessibilityLabel("\(AlarmSchedule.weekdayNames[i]) alarm")
                }
                .frame(minHeight: 50)
                if i < 6 { Divider().background(Theme.line) }
            }
        }
    }

    private func startEditing(_ i: Int) {
        let m = store.schedule.days[i].minutes
        pickerTime = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        editing = i
    }

    private var timeSheet: some View {
        NavigationStack {
            VStack {
                DatePicker("Wake time", selection: $pickerTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                Spacer()
            }
            .padding()
            .navigationTitle(editing.map { "\(AlarmSchedule.weekdayNames[$0]) wake time" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let i = editing {
                            let c = Calendar.current.dateComponents([.hour, .minute], from: pickerTime)
                            store.schedule.days[i].minutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                            store.schedule.days[i].on = true
                            store.schedule.skipThrough = nil
                        }
                        editing = nil
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: Formatting

    static func dayTime(_ d: Date) -> String {
        let i = AlarmSchedule.index(of: d, calendar: .current)
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return "\(AlarmSchedule.weekdayNames[i]) \(AlarmSchedule.label(minutes: (c.hour ?? 0) * 60 + (c.minute ?? 0)))"
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}
