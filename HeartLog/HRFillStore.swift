import Foundation

extension BandCapture {
    /// The band's seconds between two times in phone time (Unix seconds), tidied.
    func seconds(from: Int64, to: Int64) -> [BandSecond] {
        guard to > from else { return [] }
        let cal = Calendar.current
        var raw: [BandSecond] = []
        var d = cal.startOfDay(for: Date(timeIntervalSince1970: Double(from)))
        let last = Date(timeIntervalSince1970: Double(to))
        while d <= last {
            raw += load(day: BandCaptureKeys.day(d))
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return BandNight.tidy(raw.filter { $0.t >= from && $0.t < to })
    }
}

enum BandCaptureKeys {
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Same key BandCapture files a day under (local date at midday).
    static func day(_ start: Date) -> String { format.string(from: start.addingTimeInterval(43_200)) }
}

extension Store {
    /// Live readings with the band's own record filling the gaps. For daytime
    /// numbers only; sleep uses `readSamples`. Safe off the main thread.
    func readDaySamples(from: Int64, to: Int64) -> [Sample] {
        let live = readSamples(from: from, to: to)
        let band = BandCapture.shared.seconds(from: from / 1000, to: (to + 999) / 1000)
        return HRFill.merge(live: live, band: band).filter { $0.t >= from && $0.t < to }
    }
}
