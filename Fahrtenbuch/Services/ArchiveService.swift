import Foundation
import SwiftData

/// Legt Fahrtenbuch-PDF und CSV als Dateien ab – in iCloud Drive (Ordner „Fahrtenbuch“) oder,
/// ohne iCloud, in der Dateien-App unter „Auf meinem iPhone › Fahrtenbuch“.
@MainActor
enum ArchiveService {
    private static var cachedFolder: (url: URL, iCloud: Bool)?

    static func folder() async -> (url: URL, iCloud: Bool) {
        if let cachedFolder { return cachedFolder }
        let containerID = DataStore.cloudContainerID
        // Die iCloud-Abfrage kann dauern und darf nicht auf dem Haupt-Thread laufen.
        let cloud = await Task.detached { FileManager.default.url(forUbiquityContainerIdentifier: containerID) }.value
        let base = cloud?.appendingPathComponent("Documents")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Archiv", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let result = (url, cloud != nil)
        cachedFolder = result
        return result
    }

    @discardableResult
    static func archive(_ period: ExportPeriod, in context: ModelContext) async throws -> [URL] {
        let trips = ((try? context.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.startDate)]))) ?? [])
            .filter { $0.status != .recording && period.contains($0.startDate) }
        guard !trips.isEmpty else { return [] }
        let audit = ((try? context.fetch(FetchDescriptor<AuditEntry>(sortBy: [SortDescriptor(\.timestamp)]))) ?? [])
            .filter { period.contains($0.trip?.startDate ?? $0.timestamp) }
        let expenses = ((try? context.fetch(FetchDescriptor<Expense>(sortBy: [SortDescriptor(\.date)]))) ?? [])
            .filter { period.contains($0.date) }

        let sources = [try ExportService.pdf(trips: trips, period: period, audit: audit, expenses: expenses),
                       try ExportService.csv(trips: trips, period: period)]
        let target = await folder().url
        return try sources.map { source in
            let destination = target.appendingPathComponent(source.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }
    }

    /// Einmal pro Monat automatisch: den abgelaufenen Monat und das laufende Jahr sichern.
    static func archiveIfNeeded(in context: ModelContext) async {
        guard AppSettings.autoArchive,
              let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: .now) else { return }
        let c = Calendar.current.dateComponents([.year, .month], from: lastMonth)
        guard let year = c.year, let month = c.month else { return }
        let key = String(format: "%04d-%02d", year, month)
        guard AppSettings.lastArchivedMonth != key else { return }
        do {
            try await archive(ExportPeriod(year: year, month: month), in: context)
            try await archive(ExportPeriod(year: year, month: nil), in: context)
            AppSettings.lastArchivedMonth = key
        } catch {
            // Beim nächsten App-Start erneut versuchen.
        }
    }

    /// Manuell: laufender Monat + laufendes Jahr.
    static func archiveNow(in context: ModelContext) async throws -> Int {
        let c = Calendar.current.dateComponents([.year, .month], from: .now)
        guard let year = c.year, let month = c.month else { return 0 }
        let files = try await archive(ExportPeriod(year: year, month: month), in: context)
            + archive(ExportPeriod(year: year, month: nil), in: context)
        return files.count
    }
}
