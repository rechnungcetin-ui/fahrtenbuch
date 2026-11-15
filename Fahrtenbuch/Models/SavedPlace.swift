import Foundation
import SwiftData
import CoreLocation

enum PlaceKind: String, Codable, CaseIterable, Identifiable {
    case home, work, customer, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: "Zuhause"
        case .work: "Arbeitsstätte / Büro"
        case .customer: "Kunde / Geschäftspartner"
        case .other: "Sonstiger Ort"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .work: "building.2.fill"
        case .customer: "person.2.fill"
        case .other: "mappin.circle.fill"
        }
    }
}

/// Gespeicherte Orte (Zuhause, Büro, Kunden). Fahrten dorthin werden automatisch benannt und vorsortiert.
@Model
final class SavedPlace {
    var name: String = ""
    var address: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var radius: Double = 150
    var kindRaw: String = PlaceKind.other.rawValue
    var defaultPurpose: String = ""

    init(name: String, address: String, coordinate: CLLocationCoordinate2D, kind: PlaceKind, defaultPurpose: String = "") {
        self.name = name
        self.address = address
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.kindRaw = kind.rawValue
        self.defaultPurpose = defaultPurpose
    }

    var kind: PlaceKind { PlaceKind(rawValue: kindRaw) ?? .other }
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    var label: String { address.isEmpty ? name : "\(name) – \(address)" }
}
