import XCTest

final class MetricsTests: XCTestCase {
    private func run(_ hr: Int, seconds: Int, from start: Int64 = 0, rr: [Int] = []) -> [Sample] {
        (0..<seconds).map { Sample(t: start + Int64($0) * 1000, hr: hr, rr: rr) }
    }

    func testZonesFromHeartRateReserve() {
        let b = Metrics.zoneBounds(maxHR: 180, resting: 60)
        XCTAssertEqual(b, [108, 132, 144, 156, 168])
        XCTAssertEqual(Metrics.zone(100, b), 0)
        XCTAssertEqual(Metrics.zone(150, b), 3)
        XCTAssertEqual(Metrics.zone(170, b), 5)
    }

    func testZoneSecondsSkipGaps() {
        let b = Metrics.zoneBounds(maxHR: 180, resting: 60)
        let s = run(150, seconds: 11) + run(150, seconds: 5, from: 40_000)
        let z = Metrics.zoneSeconds(s, b)
        XCTAssertEqual(z[3], 14, accuracy: 0.001)
        XCTAssertEqual(z.reduce(0, +), 14, accuracy: 0.001)
    }

    func testStrainScaleAndCap() {
        XCTAssertEqual(Metrics.strain(zoneSeconds: [3600, 0, 0, 0, 0, 0]), 0, accuracy: 0.001)
        let thirtyInZone3 = Metrics.strain(zoneSeconds: [0, 0, 0, 1800, 0, 0])
        XCTAssertEqual(thirtyInZone3, 3.82 * log(21), accuracy: 0.01)
        XCTAssertLessThanOrEqual(Metrics.strain(zoneSeconds: [0, 0, 0, 0, 0, 100_000]), 21)
    }

    func testRmssdAndHrv() {
        let beats = (0..<60).map { $0 % 2 == 0 ? 800 : 850 }
        XCTAssertEqual(Metrics.rmssd(beats) ?? 0, 50, accuracy: 0.001)
        XCTAssertNil(Metrics.rmssd([800, 850, 800]))
        let s = (0..<60).map { Sample(t: Int64($0) * 1000, hr: 72, rr: [$0 % 2 == 0 ? 800 : 850]) }
        XCTAssertEqual(Metrics.hrv(s) ?? 0, 50, accuracy: 0.001)
    }

    func testRestingIgnoresBriefDips() {
        var s = run(70, seconds: 600) + run(55, seconds: 600, from: 600_000)
        s.append(Sample(t: 1_300_000, hr: 40, rr: []))
        XCTAssertEqual(Metrics.restingHR(s), 55)
    }

    func testDetectActivityAllowsShortDip() {
        let s = run(130, seconds: 420) + run(90, seconds: 60, from: 420_000) + run(130, seconds: 480, from: 480_000)
        let spans = Metrics.detectActivities(s, threshold: 108)
        XCTAssertEqual(spans, [Metrics.Span(start: 0, end: 960_000)])
        XCTAssertTrue(Metrics.detectActivities(run(130, seconds: 300), threshold: 108).isEmpty)
    }

    func testCaloriesRestingOnly() {
        let body = Metrics.Body(kg: 60, cm: 165, age: 50, female: true)
        let bounds = Metrics.zoneBounds(maxHR: 180, resting: 60)
        let kcal = Metrics.calories(run(65, seconds: 600), body: body, bounds: bounds, elapsedMinutes: 1440)
        XCTAssertEqual(kcal, 1220.25, accuracy: 0.01)
        let active = Metrics.calories(run(140, seconds: 601), body: body, bounds: bounds, elapsedMinutes: 10)
        XCTAssertGreaterThan(active, 50)
    }
}
