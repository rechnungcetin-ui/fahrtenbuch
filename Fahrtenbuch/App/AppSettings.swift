import Foundation
import CoreLocation

/// Einfache Einstellungen in UserDefaults. Die Keys werden auch von `@AppStorage` in den Views genutzt.
enum AppSettings {
    enum Key {
        static let vehicleName = "vehicleName"
        static let licensePlate = "licensePlate"
        static let odometerMeters = "odometerMeters"
        static let carName = "carBluetoothName"
        static let autoDetectBluetooth = "autoDetectBluetooth"
        static let stopOnDisconnect = "stopOnDisconnect"
        static let autoDetectMotion = "autoDetectMotion"
        static let autoStopMinutes = "autoStopMinutes"
        static let autoFinalizeDays = "autoFinalizeDays"
        static let reminderHour = "reminderHour"
        static let detectionSpeedKmh = "detectionSpeedKmh"
        static let calendarSuggestions = "calendarSuggestions"
        static let parkingLat = "parkingLat"
        static let parkingLon = "parkingLon"
        static let parkingTime = "parkingTime"
        static let iCloudSync = "iCloudSync"
        static let autoArchive = "autoArchive"
        static let lastArchivedMonth = "lastArchivedMonth"
        static let ruleReturnTrip = "ruleReturnTrip"
        static let ruleKnownRoute = "ruleKnownRoute"
        static let ruleWorkHours = "ruleWorkHours"
        static let workStartHour = "workStartHour"
        static let workEndHour = "workEndHour"
        static let workOnSaturday = "workOnSaturday"
        static let rateBusinessCents = "rateBusinessCents"
        static let rateCommuteCents = "rateCommuteCents"
        static let commutePerDrivenKm = "commutePerDrivenKm"
        static let commuteDistanceKm = "commuteDistanceKm"
        static let sevDeskTravelAccount = "sevDeskTravelAccount"
        static let sevDeskVehicleAccount = "sevDeskVehicleAccount"
        static let sevDeskSentPeriods = "sevDeskSentPeriods"
    }

    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.autoDetectBluetooth: true,
            Key.stopOnDisconnect: true,
            Key.autoDetectMotion: true,
            Key.detectionSpeedKmh: 20,
            Key.calendarSuggestions: true,
            Key.iCloudSync: true,
            Key.autoArchive: true,
            Key.ruleReturnTrip: true,
            Key.ruleKnownRoute: true,
            Key.ruleWorkHours: false,
            Key.workStartHour: 8,
            Key.workEndHour: 18,
            Key.workOnSaturday: false,
            Key.rateBusinessCents: 30,
            Key.rateCommuteCents: 38,
            Key.commutePerDrivenKm: false,
            Key.commuteDistanceKm: 0.0,
            Key.autoStopMinutes: 5,
            Key.autoFinalizeDays: 7,
            Key.reminderHour: 19,
            Key.odometerMeters: 0.0,
        ])
    }

    static var vehicleName: String { defaults.string(forKey: Key.vehicleName) ?? "" }
    static var licensePlate: String { defaults.string(forKey: Key.licensePlate) ?? "" }

    static var vehicleDisplayName: String {
        let parts = [vehicleName, licensePlate].filter { !$0.isEmpty }
        return parts.isEmpty ? "Mein Auto" : parts.joined(separator: " · ")
    }

    /// Kilometerstand in Metern (als Double, damit sich keine Rundungsfehler aufsummieren).
    static var odometerMeters: Double {
        get { defaults.double(forKey: Key.odometerMeters) }
        set { defaults.set(newValue, forKey: Key.odometerMeters) }
    }

    static var odometerKm: Int { Int(odometerMeters / 1000) }

    static var carBluetoothName: String { defaults.string(forKey: Key.carName) ?? "" }
    static var autoDetectBluetooth: Bool { defaults.bool(forKey: Key.autoDetectBluetooth) }
    static var stopOnDisconnect: Bool { defaults.bool(forKey: Key.stopOnDisconnect) }
    /// Automatische Fahrterkennung ohne Bluetooth (Geofence + Bewegungssensor + Geschwindigkeit).
    static var autoDetectDriving: Bool { defaults.bool(forKey: Key.autoDetectMotion) }
    static var detectionSpeedKmh: Int { defaults.integer(forKey: Key.detectionSpeedKmh) }
    static var calendarSuggestions: Bool { defaults.bool(forKey: Key.calendarSuggestions) }

    /// Wo das Auto zuletzt geparkt wurde – Startpunkt der nächsten automatisch erkannten Fahrt.
    static var parkingSpot: CLLocation? {
        get {
            guard defaults.object(forKey: Key.parkingLat) != nil else { return nil }
            let time = Date(timeIntervalSince1970: defaults.double(forKey: Key.parkingTime))
            return CLLocation(coordinate: .init(latitude: defaults.double(forKey: Key.parkingLat),
                                                longitude: defaults.double(forKey: Key.parkingLon)),
                              altitude: 0, horizontalAccuracy: 20, verticalAccuracy: -1, timestamp: time)
        }
        set {
            guard let newValue else {
                [Key.parkingLat, Key.parkingLon, Key.parkingTime].forEach(defaults.removeObject(forKey:))
                return
            }
            defaults.set(newValue.coordinate.latitude, forKey: Key.parkingLat)
            defaults.set(newValue.coordinate.longitude, forKey: Key.parkingLon)
            defaults.set(newValue.timestamp.timeIntervalSince1970, forKey: Key.parkingTime)
        }
    }
    static var iCloudSync: Bool { defaults.bool(forKey: Key.iCloudSync) }
    static var autoArchive: Bool { defaults.bool(forKey: Key.autoArchive) }
    static var lastArchivedMonth: String {
        get { defaults.string(forKey: Key.lastArchivedMonth) ?? "" }
        set { defaults.set(newValue, forKey: Key.lastArchivedMonth) }
    }
    static var ruleReturnTrip: Bool { defaults.bool(forKey: Key.ruleReturnTrip) }
    static var ruleKnownRoute: Bool { defaults.bool(forKey: Key.ruleKnownRoute) }
    static var ruleWorkHours: Bool { defaults.bool(forKey: Key.ruleWorkHours) }
    static var workStartHour: Int { defaults.integer(forKey: Key.workStartHour) }
    static var workEndHour: Int { defaults.integer(forKey: Key.workEndHour) }
    static var workOnSaturday: Bool { defaults.bool(forKey: Key.workOnSaturday) }
    // Fahrtgeld
    static var rateBusinessCents: Int { defaults.integer(forKey: Key.rateBusinessCents) }
    static var rateCommuteCents: Int { defaults.integer(forKey: Key.rateCommuteCents) }
    static var commutePerDrivenKm: Bool { defaults.bool(forKey: Key.commutePerDrivenKm) }
    static var commuteDistanceKm: Double {
        get { defaults.double(forKey: Key.commuteDistanceKm) }
        set { defaults.set(newValue, forKey: Key.commuteDistanceKm) }
    }

    // sevDesk
    static var sevDeskTravelAccount: SevDeskAccount? {
        get { account(Key.sevDeskTravelAccount) }
        set { setAccount(newValue, Key.sevDeskTravelAccount) }
    }
    static var sevDeskVehicleAccount: SevDeskAccount? {
        get { account(Key.sevDeskVehicleAccount) }
        set { setAccount(newValue, Key.sevDeskVehicleAccount) }
    }
    /// Bereits übertragene Fahrtgeld-Zeiträume („2026-11“ → Beleg-ID), damit nichts doppelt gesendet wird.
    static var sevDeskSentPeriods: [String: String] {
        get { defaults.dictionary(forKey: Key.sevDeskSentPeriods) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.sevDeskSentPeriods) }
    }
    private static func account(_ key: String) -> SevDeskAccount? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SevDeskAccount.self, from: $0) }
    }
    private static func setAccount(_ account: SevDeskAccount?, _ key: String) {
        defaults.set(account.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    static var autoStopMinutes: Int { defaults.integer(forKey: Key.autoStopMinutes) }
    static var autoFinalizeDays: Int { defaults.integer(forKey: Key.autoFinalizeDays) }
    static var reminderHour: Int { defaults.integer(forKey: Key.reminderHour) }
}

/// Rechtlicher Hinweis – erscheint in Auswertung, Einstellungen und im PDF.
enum AppInfo {
    static let disclaimer = "Alle Angaben ohne Gewähr. Diese App ist ein Hilfsmittel zur Dokumentation deiner Fahrten und keine Steuerberatung. Ob und in welcher Höhe Fahrtkosten absetzbar sind, klärst du bitte mit deinem Steuerberater oder Finanzamt."
    static let shortDisclaimer = "Alle Angaben ohne Gewähr · keine Steuerberatung"
}

/// Deutsche Formatierung für Datum, Uhrzeit und Kilometer.
enum Fmt {
    static let locale = Locale(identifier: "de_DE")

    static let date: DateFormatter = make("dd.MM.yyyy")
    static let time: DateFormatter = make("HH:mm")
    static let dateTime: DateFormatter = make("dd.MM.yyyy HH:mm")

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = format
        return f
    }

    private static let kmFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    static func kmValue(_ km: Double) -> String { kmFormatter.string(from: NSNumber(value: km)) ?? "0,0" }
    static func km(_ km: Double) -> String { kmValue(km) + " km" }
    static func monthName(_ month: Int) -> String { date.monthSymbols[month - 1] }
}
