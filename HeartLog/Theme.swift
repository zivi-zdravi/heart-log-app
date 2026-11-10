import Charts
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Theme {
    static let bg = Color(hex: 0x11181A)
    static let card = Color(hex: 0x1C2628)
    static let raised = Color(hex: 0x263234)
    static let track = Color(hex: 0x2C3A3C)
    static let line = Color(hex: 0x55666A)
    static let text = Color(hex: 0xF2F5F3)
    static let dim = Color(hex: 0xA7B4AE)
    static let green = Color(hex: 0x8FD0AE)
    static let blue = Color(hex: 0x8DB6EA)
    static let orange = Color(hex: 0xF0A27F)
    static let zoneColors: [Color] = [line, Color(hex: 0xDDE5E0), blue, green, orange, Color(hex: 0xFF9E94)]

    static func display(_ size: CGFloat) -> Font { .custom("Outfit", size: size).weight(.semibold) }

    static let dayText: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEEMMMd"); return f }()
    static let weekday: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEE"); return f }()
    static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()

    static func clock(_ ms: Int64) -> String { time.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }

    static func duration(_ seconds: Double, showSeconds: Bool = false) -> String {
        let s = Int(seconds)
        if showSeconds && s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct TintButton: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(color)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct SolidButton: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(Theme.bg)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct Bar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 10
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: g.size.width * CGFloat(min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

struct ScoreRow: View {
    let label: String
    let value: String
    let fraction: Double?
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(value)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(fraction == nil ? Theme.dim : Theme.text)
            Bar(fraction: fraction ?? 0, color: color)
        }
    }
}

struct Tile: View {
    let title: String
    let value: String
    var note: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13)).foregroundColor(Theme.dim)
            Text(value).font(Theme.display(23)).foregroundColor(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
            if let note { Text(note).font(.system(size: 12)).foregroundColor(Theme.dim) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct ZoneBars: View {
    let seconds: [Double]
    let bounds: [Int]
    var body: some View {
        let total = max(1, seconds.dropFirst().reduce(0, +))
        VStack(spacing: 8) {
            ForEach((1...5).reversed(), id: \.self) { z in
                HStack(spacing: 8) {
                    Text(label(z)).font(.system(size: 13)).frame(width: 104, alignment: .leading)
                    Bar(fraction: seconds[z] / total, color: Theme.zoneColors[z], height: 12)
                    Text(Theme.duration(seconds[z], showSeconds: true)).font(.system(size: 13)).monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                .foregroundColor(Theme.text)
            }
        }
    }

    private func label(_ z: Int) -> String {
        z == 5 ? "\(z): \(bounds[4])+" : "\(z): \(bounds[z - 1]) to \(bounds[z] - 1)"
    }
}

struct HRPoint: Identifiable {
    let id: Int64
    let date: Date
    let hr: Int
}

struct HRChart: View {
    let samples: [Sample]
    let color: Color
    var body: some View {
        let points = Self.points(samples)
        if points.count < 2 {
            Text("Not enough readings yet").font(.system(size: 13)).foregroundColor(Theme.dim).frame(maxWidth: .infinity, minHeight: 60)
        } else {
            let lo = (points.map(\.hr).min() ?? 40) - 5
            let hi = (points.map(\.hr).max() ?? 180) + 5
            Chart(points) { p in
                LineMark(x: .value("Time", p.date), y: .value("Heart rate", p.hr))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: lo...hi)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel() } }
            .accessibilityLabel("Heart rate from \(lo + 5) to \(hi - 5)")
        }
    }

    /// Averages readings into at most about 300 points so long recordings stay fast.
    static func points(_ s: [Sample]) -> [HRPoint] {
        let valid = s.filter { $0.hr > 0 }
        guard let first = valid.first, let last = valid.last else { return [] }
        let bucket = max(Int64(5_000), (last.t - first.t) / 300)
        var groups: [Int64: (sum: Int, n: Int)] = [:]
        for x in valid {
            let k = x.t / bucket
            let v = groups[k] ?? (0, 0)
            groups[k] = (v.sum + x.hr, v.n + 1)
        }
        return groups.keys.sorted().map { k in
            let v = groups[k]!
            return HRPoint(id: k, date: Date(timeIntervalSince1970: Double(k * bucket) / 1000), hr: v.sum / v.n)
        }
    }
}

struct ComingSoon: View {
    let title: String
    let note: String
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(Theme.display(30))
                Card { Text(note).font(.system(size: 15)).foregroundColor(Theme.dim) }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
