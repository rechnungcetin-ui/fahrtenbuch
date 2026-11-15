import AppIntents

/// Wird von der Kurzbefehle-Automation „Wenn mit [Auto] verbunden“ ausgelöst – auch wenn die App geschlossen ist.
struct StartTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Fahrt starten"
    static let description = IntentDescription("Startet die GPS-Aufzeichnung einer Fahrt im Fahrtenbuch.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recorder = TripRecorder.shared
        guard !recorder.isRecording else { return .result(dialog: "Die Fahrt wird bereits aufgezeichnet.") }
        recorder.startTrip(trigger: .shortcut)
        return .result(dialog: recorder.isRecording
                       ? "Fahrt wird aufgezeichnet. Gute Fahrt!"
                       : "Bitte erlaube dem Fahrtenbuch den Standortzugriff „Immer“.")
    }
}

/// Wird von der Automation „Wenn von [Auto] getrennt“ ausgelöst.
struct StopTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Fahrt beenden"
    static let description = IntentDescription("Beendet die laufende Fahrt und speichert sie im Fahrtenbuch.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard TripRecorder.shared.isRecording else { return .result(dialog: "Es läuft gerade keine Fahrt.") }
        TripRecorder.shared.stopTrip(reason: .shortcut)
        return .result(dialog: "Fahrt gespeichert.")
    }
}

struct FahrtenbuchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartTripIntent(),
                    phrases: ["Fahrt starten mit \(.applicationName)", "Starte \(.applicationName)"],
                    shortTitle: "Fahrt starten", systemImageName: "car.fill")
        AppShortcut(intent: StopTripIntent(),
                    phrases: ["Fahrt beenden mit \(.applicationName)", "Beende \(.applicationName)"],
                    shortTitle: "Fahrt beenden", systemImageName: "flag.checkered")
    }
}
