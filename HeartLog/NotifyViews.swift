import SwiftUI

/// Settings > Notifications (approved mockup).
struct NotificationsView: View {
    @ObservedObject private var store = NotifyStore.shared

    private func binding<T>(_ key: WritableKeyPath<NotifySettings, T>) -> Binding<T> {
        Binding(get: { store.settings[keyPath: key] }, set: { v in store.change { $0[keyPath: key] = v } })
    }

    private func row(_ title: String, _ detail: String, note: String? = nil, _ key: WritableKeyPath<NotifySettings, NotifyRoute>, phoneOnly: Bool = false) -> some View {
        NavigationLink {
            RoutePicker(title: title, detail: detail, route: binding(key), phoneOnly: phoneOnly)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(Theme.text)
                    Text(detail).font(.system(size: 13)).foregroundColor(Theme.dim)
                    if let note { Text(note).font(.system(size: 12)).foregroundColor(Theme.dim).italic() }
                }
                Spacer()
                Text(store.settings[keyPath: key].short)
                    .foregroundColor(store.settings[keyPath: key] == .off ? Theme.dim : Theme.green)
            }
            .frame(minHeight: 44)
        }
    }

    private func sub(_ title: String, _ detail: String, value: String, _ stepper: some View) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(Theme.text)
                Text(detail).font(.system(size: 13)).foregroundColor(Theme.dim)
            }
            Spacer()
            Text(value).foregroundColor(Theme.text).monospacedDigit()
            stepper.labelsHidden().fixedSize()
        }
        .frame(minHeight: 44)
    }

    private func clock(_ key: WritableKeyPath<NotifySettings, Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(store.settings[keyPath: key]) * 60)
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            store.change { $0[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0) }
        })
    }

    var body: some View {
        Form {
            Section {
            } footer: {
                Text("Each one can go to your phone, buzz the band, do both, or stay off. Tap a row to choose.")
            }
            Section("The band") {
                row("Low battery", "When the band drops under \(store.settings.lowBatteryAt)%", \.lowBattery)
                sub("Alert me at", "The battery level that counts as low", value: "\(store.settings.lowBatteryAt)%",
                    Stepper("", value: binding(\.lowBatteryAt), in: 5...50, step: 5))
                row("On the charger", "When you put the band on or take it off the charger", \.charger)
                row("Gone quiet", "When Zdravlje stops hearing the band for 30 minutes",
                    note: "Phone only: the band can't buzz when it isn't connected.", \.goneQuiet, phoneOnly: true)
                row("Zdravlje closed", "When Zdravlje is swiped away while recording, and again an hour later if it's still closed",
                    note: "Phone only. The band keeps everything, and opening Zdravlje picks up where it left off.", \.appClosed, phoneOnly: true)
            }
            Section("Alarm") {
                row("Alarm not saved", "When the band never confirms tonight's alarm",
                    note: "Phone only, for the same reason.", \.alarmNotSaved, phoneOnly: true)
                row("No-alarm check-in", "7 PM on a night you usually have an alarm but none is set", \.noAlarmCheckIn)
            }
            Section("Through the day") {
                row("Wind-down", "45 minutes before your target bedtime from the Sleep screen", \.windDown)
                row("Step goal reached", "Once, when today crosses your steps goal", \.stepGoal)
                sub("Steps goal", "The daily steps that count as your goal", value: store.settings.stepGoalCount.formatted(),
                    Stepper("", value: binding(\.stepGoalCount), in: 1000...30000, step: 500))
                row("Possible activity", "When Zdravlje spots what looks like an activity", \.possibleActivity)
                row("Water reminder", "During your waking hours, if you haven't logged a glass", \.water)
                sub("Remind me every", "How often the water reminder can come",
                    value: store.settings.waterEveryHours == 1 ? "1 hour" : "\(store.settings.waterEveryHours) hours",
                    Stepper("", value: binding(\.waterEveryHours), in: 1...6))
            }
            Section("Overnight") {
                row("Breathing rate higher than usual", "In the morning, when last night was clearly above your usual range", \.breathingHigh)
            }
            Section {
                Toggle(isOn: binding(\.quietOn)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quiet hours").foregroundColor(Theme.text)
                        Text("Nothing buzzes or notifies in this window").font(.system(size: 13)).foregroundColor(Theme.dim)
                    }
                }
                .tint(Theme.green)
                if store.settings.quietOn {
                    DatePicker("Starts", selection: clock(\.quietStart), displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: clock(\.quietEnd), displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("Quiet hours")
            } footer: {
                Text("Your band alarm isn't affected by quiet hours or anything here. Change it on the Alarm screen. These work while Zdravlje is connected to the band; Gone quiet works even when it isn't.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Notifications")
    }
}

/// Off / Phone / Band buzz / Both, in the same list style as Double-tap.
private struct RoutePicker: View {
    let title: String
    let detail: String
    @Binding var route: NotifyRoute
    let phoneOnly: Bool

    var body: some View {
        Form {
            Section {
                ForEach(phoneOnly ? [.off, .phone] : NotifyRoute.allCases, id: \.self) { r in
                    Button { route = r } label: {
                        HStack {
                            Text(r.label).foregroundColor(route == r ? Theme.green : Theme.text)
                            Spacer()
                            if route == r { Image(systemName: "checkmark").foregroundColor(Theme.green) }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityAddTraits(route == r ? .isSelected : [])
                }
            } header: {
                Text(detail)
            } footer: {
                Text(phoneOnly ? "Phone only: the band can't buzz when it isn't connected."
                     : "\"Band buzz\" is a short pulse, not the alarm buzz.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(title)
    }
}
