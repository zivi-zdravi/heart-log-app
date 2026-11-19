import Foundation
import UserNotifications

/// notify.json: what each notification does (backed up). notifystate.json:
/// what has been sent already (kept on this phone only).
final class NotifyStore: ObservableObject {
    static let shared = NotifyStore()
    static let fileName = "notify.json"

    @Published private(set) var settings: NotifySettings
    private(set) var state: NotifyState

    private static var url: URL { Store.shared.dir.appendingPathComponent(fileName) }
    private static var stateURL: URL { Store.shared.dir.appendingPathComponent("notifystate.json") }

    private init() {
        settings = (try? JSONDecoder().decode(NotifySettings.self, from: Data(contentsOf: Self.url))) ?? NotifySettings()
        state = (try? JSONDecoder().decode(NotifyState.self, from: Data(contentsOf: Self.stateURL))) ?? NotifyState()
    }

    func reload() {
        settings = (try? JSONDecoder().decode(NotifySettings.self, from: Data(contentsOf: Self.url))) ?? NotifySettings()
    }

    func change(_ edit: (inout NotifySettings) -> Void) {
        var s = settings
        edit(&s)
        guard s != settings else { return }
        let before = settings
        settings = s
        JSONFile.write(s, to: Self.url)
        NotifyEngine.shared.settingsChanged(from: before, to: s)
    }

    func changeState(_ edit: (inout NotifyState) -> Void) {
        var s = state
        edit(&s)
        guard s != state else { return }
        state = s
        JSONFile.write(s, to: Self.stateURL)
    }
}

/// Decides when to notify and sends each alert to the phone, the band, or both.
/// Runs from the band link's once-a-minute tick, so it only works while
/// Zdravlje is connected to the band (except Gone quiet, which iOS delivers).
final class NotifyEngine {
    static let shared = NotifyEngine()

    private let center = UNUserNotificationCenter.current()
    private static let quietID = "gone-quiet"
    private var lastQuietReschedule = Date.distantPast
    private var lastSteps = Date.distantPast
    private var lastActivityScan = Date.distantPast
    private var lastTargetCalc = Date.distantPast
    private var windDownToday: (key: String, minute: Int)?
    private var alarmUnsavedSince: Date?
    private var busy = false
    private var lastBreathingCheck = Date.distantPast

    private var settings: NotifySettings { NotifyStore.shared.settings }
    private var state: NotifyState { NotifyStore.shared.state }

    // MARK: Permission

    func requestPermissionIfNeeded() {
        guard settings.anyPhone else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func settingsChanged(from old: NotifySettings, to new: NotifySettings) {
        if new.anyPhone && !old.anyPhone { requestPermissionIfNeeded() }
        if !new.goneQuiet.toPhone { center.removePendingNotificationRequests(withIdentifiers: [Self.quietID]) }
        if new.charger != old.charger { BandLink.shared.eventsNeedChanged() }
        if new.stepGoalCount != old.stepGoalCount { NotifyStore.shared.changeState { $0.stepGoalDay = nil } }
        windDownToday = nil
    }

    // MARK: Sending

    private func minuteOfDay(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func isQuiet(_ d: Date = Date()) -> Bool { NotifyRules.isQuiet(minuteOfDay(d), settings) }

    /// Sends now unless it's quiet hours. Returns whether anything went out.
    @discardableResult
    private func send(_ route: NotifyRoute, id: String, title: String, body: String) -> Bool {
        guard route != .off, !isQuiet() else { return false }
        if route.toPhone {
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = .default
            center.add(UNNotificationRequest(identifier: "\(id)-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil))
        }
        if route.toBand { BandLink.shared.buzz(id) }
        BandLink.shared.log?("notify", "\(id) \(route.rawValue)")
        return true
    }

    // MARK: Gone quiet

    /// Each band sample pushes the "gone quiet" alert 30 minutes into the
    /// future, so it only ever fires if the samples stop. iOS delivers it even
    /// when Zdravlje is suspended.
    func bandHeard() {
        guard settings.goneQuiet.toPhone, Date().timeIntervalSince(lastQuietReschedule) >= 60 else { return }
        lastQuietReschedule = Date()
        let last = Date()
        var fire = last.addingTimeInterval(30 * 60)
        if isQuiet(fire), let end = quietEnd(after: fire) { fire = end }
        let c = UNMutableNotificationContent()
        c.title = "Band gone quiet"
        c.body = "Zdravlje hasn't heard the band since \(last.formatted(date: .omitted, time: .shortened)). Check it's on and in range."
        c.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, fire.timeIntervalSinceNow), repeats: false)
        center.add(UNNotificationRequest(identifier: Self.quietID, content: c, trigger: trigger))
    }

    /// You stopped recording on purpose: nothing to warn about.
    func recordingStopped() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.quietID])
        lastQuietReschedule = .distantPast
    }

    private func quietEnd(after d: Date) -> Date? {
        let cal = Calendar.current
        let start = cal.startOfDay(for: d)
        for offset in 0...1 {
            guard let day = cal.date(byAdding: .day, value: offset, to: start) else { continue }
            let end = day.addingTimeInterval(Double(settings.quietEnd) * 60)
            if end > d { return end }
        }
        return nil
    }

    // MARK: Band events

    /// Waits a few seconds for a fresh battery reading so the message can say it.
    func charger(on: Bool) {
        guard settings.charger != .off else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            let level = Recorder.shared.battery.map { "\($0)%" }
            let body: String
            if on {
                body = level.map { "Charging started. Battery at \($0)." } ?? "Charging started."
                self.send(self.settings.charger, id: "charger", title: "Band charging", body: body)
                return
            }
            // The band says "stopped charging" both when the pack comes off and
            // when the pack runs empty. Only a removal event means it came off.
            let removed = Recorder.shared.packRemovedAt.map { Date().timeIntervalSince($0) < 30 } ?? false
            if removed {
                body = level.map { "The battery pack was taken off. Band at \($0)." } ?? "The battery pack was taken off."
                self.send(self.settings.charger, id: "charger", title: "Charger off", body: body)
            } else {
                body = level.map { "The battery pack stopped charging the band but is still on, so it's probably empty. Band at \($0)." }
                    ?? "The battery pack stopped charging the band but is still on, so it's probably empty."
                self.send(self.settings.charger, id: "charger", title: "Battery pack empty?", body: body)
            }
        }
    }

    // MARK: Once a minute

    func tick(now: Date = Date()) {
        let s = settings
        let cal = Calendar.current
        let todayKey = DayEngine.shared.key(now)
        let minute = minuteOfDay(now)

        // Low battery
        if s.lowBattery != .off, let level = Recorder.shared.battery {
            let r = NotifyRules.lowBattery(level: level, at: s.lowBatteryAt, sent: state.lowBatterySent)
            if r.fire {
                let sent = send(s.lowBattery, id: "battery", title: "Band battery low", body: "The band is at \(level)%. Charge it soon.")
                NotifyStore.shared.changeState { $0.lowBatterySent = sent }
            } else if r.sent != state.lowBatterySent {
                NotifyStore.shared.changeState { $0.lowBatterySent = r.sent }
            }
        }

        // Alarm not saved: the next alarm is within a day and the band hasn't
        // confirmed it for 15 minutes.
        if s.alarmNotSaved.toPhone, let next = AlarmStore.shared.next, next.timeIntervalSince(now) < 86_400 {
            let ok = AlarmStore.shared.armed.map { $0.confirmed && abs($0.wake.timeIntervalSince(next)) < 1 } ?? false
            if ok {
                alarmUnsavedSince = nil
            } else {
                if alarmUnsavedSince == nil { alarmUnsavedSince = now }
                if let since = alarmUnsavedSince, now.timeIntervalSince(since) >= 15 * 60, state.notSavedDay != todayKey,
                   send(.phone, id: "alarm-not-saved", title: "Alarm not saved",
                        body: "The band hasn't confirmed your \(AlarmView.dayTime(next)) alarm. Open Zdravlje's Alarm screen to retry.") {
                    NotifyStore.shared.changeState { $0.notSavedDay = todayKey }
                }
            }
        } else {
            alarmUnsavedSince = nil
        }

        // No-alarm check-in at 7 PM
        if s.noAlarmCheckIn != .off, minute >= 19 * 60, state.checkInDay != todayKey,
           NotifyRules.checkInDue(schedule: AlarmStore.shared.schedule, now: now, calendar: cal) {
            if send(s.noAlarmCheckIn, id: "no-alarm", title: "No alarm tomorrow",
                    body: "You usually have an alarm tomorrow, but none is set. Open the Alarm screen if you want one.") {
                NotifyStore.shared.changeState { $0.checkInDay = todayKey }
            }
        }

        // Water reminder
        if s.water != .off, !isQuiet(now) {
            let woke = cal.startOfDay(for: now).addingTimeInterval(Double(s.quietOn ? s.quietEnd : 7 * 60) * 60)
            let nowMs = Int64(now.timeIntervalSince1970 * 1000)
            let lastGlass = WaterStore.shared.data.days[todayKey]?.lastAt
            if now >= woke, NotifyRules.waterDue(now: nowMs, lastGlass: lastGlass, lastReminder: state.lastWaterReminder,
                                                  wokeAt: Int64(woke.timeIntervalSince1970 * 1000), everyHours: s.waterEveryHours) {
                let w = WaterStore.shared
                if send(s.water, id: "water", title: "Time for water", body: "\(w.data.label(todayKey)) so far today.") {
                    NotifyStore.shared.changeState { $0.lastWaterReminder = nowMs }
                }
            }
        }

        // Wind-down
        if s.windDown != .off, state.windDownDay != todayKey {
            if let w = windDownToday, w.key == todayKey {
                if minute >= w.minute, minute < w.minute + 45,
                   send(s.windDown, id: "wind-down", title: "Time to wind down", body: "Your target bedtime is in 45 minutes.") {
                    NotifyStore.shared.changeState { $0.windDownDay = todayKey }
                }
            } else if now.timeIntervalSince(lastTargetCalc) >= 3600 {
                lastTargetCalc = now
                computeWindDown(now)
            }
        }

        // Breathing rate higher than usual: once a day, after you're up.
        if s.breathingHigh != .off, state.breathingDay != todayKey, !isQuiet(now), minute < 15 * 60,
           now.timeIntervalSince(lastBreathingCheck) >= 30 * 60 {
            lastBreathingCheck = now
            checkBreathing(now, key: todayKey)
        }

        // Step goal, every 15 minutes
        if s.stepGoal != .off, state.stepGoalDay != todayKey, now.timeIntervalSince(lastSteps) >= 15 * 60 {
            lastSteps = now
            checkSteps(now, key: todayKey)
        }

        // Possible activity, every 10 minutes
        if s.possibleActivity != .off, now.timeIntervalSince(lastActivityScan) >= 10 * 60 {
            lastActivityScan = now
            scanActivities(now)
        }
    }

    // MARK: Background checks

    private func computeWindDown(_ now: Date) {
        guard !busy else { return }
        busy = true
        let settingsNow = SettingsStore.shared.value
        Task.detached { [weak self] in
            let cal = Calendar.current
            let today = cal.startOfDay(for: now)
            let from = cal.date(byAdding: .day, value: -14, to: today) ?? today
            let to = cal.date(byAdding: .day, value: -1, to: today) ?? today
            let wakes = DayEngine.shared.records(from: from, to: to, settings: settingsNow).compactMap { $0.sleep }.map { p -> Double in
                let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(p.wake) / 1000))
                return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
            }
            let need = DayEngine.shared.record(today, settings: settingsNow)?.sleepNeedMin
            let minute = SleepMath.median(wakes).flatMap { w in need.map { NotifyRules.windDownMinute(usualWakeMinute: w, needMinutes: $0) } }
            await MainActor.run {
                guard let self else { return }
                self.busy = false
                if let minute { self.windDownToday = (DayEngine.shared.key(now), minute) }
            }
        }
    }

    private func checkBreathing(_ now: Date, key: String) {
        let settingsNow = SettingsStore.shared.value
        let route = settings.breathingHigh
        Task.detached { [weak self] in
            let cal = Calendar.current
            let today = cal.startOfDay(for: now)
            let r = DayEngine.shared.record(today, settings: settingsNow)
            let nowMs = Int64(now.timeIntervalSince1970 * 1000)
            // Wait until the night is over and you've been up a little while.
            guard let r, let p = r.sleep, p.wake < nowMs - 30 * 60_000 else { return }
            let from = cal.date(byAdding: .day, value: -28, to: today) ?? today
            let to = cal.date(byAdding: .day, value: -1, to: today) ?? today
            let usual = StageMath.usualRange(DayEngine.shared.records(from: from, to: to, settings: settingsNow).compactMap(\.respRate))
            await MainActor.run {
                guard let self, NotifyStore.shared.state.breathingDay != key else { return }
                guard let rate = r.respRate, let u = usual, NotifyRules.breathingHigh(rate, usual: u) else {
                    NotifyStore.shared.changeState { $0.breathingDay = key }
                    return
                }
                let body = String(format: "Last night: %.1f a minute, above your usual (%.1f to %.1f). A rise like this can come before getting sick. Alcohol, a late meal, a hard workout or a warm room can do it too.", rate, u.low, u.high)
                if self.send(route, id: "breathing", title: "Breathing rate higher than usual", body: body) {
                    NotifyStore.shared.changeState { $0.breathingDay = key }
                }
            }
        }
    }

    private func checkSteps(_ now: Date, key: String) {
        let goal = settings.stepGoalCount
        let route = settings.stepGoal
        Task { @MainActor in
            let p = StepsProvider()
            await p.load(day: Calendar.current.startOfDay(for: now))
            guard let steps = p.steps, steps >= goal, NotifyStore.shared.state.stepGoalDay != key else { return }
            if self.send(route, id: "steps", title: "Step goal reached", body: "\(steps.formatted()) steps today. Nice work.") {
                NotifyStore.shared.changeState { $0.stepGoalDay = key }
            }
        }
    }

    private func scanActivities(_ now: Date) {
        let settingsNow = SettingsStore.shared.value
        let day = Calendar.current.startOfDay(for: now)
        let acts = ActivityStore.shared.all
        let route = settings.possibleActivity
        Task.detached { [weak self] in
            let found = DaySummary.compute(day: day, settings: settingsNow, activities: acts).suggestions
            await MainActor.run {
                guard let self else { return }
                let nowMs = Int64(now.timeIntervalSince1970 * 1000)
                let dayMs = Int64(day.timeIntervalSince1970 * 1000)
                // Only recent ones, so turning this on doesn't announce the whole morning.
                let fresh = found.filter { nowMs - $0.end < 30 * 60_000 && !NotifyStore.shared.state.announcedActivities.contains($0.start) }
                guard let span = fresh.last else { return }
                let mins = Int((span.end - span.start) / 60_000)
                let start = Date(timeIntervalSince1970: Double(span.start) / 1000).formatted(date: .omitted, time: .shortened)
                if self.send(route, id: "activity", title: "Possible activity",
                             body: "Looks like \(mins) minutes of activity from \(start). Open Today to save it.") {
                    NotifyStore.shared.changeState { s in
                        s.announcedActivities = s.announcedActivities.filter { $0 >= dayMs } + fresh.map(\.start)
                    }
                }
            }
        }
    }
}
