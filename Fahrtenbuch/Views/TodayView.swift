import SwiftUI
import SwiftData
import MapKit
import CoreLocation

struct TodayView: View {
    @Query(sort: \Trip.startDate, order: .reverse) private var trips: [Trip]
    @State private var recorder = TripRecorder.shared
    @AppStorage(AppSettings.Key.carName) private var carName = ""
    @AppStorage(AppSettings.Key.autoDetectMotion) private var autoDetect = true
    @State private var showManual = false

    private var todaysTrips: [Trip] {
        trips.filter { Calendar.current.isDateInToday($0.startDate) && $0.status != .recording }
    }

    private var olderOpenTrips: [Trip] {
        trips.filter { $0.needsAttention && !Calendar.current.isDateInToday($0.startDate) }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<11: "Guten Morgen"
        case 11..<18: "Hallo"
        default: "Guten Abend"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if recorder.authorization != .authorizedAlways || (carName.isEmpty && !autoDetect) {
                    Section { SetupCard(authorization: recorder.authorization, carConfigured: !carName.isEmpty || autoDetect) }
                }

                Section {
                    if let trip = recorder.activeTrip {
                        ActiveTripCard(trip: trip, distance: recorder.liveDistance) {
                            recorder.stopTrip(reason: .manual)
                        }
                    } else {
                        if recorder.isProbing {
                            Label("Bewegung erkannt – prüfe, ob du Auto fährst …", systemImage: "location.magnifyingglass")
                                .foregroundStyle(.blue)
                        } else if autoDetect && recorder.authorization == .authorizedAlways {
                            Label("Automatische Erkennung aktiv – einfach losfahren.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Button {
                            recorder.startTrip(trigger: .manual)
                        } label: {
                            Label("Fahrt jetzt manuell starten", systemImage: "play.circle.fill")
                                .font(.headline)
                        }
                        Button { showManual = true } label: {
                            Label("Vergessene Fahrt nachtragen", systemImage: "square.and.pencil")
                        }
                    }
                }

                Section("Dieser Monat") {
                    MonthSummaryCard(trips: trips.filter {
                        $0.status != .recording && Calendar.current.isDate($0.startDate, equalTo: .now, toGranularity: .month)
                    })
                }

                Section {
                    if todaysTrips.isEmpty {
                        Text("Heute noch keine Fahrten. Sobald du mit deinem Auto verbunden bist, läuft die Aufzeichnung automatisch.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(todaysTrips) { trip in
                            NavigationLink(value: trip) { TripRow(trip: trip) }
                        }
                    }
                } header: {
                    Text("Heute")
                } footer: {
                    if !todaysTrips.isEmpty {
                        let km = todaysTrips.reduce(0) { $0 + $1.distanceKm }
                        Text("\(todaysTrips.count) Fahrt\(todaysTrips.count == 1 ? "" : "en") · \(Fmt.km(km))")
                    }
                }

                if !olderOpenTrips.isEmpty {
                    Section("Noch zuzuordnen") {
                        ForEach(olderOpenTrips) { trip in
                            NavigationLink(value: trip) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Fmt.date.string(from: trip.startDate)).font(.caption).foregroundStyle(.secondary)
                                    TripRow(trip: trip)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(greeting)! Wo warst du heute?")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Trip.self) { TripDetailView(trip: $0) }
            .sheet(isPresented: $showManual) { ManualTripView() }
        }
    }
}

private struct ActiveTripCard: View {
    let trip: Trip
    let distance: Double
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Fahrt läuft", systemImage: "record.circle")
                .font(.headline)
                .foregroundStyle(.red)
                .symbolEffect(.pulse)

            Map(initialPosition: .userLocation(fallback: .automatic)) { UserAnnotation() }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack {
                VStack(alignment: .leading) {
                    Text(Fmt.km(distance / 1000)).font(.title.bold()).monospacedDigit()
                    Text("seit \(Fmt.time.string(from: trip.startDate))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TimelineView(.periodic(from: trip.startDate, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(trip.startDate)),
                         format: .time(pattern: .hourMinuteSecond))
                        .font(.title3).monospacedDigit()
                }
            }

            Button(role: .destructive, action: onStop) {
                Label("Fahrt beenden", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 6)
    }
}

private struct SetupCard: View {
    let authorization: CLAuthorizationStatus
    let carConfigured: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Einrichtung abschließen", systemImage: "checklist").font(.headline)

            if authorization != .authorizedAlways {
                Text("Damit Fahrten automatisch aufgezeichnet werden, braucht die App den Standortzugriff „Immer“.")
                    .font(.subheadline)
                if authorization == .denied || authorization == .restricted {
                    Button("iPhone-Einstellungen öffnen") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } else {
                    Button("Standort erlauben") { TripRecorder.shared.requestLocationPermission() }
                }
            }

            if !carConfigured {
                Text("Hinterlege dein Auto (Bluetooth-Name) und richte den Kurzbefehl ein.").font(.subheadline)
                Button("Zu den Einstellungen") { AppRouter.shared.selectedTab = .settings }
            }
        }
        .buttonStyle(.bordered)
        .padding(.vertical, 4)
    }
}
