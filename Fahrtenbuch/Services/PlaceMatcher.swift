import Foundation
import CoreLocation
import SwiftData

/// Erkennt gespeicherte Orte am Start/Ziel und schlägt die Fahrtart vor.
@MainActor
enum PlaceMatcher {
    static func match(_ coordinate: CLLocationCoordinate2D?, in places: [SavedPlace]) -> SavedPlace? {
        guard let coordinate else { return nil }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return places
            .filter { $0.location.distance(from: location) <= $0.radius }
            .min { $0.location.distance(from: location) < $1.location.distance(from: location) }
    }

    static func apply(to trip: Trip, in context: ModelContext) {
        let places = (try? context.fetch(FetchDescriptor<SavedPlace>())) ?? []
        guard !places.isEmpty else { return }

        let start = match(trip.startCoordinate, in: places)
        let end = match(trip.endCoordinate, in: places)
        if let start { trip.startAddress = start.label }
        if let end { trip.endAddress = end.label }

        guard trip.category == .unassigned else { return }
        let kinds = Set([start?.kind, end?.kind].compactMap { $0 })

        if kinds == [.home, .work] {
            trip.category = .commute
        } else if let customer = [end, start].compactMap({ $0 }).first(where: { $0.kind == .customer }) {
            trip.category = .business
            trip.businessPartner = customer.name
            trip.purpose = customer.defaultPurpose.isEmpty ? "Kundentermin" : customer.defaultPurpose
        }
    }
}
