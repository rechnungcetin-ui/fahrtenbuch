import SwiftData

/// Ein gemeinsamer Datenspeicher für App, Kurzbefehle und Mitteilungen.
/// Mit iCloud-Sync (CloudKit, privater Bereich) sind die Daten bei Verlust des iPhones sicher.
@MainActor
enum DataStore {
    static let cloudContainerID = "iCloud.de.meinfahrtenbuch.app"

    /// `true`, wenn der Speicher mit iCloud synchronisiert (Einstellung + iCloud verfügbar).
    private(set) static var usesCloudKit = false

    static let container: ModelContainer = {
        AppSettings.registerDefaults()
        let schema = Schema([Trip.self, AuditEntry.self, SavedPlace.self, Expense.self])

        if AppSettings.iCloudSync {
            let cloud = ModelConfiguration(schema: schema, cloudKitDatabase: .private(cloudContainerID))
            if let container = try? ModelContainer(for: schema, configurations: cloud) {
                usesCloudKit = true
                return container
            }
        }
        do {
            let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: local)
        } catch {
            fatalError("Datenspeicher konnte nicht geöffnet werden: \(error)")
        }
    }()

    static var context: ModelContext { container.mainContext }
}
