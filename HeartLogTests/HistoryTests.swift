import XCTest

final class HistoryTests: XCTestCase {
    static let fixture = Data(base64Encoded: "UEsDBBQAAAAAAAAAIQAAAAAAAAAAAAAAAAAOAAAAbXlfd2hvb3BfZGF0YS9QSwMEFAAAAAgAEpxpXSOEoUqoAQAARgMAACYAAABteV93aG9vcF9kYXRhL3BoeXNpb2xvZ2ljYWxfY3ljbGVzLmNzdm2PTW7bMBCF9wFyh9kYkICxMaT1Y3mXPyAFmo2dImtaGitEJFKgaDfq1brokXqFQrbqqGoILoYf58178/vnr7surxhar5wHr2vGM2BTjJ99+cMaxg3n9siugza3jmGGG269NiW8cj/BKc8Q7Jo6xMcPcFROq52utO8gqNsQt2/agOe6gSDnqtWHNsTbytoC7HtXsoEZ3qsOtt4pbfDBsCs72B2c4QKCXFUhPql3eNwMVjdHdqrkD7CtmBuwpmWPL+qNh/KMG3Z762pl8iF/o53y1nVDenca2Z56i4NTXlsDQa1NiF8M7LiY0q+6fPXwqeC+Z8H2ZRtOfzYPT1N0872POoHnzIb7zUeg4J3/B/B+r3PNJu9gNqDcmla3/syuryTJZC5oviSQck20JsILEyDFwL49380p7atEYJyhXOEyWmSYxShoEaNYEaGICdOR/jRzOZ1JycDSFEW8yDCShNGq7yEURJgRJoRRnCDhKsU4G8UUIOQ6PslHmS5n3Lf8fx0RXRiKGOOzEWHv29/Bc4l/HcWcBNBqUI0cI8JEoowQMVpInJ7rqz9QSwMEFAAAAAAAEpxpXfsN5PKPAQAAjwEAABoAAABteV93aG9vcF9kYXRhL3dvcmtvdXRzLmNzdkN5Y2xlIHN0YXJ0IHRpbWUsQ3ljbGUgZW5kIHRpbWUsQ3ljbGUgdGltZXpvbmUsV29ya291dCBzdGFydCB0aW1lLFdvcmtvdXQgZW5kIHRpbWUsRHVyYXRpb24gKG1pbiksQWN0aXZpdHkgbmFtZSxBY3Rpdml0eSBTdHJhaW4sRW5lcmd5IGJ1cm5lZCAoY2FsKSxNYXggSFIgKGJwbSksQXZlcmFnZSBIUiAoYnBtKSxIUiBab25lIDEgJSxIUiBab25lIDIgJSxIUiBab25lIDMgJSxIUiBab25lIDQgJSxIUiBab25lIDUgJSxHUFMgZW5hYmxlZAoyMDI2LTEwLTMwIDIyOjAwOjAwLDIwMjYtMTAtMzEgMjE6MDA6MDAsVVRDLTA3OjAwLDIwMjYtMTAtMzEgMTI6MDU6MDAsMjAyNi0xMC0zMSAxMjo0NTowMCw0MCwiV2Fsa2luZywgb3V0ZG9vciIsOC4yLDIxMCwxNDAsMTE1LDEwLDIwLDMwLDI1LDE1LGZhbHNlClBLAwQUAAAACAASnGldAAAAAAIAAAAAAAAAFwAAAG15X3dob29wX2RhdGEvZW1wdHkudHh0AwBQSwECFAMUAAAAAAAAACEAAAAAAAAAAAAAAAAADgAAAAAAAAAAAAAAgAEAAAAAbXlfd2hvb3BfZGF0YS9QSwECFAMUAAAACAASnGldI4ShSqgBAABGAwAAJgAAAAAAAAAAAAAAgAEsAAAAbXlfd2hvb3BfZGF0YS9waHlzaW9sb2dpY2FsX2N5Y2xlcy5jc3ZQSwECFAMUAAAAAAASnGld+w3k8o8BAACPAQAAGgAAAAAAAAAAAAAAgAEYAgAAbXlfd2hvb3BfZGF0YS93b3Jrb3V0cy5jc3ZQSwECFAMUAAAACAASnGldAAAAAAIAAAAAAAAAFwAAAAAAAAAAAAAAgAHfAwAAbXlfd2hvb3BfZGF0YS9lbXB0eS50eHRQSwUGAAAAAAQABAAdAQAAFgQAAAAA")!

    private var pacific: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        return c
    }

    func testZipEntries() throws {
        let files = try ZipReader.entries(Self.fixture)
        XCTAssertEqual(Set(files.keys), ["my_whoop_data/physiological_cycles.csv", "my_whoop_data/workouts.csv", "my_whoop_data/empty.txt"])
        XCTAssertEqual(files["my_whoop_data/empty.txt"], Data())
        let text = String(decoding: try XCTUnwrap(files["my_whoop_data/workouts.csv"]), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("Cycle start time"))
    }

    func testNotZip() {
        XCTAssertThrowsError(try ZipReader.entries(Data("hello, this is not a zip file at all".utf8)))
    }

    func testCSVQuotes() {
        let rows = CSV.rows("\u{FEFF}a,b,c\r\n\"x, y\",\"say \"\"hi\"\"\",\r\nlast,row,3")
        XCTAssertEqual(rows, [["a", "b", "c"], ["x, y", "say \"hi\"", ""], ["last", "row", "3"]])
    }

    func testParseKeysByWakeDate() throws {
        let h = HistoryImport.parse(files: try ZipReader.entries(Self.fixture), calendar: pacific)
        XCTAssertEqual(Set(h.days.keys), ["2026-10-31", "2026-11-01"])
        let d = try XCTUnwrap(h.days["2026-10-31"])
        XCTAssertEqual(d.recovery, 61)
        XCTAssertEqual(d.hrv, 28)
        XCTAssertEqual(d.rhr, 59)
        XCTAssertEqual(d.sleepScore, 77)
        XCTAssertEqual(d.sleep?.asleepMin, 420)
        XCTAssertEqual(d.sleep?.inBedMin, 480)
        XCTAssertTrue(d.isWhoop)
        XCTAssertNil(h.days["2026-11-01"]?.sleep)
        XCTAssertEqual(h.days["2026-11-01"]?.strain, 4.2)
        XCTAssertEqual(h.workouts.count, 1)
        let w = try XCTUnwrap(h.workouts.first)
        XCTAssertEqual(w.type, "Walking, outdoor")
        XCTAssertEqual(w.end - w.start, 40 * 60_000)
        XCTAssertEqual(w.zones, [10, 20, 30, 25, 15])
        XCTAssertEqual(HistoryImport.dayKey(Date(timeIntervalSince1970: Double(w.start) / 1000), calendar: pacific), "2026-10-31")
    }

    func testMergeOnlyAdds() throws {
        let incoming = HistoryImport.parse(files: try ZipReader.entries(Self.fixture), calendar: pacific)
        var current = HistoryData()
        var mine = DayRecord(day: "2026-10-31", source: "whoop")
        mine.recovery = 99
        current.days["2026-10-31"] = mine
        let (merged, added) = HistoryImport.merge(incoming, into: current)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(merged.days["2026-10-31"]?.recovery, 99)
        XCTAssertEqual(merged.workouts.count, 1)
        let (again, none) = HistoryImport.merge(incoming, into: merged)
        XCTAssertEqual(none, 0)
        XCTAssertEqual(again.workouts.count, 1)
    }

    func testTimeZoneText() {
        XCTAssertEqual(HistoryImport.timeZone("UTC-07:00").secondsFromGMT(), -25200)
        XCTAssertEqual(HistoryImport.timeZone("UTC+05:30").secondsFromGMT(), 19800)
        XCTAssertEqual(HistoryImport.timeZone(nil).secondsFromGMT(), 0)
    }
}
