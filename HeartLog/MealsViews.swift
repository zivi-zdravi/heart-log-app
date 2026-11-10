import SwiftUI
import VisionKit

private func dayKey(_ d: Date) -> String { DayEngine.shared.key(d) }

private func cal(_ v: Double) -> String { Int(v.rounded()).formatted() }

private func grams(_ v: Double) -> String { v < 10 && v != v.rounded() ? String(format: "%.1f g", v) : "\(Int(v.rounded())) g" }

/// Loads the day's goal off the main thread (it reads past days' burn).
@MainActor
enum GoalLoader {
    static func load() async -> MealStore.Goal {
        let s = MealStore.shared.settings
        let a = SettingsStore.shared.value
        return await Task.detached(priority: .userInitiated) { MealStore.goal(settings: s, appSettings: a) }.value
    }
}

struct MealsView: View {
    @ObservedObject private var store = MealStore.shared
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var goal: MealStore.Goal?
    @State private var burned: Double?
    @State private var setup = false
    @State private var editingGoal = false
    @State private var search: SearchRequest?
    @State private var scanning = false

    struct SearchRequest: Identifiable {
        let id = UUID()
        let slot: MealSlot
        var favorites = false
    }

    private var key: String { dayKey(day) }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var defaultSlot: MealSlot { MealSlot.at(hour: Calendar.current.component(.hour, from: Date())) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        DayChevrons(text: Theme.dayText.string(from: day), canGoForward: !isToday) { by in
                            if let d = Calendar.current.date(byAdding: .day, value: by, to: day), d <= Calendar.current.startOfDay(for: Date()) { day = d }
                        }
                        Text("Meals").font(Theme.display(30)).foregroundColor(Theme.text)
                    }
                    summary
                    Button { search = SearchRequest(slot: defaultSlot) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                            Text("Search for a food")
                            Spacer()
                        }
                        .font(.system(size: 16)).foregroundColor(Theme.dim)
                        .padding(.horizontal, 14).frame(minHeight: 50)
                        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
                    }
                    HStack(spacing: 10) {
                        Button("Favorites") { search = SearchRequest(slot: defaultSlot, favorites: true) }.buttonStyle(TintButton(color: Theme.text))
                        Button("Barcode") { scanning = true }.buttonStyle(TintButton(color: Theme.text))
                        Text("Photo (with AI)").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.dim)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .accessibilityLabel("Photo logging comes with the AI update")
                    }
                    meals
                    Text("Tap a meal to see or change its foods.").font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .followToday($day)
        .task(id: day) { await reload() }
        .onAppear {
            if !store.settings.setUp { setup = true }
            Task { await reload() }
        }
        .sheet(isPresented: $setup, onDismiss: { Task { await reload() } }) { GoalView(firstTime: true) }
        .sheet(isPresented: $editingGoal, onDismiss: { Task { await reload() } }) { GoalView(firstTime: false) }
        .sheet(item: $search) { r in FoodSearchView(day: day, slot: r.slot, favoritesOnly: r.favorites) }
        .sheet(isPresented: $scanning) { BarcodeView(day: day, slot: defaultSlot) }
    }

    private func reload() async {
        goal = await GoalLoader.load()
        burned = await DayLoader.load(day)?.calories
    }

    private var summary: some View {
        let t = store.total(key)
        let g = goal?.calories
        return Card {
            HStack(alignment: .firstTextBaseline) {
                Text(cal(t.kcal)).font(Theme.display(34)).foregroundColor(Theme.text)
                Spacer()
                Button { editingGoal = true } label: {
                    HStack(spacing: 5) {
                        Text("eaten of")
                        Text(g.map { $0.formatted() } ?? "--").fontWeight(.semibold).foregroundColor(Theme.text)
                        Text("cal")
                        Image(systemName: "pencil").font(.system(size: 12))
                    }
                    .font(.system(size: 14)).foregroundColor(Theme.dim).frame(minHeight: 44)
                }
                .accessibilityLabel("Change daily goal, now \(g ?? 0) calories")
            }
            Bar(fraction: g.map { t.kcal / Double(max(1, $0)) } ?? 0, color: (g.map { t.kcal > Double($0) + 100 } ?? false) ? Theme.orange : Theme.green)
            if let g {
                let left = Double(g) - t.kcal
                Text(left >= 0 ? "\(cal(left)) left for \(isToday ? "today" : "the day"). Tap the goal to change it or your aim." : "\(cal(-left)) over the goal")
                    .font(.system(size: 13)).foregroundColor(Theme.dim)
            }
            HStack {
                macro("Protein", t.protein)
                macro("Carbs", t.carbs)
                macro("Fat", t.fat)
            }
            .padding(.top, 4)
            Divider().overlay(Theme.track)
            HStack {
                Text(isToday ? "Burned so far (estimate)" : "Burned (estimate)").foregroundColor(Theme.dim)
                Spacer()
                Text(burned.map { "\(cal($0)) cal" } ?? "--").fontWeight(.semibold).foregroundColor(Theme.text)
            }
            .font(.system(size: 14))
        }
    }

    private func macro(_ name: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).foregroundColor(Theme.dim)
            Text(grams(v)).fontWeight(.semibold).foregroundColor(Theme.text)
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meals: some View {
        VStack(spacing: 0) {
            ForEach(Array(MealSlot.allCases.enumerated()), id: \.element) { i, slot in
                let list = store.entries(key).filter { $0.slot == slot }
                Group {
                    if list.isEmpty {
                        Button { search = SearchRequest(slot: slot) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(slot.rawValue).fontWeight(.semibold).foregroundColor(Theme.text)
                                    Text("Not logged yet").font(.system(size: 14)).foregroundColor(Theme.dim)
                                }
                                Spacer()
                                Text("Add").fontWeight(.semibold).foregroundColor(Theme.green)
                            }
                            .frame(minHeight: 52).contentShape(Rectangle())
                        }
                    } else {
                        NavigationLink { MealDetailView(day: day, slot: slot) } label: { mealRow(slot, list) }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 15))
                if i < MealSlot.allCases.count - 1 { Divider().overlay(Theme.track) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func mealRow(_ slot: MealSlot, _ list: [MealEntry]) -> some View {
        let flagged = list.flatMap { MealMath.avoidMatches($0.food, avoid: store.settings.avoid) }
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(slot.rawValue).fontWeight(.semibold).foregroundColor(Theme.text)
                Text(Theme.clock(list[0].time)).font(.system(size: 13)).foregroundColor(Theme.dim)
                Spacer()
                Text("\(cal(list.reduce(0) { $0 + $1.nutrients.kcal })) cal").foregroundColor(Theme.text)
            }
            Text(list.map(\.food.name).joined(separator: ", ")).font(.system(size: 14)).foregroundColor(Theme.dim).lineLimit(2)
            if let first = flagged.first {
                Label("Contains \(first), on your avoid list", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundColor(Theme.orange)
            }
        }
        .padding(.vertical, 12).contentShape(Rectangle())
    }
}

// MARK: - Goal

struct GoalView: View {
    let firstTime: Bool
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = MealStore.shared
    @State private var aim: MealAim = .maintain
    @State private var automatic = true
    @State private var manual = 2000
    @State private var goal: MealStore.Goal?

    private var shown: Int { automatic ? (goal?.calories ?? manual) : manual }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(firstTime ? "Meals, first time" : "Daily goal").font(.system(size: 13)).foregroundColor(Theme.dim)
                    Text("What are you aiming for?").font(Theme.display(30)).foregroundColor(Theme.text)
                    Text("Zdravlje sets a daily calorie goal from what you usually burn. You can change it any time.")
                        .font(.system(size: 15)).foregroundColor(Color(hex: 0xC9D3CE))
                    ForEach(MealAim.allCases, id: \.self) { a in
                        Button { aim = a; automatic = true; Task { await recalc() } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: aim == a ? "largecircle.fill.circle" : "circle").font(.system(size: 20))
                                    .foregroundColor(aim == a ? Theme.green : Theme.dim)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.rawValue).font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.text)
                                    Text(a.detail).font(.system(size: 13)).foregroundColor(Theme.dim)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16).frame(minHeight: 64)
                            .background(aim == a ? Theme.raised : Theme.card).clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(aim == a ? Theme.green : Theme.line, lineWidth: aim == a ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(aim == a ? .isSelected : [])
                    }
                    Card {
                        Text("Your daily goal").font(.system(size: 13)).foregroundColor(Theme.dim)
                        HStack {
                            step("-", -50)
                            Spacer()
                            (Text(shown.formatted()).font(Theme.display(40)).foregroundColor(Theme.text) + Text(" cal").font(.system(size: 15)).foregroundColor(Theme.dim))
                            Spacer()
                            step("+", 50)
                        }
                        Text(explain).font(.system(size: 13)).foregroundColor(Theme.dim)
                        if !automatic {
                            Button("Go back to the automatic goal") { automatic = true }.font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.blue).frame(minHeight: 44)
                        }
                    }
                    Button(firstTime ? "Start logging" : "Save") { save() }.buttonStyle(TintButton(color: Theme.green)).padding(.top, 8)
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar {
                if !firstTime { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(firstTime)
        .onAppear {
            let s = store.settings
            aim = s.aim
            automatic = s.automatic
            manual = s.manualGoal
        }
        .task { await recalc() }
    }

    private var explain: String {
        var parts: [String] = []
        if !automatic { parts.append("Set by you.") }
        if let u = goal?.usualBurn { parts.append("You usually burn about \(Int(u.rounded()).formatted()) a day (last 4 weeks).") }
        else { parts.append("Once there's a week of burn data, the goal follows it. Add your details in Settings for a better start.") }
        if let r = goal?.restingBurn { parts.append("The automatic goal never goes below your resting burn of about \(Int(r.rounded()).formatted()).") }
        return parts.joined(separator: " ")
    }

    private func step(_ label: String, _ by: Int) -> some View {
        Button {
            manual = max(800, shown + by)
            automatic = false
        } label: {
            Text(label).font(.system(size: 22, weight: .semibold)).foregroundColor(Theme.text)
                .frame(width: 44, height: 44).background(Theme.raised).clipShape(Circle())
                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
        }
        .accessibilityLabel(by > 0 ? "Raise goal by 50" : "Lower goal by 50")
    }

    private func recalc() async {
        var s = store.settings
        s.aim = aim
        s.automatic = true
        let a = SettingsStore.shared.value
        goal = await Task.detached { MealStore.goal(settings: s, appSettings: a) }.value
        if goal?.usualBurn == nil && automatic { manual = goal?.calories ?? manual }
    }

    private func save() {
        var s = store.settings
        s.setUp = true
        s.aim = aim
        s.automatic = automatic && goal?.usualBurn != nil
        s.manualGoal = automatic ? (goal?.calories ?? manual) : manual
        store.settings = s
        dismiss()
    }
}

// MARK: - Search

struct FoodSearchView: View {
    let day: Date
    let slot: MealSlot
    var favoritesOnly = false
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = MealStore.shared
    @State private var query = ""
    @State private var filter = 0
    @State private var usda: [FoodItem] = []
    @State private var packaged: [FoodItem] = []
    @State private var searching = false
    @State private var problem = ""
    @State private var custom = false
    @FocusState private var focused: Bool

    private var mine: [FoodItem] {
        let pool: [FoodItem]
        switch filter {
        case 2: pool = store.data.favorites
        case 1: pool = store.data.recents
        default: pool = store.data.favorites + store.data.recents.filter { r in !store.data.favorites.contains { $0.id == r.id } }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? pool : pool.filter { $0.displayName.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Search foods", text: $query)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .onSubmit { Task { await runSearch() } }
                        .font(.system(size: 16)).foregroundColor(Theme.text)
                        .padding(.horizontal, 14).frame(minHeight: 50)
                        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Theme.green : Theme.line, lineWidth: 1))
                    HStack(spacing: 8) {
                        chip("All", 0)
                        chip("Recent", 1)
                        chip("Favorites", 2)
                    }
                    if !mine.isEmpty {
                        section(query.isEmpty ? (filter == 2 ? "Your favorites" : "You've had before") : "You've had before", mine.prefix(query.isEmpty ? 25 : 6).map { $0 })
                    } else if query.isEmpty {
                        Text(filter == 2 ? "No favorites yet. Tap the star on a food to add it." : "Search for a food, or scan a barcode from the Meals screen.")
                            .font(.system(size: 14)).foregroundColor(Theme.dim)
                    }
                    if filter == 0 {
                        if searching { ProgressView().frame(maxWidth: .infinity, minHeight: 60) }
                        if !problem.isEmpty { Text(problem).font(.system(size: 14)).foregroundColor(Theme.orange) }
                        if !usda.isEmpty { section("Everyday foods (USDA)", usda) }
                        if !packaged.isEmpty { section("Packaged foods (Open Food Facts)", packaged) }
                        if !searching && !query.isEmpty && usda.isEmpty && packaged.isEmpty && problem.isEmpty && didSearch {
                            Text("Nothing found. Try fewer words, or enter it yourself.").font(.system(size: 14)).foregroundColor(Theme.dim)
                        }
                    }
                    Button("Can't find it? Enter it yourself") { custom = true }.buttonStyle(TintButton(color: Theme.text)).padding(.top, 8)
                    Text("Only what you type is sent to the food databases.").font(.system(size: 12)).foregroundColor(Theme.dim).frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Add to \(slot.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(isPresented: $custom) { CustomFoodView(day: day, slot: slot) { dismiss() } }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if favoritesOnly { filter = 2 } else { focused = true }
        }
        .task(id: query) {
            guard filter == 0, query.trimmingCharacters(in: .whitespaces).count >= 3 else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { await runSearch() }
        }
    }

    @State private var didSearch = false

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        problem = ""
        async let a = attempt { try await FoodAPI.usda(q) }
        async let b = attempt { try await FoodAPI.packaged(q) }
        let (ra, rb) = await (a, b)
        guard q == query.trimmingCharacters(in: .whitespaces) else { return }
        usda = (try? ra.get()) ?? []
        packaged = (try? rb.get()) ?? []
        if case .failure(let e) = ra, usda.isEmpty, packaged.isEmpty { problem = e.localizedDescription }
        searching = false
        didSearch = true
    }

    private func chip(_ label: String, _ tag: Int) -> some View {
        Button { filter = tag } label: {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundColor(filter == tag ? Theme.green : Theme.text)
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(filter == tag ? Theme.raised : Color.clear).clipShape(Capsule())
                .overlay(Capsule().stroke(filter == tag ? Theme.green : Theme.line, lineWidth: 1))
        }
        .accessibilityAddTraits(filter == tag ? .isSelected : [])
    }

    private func section(_ title: String, _ foods: [FoodItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13)).foregroundColor(Theme.dim).padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(Array(foods.enumerated()), id: \.element.id) { i, f in
                    NavigationLink { FoodAmountView(food: f, day: day, slot: slot) { dismiss() } } label: { FoodRow(food: f) }
                        .buttonStyle(.plain)
                    if i < foods.count - 1 { Divider().overlay(Theme.track) }
                }
            }
            .padding(.horizontal, 16)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

private func attempt<T>(_ body: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

struct FoodRow: View {
    let food: FoodItem
    var body: some View {
        let s = food.servings.first ?? Serving(label: "100 g", grams: 100)
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(food.displayName).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text).lineLimit(2)
                Text("per \(s.label)").font(.system(size: 13)).foregroundColor(Theme.dim).lineLimit(1)
            }
            Spacer()
            Text("\(cal(food.nutrients(amount: 1, serving: s).kcal)) cal").font(.system(size: 15)).foregroundColor(Theme.text)
        }
        .frame(minHeight: 60).contentShape(Rectangle())
    }
}

// MARK: - Amount

struct FoodAmountView: View {
    let food: FoodItem
    let day: Date
    var slot: MealSlot
    var existing: MealEntry?
    let done: () -> Void
    @ObservedObject private var store = MealStore.shared
    @State private var amountText = "1"
    @State private var serving: Serving?
    @State private var meal: MealSlot = .breakfast
    @State private var time = Date()

    init(food: FoodItem, day: Date, slot: MealSlot, existing: MealEntry? = nil, done: @escaping () -> Void) {
        self.food = food
        self.day = day
        self.slot = slot
        self.existing = existing
        self.done = done
    }

    private var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var chosen: Serving { serving ?? food.allServings.first ?? Serving(label: "g", grams: 1) }
    private var totals: Nutrients { food.nutrients(amount: amount, serving: chosen) }
    private var flagged: [String] { MealMath.avoidMatches(food, avoid: store.settings.avoid) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(food.sourceLabel).font(.system(size: 13)).foregroundColor(Theme.dim)
                    Text(food.displayName).font(Theme.display(26)).foregroundColor(Theme.text)
                }
                Card {
                    Text("How much").font(.system(size: 13)).foregroundColor(Theme.dim)
                    HStack(spacing: 10) {
                        circleButton("-") { amountText = trim(max(0, amount - step)) }
                        TextField("Amount", text: $amountText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.center)
                            .font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.text)
                            .frame(minHeight: 44).background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
                        circleButton("+") { amountText = trim(amount + step) }
                    }
                    FlowChips(items: food.allServings, selected: chosen) { s in
                        let g = amount * chosen.grams
                        serving = s
                        if s.grams > 0 && (s.label == "g" || s.label == "oz" || chosen.label == "g" || chosen.label == "oz") {
                            amountText = trim(s.label == "g" ? g.rounded() : (g / s.grams * 10).rounded() / 10)
                        }
                    }
                }
                Card {
                    HStack(alignment: .firstTextBaseline) {
                        Text(cal(totals.kcal)).font(Theme.display(34)).foregroundColor(Theme.text)
                        Spacer()
                        Text("calories").font(.system(size: 14)).foregroundColor(Theme.dim)
                    }
                    HStack {
                        stat("Protein", totals.protein)
                        stat("Carbs", totals.carbs)
                        stat("Fat", totals.fat)
                    }
                }
                Card {
                    HStack {
                        Text("Meal").foregroundColor(Theme.text)
                        Spacer()
                        Picker("Meal", selection: $meal) { ForEach(MealSlot.allCases) { Text($0.rawValue).tag($0) } }.tint(Theme.dim)
                    }
                    Divider().overlay(Theme.track)
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).foregroundColor(Theme.text)
                }
                if !flagged.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundColor(Theme.orange)
                        (Text("Heads up: ").fontWeight(.semibold) + Text("this matches \(flagged.joined(separator: ", ")) on your avoid list."))
                            .foregroundColor(Theme.text)
                    }
                    .font(.system(size: 14)).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.orange, lineWidth: 1))
                }
                Button(existing == nil ? "Add to \(meal.rawValue)" : "Save") { save() }
                    .buttonStyle(TintButton(color: Theme.green)).disabled(amount <= 0).padding(.top, 6)
                if let e = existing {
                    Button("Remove from \(e.slot.rawValue)") { store.remove(e.id); done() }.buttonStyle(TintButton(color: Theme.orange))
                }
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.toggleFavorite(food) } label: {
                    Image(systemName: store.isFavorite(food) ? "star.fill" : "star").foregroundColor(store.isFavorite(food) ? Theme.green : Theme.dim)
                }
                .accessibilityLabel(store.isFavorite(food) ? "Remove from favorites" : "Add to favorites")
            }
        }
        .onAppear {
            if let e = existing {
                amountText = trim(e.amount)
                serving = e.serving
                meal = e.slot
                time = Date(timeIntervalSince1970: Double(e.time) / 1000)
            } else {
                meal = slot
                let cal = Calendar.current
                if cal.isDateInToday(day) {
                    time = Date()
                } else {
                    let hour = [MealSlot.breakfast: 8, .lunch: 12, .dinner: 18, .snacks: 15][slot] ?? 12
                    time = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
                }
                if chosen.label == "g" { amountText = "100" }
            }
        }
    }

    private var step: Double { chosen.label == "g" ? 10 : chosen.label == "oz" ? 0.5 : 0.5 }

    private func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private func circleButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 22, weight: .semibold)).foregroundColor(Theme.text)
                .frame(width: 44, height: 44).background(Theme.raised).clipShape(Circle())
                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
        }
        .accessibilityLabel(label == "+" ? "More" : "Less")
    }

    private func stat(_ name: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).foregroundColor(Theme.dim)
            Text(grams(v)).fontWeight(.semibold).foregroundColor(Theme.text)
        }
        .font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        let cal = Calendar.current
        // Keep the chosen time on the day being viewed.
        let c = cal.dateComponents([.hour, .minute], from: time)
        let at = cal.date(bySettingHour: c.hour ?? 12, minute: c.minute ?? 0, second: 0, of: day) ?? time
        let entry = MealEntry(id: existing?.id ?? UUID().uuidString, day: dayKey(day), slot: meal,
                              time: Int64(at.timeIntervalSince1970 * 1000), food: food, amount: amount, serving: chosen)
        store.add(entry)
        done()
    }
}

/// Wrapping row of selectable chips.
struct FlowChips: View {
    let items: [Serving]
    let selected: Serving
    let pick: (Serving) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { s in
                    Button { pick(s) } label: {
                        Text(s.label).font(.system(size: 13, weight: .semibold)).foregroundColor(s == selected ? Theme.green : Theme.text)
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .background(s == selected ? Theme.raised : Color.clear).clipShape(Capsule())
                            .overlay(Capsule().stroke(s == selected ? Theme.green : Theme.line, lineWidth: 1))
                    }
                    .accessibilityAddTraits(s == selected ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: - Enter it yourself

struct CustomFoodView: View {
    let day: Date
    let slot: MealSlot
    let done: () -> Void
    @State private var name = ""
    @State private var servingName = "1 serving"
    @State private var kcal = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var next: FoodItem?
    @State private var showNext = false

    private func n(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    var body: some View {
        Form {
            Section {
                TextField("Food name", text: $name)
                TextField("Serving, for example 1 bowl", text: $servingName)
            } footer: {
                Text("Chains post nutrition info on their website or app. Enter it once, then star it to reuse.")
            }
            Section("Per serving") {
                field("Calories", $kcal)
                field("Protein (g)", $protein)
                field("Carbs (g)", $carbs)
                field("Fat (g)", $fat)
            }
            Section {
                Button("Next") {
                    next = FoodItem(id: "custom:\(UUID().uuidString)", name: name.trimmingCharacters(in: .whitespaces), brand: nil, source: .custom,
                                    per100g: Nutrients(kcal: n(kcal), protein: n(protein), carbs: n(carbs), fat: n(fat)),
                                    servings: [Serving(label: servingName.isEmpty ? "serving" : servingName, grams: 100)], ingredients: nil)
                    showNext = true
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || n(kcal) <= 0)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Enter a food")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showNext) {
            if let f = next { FoodAmountView(food: f, day: day, slot: slot, done: done) }
        }
    }

    private func field(_ label: String, _ value: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: value).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100)
        }
    }
}

// MARK: - Meal detail

struct MealDetailView: View {
    let day: Date
    let slot: MealSlot
    @ObservedObject private var store = MealStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var editing: MealEntry?

    private var list: [MealEntry] { store.entries(dayKey(day)).filter { $0.slot == slot } }

    var body: some View {
        List {
            Section {
                ForEach(list) { e in
                    Button { editing = e } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.food.displayName).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                                Text("\(e.amountText), \(Theme.clock(e.time))").font(.system(size: 13)).foregroundColor(Theme.dim)
                                if let m = MealMath.avoidMatches(e.food, avoid: store.settings.avoid).first {
                                    Label("Contains \(m)", systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundColor(Theme.orange)
                                }
                            }
                            Spacer()
                            Text("\(cal(e.nutrients.kcal)) cal").foregroundColor(Theme.text)
                        }
                    }
                }
                .onDelete { idx in idx.map { list[$0].id }.forEach(store.remove) }
                .listRowBackground(Theme.card)
            } footer: {
                let t = list.reduce(Nutrients.zero) { $0 + $1.nutrients }
                Text("\(cal(t.kcal)) cal. Protein \(grams(t.protein)), carbs \(grams(t.carbs)), fat \(grams(t.fat)). Swipe a food to delete it.")
            }
            Section {
                Button("Add another food") { adding = true }.foregroundColor(Theme.green).listRowBackground(Theme.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(slot.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { FoodSearchView(day: day, slot: slot) }
        .sheet(item: $editing) { e in
            NavigationStack {
                FoodAmountView(food: e.food, day: day, slot: e.slot, existing: e) { editing = nil }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } } }
            }
            .preferredColorScheme(.dark)
        }
        .onChange(of: list.isEmpty) { empty in if empty { dismiss() } }
    }
}

// MARK: - Barcode

struct BarcodeView: View {
    let day: Date
    let slot: MealSlot
    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var typed = ""
    @State private var found: FoodItem?
    @State private var looking = false
    @State private var message = ""
    @State private var useFound = false

    private var canScan: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if canScan && found == nil && !looking {
                    ScannerView { c in Task { await lookup(c) } }
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(alignment: .bottom) {
                            Text("Point at the barcode on the package").font(.system(size: 15)).foregroundColor(Theme.text)
                                .padding(10).background(Theme.bg.opacity(0.7)).clipShape(Capsule()).padding(.bottom, 16)
                        }
                        .padding(20)
                } else if !canScan && found == nil {
                    Text("The camera scanner isn't available. Type the number under the barcode instead.")
                        .font(.system(size: 15)).foregroundColor(Theme.dim).padding(20)
                    Spacer()
                } else {
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 12) {
                    if looking {
                        HStack { ProgressView(); Text("Looking up \(code ?? "")").foregroundColor(Theme.dim) }
                    } else if let f = found {
                        Text("Found it").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.green)
                        FoodRow(food: f)
                        HStack(spacing: 10) {
                            Button("Use this") { useFound = true }.buttonStyle(TintButton(color: Theme.green))
                            Button("Scan again") { found = nil; code = nil; message = "" }.buttonStyle(TintButton(color: Theme.text))
                        }
                    } else {
                        if !message.isEmpty { Text(message).font(.system(size: 14)).foregroundColor(Theme.orange) }
                        HStack(spacing: 10) {
                            TextField("Number under the barcode", text: $typed).keyboardType(.numberPad)
                                .padding(.horizontal, 12).frame(minHeight: 44).background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
                            Button("Look up") { Task { await lookup(typed) } }.font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.green)
                                .frame(minHeight: 44).disabled(typed.filter(\.isNumber).count < 6)
                        }
                    }
                    Text("Product info comes from Open Food Facts. Only the barcode number is sent.").font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card)
            }
            .background(Color(hex: 0x0B1011).ignoresSafeArea())
            .navigationTitle("Scan a barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(isPresented: $useFound) {
                if let f = found { FoodAmountView(food: f, day: day, slot: slot) { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func lookup(_ c: String) async {
        guard !looking, code != c || found == nil else { return }
        code = c
        looking = true
        message = ""
        do {
            found = try await FoodAPI.barcode(c)
            if found == nil { message = "That product isn't in Open Food Facts yet. Search by name, or enter it yourself." }
        } catch {
            message = error.localizedDescription
        }
        looking = false
    }
}

struct ScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode()], qualityLevel: .balanced,
                                           isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var last: String?
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let b) = item, let v = b.payloadStringValue, v != last {
                    last = v
                    onCode(v)
                    return
                }
            }
        }
    }
}

// MARK: - Settings

struct MealsSettingsView: View {
    @ObservedObject private var store = MealStore.shared
    @State private var newAvoid = ""
    @State private var key = FoodKey.value ?? ""
    @State private var goal: MealStore.Goal?
    @State private var keyHelp = false

    var body: some View {
        Form {
            Section {
                Picker("Aiming to", selection: Binding(get: { store.settings.aim }, set: { v in store.settings.aim = v; Task { await reload() } })) {
                    ForEach(MealAim.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Set goal automatically", isOn: Binding(get: { store.settings.automatic }, set: { v in
                    var s = store.settings
                    if !v { s.manualGoal = goal?.calories ?? s.manualGoal }
                    s.automatic = v
                    store.settings = s
                    Task { await reload() }
                }))
                .tint(Theme.green)
                if store.settings.automatic {
                    HStack { Text("Daily goal"); Spacer(); Text("\(goal?.calories.formatted() ?? "--") cal").fontWeight(.semibold) }
                } else {
                    Stepper(value: Binding(get: { store.settings.manualGoal }, set: { store.settings.manualGoal = $0 }), in: 800...6000, step: 50) {
                        HStack { Text("Daily goal"); Spacer(); Text("\(store.settings.manualGoal.formatted()) cal").fontWeight(.semibold) }
                    }
                }
            } header: {
                Text("Calorie goal")
            } footer: {
                Text("Automatic: your usual burn over the last 4 weeks, adjusted for your aim. Turn it off to set your own number.")
            }

            Section {
                ForEach(store.settings.avoid, id: \.self) { a in Text(a) }
                    .onDelete { idx in var s = store.settings; s.avoid.remove(atOffsets: idx); store.settings = s }
                HStack {
                    TextField("Add a food or ingredient", text: $newAvoid).onSubmit(addAvoid)
                    Button("Add", action: addAvoid).disabled(newAvoid.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Avoid list")
            } footer: {
                Text("Zdravlje checks food names and, for packaged foods, ingredient lists. It can miss things, so always check labels. Swipe to remove.")
            }

            Section {
                TextField("Paste your free key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: key) { FoodKey.set($0) }
                Button("How to get a free key (2 minutes)") { keyHelp = true }
            } header: {
                Text("Food database")
            } footer: {
                Text("The key stays on this phone and is never included in backups. Without one, search still works but is limited to a few searches an hour.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Meals")
        .task { await reload() }
        .sheet(isPresented: $keyHelp) { KeyHelp() }
    }

    private func reload() async { goal = await GoalLoader.load() }

    private func addAvoid() {
        let t = newAvoid.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var s = store.settings
        if !s.avoid.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { s.avoid.append(t) }
        store.settings = s
        newAvoid = ""
    }
}

struct KeyHelp: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("1. Open api.data.gov/signup in Safari.")
                Text("2. Enter a first name, last name and email. Any email you can check works.")
                Text("3. The key appears on screen and is emailed to you. It's a long mix of letters and numbers.")
                Text("4. Copy it, come back here, and paste it into the USDA key box.")
                Link("Open api.data.gov/signup", destination: URL(string: "https://api.data.gov/signup/")!).foregroundColor(Theme.green)
            }
            .navigationTitle("Get a free USDA key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
