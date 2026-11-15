import Foundation
import UserNotifications
import SwiftData

/// Mitteilungen: „Fahrt läuft“, „Fahrt beendet – zuordnen“ (mit Schnellaktionen) und die abendliche Erinnerung.
@MainActor
enum NotificationService {
    static let tripFinishedCategory = "TRIP_FINISHED"
    private static let activeTripID = "trip-active"
    private static let reminderID = "daily-reminder"

    enum Action {
        static let business = "SET_BUSINESS"
        static let privateTrip = "SET_PRIVATE"
        static let commute = "SET_COMMUTE"
        static let discard = "DISCARD"
    }

    private static var center: UNUserNotificationCenter { .current() }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func registerCategories() {
        let actions = [
            // Geschäftlich öffnet die App, damit direkt der Reisezweck eingetragen werden kann.
            UNNotificationAction(identifier: Action.business, title: "Geschäftlich", options: [.foreground],
                                 icon: UNNotificationActionIcon(systemImageName: "briefcase.fill")),
            UNNotificationAction(identifier: Action.privateTrip, title: "Privat", options: [],
                                 icon: UNNotificationActionIcon(systemImageName: "house.fill")),
            UNNotificationAction(identifier: Action.commute, title: "Arbeitsweg", options: [],
                                 icon: UNNotificationActionIcon(systemImageName: "building.2.fill")),
            // Bus, Bahn, Taxi oder Beifahrer – wird ebenfalls als „im Fahrzeug“ erkannt.
            UNNotificationAction(identifier: Action.discard, title: "Nicht selbst gefahren (löschen)",
                                 options: [.destructive], icon: UNNotificationActionIcon(systemImageName: "trash")),
        ]
        let category = UNNotificationCategory(identifier: tripFinishedCategory, actions: actions,
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    static func tripStarted(trigger: TripTrigger, at start: Date = .now) {
        let content = UNMutableNotificationContent()
        content.title = trigger == .motion ? "🚗 Autofahrt erkannt" : "🚗 Fahrt wird aufgezeichnet"
        content.body = "Start um \(Fmt.time.string(from: start)) · \(trigger.label). Gute Fahrt!"
        content.interruptionLevel = .passive
        post(id: activeTripID, content)
    }

    static func clearActiveTripNotice() {
        center.removeDeliveredNotifications(withIdentifiers: [activeTripID])
    }

    static func tripFinished(_ trip: Trip) {
        clearActiveTripNotice()
        let content = UNMutableNotificationContent()
        content.title = "Fahrt beendet · \(trip.distanceText)"
        content.body = "\(trip.displayStart) → \(trip.displayEnd)\n"
            + (trip.category == .unassigned
               ? (CalendarSuggester.suggestion(for: trip).map { "Termin: „\($0.title)“? Gedrückt halten zum Zuordnen." }
                  ?? "Gedrückt halten, um die Fahrt zuzuordnen.")
               : "Zugeordnet als \(trip.category.label)\(trip.purpose.isEmpty ? "" : ": \(trip.purpose)").")
        content.sound = .default
        content.categoryIdentifier = tripFinishedCategory
        content.userInfo = ["tripID": trip.id.uuidString]
        post(id: "trip-\(trip.id.uuidString)", content)
    }

    static func permissionMissing() {
        let content = UNMutableNotificationContent()
        content.title = "Fahrt konnte nicht aufgezeichnet werden"
        content.body = "Bitte erlaube dem Fahrtenbuch den Standortzugriff „Immer“."
        post(id: "permission", content)
    }

    /// Plant die Erinnerung „Wo warst du heute?“, solange Fahrten ohne Angaben existieren.
    static func refreshDailyReminder(in context: ModelContext) {
        let recorded = TripStatus.recorded.rawValue
        let trips = (try? context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.statusRaw == recorded }))) ?? []
        let open = trips.filter(\.needsAttention).count

        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
        center.setBadgeCount(open)
        guard open > 0 else { return }

        let calendar = Calendar.current
        guard let today = calendar.date(bySettingHour: AppSettings.reminderHour, minute: 0, second: 0, of: .now),
              let fire = today > .now ? today : calendar.date(byAdding: .day, value: 1, to: today) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Wo warst du heute?"
        content.body = open == 1
            ? "1 Fahrt wartet auf Zweck & Zuordnung – dauert 10 Sekunden."
            : "\(open) Fahrten warten auf Zweck & Zuordnung – dauert keine Minute."
        content.sound = .default
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        center.add(UNNotificationRequest(identifier: reminderID, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
    }

    static func handle(action: String, tripID: String?) {
        guard let tripID, let uuid = UUID(uuidString: tripID) else {
            AppRouter.shared.selectedTab = .today
            return
        }
        let context = DataStore.context
        var descriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        guard let trip = try? context.fetch(descriptor).first else { return }

        if action == Action.discard {
            if trip.isEditable { try? TripLedger.delete(trip, in: context) }
            return
        }

        let category: TripCategory? = switch action {
        case Action.business: .business
        case Action.privateTrip: .privateTrip
        case Action.commute: .commute
        default: nil
        }
        if let category, trip.isEditable { try? TripLedger.setCategory(category, for: trip, in: context) }
        if category == nil || category == .business { AppRouter.shared.open(trip) }
    }

    private static func post(id: String, _ content: UNNotificationContent) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let tripID = response.notification.request.content.userInfo["tripID"] as? String
        let action = response.actionIdentifier
        await MainActor.run { NotificationService.handle(action: action, tripID: tripID) }
    }
}
