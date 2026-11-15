import Foundation
import SwiftData
import CryptoKit

/// Alle Änderungen am Fahrtenbuch laufen hier durch: protokolliert, festschreibbar, fälschungssicher verkettet.
@MainActor
enum TripLedger {
    enum LedgerError: LocalizedError {
        case locked, unassigned, missingPurpose, invalidManual, overlap, laterFinalized, notMergeable

        var errorDescription: String? {
            switch self {
            case .invalidManual: "Bitte prüfe Zeiten und Kilometer."
            case .overlap: "In diesem Zeitraum gibt es schon eine Fahrt."
            case .laterFinalized: "Nach diesem Zeitpunkt gibt es bereits festgeschriebene Fahrten. Nachtragen ist nur vor offenen Fahrten möglich, sonst würden die Kilometerstände nicht mehr stimmen."
            case .notMergeable: "Diese Fahrten können nicht zusammengeführt werden (nur aufeinanderfolgende, nicht festgeschriebene Fahrten)."
            case .locked: "Diese Fahrt ist festgeschrieben und kann nicht mehr geändert werden."
            case .unassigned: "Bitte wähle zuerst die Fahrtart (geschäftlich, privat oder Arbeitsweg)."
            case .missingPurpose: "Bitte gib für geschäftliche Fahrten einen Reisezweck an."
            }
        }
    }

    static func log(_ field: String, old: String, new: String, trip: Trip?, in context: ModelContext) {
        guard old != new else { return }
        let entry = AuditEntry(field: field, oldValue: old, newValue: new, tripLabel: trip?.shortLabel ?? "Allgemein")
        context.insert(entry)
        entry.trip = trip
    }

    static func update(_ trip: Trip, category: TripCategory, purpose: String, partner: String,
                       detour: String, startAddress: String, endAddress: String, in context: ModelContext) throws {
        guard trip.isEditable else { throw LedgerError.locked }
        let clean = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }

        log("Fahrtart", old: trip.category.label, new: category.label, trip: trip, in: context)
        log("Reisezweck", old: trip.purpose, new: clean(purpose), trip: trip, in: context)
        log("Geschäftspartner", old: trip.businessPartner, new: clean(partner), trip: trip, in: context)
        log("Umweg/Bemerkung", old: trip.detourNote, new: clean(detour), trip: trip, in: context)
        log("Startadresse", old: trip.startAddress, new: clean(startAddress), trip: trip, in: context)
        log("Zieladresse", old: trip.endAddress, new: clean(endAddress), trip: trip, in: context)

        trip.category = category
        trip.purpose = clean(purpose)
        trip.businessPartner = clean(partner)
        trip.detourNote = clean(detour)
        trip.startAddress = clean(startAddress)
        trip.endAddress = clean(endAddress)

        try context.save()
        NotificationService.refreshDailyReminder(in: context)
    }

    static func setCategory(_ category: TripCategory, for trip: Trip, in context: ModelContext) throws {
        try update(trip, category: category, purpose: trip.purpose, partner: trip.businessPartner,
                   detour: trip.detourNote, startAddress: trip.startAddress, endAddress: trip.endAddress, in: context)
    }

    // MARK: - Festschreiben

    static func finalize(_ trip: Trip, automatic: Bool = false, in context: ModelContext) throws {
        guard trip.status == .recorded else { throw LedgerError.locked }
        guard trip.category != .unassigned else { throw LedgerError.unassigned }
        if trip.category == .business && trip.purpose.isEmpty { throw LedgerError.missingPurpose }

        trip.previousHash = latestHash(in: context)
        trip.status = .finalized
        trip.finalizedAt = .now
        trip.integrityHash = fingerprint(of: trip)
        log("Status", old: TripStatus.recorded.label,
            new: automatic ? "Festgeschrieben (automatisch)" : "Festgeschrieben", trip: trip, in: context)
        try context.save()
    }

    /// Schreibt erledigte Fahrten nach X Tagen automatisch fest („zeitnah und in geschlossener Form“).
    static func autoFinalize(in context: ModelContext) {
        let days = AppSettings.autoFinalizeDays
        guard days > 0 else { return }
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        let recorded = TripStatus.recorded.rawValue
        let descriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.statusRaw == recorded },
                                               sortBy: [SortDescriptor(\.startDate)])
        for trip in (try? context.fetch(descriptor)) ?? [] where (trip.endDate ?? trip.startDate) < cutoff {
            try? finalize(trip, automatic: true, in: context)
        }
    }

    static func latestHash(in context: ModelContext) -> String {
        let finalized = TripStatus.finalized.rawValue
        var descriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.statusRaw == finalized },
                                               sortBy: [SortDescriptor(\.finalizedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first?.integrityHash) ?? "START"
    }

    /// SHA-256 über alle steuerrelevanten Felder + Prüfsumme der vorherigen Fahrt (Hash-Kette).
    static func fingerprint(of trip: Trip) -> String {
        let iso = ISO8601DateFormatter()
        let fields = [
            trip.id.uuidString, iso.string(from: trip.startDate), trip.endDate.map(iso.string(from:)) ?? "",
            String(trip.startOdometer), String(trip.endOdometer ?? 0), String(format: "%.1f", trip.distanceMeters),
            trip.categoryRaw, trip.startAddress, trip.endAddress, trip.purpose, trip.businessPartner,
            trip.detourNote, trip.vehicle, trip.previousHash,
        ]
        return SHA256.hash(data: Data(fields.joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ trip: Trip) -> Bool {
        trip.status == .finalized && trip.integrityHash == fingerprint(of: trip)
    }

    // MARK: - Zusammenführen (Fahrt mit Zwischenstopp)

    /// Nächste Fahrt nach `trip`, falls beide zusammengeführt werden können (gleicher Tag, max. 4 h Pause).
    static func mergeCandidate(after trip: Trip, in trips: [Trip]) -> Trip? {
        guard trip.isEditable, let end = trip.endDate,
              let next = trips.filter({ $0.startDate > trip.startDate && $0.status != .recording })
                              .min(by: { $0.startDate < $1.startDate }),
              next.isEditable,
              Calendar.current.isDate(next.startDate, inSameDayAs: trip.startDate),
              next.startDate.timeIntervalSince(end) < 4 * 3600 else { return nil }
        return next
    }

    static func merge(_ first: Trip, with second: Trip, in context: ModelContext) throws {
        guard first.isEditable, second.isEditable, second.startDate > first.startDate else { throw LedgerError.notMergeable }

        let firstLabel = first.shortLabel
        let secondLabel = second.shortLabel
        let stopTime = "\(first.endDate.map { Fmt.time.string(from: $0) } ?? "")–\(Fmt.time.string(from: second.startDate))"
        let stopNote = "Zwischenstopp: \(first.endAddress.isEmpty ? "unbekannt" : first.endAddress) (\(stopTime))"

        func combine(_ a: String, _ b: String) -> String {
            [a, b].filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: " / ")
        }

        first.route = first.route + second.route
        first.distanceMeters += second.distanceMeters
        first.endDate = second.endDate
        first.endOdometer = second.endOdometer
        first.endAddress = second.endAddress
        if first.category == .unassigned { first.category = second.category }
        first.purpose = combine(first.purpose, second.purpose)
        first.businessPartner = combine(first.businessPartner, second.businessPartner)
        first.detourNote = combine(first.detourNote, combine(stopNote, second.detourNote))

        // Protokoll der zweiten Fahrt übernehmen und das Zusammenführen vermerken.
        for entry in second.auditEntries { entry.trip = first }
        log("Zusammengeführt", old: "\(firstLabel) + \(secondLabel)", new: first.shortLabel, trip: first, in: context)
        log("Fahrt zusammengeführt", old: secondLabel, new: "Teil von \(first.shortLabel)", trip: nil, in: context)

        context.delete(second)
        try context.save()
        NotificationService.refreshDailyReminder(in: context)
    }

    // MARK: - Nachtragen

    static func addManualTrip(start: Date, end: Date, km: Double, startAddress: String, endAddress: String,
                              category: TripCategory, purpose: String, partner: String, reason: String,
                              in context: ModelContext) throws {
        guard end > start, km > 0, km < 2000 else { throw LedgerError.invalidManual }

        let all = (try? context.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.startDate)]))) ?? []
        if all.contains(where: { $0.startDate < end && ($0.endDate ?? .distantFuture) > start }) { throw LedgerError.overlap }

        let later = all.filter { $0.startDate >= end }
        if later.contains(where: { $0.status == .finalized }) { throw LedgerError.laterFinalized }
        let previous = all.last { $0.startDate < start }

        let startOdometer = later.first?.startOdometer ?? previous?.endOdometer ?? AppSettings.odometerKm
        let shift = Int((km).rounded())

        let trip = Trip(startDate: start, startOdometer: startOdometer, vehicle: AppSettings.vehicleDisplayName, trigger: .manualEntry)
        trip.endDate = end
        trip.distanceMeters = km * 1000
        trip.endOdometer = startOdometer + shift
        trip.startAddress = startAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        trip.endAddress = endAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        trip.category = category
        trip.purpose = category == .business ? purpose.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        trip.businessPartner = category == .business ? partner.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        trip.manualReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        trip.status = .recorded
        context.insert(trip)
        log("Fahrt nachgetragen", old: "", new: "\(Fmt.km(km)) · Grund: \(trip.manualReason)", trip: trip, in: context)

        // Spätere Fahrten (und der aktuelle Stand) verschieben sich um die nachgetragenen Kilometer.
        for t in later {
            log("Kilometerstand verschoben", old: "\(t.startOdometer)–\(t.endOdometer ?? t.startOdometer)",
                new: "\(t.startOdometer + shift)–\((t.endOdometer ?? t.startOdometer) + shift)", trip: t, in: context)
            t.startOdometer += shift
            if let e = t.endOdometer { t.endOdometer = e + shift }
        }
        AppSettings.odometerMeters += km * 1000
        try context.save()
        NotificationService.refreshDailyReminder(in: context)
    }

    // MARK: - Sonstiges

    /// Nach einer Wiederherstellung aus iCloud (neues iPhone): Kilometerstand aus der letzten Fahrt übernehmen.
    static func restoreOdometerIfNeeded(in context: ModelContext) {
        guard AppSettings.odometerMeters == 0 else { return }
        var descriptor = FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        descriptor.fetchLimit = 1
        if let km = (try? context.fetch(descriptor))?.first?.endOdometer, km > 0 {
            AppSettings.odometerMeters = Double(km) * 1000
        }
    }

    static func correctOdometer(to km: Int, in context: ModelContext) throws {
        log("Kilometerstand korrigiert", old: "\(AppSettings.odometerKm) km", new: "\(km) km", trip: nil, in: context)
        AppSettings.odometerMeters = Double(km) * 1000
        try context.save()
    }

    static func delete(_ trip: Trip, in context: ModelContext) throws {
        guard trip.status != .finalized else { throw LedgerError.locked }
        log("Fahrt gelöscht", old: "\(trip.shortLabel): \(trip.startAddress) → \(trip.endAddress)",
            new: "–", trip: nil, in: context)
        context.delete(trip)
        try context.save()
        NotificationService.refreshDailyReminder(in: context)
    }
}
