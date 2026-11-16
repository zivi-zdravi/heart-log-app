import SwiftUI
import PhotosUI

// MARK: Describe card (top of Add food)

/// "Describe it in your own words" card, shown on the add-food screen when AI is set up.
struct AIDescribeCard: View {
    let day: Date
    let slot: MealSlot
    let done: () -> Void
    @ObservedObject private var ai = AIStore.shared
    @State private var text = ""
    @State private var input: AIMealView.Input?
    @State private var going = false
    @State private var camera = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").foregroundColor(Theme.blue)
                Text("Describe it in your own words").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            }
            if ai.settings.describe {
                TextField("e.g. 2 scrambled eggs with butter and a slice of toast", text: $text, axis: .vertical)
                    .lineLimit(3...5)
                    .font(.system(size: 15)).foregroundColor(Theme.text)
                    .padding(10)
                    .background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.blue, lineWidth: 1))
            }
            HStack(spacing: 10) {
                if ai.settings.describe {
                    Button("Work it out") { input = .text(text.trimmingCharacters(in: .whitespacesAndNewlines)); going = true }
                        .buttonStyle(TintButton(color: Theme.blue))
                        .disabled(text.trimmingCharacters(in: .whitespaces).count < 3)
                }
                if ai.settings.photos {
                    Button { camera = true } label: { Label("Photo", systemImage: "camera") }
                        .buttonStyle(TintButton(color: Theme.text))
                        .frame(maxWidth: ai.settings.describe ? 120 : .infinity)
                }
            }
            Text(ai.settings.describe ? "Sends only this text (or the photo) to Claude through your home server." : "Sends only the photo to Claude through your home server.")
                .font(.system(size: 12)).foregroundColor(Theme.dim)
        }
        .padding(16)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 16))
        .navigationDestination(isPresented: $going) {
            if let input { AIMealView(day: day, slot: slot, input: input, done: done) }
        }
        .sheet(isPresented: $camera) {
            MealCamera { image in
                camera = false
                if let image { input = .photo(image); going = true }
            }
            .ignoresSafeArea()
        }
    }
}

/// Camera when there is one, otherwise the photo library.
struct MealCamera: UIViewControllerRepresentable {
    let finish: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finish: (UIImage?) -> Void
        init(_ f: @escaping (UIImage?) -> Void) { finish = f }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            finish(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }
    }
}

// MARK: Claude's breakdown of a meal

struct AIMealView: View {
    enum Input: Hashable, Identifiable {
        case text(String), photo(UIImage)
        var id: String { switch self { case .text(let t): return "t" + t; case .photo(let p): return "p\(ObjectIdentifier(p).hashValue)" } }
    }

    let day: Date
    let slot: MealSlot
    let input: Input
    let done: () -> Void
    @ObservedObject private var store = MealStore.shared
    @State private var foods: [AIFood] = []
    @State private var low = 0.0
    @State private var high = 0.0
    @State private var loading = true
    @State private var problem = ""
    @State private var unclear = ""
    @State private var note = ""
    @State private var extra = ""
    @State private var addingExtra = false
    @State private var working = false
    @State private var editing: AIFood?

    private var isPhoto: Bool { if case .photo = input { return true } else { return false } }
    private var total: Nutrients { foods.reduce(.zero) { $0 + $1.nutrients } }
    private var flagged: [String] {
        Array(Set(foods.flatMap { MealMath.avoidMatches($0.food, avoid: store.settings.avoid) + MealMath.avoidMatches(AIMeal.estimated($0.item), avoid: store.settings.avoid) })).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch input {
                case .text(let t):
                    Text("\u{201C}\(t)\u{201D}").font(.system(size: 14)).italic().foregroundColor(Theme.dim)
                case .photo(let image):
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 220).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("Your meal photo")
                }
                if loading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(isPhoto ? "Claude is looking at your plate" : "Claude is working it out").font(.system(size: 14)).foregroundColor(Theme.dim)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else if !problem.isEmpty {
                    Text(problem).font(.system(size: 15)).foregroundColor(Theme.orange)
                    Button("Try again") { Task { await load() } }.buttonStyle(TintButton(color: Theme.text))
                } else {
                    if !unclear.isEmpty { Text(unclear).font(.system(size: 14)).foregroundColor(Theme.orange) }
                    totals
                    if !foods.isEmpty {
                        Text(isPhoto ? "What Claude sees. Tap one to fix it." : "What Claude found. Tap one to change the amount or remove it.")
                            .font(.system(size: 13)).foregroundColor(Theme.dim)
                        list
                    }
                    if isPhoto {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Anything it can't see? (sauce, butter, what's in it)").font(.system(size: 13)).foregroundColor(Theme.dim)
                            HStack(spacing: 8) {
                                TextField("e.g. teriyaki glaze on the salmon", text: $note)
                                    .font(.system(size: 15)).foregroundColor(Theme.text)
                                    .padding(.horizontal, 14).frame(minHeight: 48)
                                    .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
                                Button("Redo") { Task { await load() } }.buttonStyle(TintButton(color: Theme.blue)).frame(width: 80)
                                    .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty || working)
                            }
                        }
                    }
                    if addingExtra {
                        HStack(spacing: 8) {
                            TextField("What it missed, e.g. a glass of orange juice", text: $extra)
                                .font(.system(size: 15)).foregroundColor(Theme.text)
                                .padding(.horizontal, 14).frame(minHeight: 48)
                                .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.blue, lineWidth: 1))
                            Button("Add") { Task { await addExtra() } }.buttonStyle(TintButton(color: Theme.blue)).frame(width: 70)
                                .disabled(extra.trimmingCharacters(in: .whitespaces).count < 2 || working)
                        }
                    } else {
                        Button("Add something it missed") { addingExtra = true }
                            .buttonStyle(TintButton(color: Theme.text))
                    }
                    if working { ProgressView().frame(maxWidth: .infinity) }
                    if !store.settings.avoid.isEmpty && !foods.isEmpty {
                        Label(flagged.isEmpty ? "Checked against your avoid list: nothing on it." : "Heads up: \(flagged.joined(separator: ", ")) on your avoid list.",
                              systemImage: flagged.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.system(size: 13)).foregroundColor(flagged.isEmpty ? Theme.dim : Theme.orange)
                    }
                    if !foods.isEmpty {
                        Button { save() } label: {
                            Text("Add \(foods.count) food\(foods.count == 1 ? "" : "s") to \(slot.rawValue)")
                                .font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.bg)
                                .frame(maxWidth: .infinity, minHeight: 50).background(Theme.green).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.top, 8)
                    }
                    Text(isPhoto ? "Estimates from Claude. Calories come from USDA where a match was found. The photo is read on your home server and not kept there."
                         : "Estimates from Claude. Calories come from USDA where a match was found; amounts are Claude's reading of what you wrote, so check them before adding.")
                        .font(.system(size: 12)).foregroundColor(Theme.dim).frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Add to \(slot.rawValue)")
        .navigationBarTitleDisplayMode(.inline)
        .task { if foods.isEmpty && problem.isEmpty { await load() } }
        .sheet(item: $editing) { f in
            AIFoodEdit(food: f) { changed in
                if let i = foods.firstIndex(where: { $0.id == f.id }) {
                    if let changed { foods[i] = changed } else { foods.remove(at: i) }
                }
                editing = nil
            }
            .presentationDetents([.medium])
        }
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(AIMeal.caloriesText(foods, low: low, high: high)).font(Theme.display(30)).foregroundColor(Theme.text)
                Spacer()
                Text("cal, estimated").font(.system(size: 14)).foregroundColor(Theme.dim)
            }
            HStack {
                macro("Protein", total.protein)
                macro("Carbs", total.carbs)
                macro("Fat", total.fat)
            }
        }
        .padding(16).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func macro(_ name: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).foregroundColor(Theme.dim)
            Text("\(Int(v.rounded())) g").fontWeight(.semibold).foregroundColor(Theme.text)
        }
        .font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(foods.enumerated()), id: \.element.id) { i, f in
                Button { editing = f } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.item.name).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                            Text(detail(f)).font(.system(size: 13)).foregroundColor(Theme.dim).multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Text("\(Int(f.nutrients.kcal.rounded())) cal").font(.system(size: 15)).foregroundColor(Theme.text)
                    }
                    .frame(minHeight: 64)
                }
                .buttonStyle(.plain)
                if i < foods.count - 1 { Divider().overlay(Theme.track) }
            }
        }
        .padding(.horizontal, 16).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func detail(_ f: AIFood) -> String {
        var s = f.item.amount_text
        if f.item.guess { s += f.item.note.map { $0.isEmpty ? " (a guess)" : " (a guess: \($0))" } ?? " (a guess)" }
        s += f.fromUSDA ? " · USDA" : " · Claude's estimate"
        return s
    }

    private func resolve(_ r: AIMealResult) async -> [AIFood] {
        await withTaskGroup(of: (Int, AIFood).self) { group in
            for (i, item) in r.items.enumerated() {
                group.addTask {
                    let match = try? await FoodAPI.usda(item.usda_query).first
                    return (i, AIMeal.food(for: item, usdaMatch: match))
                }
            }
            var out: [(Int, AIFood)] = []
            for await x in group { out.append(x) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func load() async {
        loading = foods.isEmpty
        working = !foods.isEmpty
        problem = ""
        do {
            let r: AIMealResult
            switch input {
            case .text(let t): r = try await AIClient.meal(text: t, avoid: store.settings.avoid)
            case .photo(let p): r = try await AIClient.meal(photo: p, note: note, avoid: store.settings.avoid)
            }
            foods = await resolve(r)
            low = r.calories_low
            high = r.calories_high
            unclear = r.unclear ?? ""
        } catch {
            problem = error.localizedDescription
        }
        loading = false
        working = false
    }

    private func addExtra() async {
        working = true
        defer { working = false }
        do {
            let r = try await AIClient.meal(text: extra, avoid: store.settings.avoid)
            foods += await resolve(r)
            low += r.calories_low
            high += r.calories_high
            extra = ""
            addingExtra = false
        } catch {
            problem = error.localizedDescription
        }
    }

    private func save() {
        let cal = Calendar.current
        let at: Date
        if cal.isDateInToday(day) {
            at = Date()
        } else {
            let hour = [MealSlot.breakfast: 8, .lunch: 12, .dinner: 18, .snacks: 15][slot] ?? 12
            at = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        for f in foods {
            store.add(MealEntry(id: UUID().uuidString, day: DayEngine.shared.key(day), slot: slot,
                                time: Int64(at.timeIntervalSince1970 * 1000), food: f.food, amount: 1, serving: f.serving))
        }
        done()
    }
}

/// Change the amount of one AI-found food, or remove it.
private struct AIFoodEdit: View {
    let food: AIFood
    let finish: (AIFood?) -> Void
    @State private var grams: Double

    init(food: AIFood, finish: @escaping (AIFood?) -> Void) {
        self.food = food
        self.finish = finish
        _grams = State(initialValue: food.grams)
    }

    private var edited: AIFood {
        var f = food
        f.grams = grams
        if grams != food.grams { f.item.amount_text = "\(Int(grams.rounded())) g" }
        return f
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(food.item.name).font(.system(size: 20, weight: .semibold)).foregroundColor(Theme.text)
                Text("Claude read this as \(food.item.amount_text), about \(Int(food.grams.rounded())) g.").font(.system(size: 14)).foregroundColor(Theme.dim)
                HStack(spacing: 16) {
                    step("−") { grams = max(5, (grams * 0.8).rounded()) }
                    VStack {
                        Text("\(Int(grams.rounded())) g").font(Theme.display(28)).foregroundColor(Theme.text)
                        Text("\(Int(edited.nutrients.kcal.rounded())) cal").font(.system(size: 14)).foregroundColor(Theme.dim)
                    }
                    .frame(maxWidth: .infinity)
                    step("+") { grams = (grams * 1.25).rounded() }
                }
                Button("Remove from this meal", role: .destructive) { finish(nil) }.buttonStyle(TintButton(color: Theme.orange))
                Spacer()
            }
            .padding(20)
            .background(Theme.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(food) } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { finish(edited) } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func step(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 22, weight: .semibold)).foregroundColor(Theme.text)
                .frame(width: 44, height: 44).background(Theme.raised).clipShape(Circle())
                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
        }
        .accessibilityLabel(label == "+" ? "More" : "Less")
    }
}

/// From the Meals screen's Photo button: camera, then Claude's estimate.
struct AIPhotoFlow: View {
    let day: Date
    let slot: MealSlot
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                NavigationStack {
                    AIMealView(day: day, slot: slot, input: .photo(image)) { dismiss() }
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                }
                .preferredColorScheme(.dark)
            } else {
                MealCamera { picked in
                    if let picked { image = picked } else { dismiss() }
                }
                .ignoresSafeArea()
            }
        }
    }
}

// MARK: Ask about your data

struct AskView: View {
    let range: TrendRange
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var turns: [(role: String, text: String)] = []
    @State private var asking = false
    @State private var problem = ""
    @State private var sent = ""
    @FocusState private var focused: Bool

    private var days: Int { range == .week ? 7 : range == .month ? 28 : 365 }

    private var suggestions: [String] {
        switch range {
        case .week: return ["Why was my recovery low this week?", "How did I sleep this week?", "Am I drinking enough water?"]
        case .month: return ["Do late dinners hurt my sleep?", "What helps my recovery most?", "Am I sleeping more on weekends?"]
        case .year: return ["How has my sleep changed this year?", "Which months was I most recovered?", "Is my resting heart rate trending down?"]
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(suggestions, id: \.self) { s in
                                        Button { Task { await ask(s) } } label: {
                                            Text(s).font(.system(size: 13)).foregroundColor(Theme.text)
                                                .padding(.horizontal, 12).frame(minHeight: 36)
                                                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                                        }
                                    }
                                }
                            }
                            ForEach(Array(turns.enumerated()), id: \.offset) { i, t in
                                bubble(t.role, t.text).id(i)
                            }
                            if asking {
                                HStack(spacing: 8) { ProgressView(); Text("Looking at your numbers").font(.system(size: 14)).foregroundColor(Theme.dim) }
                                    .id("asking")
                            }
                            if !problem.isEmpty { Text(problem).font(.system(size: 14)).foregroundColor(Theme.orange) }
                            if !sent.isEmpty {
                                DisclosureGroup("What was sent for this answer") {
                                    Text(sent).font(.system(size: 13)).foregroundColor(Theme.dim).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                                }
                                .font(.system(size: 13)).foregroundColor(Theme.dim).tint(Theme.dim)
                            }
                        }
                        .padding(20)
                    }
                    .onChange(of: turns.count) { n in withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) } }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Ask about your sleep, recovery, meals...", text: $question, axis: .vertical)
                            .lineLimit(1...4)
                            .focused($focused)
                            .font(.system(size: 15)).foregroundColor(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 24))
                            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Theme.line, lineWidth: 1))
                        Button { Task { await ask(question) } } label: {
                            Image(systemName: "paperplane").foregroundColor(Theme.blue)
                                .frame(width: 48, height: 48).background(Theme.raised).clipShape(Circle())
                        }
                        .accessibilityLabel("Send")
                        .disabled(question.trimmingCharacters(in: .whitespaces).count < 3 || asking)
                    }
                    Text("Answers come from your own numbers and are general information, not medical advice. Conversations aren't saved on the server.")
                        .font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Theme.bg)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Ask about your data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func bubble(_ role: String, _ text: String) -> some View {
        HStack {
            if role == "user" { Spacer(minLength: 40) }
            answerText(text)
                .font(.system(size: 15)).foregroundColor(Theme.text)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(role == "user" ? Color(hex: 0x26394A) : Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .textSelection(.enabled)
            if role != "user" { Spacer(minLength: 20) }
        }
    }

    /// Bold and italics from Claude's markdown; everything else as plain text.
    /// (Not LocalizedStringKey: a "%" in an answer, like "62%", would be read
    /// as a format code and can blank the whole bubble.)
    private func answerText(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
        return Text(verbatim: s)
    }

    private func ask(_ q: String) async {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3, !asking else { return }
        question = ""
        focused = false
        problem = ""
        let history = turns
        turns.append((role: "user", text: q))
        asking = true
        let meals = AskContext.mealSummaries(days: days)
        let ctx = await Task.detached { AskContext.build(days: days, meals: meals) }.value
        sent = ctx.description
        do {
            let a = try await AIClient.ask(question: q, context: ctx.json, history: history)
            guard !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIClient.Failure.server("Claude sent back an empty answer. Try asking again.") }
            turns.append((role: "assistant", text: a))
        } catch {
            problem = error.localizedDescription
            turns.removeLast()
            question = q
        }
        asking = false
    }
}

/// The daily summaries an answer is based on. Numbers only: no names,
/// no raw heart data, no photos.
enum AskContext {
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    struct MealDay { var kcal: Int; var protein: Int; var first: Int64; var last: Int64 }

    /// Meal totals and times per day, read on the main actor where meals live.
    @MainActor
    static func mealSummaries(days: Int) -> [String: MealDay] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [String: MealDay] = [:]
        for i in 0..<days {
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            let k = DayEngine.shared.key(d)
            let e = MealStore.shared.entries(k)
            guard let first = e.first, let last = e.last else { continue }
            let t = MealStore.shared.total(k)
            out[k] = MealDay(kcal: Int(t.kcal), protein: Int(t.protein), first: first.time, last: last.time)
        }
        return out
    }

    static func build(days: Int, meals mealDays: [String: MealDay]) -> (json: [String: Any], description: String) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let records = DayEngine.shared.records(from: from, to: today, settings: SettingsStore.shared.value)
        let water = WaterStore.shared.data
        let bands = BandHistoryStore.shared.days
        let hm: (Int64) -> String = { ms in
            let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(ms) / 1000))
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        func r1(_ v: Double?) -> Double? { v.map { ($0 * 10).rounded() / 10 } }
        var rows: [[String: Any]] = []
        for r in records {
            var d: [String: Any] = ["date": r.day]
            if let date = dayParser.date(from: r.day) { d["weekday"] = Theme.weekday.string(from: date) }
            d["recovery_pct"] = r1(r.recovery)
            d["sleep_score"] = r1(r.sleepScore)
            d["hrv_ms"] = r1(r.hrv)
            d["resting_hr"] = r.rhr
            d["strain"] = r1(r.strain)
            d["calories_burned"] = r.calories.map { Int($0) }
            d["breathing_per_min"] = r1(r.respRate)
            if let s = r.sleep {
                d["bedtime"] = hm(s.onset)
                d["wake_time"] = hm(s.wake)
                d["asleep_hours"] = r1(s.asleepMin / 60)
                d["sleep_efficiency_pct"] = Int(s.efficiency)
                d["lowest_hr"] = s.lowestHR
            }
            if let b = bands[r.day], (b.stages ?? []).isEmpty == false {
                let m = b.stageMinutes
                d["deep_min"] = Int(m[.deep] ?? 0)
                d["rem_min"] = Int(m[.rem] ?? 0)
                d["light_min"] = Int(m[.light] ?? 0)
            }
            if let m = mealDays[r.day] {
                d["calories_eaten"] = m.kcal
                d["protein_g"] = m.protein
                d["first_meal"] = hm(m.first)
                d["last_meal"] = hm(m.last)
            }
            if water.ounces(r.day) > 0 { d["water_oz"] = water.ounces(r.day) }
            rows.append(d.compactMapValues { $0 is NSNull ? nil : $0 })
        }
        let json: [String: Any] = ["days": rows, "note": "One row per day, keyed by the date the person woke up. Missing fields were not measured."]
        let desc = "Your question, plus daily summaries for \(rows.count) days: recovery, sleep score and times, sleep stages where known, HRV, resting heart rate, breathing rate, strain, calories, meal times and water. No names, no raw heart data, no photos."
        return (json, desc)
    }
}

// MARK: Settings > AI

struct AISettingsView: View {
    @ObservedObject private var ai = AIStore.shared
    @State private var status: AIClient.Status?
    @State private var problem = ""
    @State private var checking = false
    @State private var limit: Double = 10

    var body: some View {
        Form {
            Section {
                TextField("borisavljevicserver.your-tailnet.ts.net:8443", text: $ai.server)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("This phone's pass code", text: $ai.passcode)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    Text("Connection").foregroundColor(Theme.dim)
                    Spacer()
                    if checking { ProgressView() } else if let s = status {
                        Label(s.keySet ? "Working, as \(s.person)" : "Connected, but no Claude key", systemImage: "circle.fill")
                            .labelStyle(.titleAndIcon).foregroundColor(s.keySet ? Theme.green : Theme.orange).font(.system(size: 14))
                    } else {
                        Text(problem.isEmpty ? "Not checked" : "Not working").foregroundColor(problem.isEmpty ? Theme.dim : Theme.orange)
                    }
                }
                Button("Check connection") { Task { await check() } }.disabled(!ai.isSetUp)
                if !problem.isEmpty { Text(problem).font(.system(size: 13)).foregroundColor(Theme.orange) }
            } header: {
                Text("Home server")
            } footer: {
                Text("The Claude key lives only on the server. This phone holds a pass code that lets it use the server, kept in the phone's keychain and never in backups. Tailscale must be on.")
            }
            Section("Use AI for") {
                Toggle(isOn: $ai.settings.describe) { row("Describing meals", "Sends what you type") }
                Toggle(isOn: $ai.settings.photos) { row("Meal photos", "Sends the photo, not kept on the server") }
                Toggle(isOn: $ai.settings.ask) { row("Questions about your data", "Sends daily summaries, never raw heart data") }
            }
            .tint(Theme.green)
            if let s = status {
                Section {
                    HStack { Text("Requests"); Spacer(); Text("\(s.requests)").fontWeight(.semibold) }
                    HStack { Text("Estimated cost"); Spacer(); Text(String(format: "$%.2f", s.costUsd)).fontWeight(.semibold) }
                    HStack { Text("This phone"); Spacer(); Text(String(format: "%d, $%.2f", s.mine.requests, s.mine.costUsd)).foregroundColor(Theme.dim) }
                    if s.admin {
                        Stepper(value: $limit, in: 1...200, step: 5) {
                            HStack { Text("Monthly limit"); Spacer(); Text(String(format: "$%.0f", limit)).fontWeight(.semibold) }
                        }
                        .onChange(of: limit) { v in Task { try? await AIClient.setLimit(v) } }
                    } else {
                        HStack { Text("Monthly limit"); Spacer(); Text(String(format: "$%.0f", s.limitUsd)).fontWeight(.semibold) }
                    }
                } header: {
                    Text("This month")
                } footer: {
                    Text("The server stops answering for the rest of the month once the limit is reached, so a bug can never run up a bill.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("AI")
        .task { if ai.isSetUp { await check() } }
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundColor(Theme.text)
            Text(detail).font(.system(size: 13)).foregroundColor(Theme.dim)
        }
    }

    private func check() async {
        checking = true
        problem = ""
        do {
            let s = try await AIClient.status()
            status = s
            limit = s.limitUsd
        } catch {
            status = nil
            problem = error.localizedDescription
        }
        checking = false
    }
}
