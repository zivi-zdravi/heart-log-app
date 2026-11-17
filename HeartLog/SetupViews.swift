import SwiftUI

/// First-run setup for a new person: welcome, about you, device, history, features, AI.
/// Shown once. A phone that already has Zdravlje data skips it.
struct SetupFlow: View {
    let done: () -> Void

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var r = Recorder.shared
    @ObservedObject private var ai = AIStore.shared
    @ObservedObject private var body_ = BodyStore.shared
    @State private var step = 0
    @State private var weight = ""
    @State private var feet = ""
    @State private var inches = ""
    @State private var age = ""
    @State private var notificationsOn = true
    @State private var bodyLogOn = false
    @State private var passcode = ""
    @FocusState private var typing: Bool

    private let steps = 6
    private let soft = Color(hex: 0xC9D3CE)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule().fill(i <= step ? Theme.green : Theme.track).frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                .padding(.top, 4)
                .accessibilityLabel("Step \(step + 1) of \(steps)")
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) { page }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                Button(ctaTitle) { next() }
                    .font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.bg)
                    .frame(maxWidth: .infinity, minHeight: 52).background(Theme.green).clipShape(RoundedRectangle(cornerRadius: 14))
                    .buttonStyle(.plain)
                if let skip = skipTitle {
                    Button(skip) { advance() }.font(.system(size: 14)).foregroundColor(Theme.dim).frame(maxWidth: .infinity, minHeight: 40)
                }
            }
            .padding(20)
            .background(Theme.bg.ignoresSafeArea())
            .toolbar {
                if step > 0 { ToolbarItem(placement: .navigationBarLeading) { Button("Back") { step -= 1 } } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { typing = false } }
            }
        }
        .onAppear(perform: load)
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        switch step {
        case 0: welcome
        case 1: aboutYou
        case 2: device
        case 3: history
        case 4: features
        default: aiPage
        }
    }

    private func title(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(Theme.display(28)).foregroundColor(Theme.text).padding(.top, 8)
            Text(sub).font(.system(size: 15)).foregroundColor(soft)
        }
    }

    private func box<C: View>(_ accent: Color? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .accentCard(accent, radius: 16)
    }

    private var welcome: some View {
        Group {
            title("Welcome to Zdravlje", "Your health, from your own band or watch, kept on your phone.")
            box {
                bullet(Theme.green, "Sleep, recovery and strain each day")
                bullet(Theme.blue, "Trends, meals, water and a body log")
                bullet(Theme.orange, "No account and no subscription")
                bullet(Color(hex: 0xC7A6E8), "Your data stays on this phone and in your own backups")
            }
            box(Theme.blue) {
                Text("Used WHOOP before? Do this first").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Text("Request your WHOOP data export now: in the WHOOP app, Account, then Data export. WHOOP emails you a zip file, which can take a while.")
                    .font(.system(size: 13)).foregroundColor(soft)
                Text("You'll be asked for it later in setup. If it hasn't arrived yet, skip that step and import it any time from Settings.")
                    .font(.system(size: 13)).foregroundColor(soft)
            }
        }
    }

    private func bullet(_ c: Color, _ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(t).font(.system(size: 14)).foregroundColor(soft)
        }
    }

    private var aboutYou: some View {
        Group {
            title("About you", "Used for calories and heart rate zones. Stays on this phone.")
            box {
                field("Name") { TextField("Your name", text: $settings.value.profileName).multilineTextAlignment(.trailing).focused($typing) }
                Divider().overlay(Theme.track)
                field("Weight") {
                    TextField("0", text: $weight).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70).focused($typing)
                    Text("lb").foregroundColor(Theme.dim)
                }
                Divider().overlay(Theme.track)
                field("Height") {
                    TextField("0", text: $feet).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 36).focused($typing)
                    Text("ft").foregroundColor(Theme.dim)
                    TextField("0", text: $inches).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 36).focused($typing)
                    Text("in").foregroundColor(Theme.dim)
                }
                Divider().overlay(Theme.track)
                field("Age") { TextField("0", text: $age).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70).focused($typing) }
                Picker("Sex", selection: $settings.value.female) {
                    Text("Female").tag(Bool?.some(true))
                    Text("Male").tag(Bool?.some(false))
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 6)
            }
            Text("Heart rate zones start from your age. If you bring in your WHOOP history next, they're fitted to you instead, and they keep adjusting from your own nights.")
                .font(.system(size: 13)).foregroundColor(Theme.dim)
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundColor(Theme.text)
            Spacer()
            content()
        }
        .font(.system(size: 15))
        .frame(minHeight: 40)
    }

    private var device: some View {
        Group {
            title("Your device", "What will you wear?")
            box {
                HStack(spacing: 12) {
                    Image(systemName: "largecircle.fill.circle").foregroundColor(Theme.green).font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("WHOOP band").font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.text)
                        Text("Live heart rate, sleep from the band, alarm and double-tap").font(.system(size: 12)).foregroundColor(Theme.dim)
                    }
                }
                .frame(minHeight: 60)
                Divider().overlay(Theme.track)
                HStack(spacing: 12) {
                    Image(systemName: "circle").foregroundColor(Theme.line).font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Watch").font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.text)
                        Text("Coming later. Reads from Apple Health.").font(.system(size: 12)).foregroundColor(Theme.dim)
                    }
                }
                .frame(minHeight: 60)
                .opacity(0.55)
                .accessibilityLabel("Apple Watch, coming later")
            }
            box(Theme.green) {
                Text("Find your band").font(.system(size: 13)).foregroundColor(Theme.dim)
                if r.recording {
                    Label("Connected. Recording.", systemImage: "checkmark.circle.fill").foregroundColor(Theme.green).font(.system(size: 15, weight: .semibold))
                } else {
                    ForEach(r.bands.sorted { $0.rssi > $1.rssi }) { b in
                        Button { r.start(b) } label: {
                            HStack {
                                Text(b.name).foregroundColor(Theme.text)
                                Spacer()
                                Text(b.rssi > -60 ? "Very close · Tap to connect" : b.rssi > -80 ? "Nearby · Tap to connect" : "Far").foregroundColor(Theme.green)
                            }
                            .font(.system(size: 14)).frame(minHeight: 44)
                        }
                    }
                    if r.bands.isEmpty { Text("Looking. Tap the band to wake it.").font(.system(size: 14)).foregroundColor(soft) }
                }
                Text("Tap the band to wake it. Keep it near the phone.").font(.system(size: 12)).foregroundColor(Theme.dim)
            }
        }
        .onAppear { if !r.recording && !r.scanning { r.startScan() } }
    }

    private var history: some View {
        Group {
            title("Bring your history", "Optional, but it makes the first weeks much better.")
            box(Theme.blue) {
                Text("WHOOP export").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Text("The zip file WHOOP emailed you (requested on the first screen). Open it here.").font(.system(size: 13)).foregroundColor(soft)
                NavigationLink { ImportView() } label: {
                    Text("Choose the zip file").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.blue)
                        .frame(maxWidth: .infinity, minHeight: 44).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.blue, lineWidth: 1))
                }
                .buttonStyle(.plain)
                let n = HistoryStore.shared.days.count
                if n > 0 { Text("\(n) days brought in.").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.green) }
            }
            box {
                Text("What it gives you").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Text("Your usual HRV, resting heart rate and sleep from day one, heart rate zones fitted to you, and a full year in Trends.")
                    .font(.system(size: 13)).foregroundColor(soft)
            }
        }
    }

    private var features: some View {
        Group {
            title("Pick what you want", "Turn on what's useful. Everything else stays out of the way.")
            box {
                toggle("Meals", "Log food and see eaten vs burned", $settings.value.mealsOn)
                Divider().overlay(Theme.track)
                toggle("Water", "Glasses through the day, band buzz reminders", $settings.value.waterOn)
                Divider().overlay(Theme.track)
                toggle("Body log", "Blood pressure, cycle, menopause", $bodyLogOn)
                if bodyLogOn {
                    VStack(spacing: 0) {
                        let offer = BodyMath.suggested(female: settings.value.female, age: settings.value.age)
                        if offer.contains(.bloodPressure) { toggle("Blood pressure", nil, bodyBinding(\.bloodPressure)) }
                        if offer.contains(.cycle) { toggle("Cycle", nil, bodyBinding(\.cycle)) }
                        if offer.contains(.menopause) { toggle("Menopause", nil, bodyBinding(\.menopause)) }
                    }
                    .padding(.leading, 16)
                }
                Divider().overlay(Theme.track)
                toggle("Band alarm", "Silent wake-up buzz", $settings.value.alarmOn)
                Divider().overlay(Theme.track)
                toggle("Notifications", "Low battery, wind-down, step goal", $notificationsOn)
                Divider().overlay(Theme.track)
                toggle("Greet me in Serbian", "English unless this is on: Dobro jutro, Dobar dan, Dobro veče", $settings.value.serbianGreeting)
            }
            Text("Each of these has more choices in Settings later.").font(.system(size: 13)).foregroundColor(Theme.dim)
        }
    }

    private func bodyBinding(_ key: WritableKeyPath<BodySettings, Bool>) -> Binding<Bool> {
        Binding(get: { body_.settings[keyPath: key] }, set: { v in var s = body_.settings; s[keyPath: key] = v; body_.settings = s })
    }

    private func toggle(_ t: String, _ sub: String?, _ b: Binding<Bool>) -> some View {
        Toggle(isOn: b) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(.system(size: 15)).foregroundColor(Theme.text)
                if let sub { Text(sub).font(.system(size: 12)).foregroundColor(Theme.dim) }
            }
        }
        .tint(Theme.green)
        .frame(minHeight: 50)
    }

    private var aiPage: some View {
        Group {
            title("Ask about your data", "Optional. Lets you ask questions in plain words and describe meals.")
            box(Theme.blue) {
                field("Home server") {
                    TextField("Address", text: $ai.server).multilineTextAlignment(.trailing).focused($typing)
                        .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                }
                Divider().overlay(Theme.track)
                field("Pass code") { SecureField("Pass code", text: $passcode).multilineTextAlignment(.trailing).focused($typing) }
            }
            Text("Ask Katie for the server address and the family pass code; she can AirDrop them to you to paste in. Both stay only on this phone.").font(.system(size: 13)).foregroundColor(Theme.dim)
            box(Theme.green) {
                Text("You're set").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Text("Wear the band tonight. Sleep, recovery and strain show tomorrow morning; your usual ranges fill in over the first week.")
                    .font(.system(size: 13)).foregroundColor(soft)
            }
        }
    }

    // MARK: Flow

    private var ctaTitle: String {
        switch step {
        case 0: return "Get started"
        case 2: return r.recording ? "Continue" : "Continue without the band"
        case steps - 1: return "Open Today"
        default: return "Continue"
        }
    }

    private var skipTitle: String? {
        switch step {
        case 1: return "Skip for now"
        case 3: return "Not here yet? Skip and import later"
        case steps - 1: return "Skip AI for now"
        default: return nil
        }
    }

    private func load() {
        let s = settings.value
        weight = s.weightKg.map { String(Int(($0 / 0.45359237).rounded())) } ?? ""
        if let cm = s.heightCm {
            let total = Int((cm / 2.54).rounded())
            feet = String(total / 12)
            inches = String(total % 12)
        }
        age = s.age.map(String.init) ?? ""
        bodyLogOn = body_.settings.anyOn
        passcode = ai.passcode
    }

    private func next() {
        if step == 1 { saveAboutYou() }
        if step == steps - 1 {
            let code = passcode.trimmingCharacters(in: .whitespaces)
            if !code.isEmpty {
                ai.passcode = code
            }
        }
        advance()
    }

    private func advance() {
        typing = false
        if step == 1 { saveAboutYou() }
        if step < steps - 1 {
            step += 1
        } else {
            finish()
        }
    }

    private func saveAboutYou() {
        var s = settings.value
        s.weightKg = Double(weight).map { $0 * 0.45359237 }
        let f = Int(feet) ?? 0, i = Int(inches) ?? 0
        s.heightCm = (f > 0 || i > 0) ? Double(f * 12 + i) * 2.54 : nil
        s.age = Int(age)
        if let a = s.age, a > 0 { s.maxHR = DetailMath.maxHR(age: a) }
        settings.value = s
    }

    private func finish() {
        var s = settings.value
        // Fit resting heart rate for zones from imported history, if there is any.
        let rhrs = HistoryStore.shared.days.values.sorted { $0.day < $1.day }.compactMap(\.rhr)
        if let rest = DetailMath.restingForZones(rhrs) { s.restingForZones = rest }
        settings.value = s
        if !bodyLogOn { var b = body_.settings; b.bloodPressure = false; b.cycle = false; b.menopause = false; body_.settings = b }
        if !notificationsOn {
            NotifyStore.shared.change { n in
                n.lowBattery = .off; n.charger = .off; n.goneQuiet = .off; n.alarmNotSaved = .off; n.noAlarmCheckIn = .off
                n.windDown = .off; n.stepGoal = .off; n.possibleActivity = .off; n.water = .off; n.breathingHigh = .off
            }
        }
        if !s.waterOn { WaterFeature.turnedOff() }
        done()
    }
}

enum WaterFeature {
    /// With water off, reminders stop and a double-tap no longer logs a glass.
    static func turnedOff() {
        NotifyStore.shared.change { $0.water = .off }
        if WaterStore.shared.tapAction == .logWater { WaterStore.shared.tapAction = .nothing }
    }
}

enum SetupGate {
    /// A phone that already has Zdravlje settings or history (Katie's) never sees first-run setup.
    static var alreadyInUse: Bool {
        let dir = Store.shared.dir
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path)
            || !HistoryStore.shared.days.isEmpty
    }
}

/// The welcome after setup: a grey dot grows inside a drawing green ring, the name appears,
/// then the dot floods the screen and bursts to show Today. About 2 seconds; a tap skips it.
struct WelcomeBurst: View {
    let name: String
    let done: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ring: CGFloat = 0
    @State private var dot: CGFloat = 10
    @State private var nameShown = false
    @State private var flood = false
    @State private var gone = false
    @State private var finished = false

    private let dotColor = Color(hex: 0x222C2E)

    var body: some View {
        GeometryReader { g in
            let cover = max(g.size.width, g.size.height) * 2.4
            ZStack {
                Theme.bg.opacity(flood ? 0 : 1)
                Circle().fill(dotColor).frame(width: flood ? cover : dot, height: flood ? cover : dot)
                if !flood {
                    Circle().trim(from: 0, to: ring)
                        .stroke(Theme.green, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 140, height: 140)
                }
                VStack(spacing: 6) {
                    Spacer().frame(height: 220)
                    Text(name.isEmpty ? "Welcome" : "Welcome, \(name)").font(Theme.display(26)).foregroundColor(Theme.text)
                    Text("Your first night starts tonight.").font(.system(size: 14)).foregroundColor(Color(hex: 0xC9D3CE))
                }
                .opacity(nameShown && !flood ? 1 : 0)
            }
            .frame(width: g.size.width, height: g.size.height)
            .opacity(gone ? 0 : 1)
            .scaleEffect(gone ? 1.15 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name.isEmpty ? "Welcome" : "Welcome, \(name)")
        .accessibilityAddTraits(.isButton)
        .onAppear(perform: play)
    }

    private func play() {
        if reduceMotion {
            ring = 1
            dot = 0
            nameShown = true
            after(1.2) { withAnimation(.easeOut(duration: 0.4)) { gone = true } }
            after(1.6) { finish() }
            return
        }
        withAnimation(.easeInOut(duration: 0.9)) { ring = 1; dot = 96 }
        withAnimation(.easeOut(duration: 0.6)) { nameShown = true }
        after(1.3) { withAnimation(.easeIn(duration: 0.45)) { flood = true } }
        after(1.75) { withAnimation(.easeOut(duration: 0.3)) { gone = true } }
        after(2.1) { finish() }
    }

    private func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

    private func finish() {
        guard !finished else { return }
        finished = true
        done()
    }
}
