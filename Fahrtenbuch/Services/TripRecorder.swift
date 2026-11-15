import Foundation
import UIKit
import CoreLocation
import CoreMotion
import MapKit
import SwiftData
import Observation

enum StopReason {
    case manual, shortcut, bluetooth, stationary
}

/// Erkennt Autofahrten und zeichnet sie per GPS auf.
///
/// Ablauf der automatischen Erkennung (ohne Bluetooth):
/// 1. **Ruhe (idle):** Nur stromsparende Dienste laufen – Geofence um den Parkplatz, Besuche (CLVisit),
///    signifikante Ortswechsel und der Bewegungssensor. Diese wecken die App auch, wenn sie geschlossen ist.
/// 2. **Prüfen (probing):** GPS läuft bis zu 3 Minuten. Sind wir stabil schneller als die eingestellte
///    Geschwindigkeit (und meldet CoreMotion „Fahrzeug“ statt „Fahrrad“), ist es eine Autofahrt.
/// 3. **Aufzeichnen (recording):** Route + Kilometer. Der Weg vom Parkplatz bis zur Erkennung wird ergänzt.
@Observable
@MainActor
final class TripRecorder: NSObject {
    enum Mode { case idle, probing, recording }

    static let shared = TripRecorder()

    /// Fahrten unter dieser Distanz gelten als Fehlauslösung.
    static let minimumTripMeters: Double = 300
    private static let parkingRegionID = "fahrtenbuch.parkplatz"
    private static let parkingRadius: CLLocationDistance = 150
    private static let probeTimeout: TimeInterval = 180

    private(set) var mode: Mode = .idle
    private(set) var activeTrip: Trip?
    private(set) var liveDistance: Double = 0
    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    // GPS-Aufzeichnung
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var storedPoints: [RoutePoint] = []
    @ObservationIgnored private var lastLocation: CLLocation?
    @ObservationIgnored private var lastStoredLocation: CLLocation?
    @ObservationIgnored private var lastMovementAt = Date.now
    @ObservationIgnored private var unsavedPoints = 0
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    @ObservationIgnored private var wantsAlways = false
    @ObservationIgnored private var askedForAlways = false

    // Fahrterkennung
    @ObservationIgnored private let motion = CMMotionActivityManager()
    @ObservationIgnored private var motionRunning = false
    @ObservationIgnored private var automotiveSince: Date?
    @ObservationIgnored private var walkingSince: Date?
    @ObservationIgnored private var cyclingAt: Date?
    @ObservationIgnored private var probeStartedAt: Date?
    @ObservationIgnored private var fastSince: Date?
    @ObservationIgnored private var probeLocations: [CLLocation] = []

    private var context: ModelContext { DataStore.context }

    var isRecording: Bool { activeTrip != nil }
    var isProbing: Bool { mode == .probing }

    private override init() {
        super.init()
        AppSettings.registerDefaults()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    /// Beim App-Start aufrufen (auch wenn iOS die App im Hintergrund startet).
    func activate() {
        recoverInterruptedTrips()
        updateAutoDetection()
    }

    // MARK: - Berechtigung

    func requestLocationPermission() {
        wantsAlways = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    // MARK: - Automatische Erkennung an/aus

    func updateAutoDetection() {
        let enabled = AppSettings.autoDetectDriving && manager.authorizationStatus == .authorizedAlways
        if enabled {
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
            startMotionUpdates()
            if mode == .idle { armParkingFence(at: nil) }
        } else {
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()
            removeParkingFence()
            stopMotionUpdates()
        }
    }

    private func armParkingFence(at location: CLLocation?) {
        guard AppSettings.autoDetectDriving,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
              let center = location ?? AppSettings.parkingSpot ?? manager.location else { return }
        removeParkingFence()
        let region = CLCircularRegion(center: center.coordinate, radius: Self.parkingRadius,
                                      identifier: Self.parkingRegionID)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    private func removeParkingFence() {
        for region in manager.monitoredRegions where region.identifier == Self.parkingRegionID {
            manager.stopMonitoring(for: region)
        }
    }

    private func startMotionUpdates() {
        guard CMMotionActivityManager.isActivityAvailable(), !motionRunning else { return }
        motionRunning = true
        motion.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            MainActor.assumeIsolated { self?.handleMotion(activity) }
        }
    }

    private func stopMotionUpdates() {
        guard motionRunning else { return }
        motion.stopActivityUpdates()
        motionRunning = false
    }

    private func handleMotion(_ activity: CMMotionActivity) {
        guard activity.confidence != .low else { return }
        if activity.automotive {
            if automotiveSince == nil { automotiveSince = activity.startDate }
            walkingSince = nil
            if mode == .idle && AppSettings.autoDetectDriving { beginProbe() }
        } else if activity.cycling {
            cyclingAt = activity.startDate
            automotiveSince = nil
        } else if activity.walking || activity.running {
            automotiveSince = nil
            if walkingSince == nil { walkingSince = activity.startDate }
        }
        // „stationary“ (Ampel, Stau) beendet die Auto-Phase bewusst nicht.
    }

    /// Beginn der letzten zusammenhängenden Auto-Phase in der Bewegungshistorie.
    private static func drivingPhaseStart(in activities: [CMMotionActivity]) -> Date? {
        var start: Date?
        for activity in activities {
            if activity.automotive && activity.confidence != .low {
                if start == nil { start = activity.startDate }
            } else if activity.walking || activity.running || activity.cycling {
                start = nil
            }
        }
        return start
    }

    // MARK: - Prüfphase: Fahren wir wirklich Auto?

    private func beginProbe() {
        guard mode == .idle else { return }
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }

        mode = .probing
        probeStartedAt = .now
        fastSince = nil
        probeLocations = []
        startGPS()

        // Seit wann sitzen wir schon im Auto? (iOS speichert die Bewegungshistorie)
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motion.queryActivityStarting(from: Date.now.addingTimeInterval(-900), to: .now, to: .main) { [weak self] activities, _ in
            MainActor.assumeIsolated {
                guard let self, let activities, let start = Self.drivingPhaseStart(in: activities) else { return }
                self.automotiveSince = min(self.automotiveSince ?? start, start)
            }
        }
    }

    private func probe(_ locations: [CLLocation]) {
        let threshold = Double(AppSettings.detectionSpeedKmh) / 3.6
        for location in locations where isUsable(location, maxAge: 30) {
            let previous = probeLocations.last
            probeLocations.append(location)
            let speed = effectiveSpeed(location, previous: previous)

            if speed >= threshold {
                if fastSince == nil { fastSince = location.timestamp }
            } else if speed < threshold * 0.4 {
                fastSince = nil
            }

            guard let fastSince else { continue }
            let fastFor = location.timestamp.timeIntervalSince(fastSince)
            let cycledRecently = cyclingAt.map { Date.now.timeIntervalSince($0) < 120 } ?? false
            // Bewegungssensor bestätigt „Fahrzeug“ → schnell entscheiden; sonst etwas länger beobachten.
            if (automotiveSince != nil && fastFor >= 10) || (!cycledRecently && fastFor >= 40) {
                confirmDriving()
                return
            }
        }
        if probeLocations.count > 300 { probeLocations.removeFirst(150) }
    }

    private func cancelProbe() {
        stopGPS()
        mode = .idle
        probeStartedAt = nil
        fastSince = nil
        // Geofence neu setzen, damit wir es beim nächsten Losfahren wieder mitbekommen.
        // Der gespeicherte Parkplatz bleibt unverändert – das Auto steht ja noch dort.
        armParkingFence(at: probeLocations.last ?? manager.location)
        probeLocations = []
    }

    private func confirmDriving() {
        let fixes = probeLocations
        let startDate = [automotiveSince, fixes.first?.timestamp].compactMap { $0 }.min() ?? .now
        mode = .idle
        startTrip(trigger: .motion, startDate: startDate, origin: AppSettings.parkingSpot, initialFixes: fixes)
    }

    // MARK: - Start / Stopp

    func startTrip(trigger: TripTrigger, startDate: Date = .now, origin: CLLocation? = nil,
                   initialFixes: [CLLocation] = []) {
        guard activeTrip == nil else { return }
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            requestLocationPermission()
            NotificationService.permissionMissing()
            return
        }

        probeStartedAt = nil
        fastSince = nil
        probeLocations = []
        removeParkingFence()

        let trip = Trip(startDate: startDate, startOdometer: AppSettings.odometerKm,
                        vehicle: AppSettings.vehicleDisplayName, trigger: trigger)
        context.insert(trip)
        try? context.save()

        activeTrip = trip
        mode = .recording
        liveDistance = 0
        storedPoints = []
        lastLocation = nil
        lastStoredLocation = nil
        lastMovementAt = .now
        walkingSince = nil
        unsavedPoints = 0
        startGPS()

        // Strecke vom Parkplatz bis zur Erkennung ergänzen.
        if let origin, let firstFix = initialFixes.first {
            let gap = origin.distance(from: firstFix)
            if gap > 30 && gap < 30_000 {
                storedPoints.append(RoutePoint(coordinate: origin.coordinate, timestamp: startDate))
                liveDistance += gap
                trip.startReconstructed = true
                fillGap(from: origin, to: firstFix, startDate: startDate, for: trip)
            }
        }
        record(initialFixes, live: false)

        NotificationService.tripStarted(trigger: trigger, at: startDate)
    }

    /// Ersetzt die Luftlinie Parkplatz → erster GPS-Punkt durch die echte Straßenroute (Apple Karten).
    private func fillGap(from origin: CLLocation, to fix: CLLocation, startDate: Date, for trip: Trip) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: fix.coordinate))
        request.transportType = .automobile
        let straight = origin.distance(from: fix)

        Task { @MainActor in
            guard let route = try? await MKDirections(request: request).calculate().routes.first,
                  self.activeTrip === trip, !self.storedPoints.isEmpty else { return }
            // Nur plausible Umwege übernehmen (max. 3× Luftlinie).
            guard route.distance < straight * 3 else { return }
            self.liveDistance += route.distance - straight

            let polyline = route.polyline
            var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
            polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
            let span = fix.timestamp.timeIntervalSince(startDate)
            let count = Double(max(1, coordinates.count - 1))
            let points = coordinates.enumerated().map { index, coordinate in
                RoutePoint(coordinate: coordinate, timestamp: startDate.addingTimeInterval(span * Double(index) / count))
            }
            self.storedPoints.insert(contentsOf: points, at: 1)
        }
    }

    func stopTrip(reason: StopReason) {
        guard let trip = activeTrip else { return }
        stopGPS()

        var points = storedPoints
        var endDate = Date.now
        if reason == .stationary {
            // Standzeit am Ende abschneiden: Fahrt endete mit der letzten Bewegung.
            endDate = lastMovementAt
            points.removeAll { $0.timestamp > lastMovementAt.addingTimeInterval(30) }
        } else if let last = lastLocation, points.last?.timestamp != last.timestamp {
            points.append(RoutePoint(last))
        }

        let parking = lastLocation ?? manager.location
        activeTrip = nil
        mode = .idle
        automotiveSince = nil
        walkingSince = nil

        finish(trip, points: points, distance: liveDistance, endDate: endDate)

        if let parking { AppSettings.parkingSpot = parking }
        updateAutoDetection()
    }

    private func finish(_ trip: Trip, points: [RoutePoint], distance: Double, endDate: Date) {
        guard distance >= Self.minimumTripMeters else {
            context.delete(trip)
            try? context.save()
            NotificationService.clearActiveTripNotice()
            return
        }

        trip.route = points
        trip.distanceMeters = distance
        trip.endDate = endDate
        AppSettings.odometerMeters += distance
        trip.endOdometer = max(trip.startOdometer, AppSettings.odometerKm)
        trip.status = .recorded
        AutoClassifier.classify(trip, in: context)
        try? context.save()

        // Adressen ermitteln & Mitteilung senden – auch wenn die App gerade im Hintergrund ist.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "Fahrt abschließen")
        Task { @MainActor in
            await AddressResolver.fillAddresses(of: trip)
            try? DataStore.context.save()
            NotificationService.tripFinished(trip)
            NotificationService.refreshDailyReminder(in: DataStore.context)
            UIApplication.shared.endBackgroundTask(bgTask)
        }
    }

    /// Falls iOS die App während einer Fahrt beendet hat: gespeicherten Zwischenstand abschließen.
    private func recoverInterruptedTrips() {
        guard activeTrip == nil else { return }
        let recording = TripStatus.recording.rawValue
        let descriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.statusRaw == recording })
        guard let trips = try? context.fetch(descriptor) else { return }
        for trip in trips {
            let points = trip.route
            finish(trip, points: points, distance: trip.distanceMeters,
                   endDate: points.last?.timestamp ?? trip.startDate)
        }
    }

    // MARK: - GPS

    private func startGPS() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        manager.startUpdatingLocation()
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopGPS() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        tickTimer?.invalidate()
        tickTimer = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    private func tick() {
        switch mode {
        case .probing:
            if let started = probeStartedAt, Date.now.timeIntervalSince(started) > Self.probeTimeout { cancelProbe() }
        case .recording:
            checkForAutoStop()
        case .idle:
            break
        }
    }

    private func checkForAutoStop() {
        let still = Date.now.timeIntervalSince(lastMovementAt)
        // Ausgestiegen und zu Fuß unterwegs → Fahrt ist vorbei.
        if let walking = walkingSince, walking > lastMovementAt, still > 60 {
            stopTrip(reason: .stationary)
            return
        }
        let minutes = AppSettings.autoStopMinutes
        if minutes > 0 && still > Double(minutes * 60) {
            stopTrip(reason: .stationary)
        }
    }

    private func isUsable(_ location: CLLocation, maxAge: TimeInterval?) -> Bool {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 65 else { return false }
        if let maxAge, abs(location.timestamp.timeIntervalSinceNow) > maxAge { return false }
        return true
    }

    private func effectiveSpeed(_ location: CLLocation, previous: CLLocation?) -> Double {
        if location.speed >= 0 { return location.speed }
        guard let previous else { return 0 }
        let seconds = location.timestamp.timeIntervalSince(previous.timestamp)
        return seconds > 0 ? location.distance(from: previous) / seconds : 0
    }

    // MARK: - Standortdaten verarbeiten

    fileprivate func handle(_ locations: [CLLocation]) {
        switch mode {
        case .idle:
            // Geweckt durch signifikanten Ortswechsel: nur prüfen, wenn wir weg vom Parkplatz sind.
            guard AppSettings.autoDetectDriving, let location = locations.last else { return }
            if let parking = AppSettings.parkingSpot {
                if location.distance(from: parking) > 250 || location.speed > 5 { beginProbe() }
            } else {
                AppSettings.parkingSpot = location
                armParkingFence(at: location)
            }
        case .probing:
            probe(locations)
        case .recording:
            record(locations, live: true)
        }
    }

    private func record(_ locations: [CLLocation], live: Bool) {
        guard let trip = activeTrip else { return }

        for location in locations where isUsable(location, maxAge: live ? 30 : nil) {
            if location.speed > 1.5 { lastMovementAt = max(lastMovementAt, location.timestamp) }

            if let last = lastLocation {
                let delta = location.distance(from: last)
                let seconds = location.timestamp.timeIntervalSince(last.timestamp)
                guard seconds > 0 else { continue }
                if delta / seconds > 70 { continue }                                // GPS-Sprung (> 250 km/h)
                if delta < max(5, location.horizontalAccuracy * 0.5) { continue }    // Zittern im Stand
                liveDistance += delta
                if delta > 20 { lastMovementAt = max(lastMovementAt, location.timestamp) }
            }

            lastLocation = location
            if lastStoredLocation.map({ location.distance(from: $0) >= 15 }) ?? true {
                storedPoints.append(RoutePoint(location))
                lastStoredLocation = location
                unsavedPoints += 1
            }
        }

        // Zwischenstand sichern, falls iOS die App beendet.
        if unsavedPoints >= 20 {
            trip.route = storedPoints
            trip.distanceMeters = liveDistance
            try? context.save()
            unsavedPoints = 0
        }
    }

    fileprivate func authorizationChanged() {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse && wantsAlways && !askedForAlways {
            askedForAlways = true
            manager.requestAlwaysAuthorization()
        }
        updateAutoDetection()
    }

    fileprivate func regionExited(_ identifier: String) {
        guard identifier == Self.parkingRegionID, mode == .idle, AppSettings.autoDetectDriving else { return }
        beginProbe()
    }

    fileprivate func visitEnded() {
        guard mode == .idle, AppSettings.autoDetectDriving else { return }
        beginProbe()
    }
}

extension TripRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { self.handle(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { self.authorizationChanged() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let identifier = region.identifier
        MainActor.assumeIsolated { self.regionExited(identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let departed = visit.departureDate != .distantFuture
        MainActor.assumeIsolated { if departed { self.visitEnded() } }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {}

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Kurzzeitige Fehler (z. B. Tunnel) ignorieren – Aufzeichnung läuft weiter.
    }
}
