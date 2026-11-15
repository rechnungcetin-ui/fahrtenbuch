import SwiftUI
import SwiftData
import UserNotifications

@main
struct FahrtenbuchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(DataStore.container)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            CarAudioMonitor.shared.evaluate()
            let context = DataStore.context
            TripLedger.restoreOdometerIfNeeded(in: context)
            TripLedger.autoFinalize(in: context)
            NotificationService.refreshDailyReminder(in: context)
            Task {
                await AddressResolver.fillMissing(in: context)
                await ArchiveService.archiveIfNeeded(in: context)
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppSettings.registerDefaults()
        UNUserNotificationCenter.current().delegate = NotificationHandler.shared
        NotificationService.registerCategories()
        // Läuft auch, wenn iOS die App im Hintergrund startet (Kurzbefehl, Ortswechsel).
        TripRecorder.shared.activate()
        CarAudioMonitor.shared.start()
        return true
    }
}

enum AppTab: Hashable { case today, trips, expenses, export, settings }

struct TripLink: Identifiable, Hashable { let id: UUID }

@Observable
@MainActor
final class AppRouter {
    static let shared = AppRouter()
    var selectedTab: AppTab = .today
    var openTrip: TripLink?

    func open(_ trip: Trip) { openTrip = TripLink(id: trip.id) }
}

struct RootView: View {
    @State private var router = AppRouter.shared
    @Query(sort: \Trip.startDate, order: .reverse) private var trips: [Trip]

    private var openCount: Int { trips.filter(\.needsAttention).count }

    var body: some View {
        TabView(selection: $router.selectedTab) {
            TodayView()
                .tabItem { Label("Heute", systemImage: "car.fill") }
                .tag(AppTab.today)
            TripListView()
                .tabItem { Label("Fahrten", systemImage: "list.bullet.rectangle.portrait") }
                .badge(openCount)
                .tag(AppTab.trips)
            ExpenseListView()
                .tabItem { Label("Belege", systemImage: "doc.text.viewfinder") }
                .tag(AppTab.expenses)
            ExportView()
                .tabItem { Label("Auswertung", systemImage: "doc.text.fill") }
                .tag(AppTab.export)
            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .sheet(item: $router.openTrip) { link in
            if let trip = trips.first(where: { $0.id == link.id }) {
                NavigationStack {
                    TripDetailView(trip: trip)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Fertig") { router.openTrip = nil }
                            }
                        }
                }
            }
        }
        .task { await NotificationService.requestAuthorization() }
    }
}
