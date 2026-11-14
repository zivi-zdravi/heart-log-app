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
