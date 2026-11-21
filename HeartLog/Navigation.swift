import SwiftUI

/// Pages that live in one home tab and can be opened from anywhere. Opening
/// one jumps to its home tab first, so the back button always names the home.
enum AppPage: Hashable {
    case hrv(Date)
    case rhr(Date)
    case recovery(Date)
    case strain(Date)
    case calories(Date)
    case steps
}

enum AppTab: Int {
    case today = 0, activity, sleep, trends, log
}

final class AppNav: ObservableObject {
    static let shared = AppNav()

    @Published var tab: AppTab = .today
    /// The day every tab shows. Moving it on one tab moves it on all of them.
    @Published var day = Calendar.current.startOfDay(for: Date())
    private var knownToday = Calendar.current.startOfDay(for: Date())
    private var leftAt: Date?
    private var timer: Timer?
    var isToday: Bool { Calendar.current.isDateInToday(day) }
    /// Away this long and the day goes back to today.
    static let resetAfter: TimeInterval = 3 * 3600

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.leftAt = Date() }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if let t = self.leftAt, Date().timeIntervalSince(t) >= Self.resetAfter { self.goToday() }
            self.leftAt = nil
            self.followToday()
        }
        nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in self?.followToday() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.followToday() }
    }

    /// Moves the shared day by whole days, never past today.
    func move(_ by: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        guard let d = Calendar.current.date(byAdding: .day, value: by, to: day), d <= today else { return }
        day = d
    }

    func goToday() {
        let t = Calendar.current.startOfDay(for: Date())
        if day != t { day = t }
    }

    /// Showing today when midnight passes (the app runs overnight to record): move to the new today.
    private func followToday() {
        let now = Calendar.current.startOfDay(for: Date())
        guard now != knownToday else { return }
        if Calendar.current.isDate(day, inSameDayAs: knownToday) { day = now }
        knownToday = now
    }
    @Published var sleepPath: [AppPage] = []
    @Published var activityPath: [AppPage] = []
    /// Which side of the Log tab is showing.
    @Published var logBody = false
    /// Bumped to rebuild a tab, which takes it back to its home screen.
    @Published private(set) var stackIDs: [AppTab: Int] = [:]
    /// Tabs whose home screen is showing (not covered by a pushed page).
    private var atRoot: Set<AppTab> = []

    func stackID(_ t: AppTab) -> Int { stackIDs[t] ?? 0 }
    func rootShown(_ t: AppTab, _ shown: Bool) { if shown { atRoot.insert(t) } else { atRoot.remove(t) } }

    /// The tab bar. Leaving a tab, or tapping the one you're on, sends it home.
    func select(_ t: AppTab) {
        let old = tab
        if t == old { goHome(t) } else { tab = t; goHome(old) }
    }

    private func goHome(_ t: AppTab) {
        switch t {
        case .sleep: sleepPath = []
        case .activity: activityPath = []
        default: break
        }
        if !atRoot.contains(t) { stackIDs[t, default: 0] += 1 }
    }

    /// Opens a page in its home tab, on top of that tab's main screen.
    func open(_ page: AppPage) {
        switch page {
        case .hrv(let d), .rhr(let d), .recovery(let d):
            day = Calendar.current.startOfDay(for: d)
            sleepPath = [page]
            jump(.sleep)
        case .strain(let d), .calories(let d):
            day = Calendar.current.startOfDay(for: d)
            activityPath = [page]
            jump(.activity)
        case .steps:
            activityPath = [page]
            jump(.activity)
        }
    }

    /// Shortcut jump: the tab you leave goes home, the target keeps its new page.
    private func jump(_ t: AppTab) {
        let old = tab
        tab = t
        if old != t { goHome(old) }
    }

    func openSleep(_ day: Date) {
        self.day = Calendar.current.startOfDay(for: day)
        sleepPath = []
        jump(.sleep)
    }

    func openActivity() {
        activityPath = []
        jump(.activity)
    }

    func openLog(body: Bool) {
        logBody = body
        jump(.log)
    }
}

struct AppPageView: View {
    let page: AppPage

    var body: some View {
        switch page {
        case .hrv(let d): MetricDetailView(kind: .hrv, day: d)
        case .rhr(let d): MetricDetailView(kind: .rhr, day: d)
        case .recovery(let d): RecoveryLoader(day: d)
        case .strain(let d): StrainDetailView(day: d)
        case .calories(let d): CaloriesDetailView(day: d)
        case .steps: StepsHistoryView()
        }
    }
}

/// Recovery needs the day's record, which takes a moment to work out.
struct RecoveryLoader: View {
    let day: Date
    @State private var record: DayRecord?
    @State private var loaded = false

    var body: some View {
        Group {
            if let r = record {
                RecoveryView(day: day, record: r)
            } else if loaded {
                Text("No recovery for this day yet.").font(.system(size: 15)).foregroundColor(Theme.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg.ignoresSafeArea())
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg.ignoresSafeArea())
            }
        }
        .task(id: day) {
            record = await DayLoader.load(day)
            loaded = true
        }
    }
}

extension View {
    func appPages() -> some View {
        navigationDestination(for: AppPage.self) { AppPageView(page: $0) }
    }
}

/// The Ask button at the top of each main screen, shown when AI is set up.
struct AskButton: View {
    let topic: AskTopic
    @ObservedObject private var ai = AIStore.shared
    @State private var asking = false

    var body: some View {
        if ai.isSetUp && ai.settings.ask {
            Button { asking = true } label: {
                Label("Ask", systemImage: "sparkle").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.blue)
                    .padding(.horizontal, 14).frame(minHeight: 36)
                    .background(Color(hex: 0x26394A)).clipShape(Capsule())
            }
            .accessibilityLabel("Ask about your data")
            .sheet(isPresented: $asking) { AskView(range: .week, topic: topic) }
        }
    }
}

/// A main screen's title with the Ask button beside it.
/// Band battery and settings, top right on every main screen.
struct BandPill: View {
    @ObservedObject private var rec = Recorder.shared
    @ObservedObject private var notify = NotifyStore.shared

    var body: some View {
        NavigationLink { SettingsView() } label: {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 16)).foregroundColor(color)
                    Text(rec.battery.map { "\($0)%" } ?? "--").foregroundColor(Theme.text)
                }
                Image(systemName: "gearshape").font(.system(size: 18)).foregroundColor(Theme.dim)
            }
            .frame(minHeight: 32)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel("Band battery \(rec.battery.map { "\($0) percent" } ?? "unknown")\(rec.charging == true ? ", charging" : ""). Open settings")
    }

    private var symbol: String {
        if rec.charging == true { return "battery.100.bolt" }
        guard let b = rec.battery else { return "battery.0" }
        return b >= 88 ? "battery.100" : b >= 63 ? "battery.75" : b >= 38 ? "battery.50" : b >= 13 ? "battery.25" : "battery.0"
    }

    private var color: Color {
        if rec.charging == true { return Theme.green }
        guard let b = rec.battery else { return Theme.dim }
        return b <= notify.settings.lowBatteryAt ? Theme.orange : Theme.green
    }
}

/// The top of Activity, Sleep, Trends and Log: date row and title on the left,
/// battery and settings plus Ask on the right.
struct TabHeader: View {
    let title: String
    let topic: AskTopic
    /// nil hides the date row (Trends).
    var dateText: String?
    @ObservedObject private var nav = AppNav.shared

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if let t = dateText { DayChevrons(text: t, canGoForward: !nav.isToday, move: nav.move) }
                Text(title).font(Theme.display(30)).foregroundColor(Theme.text)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                BandPill()
                AskButton(topic: topic)
            }
        }
    }
}

extension View {
    /// Swipe left or right to move the shared day, like Today.
    func daySwipe() -> some View {
        simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
            guard abs(v.translation.width) > 60, abs(v.translation.width) > abs(v.translation.height) * 2 else { return }
            AppNav.shared.move(v.translation.width > 0 ? -1 : 1)
        })
    }
}

struct ScreenTitle: View {
    let title: String
    let topic: AskTopic

    var body: some View {
        HStack(alignment: .center) {
            Text(title).font(Theme.display(30)).foregroundColor(Theme.text)
            Spacer()
            AskButton(topic: topic)
        }
    }
}

extension View {
    /// Put on the main screen of a tab, inside its NavigationStack.
    func tabRoot(_ t: AppTab) -> some View {
        onAppear { AppNav.shared.rootShown(t, true) }
            .onDisappear { AppNav.shared.rootShown(t, false) }
    }
}
