import SwiftUI
import SwiftData

struct AuditRow: View {
    let entry: AuditEntry
    var showTrip = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.field).font(.subheadline.weight(.semibold))
                Spacer()
                Text(Fmt.dateTime.string(from: entry.timestamp)).font(.caption).foregroundStyle(.secondary)
            }
            if showTrip { Text(entry.tripLabel).font(.caption).foregroundStyle(.secondary) }
            Text("\(entry.oldValue.isEmpty ? "(leer)" : entry.oldValue) → \(entry.newValue.isEmpty ? "(leer)" : entry.newValue)")
                .font(.caption)
        }
    }
}

struct AuditLogView: View {
    @Query(sort: \AuditEntry.timestamp, order: .reverse) private var entries: [AuditEntry]

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView("Noch keine Änderungen", systemImage: "clock.arrow.circlepath")
            }
            ForEach(entries) { AuditRow(entry: $0) }
        }
        .navigationTitle("Änderungsprotokoll")
    }
}
