import XCTest

/// Synthetic fixtures shaped like OpenStrap's CSV export. No real person's data.
final class OpenStrapImportTests: XCTestCase {
    private let daily = Data("""
    date,readiness,resting_hr,hrv,sdnn,resp_rate,stress,strain,active_calories,total_calories,sleep_min,deep_min,rem_min,light_min,nap_min,sleep_efficiency,steps,worn_min,source,algo_version
    2026-01-01,50,60,30,,15.5,,8,1500,,420,90,80,250,,90,,,whoop_export,113
    2026-01-02,,,,,,,,,,,,,,0,,1200,600,band,113
    2026-01-03,,55.5,40.25,90,15.2,40,,100,1500,450,60,100,290,0,92,8000.4,1440,band,113
    """.utf8)

    private let sleep = Data("""
    date,start_ts,end_ts,stage
    2026-01-03,1000,1600,wake
    2026-01-03,1600,2200,light
    2026-01-03,2200,2201,unobserved
    2026-01-03,2201,2500,light
    2026-01-03,2500,3700,deep
    2026-01-03,3700,4300,rem
    """.utf8)

    private func files(daily: Bool = true, sleep: Bool = true) -> [String: Data] {
        var f: [String: Data] = [:]
        if daily { f["openstrap_daily_123.csv"] = self.daily }
        if sleep { f["openstrap_sleep_123.csv"] = self.sleep }
        return f
    }

    func testKeepsOnlyBandRows() {
        let r = OpenStrapImport.parse(files: files())
        XCTAssertEqual(Set(r.data.days.keys), ["2026-01-02", "2026-01-03"])
        XCTAssertEqual(r.skippedWhoopRows, 1)
        XCTAssertTrue(r.foundDaily)
        XCTAssertTrue(r.foundSleep)
    }

    func testReadsBandMeasurements() {
        let d = OpenStrapImport.parse(files: files()).data.days["2026-01-03"]!
        XCTAssertEqual(d.steps, 8000)
        XCTAssertEqual(d.respRate, 15.2)
        XCTAssertEqual(d.restingHR, 55.5)
        XCTAssertEqual(d.hrv, 40.25)
        XCTAssertEqual(d.wornMin, 1440)
        XCTAssertEqual(OpenStrapImport.parse(files: files()).data.days["2026-01-02"]?.steps, 1200)
    }

    func testStagesSkipGapsAndJoinSplitBlocks() {
        let stages = OpenStrapImport.parse(files: files()).data.days["2026-01-03"]!.stages!
        XCTAssertEqual(stages.map(\.kind), [.wake, .light, .deep, .rem])
        XCTAssertEqual(stages[1].start, 1_600_000)
        XCTAssertEqual(stages[1].end, 2_500_000) // light joined across the 1-second unobserved gap
        let totals = OpenStrapImport.parse(files: files()).data.days["2026-01-03"]!.stageMinutes
        XCTAssertEqual(totals[.deep], 20)
        XCTAssertEqual(totals[.rem], 10)
    }

    func testSleepFileAloneStillImports() {
        let r = OpenStrapImport.parse(files: files(daily: false))
        XCTAssertFalse(r.foundDaily)
        XCTAssertEqual(r.data.days["2026-01-03"]?.stages?.count, 4)
    }

    func testUnrelatedFilesAreIgnored() {
        let r = OpenStrapImport.parse(files: ["notes.csv": Data("a,b\n1,2".utf8)])
        XCTAssertFalse(r.foundDaily)
        XCTAssertFalse(r.foundSleep)
        XCTAssertTrue(r.data.days.isEmpty)
    }

    func testMergeOnlyFillsGaps() {
        var existing = BandHistoryData()
        existing.days["2026-01-03"] = BandDay(day: "2026-01-03", source: "band", steps: 9000)
        let incoming = OpenStrapImport.parse(files: files()).data
        let (merged, changed) = OpenStrapImport.merge(incoming, into: existing)
        XCTAssertEqual(merged.days["2026-01-03"]?.steps, 9000) // existing value kept
        XCTAssertEqual(merged.days["2026-01-03"]?.respRate, 15.2) // gap filled
        XCTAssertEqual(merged.days["2026-01-03"]?.source, "band")
        XCTAssertEqual(changed, 2)
        XCTAssertEqual(OpenStrapImport.merge(incoming, into: merged).changed, 0)
    }
}

final class StageMathTests: XCTestCase {
    private func s(_ a: Int64, _ b: Int64, _ k: BandStage.Kind) -> BandStage { BandStage(start: a * 60_000, end: b * 60_000, kind: k) }

    func testRangesWidenForHarderStages() {
        XCTAssertEqual(StageMath.range(.deep, minutes: 100), .init(low: 55, high: 145))
        XCTAssertEqual(StageMath.range(.light, minutes: 300), .init(low: 240, high: 360))
        XCTAssertEqual(StageMath.range(.rem, minutes: 20), .init(low: 5, high: 35)) // 15-minute floor
        XCTAssertNil(StageMath.range(.wake, minutes: 30))
        XCTAssertEqual(StageMath.range(.deep, minutes: 10)?.low, 0)
    }

    func testLongestStretchAndWakeUps() {
        let night = [s(0, 10, .wake), s(10, 100, .light), s(100, 130, .deep), s(130, 140, .wake),
                     s(140, 200, .rem), s(200, 202, .wake), s(202, 300, .light), s(300, 320, .wake)]
        XCTAssertEqual(StageMath.longestStretch(night), 120)
        XCTAssertEqual(StageMath.wakeUps(night), 1) // the 2-minute wake doesn't count; edges don't count
    }

    func testUsualRangeNeedsEnoughNights() {
        XCTAssertNil(StageMath.usualRange([400, 420, 440]))
        XCTAssertEqual(StageMath.usualRange([400, 410, 420, 430, 440]), .init(low: 410, high: 430))
    }

    func testCompareOnlyCallsClearDifferences() {
        let usual = StageMath.Range(low: 450, high: 510)
        XCTAssertEqual(StageMath.compare(587, to: usual), 1)
        XCTAssertEqual(StageMath.compare(520, to: usual), 0)
        XCTAssertEqual(StageMath.compare(420, to: usual), -1)
    }
}

final class StageNightTests: XCTestCase {
    private func s(_ a: Int64, _ b: Int64, _ k: BandStage.Kind) -> BandStage { BandStage(start: a * 60_000, end: b * 60_000, kind: k) }

    func testNightSpansAllBlocksAndCountsSleepOnly() {
        // 7 minutes awake before sleep, a wake-up in the middle, sleep to the end.
        let st = [s(0, 7, .wake), s(7, 300, .light), s(300, 330, .wake), s(330, 670, .rem)]
        let n = StageMath.night(st)!
        XCTAssertEqual(n.start, 0)
        XCTAssertEqual(n.end, 670 * 60_000)
        XCTAssertEqual(n.inBedMin, 670)
        XCTAssertEqual(n.asleepMin, 633)
        XCTAssertEqual(StageMath.awakeDuringSleep(st), 30) // the leading 7 minutes are left out
    }

    func testNoSleepMeansNoNight() {
        XCTAssertNil(StageMath.night([s(0, 30, .wake)]))
        XCTAssertNil(StageMath.night([]))
    }
}

final class PhoneUseTests: XCTestCase {
    private let m: Int64 = 60_000
    private func s(_ a: Int64, _ b: Int64, _ k: BandStage.Kind) -> BandStage { BandStage(start: a * m, end: b * m, kind: k) }
    private func span(_ a: Int64, _ b: Int64) -> PhoneUse.Span { .init(start: a * m, end: b * m) }

    func testPairsUnlocksWithLocks() {
        let ev: [(Int64, String)] = [(10 * m, "unlocked"), (25 * m, "locked"), (40 * m, "locked"), (50 * m, "unlocked")]
        XCTAssertEqual(PhoneUse.spans(ev), [span(10, 25), span(50, 80)]) // open-ended unlock capped at 30 min
    }

    func testStillOnThePhoneRunsUntilNow() {
        // Night 3: unlocked at 4:21 and still on the phone at 7:04, no lock yet.
        let ev: [(Int64, String)] = [(10 * m, "unlocked")]
        XCTAssertEqual(PhoneUse.spans(ev, now: 170 * m), [span(10, 170)])
        XCTAssertEqual(PhoneUse.spans(ev), [span(10, 40)])
    }

    func testParsesEventLines() {
        let ev = PhoneUse.parse("1000,unlocked,\n2000,battery,80\n3000,locked,\nbad line")
        XCTAssertEqual(ev.map(\.0), [1000, 2000, 3000])
        XCTAssertEqual(ev.map(\.1), ["unlocked", "battery", "locked"])
    }

    func testMidNightPhoneThenBackToSleep() {
        // Asleep 0-600; on the phone 200-220; back to sleep for hours.
        let out = PhoneUse.apply([span(200, 220)], to: [s(0, 300, .light), s(300, 600, .deep)])
        XCTAssertEqual(out.map(\.kind), [.light, .wake, .light, .deep])
        let n = StageMath.night(out)!
        XCTAssertEqual(n.end, 600 * m) // night still ends at the real final wake
        XCTAssertEqual(n.asleepMin, 580)
    }

    func testLyingInBedOnPhoneEndsTheNight() {
        // Band calls 590-670 REM, but the phone was picked up at 590 and only 10
        // "sleep" minutes follow the last lock: the night ends at 590.
        let out = PhoneUse.apply([span(590, 660)], to: [s(0, 590, .light), s(590, 670, .rem)])
        let n = StageMath.night(out)!
        XCTAssertEqual(n.end, 590 * m)
        XCTAssertEqual(n.asleepMin, 590)
        XCTAssertEqual(n.inBedMin, 670) // still in bed until 670
    }

    func testYourOwnWakeTimeTrimsTheStages() {
        // Like night 3: the band scored lying awake after 410 as REM and light.
        let st = [s(0, 20, .wake), s(20, 400, .light), s(400, 410, .wake), s(410, 560, .rem)]
        let out = StageMath.clip(st, onset: 20 * m, wake: 400 * m)
        XCTAssertEqual(out.map(\.kind), [.wake, .light, .wake])
        let n = StageMath.night(out)!
        XCTAssertEqual(n.end, 400 * m)
        XCTAssertEqual(n.asleepMin, 380)
        XCTAssertEqual(n.inBedMin, 560) // still in bed until you got up
    }

    func testYourOwnBedtimeTrimsTheStart() {
        let out = StageMath.clip([s(0, 300, .light)], onset: 60 * m, wake: 300 * m)
        XCTAssertEqual(out.map(\.kind), [.wake, .light])
        XCTAssertEqual(StageMath.night(out)!.asleepMin, 240)
    }

    func testPhoneOutsideTheNightChangesNothing() {
        let st = [s(0, 300, .light)]
        XCTAssertEqual(PhoneUse.apply([span(400, 420)], to: st), st)
    }

    func testHeartRateOnlyNight() {
        let p = SleepPeriod(onset: 0, wake: 600 * m, asleepMin: 560, inBedMin: 600, awakeEvents: 2, lowestHR: 50)
        // Mid-night 20 minutes, then a final pickup at 580 with only 10 minutes left.
        let r = PhoneUse.apply([span(200, 220), span(580, 590)], to: p)
        XCTAssertEqual(r.wake, 580 * m)
        XCTAssertEqual(r.asleepMin, 560 - 20 - 20)
        XCTAssertEqual(r.inBedMin, 600)
    }
}
