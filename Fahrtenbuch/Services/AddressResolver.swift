import Foundation
import CoreLocation
import SwiftData

/// Wandelt GPS-Koordinaten in Adressen um (Apple-Geocoding: kostenlos, ohne API-Key).
enum AddressResolver {
    static func address(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder()
            .reverseGeocodeLocation(location, preferredLocale: Fmt.locale).first else { return nil }
        return format(placemark)
    }

    static func format(_ p: CLPlacemark) -> String {
        var street = [p.thoroughfare, p.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        if street.isEmpty, let name = p.name { street = name }
        let city = [p.postalCode, p.locality].compactMap { $0 }.joined(separator: " ")
        return [street, city].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    @MainActor
    static func fillAddresses(of trip: Trip) async {
        guard trip.status != .finalized else { return }
        if trip.startAddress.isEmpty, let c = trip.startCoordinate, let a = await address(for: c) {
            trip.startAddress = a
        }
        if trip.endAddress.isEmpty, let c = trip.endCoordinate, let a = await address(for: c) {
            trip.endAddress = a
        }
    }

    /// Holt fehlende Adressen nach (z. B. wenn unterwegs kein Netz war).
    @MainActor
    static func fillMissing(in context: ModelContext) async {
        let recorded = TripStatus.recorded.rawValue
        var descriptor = FetchDescriptor<Trip>(predicate: #Predicate {
            $0.statusRaw == recorded && ($0.startAddress == "" || $0.endAddress == "")
        })
        descriptor.fetchLimit = 10
        guard let trips = try? context.fetch(descriptor), !trips.isEmpty else { return }
        for trip in trips { await fillAddresses(of: trip) }
        try? context.save()
    }
}
