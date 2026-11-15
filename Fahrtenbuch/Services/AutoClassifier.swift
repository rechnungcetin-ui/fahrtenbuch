import Foundation
import CoreLocation
import SwiftData

/// Ordnet neue Fahrten automatisch vor. Reihenfolge – die sicherste Regel gewinnt:
/// 1. Gespeicherter Ort  2. Kalendertermin am Ziel  3. Rückfahrt  4. Bekannte Strecke  5. Arbeitszeit
/// Jeder Vorschlag bleibt änderbar; welche Regel gegriffen hat, steht an der Fahrt.
@MainActor
enum AutoClassifier {
    static func classify(_ trip: Trip, in context: ModelContext) {
        // Start/Ziel als Koordinaten merken, damit spätere Fahrten schnell verglichen werden können.
        if let start = trip.startCoordinate { trip.startLat = start.latitude; trip.startLon = start.longitude }
        if let end = trip.endCoordinate { trip.endLat = end.latitude; trip.endLon = end.longitude }

        PlaceMatcher.apply(to: trip, in: context)
        if trip.category != .unassigned { trip.autoRule = "Gespeicherter Ort"; return }

        CalendarSuggester.autoApply(to: trip)
        if trip.category != .unassigned { trip.autoRule = "Kalendertermin"; return }

        let earlier = earlierTrips(before: trip, in: context)
        if AppSettings.ruleReturnTrip && applyReturnTrip(trip, earlier) { return }
        if AppSettings.ruleKnownRoute && applyKnownRoute(trip, earlier) { return }
        if AppSettings.ruleWorkHours && isWorkTime(trip.startDate) {
            trip.category = .business
            trip.autoRule = "Arbeitszeit"
        }
    }

    private static func earlierTrips(before trip: Trip, in context: ModelContext) -> [Trip] {
        let date = trip.startDate
        let recording = TripStatus.recording.rawValue
        var descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.startDate < date && $0.statusRaw != recording },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        descriptor.fetchLimit = 400
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func near(_ latA: Double, _ lonA: Double, _ latB: Double, _ lonB: Double, _ meters: Double) -> Bool {
        guard latA != 0 || lonA != 0, latB != 0 || lonB != 0 else { return false }
        return CLLocation(latitude: latA, longitude: lonA).distance(from: CLLocation(latitude: latB, longitude: lonB)) <= meters
    }

    /// Gleiche Strecke zurück wie die letzte Fahrt (am selben Tag) → gleiche Fahrtart, „Rückfahrt: …“.
    private static func applyReturnTrip(_ trip: Trip, _ earlier: [Trip]) -> Bool {
        guard let previous = earlier.first, previous.category != .unassigned,
              Calendar.current.isDate(previous.startDate, inSameDayAs: trip.startDate),
              near(trip.startLat, trip.startLon, previous.endLat, previous.endLon, 300),
              near(trip.endLat, trip.endLon, previous.startLat, previous.startLon, 300) else { return false }

        trip.category = previous.category
        if previous.category == .business {
            trip.businessPartner = previous.businessPartner
            if !previous.purpose.isEmpty {
                trip.purpose = previous.purpose.hasPrefix("Rückfahrt") ? previous.purpose : "Rückfahrt: \(previous.purpose)"
            }
        }
        trip.autoRule = "Rückfahrt"
        return true
    }

    /// Dieselbe Strecke (Start und Ziel) wurde schon mindestens zweimal gleich zugeordnet.
    private static func applyKnownRoute(_ trip: Trip, _ earlier: [Trip]) -> Bool {
        let matches = earlier.filter {
            $0.category != .unassigned
                && near(trip.startLat, trip.startLon, $0.startLat, $0.startLon, 300)
                && near(trip.endLat, trip.endLon, $0.endLat, $0.endLon, 150)
        }
        guard matches.count >= 2 else { return false }
        let counts = Dictionary(grouping: matches, by: \.category).mapValues(\.count)
        guard let (category, count) = counts.max(by: { $0.value < $1.value }),
              Double(count) / Double(matches.count) >= 0.75,
              let template = matches.first(where: { $0.category == category }) else { return false }

        trip.category = category
        if category == .business {
            trip.purpose = template.purpose
            trip.businessPartner = template.businessPartner
        }
        trip.autoRule = "Bekannte Strecke"
        return true
    }

    static func isWorkTime(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date) // 1 = Sonntag … 7 = Samstag
        let isWorkday = (2...6).contains(weekday) || (weekday == 7 && AppSettings.workOnSaturday)
        let hour = calendar.component(.hour, from: date)
        return isWorkday && hour >= AppSettings.workStartHour && hour < AppSettings.workEndHour
    }
}
