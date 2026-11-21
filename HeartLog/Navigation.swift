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
    @Published var sleepDay = Calendar.current.startOfDay(for: Date())
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
            sleepDay = Calendar.current.startOfDay(for: d)
            sleepPath = [page]
            jump(.sleep)
        case .strain, .calories, .steps:
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
        sleepDay = Calendar.current.startOfDay(for: day)
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
