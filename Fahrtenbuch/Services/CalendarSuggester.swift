import Foundation
import EventKit
import CoreLocation

/// Schlägt den Reisezweck aus dem Kalender vor: Welcher Termin passt zur Ankunftszeit (und zum Ort)?
/// Nutzt alle Kalender auf dem iPhone – auch Google- oder Outlook-Kalender, wenn sie in iOS eingebunden sind.
@MainActor
enum CalendarSuggester {
    struct Suggestion: Equatable {
        let title: String
        let location: String
        let start: Date
        /// Der Terminort liegt nahe am Ziel der Fahrt → sehr wahrscheinlich der richtige Termin.
        let locationMatches: Bool
    }

    private static let store = EKEventStore()

    static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    @discardableResult
    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    static func suggestion(for trip: Trip) -> Suggestion? {
        guard AppSettings.calendarSuggestions, isAuthorized, let arrival = trip.endDate else { return nil }

        let predicate = store.predicateForEvents(withStart: arrival.addingTimeInterval(-3600),
                                                 end: arrival.addingTimeInterval(2 * 3600), calendars: nil)
        let events = store.events(matching: predicate).filter { !$0.isAllDay && !($0.title ?? "").isEmpty }
        let destination = trip.endCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }

        func distanceToDestination(_ event: EKEvent) -> CLLocationDistance? {
            guard let geo = event.structuredLocation?.geoLocation, let destination else { return nil }
            return geo.distance(from: destination)
        }

        // Bewertung: Ortsübereinstimmung zählt am meisten, sonst die zeitliche Nähe zur Ankunft.
        let scored = events.compactMap { event -> (EKEvent, Double, Bool)? in
            let minutesOff = event.startDate.timeIntervalSince(arrival) / 60
            let distance = distanceToDestination(event)
            let near = (distance ?? .infinity) < 500
            if distance.map({ $0 > 5000 }) == true { return nil }       // Termin ganz woanders
            if !near && (minutesOff < -20 || minutesOff > 60) { return nil }
            return (event, abs(minutesOff) - (near ? 1000 : 0), near)
        }
        guard let best = scored.min(by: { $0.1 < $1.1 }) else { return nil }

        let location = best.0.structuredLocation?.title ?? best.0.location ?? ""
        return Suggestion(title: best.0.title ?? "", location: location.components(separatedBy: "\n").first ?? "",
                          start: best.0.startDate, locationMatches: best.2)
    }

    /// Bei eindeutigem Treffer (Termin am Zielort) wird die Fahrt direkt als geschäftlich vorbelegt.
    static func autoApply(to trip: Trip) {
        guard trip.category == .unassigned, let suggestion = suggestion(for: trip), suggestion.locationMatches else { return }
        trip.category = .business
        trip.purpose = suggestion.title
        if trip.businessPartner.isEmpty { trip.businessPartner = suggestion.location }
    }
}
