import XCTest

final class BackupArchiveTests: XCTestCase {
    private var root: URL!
    private var a: URL!
    private var b: URL!
    private var file: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        a = root.appendingPathComponent("a")
        b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        file = root.appendingPathComponent("x.hlbackup")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String, _ name: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func read(_ name: String, in dir: URL) throws -> String {
        String(decoding: try Data(contentsOf: dir.appendingPathComponent(name)), as: UTF8.self)
    }

    func testRoundTripIncludingLargeAndEmptyFiles() throws {
        let big = String(repeating: "1700000000000,62,16,4,812\n", count: 60_000)
        try write(big, "s100.samples.csv", in: a)
        try write("", "s100.events.csv", in: a)
        try write("Katie", "profile.txt", in: a)
        XCTAssertEqual(try BackupArchive.create(from: a, to: file), 3)
        XCTAssertEqual(try BackupArchive.restore(file, into: b), RestoreResult(added: 3, updated: 0, kept: 0))
        XCTAssertEqual(try read("s100.samples.csv", in: b), big)
        XCTAssertEqual(try read("s100.events.csv", in: b), "")
        XCTAssertEqual(try read("profile.txt", in: b), "Katie")
    }

    func testOnlyRecordingFilesAreIncluded() throws {
        try write("keep", "s1.events.csv", in: a)
        try write("no", "notes.txt", in: a)
        try write("no", ".restore-temp", in: a)
        let entries = try { () throws -> [BackupArchive.Entry] in
            try BackupArchive.create(from: a, to: file)
            return try BackupArchive.verify(file)
        }()
        XCTAssertEqual(entries.map(\.name), ["s1.events.csv"])
    }

    func testMergeExtendsSmallerAndNeverShortens() throws {
        try write("line1\nline2\n", "s1.samples.csv", in: a)
        try write("old\n", "s2.samples.csv", in: a)
        try BackupArchive.create(from: a, to: file)
        try write("line1\n", "s1.samples.csv", in: b)
        try write("old\nnew local data\n", "s2.samples.csv", in: b)
        XCTAssertEqual(try BackupArchive.restore(file, into: b), RestoreResult(added: 0, updated: 1, kept: 1))
        XCTAssertEqual(try read("s1.samples.csv", in: b), "line1\nline2\n")
        XCTAssertEqual(try read("s2.samples.csv", in: b), "old\nnew local data\n")
    }

    func testActiveRecordingIsSkipped() throws {
        try write("backup copy that is longer\n", "s9.samples.csv", in: a)
        try BackupArchive.create(from: a, to: file)
        try write("live\n", "s9.samples.csv", in: b)
        let result = try BackupArchive.restore(file, into: b, skipping: ["s9.samples.csv"])
        XCTAssertEqual(result.kept, 1)
        XCTAssertEqual(try read("s9.samples.csv", in: b), "live\n")
    }

    func testEveryFlippedRegionIsRejectedAndWritesNothing() throws {
        try write("1,2,3\n4,5,6\n", "s1.samples.csv", in: a)
        try BackupArchive.create(from: a, to: file)
        let good = try Data(contentsOf: file)
        for index in stride(from: 0, to: good.count, by: 3) {
            var bad = good
            bad[index] ^= 0xFF
            try bad.write(to: file)
            XCTAssertThrowsError(try BackupArchive.restore(file, into: b), "byte \(index)")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: b.path), [], "byte \(index)")
        }
    }

    func testTruncatedAndForeignFilesAreRejected() throws {
        try write("data\n", "s1.events.csv", in: a)
        try BackupArchive.create(from: a, to: file)
        let good = try Data(contentsOf: file)
        try good.prefix(good.count - 5).write(to: file)
        XCTAssertThrowsError(try BackupArchive.verify(file))
        try Data("this is not a backup, it is just some text long enough".utf8).write(to: file)
        XCTAssertThrowsError(try BackupArchive.verify(file))
    }

    func testSettingsFilesAreNeverOverwritten() throws {
        try write("[\"backup\"]", "activities.json", in: a)
        try write("{\"b\":1}", "settings.json", in: a)
        try BackupArchive.create(from: a, to: file)
        try write("[\"local\"]", "activities.json", in: b)
        let result = try BackupArchive.restore(file, into: b)
        XCTAssertEqual(result.deferred, ["activities.json"])
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(try read("activities.json", in: b), "[\"local\"]")
        XCTAssertEqual(try read("settings.json", in: b), "{\"b\":1}")
        XCTAssertEqual(try BackupArchive.extract(file, name: "activities.json").map { String(decoding: $0, as: UTF8.self) }, "[\"backup\"]")
    }

    func testFileNamesCannotEscapeTheFolder() {
        for bad in ["../s1.events.csv", "s1/../../x.events.csv", "/etc/s1.events.csv", "s.events.csv", "s1a.samples.csv", "s1.events.csv.exe", "profile.txt/.."] {
            XCTAssertFalse(BackupArchive.isAllowed(bad), bad)
        }
        for good in ["s1731000000000.samples.csv", "s1.events.csv", "profile.txt"] {
            XCTAssertTrue(BackupArchive.isAllowed(good), good)
        }
    }
}
