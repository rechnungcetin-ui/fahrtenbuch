import Foundation
import SwiftData
import CoreLocation

enum TripCategory: String, Codable, CaseIterable, Identifiable {
    case unassigned, business, privateTrip, commute

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unassigned: "Offen"
        case .business: "Geschäftlich"
        case .privateTrip: "Privat"
        case .commute: "Arbeitsweg"
        }
    }

    /// Bezeichnung im Export.
    var exportLabel: String {
        switch self {
        case .unassigned: "nicht zugeordnet"
        case .business: "Dienstfahrt"
        case .privateTrip: "Privatfahrt"
        case .commute: "Wohnung–Arbeitsstätte"
        }
    }

    var symbol: String {
        switch self {
        case .unassigned: "questionmark.circle.fill"
        case .business: "briefcase.fill"
        case .privateTrip: "house.fill"
        case .commute: "building.2.fill"
        }
    }

    var hint: String {
        switch self {
        case .unassigned: "Bitte ordne die Fahrt zu."
        case .business: "Für einen sauberen Nachweis: Reiseziel, Reisezweck und besuchter Geschäftspartner. Umwege bitte vermerken."
        case .privateTrip: "Bei Privatfahrten genügen die Kilometer – Ziel und Zweck erscheinen nicht im Export."
        case .commute: "Fahrten zwischen Wohnung und erster Tätigkeitsstätte – die Kilometer genügen."
        }
    }
}

enum TripStatus: String, Codable {
    case recording, recorded, finalized

    var label: String {
        switch self {
        case .recording: "Wird aufgezeichnet"
        case .recorded: "Erfasst – noch änderbar"
        case .finalized: "Festgeschrieben"
        }
    }
}

enum TripTrigger: String, Codable {
    case manual, shortcut, bluetooth, motion, manualEntry

    var label: String {
        switch self {
        case .manual: "Manuell gestartet"
        case .shortcut: "Kurzbefehl (Auto-Bluetooth)"
        case .bluetooth: "Auto-Bluetooth (App offen)"
        case .motion: "Automatische Fahrterkennung"
        case .manualEntry: "Nachgetragen"
        }
    }
}

struct RoutePoint: Codable, Hashable {
    var lat: Double
    var lon: Double
    var timestamp: Date
    var speed: Double

    init(coordinate: CLLocationCoordinate2D, timestamp: Date, speed: Double = 0) {
        lat = coordinate.latitude
        lon = coordinate.longitude
        self.timestamp = timestamp
        self.speed = speed
    }

    init(_ location: CLLocation) {
        lat = location.coordinate.latitude
        lon = location.coordinate.longitude
        timestamp = location.timestamp
        speed = max(0, location.speed)
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

@Model
final class Trip {
    var id: UUID = UUID()
    var startDate: Date = Date.now
    var endDate: Date?
    var statusRaw: String = TripStatus.recording.rawValue
    var categoryRaw: String = TripCategory.unassigned.rawValue
    var triggerRaw: String = TripTrigger.manual.rawValue

    var distanceMeters: Double = 0
    var startOdometer: Int = 0
    var endOdometer: Int?

    var startAddress: String = ""
    var endAddress: String = ""
    var purpose: String = ""
    var businessPartner: String = ""
    var detourNote: String = ""
    var vehicle: String = ""
    /// Start wurde aus der Parkposition ergänzt (automatische Erkennung greift erst nach einigen hundert Metern).
    var startReconstructed: Bool = false
    var manualReason: String = ""
    /// Welche Regel die Fahrtart automatisch vorgeschlagen hat (leer = von Hand zugeordnet).
    var autoRule: String = ""
    var startLat: Double = 0
    var startLon: Double = 0
    var endLat: Double = 0
    var endLon: Double = 0

    @Attribute(.externalStorage) var routeData: Data = Data()

    var finalizedAt: Date?
    var previousHash: String = ""
    var integrityHash: String = ""

    @Relationship(deleteRule: .nullify, inverse: \AuditEntry.trip)
    var auditLog: [AuditEntry]? = []

    init(startDate: Date, startOdometer: Int, vehicle: String, trigger: TripTrigger) {
        self.id = UUID()
        self.startDate = startDate
        self.startOdometer = startOdometer
        self.vehicle = vehicle
        self.triggerRaw = trigger.rawValue
    }

    // MARK: - Bequeme Zugriffe (werden nicht gespeichert)

    var status: TripStatus {
        get { TripStatus(rawValue: statusRaw) ?? .recorded }
        set { statusRaw = newValue.rawValue }
    }

    var category: TripCategory {
        get { TripCategory(rawValue: categoryRaw) ?? .unassigned }
        set { categoryRaw = newValue.rawValue }
    }

    var auditEntries: [AuditEntry] { auditLog ?? [] }
    var trigger: TripTrigger { TripTrigger(rawValue: triggerRaw) ?? .manual }
    var isManualEntry: Bool { trigger == .manualEntry }

    var exportCategoryLabel: String {
        isManualEntry ? "\(category.exportLabel) (nachgetragen)" : category.exportLabel
    }

    var route: [RoutePoint] {
        get { (try? JSONDecoder().decode([RoutePoint].self, from: routeData)) ?? [] }
        set { routeData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var startCoordinate: CLLocationCoordinate2D? { route.first?.coordinate }
    var endCoordinate: CLLocationCoordinate2D? { route.last?.coordinate }

    var distanceKm: Double { distanceMeters / 1000 }
    var distanceText: String { Fmt.km(distanceKm) }

    var timeRangeText: String {
        let start = Fmt.time.string(from: startDate)
        guard let endDate else { return "ab \(start)" }
        return "\(start)–\(Fmt.time.string(from: endDate))"
    }

    var shortLabel: String { "Fahrt \(Fmt.dateTime.string(from: startDate)) (\(distanceText))" }

    var displayStart: String { startAddress.isEmpty ? "Startadresse wird ermittelt …" : startAddress }
    var displayEnd: String { endAddress.isEmpty ? "Zieladresse wird ermittelt …" : endAddress }

    var isEditable: Bool { status == .recorded }

    /// Fahrt braucht noch Angaben, bevor sie festgeschrieben werden kann.
    var needsAttention: Bool {
        guard status == .recorded else { return false }
        return category == .unassigned || (category == .business && purpose.isEmpty)
    }
}
