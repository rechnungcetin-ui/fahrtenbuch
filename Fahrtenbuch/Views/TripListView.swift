import SwiftUI
import SwiftData

struct TripListView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Alle", open = "Offen", business = "Geschäftlich", privateTrip = "Privat"
        var id: String { rawValue }
    }

    @Query(sort: \Trip.startDate, order: .reverse) private var trips: [Trip]
    @State private var filter: Filter = .all
    @State private var showManual = false

    private var filtered: [Trip] {
        trips.filter { trip in
            guard trip.status != .recording else { return false }
            switch filter {
            case .all: return true
            case .open: return trip.needsAttention
            case .business: return trip.category == .business
            case .privateTrip: return trip.category == .privateTrip || trip.category == .commute
            }
        }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let trips: [Trip]
        var id: Date { day }
    }

    private var grouped: [DayGroup] {
        Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.startDate) }
            .sorted { $0.key > $1.key }
            .map { DayGroup(day: $0.key, trips: $0.value) }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if grouped.isEmpty {
                    ContentUnavailableView("Keine Fahrten", systemImage: "car",
                                           description: Text("Hier erscheinen deine aufgezeichneten Fahrten."))
                }

                ForEach(grouped) { group in
                    Section {
                        ForEach(group.trips) { trip in
                            NavigationLink(value: trip) { TripRow(trip: trip) }
                        }
                    } header: {
                        HStack {
                            Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                            Spacer()
                            Text(Fmt.km(group.trips.reduce(0) { $0 + $1.distanceKm }))
                        }
                    }
                }
            }
            .navigationTitle("Fahrten")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showManual = true } label: { Label("Fahrt nachtragen", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showManual) { ManualTripView() }
            .navigationDestination(for: Trip.self) { TripDetailView(trip: $0) }
        }
    }
}
