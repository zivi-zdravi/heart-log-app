import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @State private var picking = false
    @State private var fileName = ""
    @State private var found: HistoryData?
    @State private var status = ""
    @State private var busy = false
    @State private var done = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Import WHOOP history").font(Theme.display(28)).foregroundColor(Theme.text)
                Card {
                    Text("Choose the export file WHOOP emailed you (my_whoop_data, a .zip). Save it to Files first, then choose it here. Nothing leaves your phone.")
                        .font(.system(size: 14)).foregroundColor(Theme.dim)
                }
                Button(busy ? "Reading" : "Choose export file") { picking = true }
                    .buttonStyle(TintButton(color: Theme.text)).disabled(busy)
                if !status.isEmpty { Text(status).font(.system(size: 14)).foregroundColor(done ? Theme.green : Theme.orange) }
                if let f = found, !done {
                    summary(f)
                    Card {
                        Text("Imported: daily HRV, resting heart rate, recovery, strain, calories, sleep times and scores, and workouts. Not imported: your journal. Imported days show WHOOP's own numbers, marked as WHOOP history. Importing again later only adds new days.")
                            .font(.system(size: 14)).foregroundColor(Theme.dim)
                    }
                    Button("Import \(f.days.count) days") { save(f) }.buttonStyle(TintButton(color: Theme.green)).disabled(busy)
                }
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .data]) { read($0) }
    }

    private func summary(_ f: HistoryData) -> some View {
        let keys = f.days.keys.sorted()
        return Card {
            Text("Found in \(fileName)").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            line("Days", "\(f.days.count)")
            if let a = keys.first, let b = keys.last { line("Dates", "\(pretty(a)) to \(pretty(b))") }
            line("Sleeps", "\(f.days.values.filter { $0.sleep != nil }.count)")
            line("Workouts", "\(f.workouts.count)")
        }
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundColor(Theme.dim)
            Spacer()
            Text(v).fontWeight(.semibold).foregroundColor(Theme.text)
        }
        .font(.system(size: 15))
    }

    private func pretty(_ key: String) -> String {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let d = Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return key }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    private func read(_ picked: Result<URL, Error>) {
        guard case .success(let url) = picked else { return }
        busy = true
        done = false
        found = nil
        status = "Reading \(url.lastPathComponent)"
        fileName = url.lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let files = try ZipReader.entries(data)
                let parsed = HistoryImport.parse(files: files, calendar: .current)
                DispatchQueue.main.async {
                    busy = false
                    if parsed.days.isEmpty {
                        status = "No WHOOP days found in that file. Choose the my_whoop_data zip from WHOOP's email."
                    } else {
                        status = ""
                        found = parsed
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    status = error.localizedDescription
                }
            }
        }
    }

    private func save(_ f: HistoryData) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let added = HistoryStore.shared.merge(f)
            DispatchQueue.main.async {
                busy = false
                done = true
                status = added == f.days.count ? "Imported \(added) days." : "Imported \(added) new days. \(f.days.count - added) were already here."
            }
        }
    }
}

struct ImportedWorkoutRow: View {
    let workout: ImportedWorkout
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.type).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Text("\(Theme.dayText.string(from: Date(timeIntervalSince1970: Double(workout.start) / 1000))), \(Theme.clock(workout.start))")
                    .font(.system(size: 13)).foregroundColor(Theme.dim)
            }
            Spacer()
            if let s = workout.strain { Text(String(format: "%.1f", s)).font(.system(size: 15)).foregroundColor(Theme.text) }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.dim)
        }
        .frame(minHeight: 44)
    }
}

struct ImportedWorkoutView: View {
    let workout: ImportedWorkout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Theme.dayText.string(from: Date(timeIntervalSince1970: Double(workout.start) / 1000))), \(Theme.clock(workout.start)) to \(Theme.clock(workout.end))")
                        .font(.system(size: 13)).foregroundColor(Theme.dim)
                    Text(workout.type).font(Theme.display(30)).foregroundColor(Theme.text)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    Tile(title: "Duration", value: Theme.duration(Double(workout.end - workout.start) / 1000))
                    Tile(title: "Strain", value: workout.strain.map { String(format: "%.1f", $0) } ?? "--")
                    Tile(title: "Average heart rate", value: workout.avgHR.map { "\($0)" } ?? "--")
                    Tile(title: "Max heart rate", value: workout.maxHR.map { "\($0)" } ?? "--")
                    Tile(title: "Calories", value: workout.calories.map { Int($0).formatted() } ?? "--")
                }
                if let z = workout.zones, z.count == 5, z.reduce(0, +) > 0 {
                    Card {
                        Text("Time in zones").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                        ForEach((0..<5).reversed(), id: \.self) { i in
                            HStack(spacing: 8) {
                                Text("Zone \(i + 1)").font(.system(size: 13)).frame(width: 60, alignment: .leading)
                                Bar(fraction: z[i] / 100, color: Theme.zoneColors[i + 1], height: 12)
                                Text("\(Int(z[i].rounded()))%").font(.system(size: 13)).monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                            .foregroundColor(Theme.text)
                        }
                    }
                }
                Text("From your WHOOP history, so these are WHOOP's own numbers.").font(.system(size: 13)).foregroundColor(Theme.dim)
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}
