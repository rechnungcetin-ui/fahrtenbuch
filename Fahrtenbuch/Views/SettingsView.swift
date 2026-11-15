import SwiftUI
import SwiftData
import CoreLocation

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var recorder = TripRecorder.shared

    @AppStorage(AppSettings.Key.vehicleName) private var vehicleName = ""
    @AppStorage(AppSettings.Key.licensePlate) private var licensePlate = ""
    @AppStorage(AppSettings.Key.odometerMeters) private var odometerMeters = 0.0
    @AppStorage(AppSettings.Key.carName) private var carName = ""
    @AppStorage(AppSettings.Key.autoDetectBluetooth) private var autoBluetooth = true
    @AppStorage(AppSettings.Key.stopOnDisconnect) private var stopOnDisconnect = true
    @AppStorage(AppSettings.Key.autoDetectMotion) private var autoMotion = true
    @AppStorage(AppSettings.Key.detectionSpeedKmh) private var detectionSpeed = 20
    @AppStorage(AppSettings.Key.calendarSuggestions) private var calendarSuggestions = true
    @State private var calendarAuthorized = CalendarSuggester.isAuthorized
    @AppStorage(AppSettings.Key.autoStopMinutes) private var autoStopMinutes = 5
    @AppStorage(AppSettings.Key.autoFinalizeDays) private var autoFinalizeDays = 7
    @AppStorage(AppSettings.Key.reminderHour) private var reminderHour = 19

    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]
    @State private var connectedDevice: String?
    @State private var showOdometer = false
    @AppStorage(AppSettings.Key.iCloudSync) private var iCloudSync = true
    @AppStorage(AppSettings.Key.autoArchive) private var autoArchive = true
    @AppStorage(AppSettings.Key.ruleReturnTrip) private var ruleReturnTrip = true
    @AppStorage(AppSettings.Key.ruleKnownRoute) private var ruleKnownRoute = true
    @AppStorage(AppSettings.Key.ruleWorkHours) private var ruleWorkHours = false
    @AppStorage(AppSettings.Key.workStartHour) private var workStartHour = 8
    @AppStorage(AppSettings.Key.workEndHour) private var workEndHour = 18
    @AppStorage(AppSettings.Key.workOnSaturday) private var workOnSaturday = false
    @State private var archiveMessage: String?
    @State private var archiveLocation = ""

    var body: some View {
        NavigationStack {
            Form {
                vehicleSection
                bluetoothSection
                shortcutSection
                detectionSection
                calendarSection
                rulesSection
                backupSection
                logbookSection
                reimbursementSection
                homeWorkSection
                bookkeepingSection
                disclaimerSection
                placesSection
                permissionsSection
            }
            .navigationTitle("Einstellungen")
            .sheet(isPresented: $showOdometer) { OdometerSheet(currentKm: Int(odometerMeters / 1000)) }
        }
    }

    @ViewBuilder private var vehicleSection: some View {
        Section("Fahrzeug") {
            TextField("Bezeichnung (z. B. VW Golf)", text: $vehicleName)
            TextField("Kennzeichen", text: $licensePlate).textInputAutocapitalization(.characters)
            Button {
                showOdometer = true
            } label: {
                LabeledContent("Kilometerstand", value: "\(Int(odometerMeters / 1000)) km")
            }
            .disabled(recorder.isRecording)
        }
    }

    @ViewBuilder private var bluetoothSection: some View {
        Section {
            TextField("Bluetooth-Name deines Autos", text: $carName)
            Button("Aktuell verbundenes Gerät übernehmen") {
                connectedDevice = CarAudioMonitor.connectedDeviceName()
                if let connectedDevice { carName = connectedDevice }
            }
            if connectedDevice == nil && !carName.isEmpty {
                Text("Tipp: Verbinde dich im Auto und tippe auf den Button, um den Namen exakt zu übernehmen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Bei offener App automatisch starten", isOn: $autoBluetooth)
            Toggle("Beim Trennen automatisch beenden", isOn: $stopOnDisconnect)
        } header: {
            Text("Auto-Erkennung per Bluetooth")
        } footer: {
            Text("Für den Start bei geschlossener App unbedingt den Kurzbefehl unten einrichten – iOS erlaubt Apps keine eigene Bluetooth-Überwachung im Hintergrund.")
        }
    }

    @ViewBuilder private var shortcutSection: some View {
        Section {
            Text("Optional, aber noch genauer: Mit dem Kurzbefehl startet die Aufzeichnung exakt beim Verbinden mit dem Auto.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Kurzbefehle-App → „Automation“ → „+“")
                Text("2. „Bluetooth“ wählen → Gerät: \(carName.isEmpty ? "dein Auto" : carName) → „Ist verbunden“")
                Text("3. „Sofort ausführen“ aktivieren")
                Text("4. Aktion „Fahrt starten“ (Fahrtenbuch) hinzufügen")
                Text("5. Zweite Automation: „Ist getrennt“ → „Fahrt beenden“")
            }
            .font(.subheadline)
            Button("Kurzbefehle-App öffnen") {
                if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
            }
        } header: {
            Text("Kurzbefehl per Auto-Bluetooth (optional)")
        }
    }

    @ViewBuilder private var detectionSection: some View {
        Section {
            Toggle("Autofahrten automatisch erkennen", isOn: $autoMotion)
                .onChange(of: autoMotion) { recorder.updateAutoDetection() }
            Stepper("Ab \(detectionSpeed) km/h als Autofahrt werten", value: $detectionSpeed, in: 10...40, step: 5)
            Stepper("Beenden nach \(autoStopMinutes) Min. Stillstand", value: $autoStopMinutes, in: 2...30)
        } header: {
            Text("Fahrterkennung ohne Bluetooth")
        } footer: {
            Text("Funktioniert auch bei geschlossener App: Verlässt du deinen Parkplatz, prüft die App kurz per GPS und Bewegungssensor, ob du Auto fährst. Fahrrad wird ausgeschlossen, Bus und Bahn sehen für das iPhone aber wie Autofahren aus – solche Fahrten in der Mitteilung einfach mit „Nicht selbst gefahren“ löschen. Ausgestiegen und zu Fuß unterwegs beendet die Fahrt automatisch.")
        }
    }

    @ViewBuilder private var calendarSection: some View {
        Section {
            Toggle("Reisezweck aus Kalender vorschlagen", isOn: $calendarSuggestions)
            if !calendarAuthorized {
                Button("Kalenderzugriff erlauben") {
                    Task { calendarAuthorized = await CalendarSuggester.requestAccess() }
                }
            }
        } header: {
            Text("Kalender")
        } footer: {
            Text("Passt ein Termin zu Ankunftszeit und Ziel, wird er als Reisezweck vorgeschlagen – liegt der Terminort am Ziel, sogar automatisch eingetragen. Google- oder Outlook-Kalender funktionieren, wenn sie in den iPhone-Einstellungen hinzugefügt sind.")
        }
    }

    @ViewBuilder private var rulesSection: some View {
        Section {
            Toggle("Rückfahrten erkennen", isOn: $ruleReturnTrip)
            Toggle("Bekannte Strecken übernehmen", isOn: $ruleKnownRoute)
            Toggle("In der Arbeitszeit = geschäftlich", isOn: $ruleWorkHours)
            if ruleWorkHours {
                Stepper("Beginn \(workStartHour):00 Uhr", value: $workStartHour, in: 0...(workEndHour - 1))
                Stepper("Ende \(workEndHour):00 Uhr", value: $workEndHour, in: (workStartHour + 1)...24)
                Toggle("Auch samstags", isOn: $workOnSaturday)
            }
        } header: {
            Text("Automatische Zuordnung")
        } footer: {
            Text("Reihenfolge: gespeicherter Ort → Kalendertermin → Rückfahrt → bekannte Strecke (mind. 2× gleich zugeordnet) → Arbeitszeit. Jeder Vorschlag bleibt änderbar; bei „Arbeitszeit“ fehlt noch der Reisezweck, den trägst du nach.")
        }
    }

    @ViewBuilder private var backupSection: some View {
        Section {
            Toggle("iCloud-Sync", isOn: $iCloudSync)
            LabeledContent("Status", value: DataStore.usesCloudKit ? "Aktiv ✓" : "Nur auf diesem iPhone")
            Toggle("Monatsarchiv automatisch ablegen", isOn: $autoArchive)
            Button("Jetzt PDF + CSV archivieren") {
                Task {
                    do {
                        let count = try await ArchiveService.archiveNow(in: context)
                        archiveMessage = count == 0 ? "Keine Fahrten im laufenden Jahr." : "\(count) Dateien abgelegt."
                    } catch {
                        archiveMessage = error.localizedDescription
                    }
                }
            }
            if let archiveMessage { Text(archiveMessage).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Datensicherung")
        } footer: {
            Text("Sync: Alle Fahrten und Belege liegen zusätzlich in deiner privaten iCloud – auf einem neuen iPhone sind sie wieder da. Änderungen am Schalter gelten nach dem Neustart der App.\nArchiv: \(archiveLocation)")
        }
        .task {
            let folder = await ArchiveService.folder()
            archiveLocation = folder.iCloud ? "Dateien-App › iCloud Drive › Fahrtenbuch › Archiv" : "Dateien-App › Auf meinem iPhone › Fahrtenbuch › Archiv"
        }
    }

    @ViewBuilder private var logbookSection: some View {
        Section("Fahrtenbuch") {
            Stepper("Festschreiben nach \(autoFinalizeDays) Tagen", value: $autoFinalizeDays, in: 1...30)
            Stepper("Erinnerung um \(reminderHour):00 Uhr", value: $reminderHour, in: 6...23)
                .onChange(of: reminderHour) { NotificationService.refreshDailyReminder(in: context) }
            NavigationLink("Änderungsprotokoll") { AuditLogView() }
        }
    }

    @ViewBuilder private var reimbursementSection: some View {
        ReimbursementSettingsSection()
    }

    @ViewBuilder private var homeWorkSection: some View {
        HomeWorkSection()
    }

    @ViewBuilder private var bookkeepingSection: some View {
        Section {
            NavigationLink {
                SevDeskSettingsView()
            } label: {
                LabeledContent("sevDesk", value: SevDeskClient.isConfigured ? "Verbunden" : "Einrichten")
            }
        } header: {
            Text("Buchhaltung")
        } footer: {
            Text("Überträgt das monatliche Fahrtgeld und deine Tank-/Kfz-Belege als Entwurf an sevDesk.")
        }
    }

    @ViewBuilder private var disclaimerSection: some View {
        Section("Hinweis") {
            Text(AppInfo.disclaimer).font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var placesSection: some View {
        Section("Gespeicherte Orte") {
            if places.isEmpty {
                Text("Speichere Zuhause, Büro und Kunden direkt aus einer Fahrt heraus („Ort speichern“).")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(places) { place in
                Label {
                    VStack(alignment: .leading) {
                        Text(place.name)
                        Text(place.address).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: place.kind.symbol)
                }
            }
            .onDelete { offsets in
                for index in offsets { context.delete(places[index]) }
                try? context.save()
            }
        }
    }

    @ViewBuilder private var permissionsSection: some View {
        Section("Berechtigungen") {
            LabeledContent("Standort", value: authorizationText)
            if recorder.authorization != .authorizedAlways {
                Button("Standort „Immer“ erlauben") { recorder.requestLocationPermission() }
            }
            Button("iPhone-Einstellungen öffnen") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }

    private var authorizationText: String {
        switch recorder.authorization {
        case .authorizedAlways: "Immer ✓"
        case .authorizedWhenInUse: "Beim Verwenden (zu wenig)"
        case .denied: "Abgelehnt"
        case .restricted: "Eingeschränkt"
        default: "Nicht gefragt"
        }
    }
}

private struct OdometerSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let currentKm: Int
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Kilometerstand laut Tacho", text: $value).keyboardType(.numberPad)
                } footer: {
                    Text("GPS-Kilometer weichen leicht vom Tacho ab. Gleiche den Stand z. B. beim Tanken ab – jede Korrektur wird protokolliert.")
                }
            }
            .navigationTitle("Kilometerstand")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { value = String(currentKm) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if let km = Int(value), km >= 0 { try? TripLedger.correctOdometer(to: km, in: context) }
                        dismiss()
                    }
                    .disabled(Int(value) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
