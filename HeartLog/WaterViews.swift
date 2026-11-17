import SwiftUI

/// Water on the Meals screen, below the meals list (approved mockup).
struct WaterCard: View {
    let key: String
    @ObservedObject private var water = WaterStore.shared
    @State private var editingGoal = false

    var body: some View {
        let d = water.data
        let glasses = d.days[key]?.glasses ?? 0
        let day = d.days[key]
        Card {
            HStack(spacing: 12) {
                Image(systemName: "drop").font(.system(size: 20)).foregroundColor(Theme.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Water").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                    Button { editingGoal = true } label: {
                        HStack(spacing: 3) {
                            Text("\(d.ounces(key)) /")
                            Text("\(d.goalOz)").fontWeight(.semibold).foregroundColor(Theme.text)
                            Text("oz")
                            Image(systemName: "pencil").font(.system(size: 11))
                        }
                        .font(.system(size: 13)).foregroundColor(Theme.dim)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(minHeight: 28)
                    }
                    .accessibilityLabel("Change daily water goal, now \(d.goalOz) ounces")
                }
                Spacer(minLength: 4)
                Button { water.removeGlass(key) } label: {
                    Image(systemName: "minus").font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44).background(Circle().fill(Theme.line.opacity(0.5)))
                        .foregroundColor(Theme.text)
                }
                .disabled(glasses == 0)
                .accessibilityLabel("Remove a glass")
                VStack(spacing: 0) {
                    Text("\(glasses)").font(Theme.display(26)).foregroundColor(Theme.text)
                    Text(glasses == 1 ? "glass" : "glasses").font(.system(size: 11)).foregroundColor(Theme.dim)
                }
                .frame(minWidth: 54)
                Button { water.addGlass(key) } label: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44).background(Circle().fill(Theme.blue.opacity(0.2)))
                        .foregroundColor(Theme.blue)
                }
                .accessibilityLabel("Add a glass")
            }
            Bar(fraction: min(1, Double(d.ounces(key)) / Double(max(d.goalOz, 1))), color: Theme.blue, height: 8)
            if let at = day?.lastAt {
                Text("Last glass \(Theme.clock(at))\(day?.lastFromTap == true ? ", from a double-tap on the band" : ""). Tap the goal to change it.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            } else {
                Text("Tap + for each \(d.glassOz) oz glass, or double-tap the band. Tap the goal to change it.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            }
        }
        .sheet(isPresented: $editingGoal) {
            NavigationStack {
                Form { WaterSection() }
                    .scrollContentBackground(.hidden)
                    .background(Theme.bg.ignoresSafeArea())
                    .navigationTitle("Water")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editingGoal = false } } }
            }
            .presentationDetents([.medium])
        }
    }
}

/// Water goal and glass size, used in Settings, Meals and from the water card.
struct WaterSection: View {
    @ObservedObject private var water = WaterStore.shared

    var body: some View {
        Section {
            Stepper(value: Binding(get: { water.goalOz }, set: { water.goalOz = $0 }), in: WaterData.goalRange, step: 8) {
                HStack { Text("Daily goal"); Spacer(); Text("\(water.goalOz) oz").fontWeight(.semibold) }
            }
            Stepper(value: Binding(get: { water.glassOz }, set: { water.glassOz = $0 }), in: WaterData.glassRange, step: 2) {
                HStack { Text("Glass size"); Spacer(); Text("\(water.glassOz) oz").fontWeight(.semibold) }
            }
        } header: {
            Text("Water")
        } footer: {
            Text("The goal moves in 8 oz steps, the glass in 2 oz steps. A double-tap on the band, or + on the water card, adds one glass.")
        }
    }
}

/// Settings > Double-tap (approved mockup).
struct DoubleTapView: View {
    @ObservedObject private var water = WaterStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(TapAction.allCases, id: \.self) { a in
                    Button { water.tapAction = a } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.title).foregroundColor(water.tapAction == a ? Theme.green : Theme.text)
                                Text(a.detail).font(.system(size: 13)).foregroundColor(Theme.dim)
                            }
                            Spacer()
                            if water.tapAction == a { Image(systemName: "checkmark").foregroundColor(Theme.green) }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityAddTraits(water.tapAction == a ? .isSelected : [])
                }
            } header: {
                Text("Tap the band twice, quickly")
            } footer: {
                Text("One tap adds one glass (\(water.glassOz) oz). Glass size and your daily water goal are in Settings, Meals.")
            }
            if let at = water.data.lastTapAt, let act = water.data.lastTapAction {
                Section("Last tap") {
                    Text("\(Date(timeIntervalSince1970: Double(at) / 1000).formatted(date: .abbreviated, time: .shortened)): \(act == .logWater ? "logged a glass of water" : act == .activity ? "started or stopped an activity" : "nothing")")
                }
            }
            Section {
            } footer: {
                Text("Works while Zdravlje is connected to the band. Taps the band saved while your phone was away are ignored, so nothing gets logged hours late, and two taps within 2 seconds count once. Taps from a minute before your band alarm until 10 minutes after it are ignored too, so stopping the buzz never logs anything.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Double-tap")
    }
}

/// The band alarm on Today, under the four tiles (approved mockup).
struct AlarmTile: View {
    var accent: Color?
    @ObservedObject private var store = AlarmStore.shared
    @ObservedObject private var link = BandLink.shared
    @State private var open = false

    private func saved(_ next: Date) -> Bool {
        store.armed.map { $0.confirmed && abs($0.wake.timeIntervalSince(next)) < 1 } ?? false
    }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "alarm").font(.system(size: 20)).foregroundColor(Theme.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Band alarm").font(.system(size: 13)).foregroundColor(Theme.dim)
                    Text(store.next.map { AlarmView.dayTime($0) } ?? "Off").font(Theme.display(23)).foregroundColor(Theme.text)
                }
                Spacer()
                if let next = store.next {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(AlarmView.relative(next)).font(.system(size: 13)).foregroundColor(Theme.dim)
                        Text(saved(next) ? "Saved on the band" : "Not saved yet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(saved(next) ? Theme.green : Theme.orange)
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(Theme.dim)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .accentCard(accent, radius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.next.map { "Band alarm, \(AlarmView.dayTime($0)), \(AlarmView.relative($0)), \(saved($0) ? "saved on the band" : "not saved yet"). Open alarm" } ?? "Band alarm off. Open alarm")
        .sheet(isPresented: $open) {
            NavigationStack {
                AlarmView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { open = false } } }
            }
        }
    }
}
