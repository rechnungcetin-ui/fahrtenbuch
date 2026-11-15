import SwiftUI
import SwiftData
import CoreLocation

struct TripDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Trip.startDate, order: .reverse) private var allTrips: [Trip]

    let trip: Trip

    @State private var category: TripCategory
    @State private var purpose: String
    @State private var partner: String
    @State private var detour: String
    @State private var startAddress: String
    @State private var endAddress: String
    @State private var errorMessage: String?
    @State private var confirmFinalize = false
    @State private var confirmDelete = false
    @State private var placeTarget: PlaceTarget?
    @State private var confirmMerge = false

    init(trip: Trip) {
        self.trip = trip
        _category = State(initialValue: trip.category)
        _purpose = State(initialValue: trip.purpose)
        _partner = State(initialValue: trip.businessPartner)
        _detour = State(initialValue: trip.detourNote)
        _startAddress = State(initialValue: trip.startAddress)
        _endAddress = State(initialValue: trip.endAddress)
    }

    private var hasChanges: Bool {
        category != trip.category || purpose != trip.purpose || partner != trip.businessPartner
            || detour != trip.detourNote || startAddress != trip.startAddress || endAddress != trip.endAddress
    }

    private var recentPurposes: [String] {
        var seen = Set<String>()
        return Array(allTrips.compactMap { t -> String? in
            guard t.category == .business, !t.purpose.isEmpty, seen.insert(t.purpose).inserted else { return nil }
            return t.purpose
        }.prefix(8))
    }

    private var mergeCandidate: Trip? { TripLedger.mergeCandidate(after: trip, in: allTrips) }

    private var calendarSuggestion: CalendarSuggester.Suggestion? {
        guard trip.isEditable, let s = CalendarSuggester.suggestion(for: trip), s.title != purpose else { return nil }
        return s
    }

    var body: some View {
        Form {
            if trip.route.isEmpty {
                Section {
                    Label(trip.isManualEntry ? "Nachgetragen – keine GPS-Route. Grund: \(trip.manualReason)" : "Keine Routendaten",
                          systemImage: "square.and.pencil")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    TripMapView(points: trip.route)
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    if trip.startReconstructed {
                        Text("Der Anfang der Strecke wurde vom Parkplatz aus ergänzt, weil die automatische Erkennung erst nach einigen hundert Metern greift.")
                    }
                }
            }

            if let suggestion = calendarSuggestion {
                Section("Vorschlag aus deinem Kalender") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.title).font(.headline)
                        Text("\(Fmt.time.string(from: suggestion.start)) Uhr\(suggestion.location.isEmpty ? "" : " · \(suggestion.location)")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Als geschäftliche Fahrt übernehmen") {
                        category = .business
                        purpose = suggestion.title
                        if partner.isEmpty { partner = suggestion.location }
                    }
                }
            }

            Section("Fahrt") {
                LabeledContent("Datum", value: trip.startDate.formatted(date: .complete, time: .omitted))
                LabeledContent("Zeit", value: trip.timeRangeText)
                LabeledContent("Strecke (GPS)", value: trip.distanceText)
                LabeledContent("Km-Stand", value: "\(trip.startOdometer) → \(trip.endOdometer.map(String.init) ?? "–")")
                LabeledContent("Fahrzeug", value: trip.vehicle)
                LabeledContent("Erkannt per", value: trip.trigger.label)
                LabeledContent("Status", value: trip.status.label)
            }

            Section("Route") {
                if trip.isEditable {
                    TextField("Startadresse", text: $startAddress, axis: .vertical)
                    TextField("Zieladresse", text: $endAddress, axis: .vertical)
                    Menu {
                        Button("Start als Ort speichern") { placeTarget = .start }
                        Button("Ziel als Ort speichern") { placeTarget = .end }
                    } label: {
                        Label("Ort speichern (Zuhause, Büro, Kunde …)", systemImage: "mappin.and.ellipse")
                    }
                } else {
                    LabeledContent("Start", value: trip.startAddress)
                    LabeledContent("Ziel", value: trip.endAddress)
                }
            }

            Section {
                Picker("Fahrtart", selection: $category) {
                    ForEach(TripCategory.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                if category == .business {
                    TextField("Reisezweck (z. B. Kundentermin, Baustelle)", text: $purpose, axis: .vertical)
                    if !recentPurposes.isEmpty && trip.isEditable {
                        Menu("Zuletzt verwendet") {
                            ForEach(recentPurposes, id: \.self) { p in Button(p) { purpose = p } }
                        }
                    }
                    TextField("Besuchte Firma / Geschäftspartner", text: $partner)
                    TextField("Umweg / Bemerkung (optional)", text: $detour, axis: .vertical)
                }
            } header: {
                Text("Angaben zur Fahrt")
            } footer: {
                Text(trip.autoRule.isEmpty || category != trip.category
                     ? category.hint
                     : "Automatisch vorgeschlagen (Regel: \(trip.autoRule)) – bitte kurz prüfen. \(category.hint)")
            }
            .disabled(!trip.isEditable)

            if trip.isEditable {
                Section {
                    Button("Änderungen speichern", action: save).disabled(!hasChanges)
                    Button("Fahrt festschreiben") { confirmFinalize = true }.disabled(hasChanges)
                    if let next = mergeCandidate {
                        Button("Mit nächster Fahrt zusammenführen (\(next.timeRangeText))") { confirmMerge = true }
                            .disabled(hasChanges)
                    }
                } footer: {
                    Text("Festgeschriebene Fahrten lassen sich nicht mehr ändern. Ohne Zutun passiert das nach \(AppSettings.autoFinalizeDays) Tagen.")
                }
            }

            if trip.status == .finalized {
                Section("Festgeschrieben") {
                    LabeledContent("Am", value: trip.finalizedAt.map { Fmt.dateTime.string(from: $0) } ?? "–")
                    LabeledContent("Prüfsumme", value: String(trip.integrityHash.prefix(16)) + "…")
                    if TripLedger.verify(trip) {
                        Label("Unverändert seit dem Festschreiben", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Label("Achtung: Daten passen nicht zur Prüfsumme", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }

            if !trip.auditEntries.isEmpty {
                Section("Änderungsprotokoll") {
                    ForEach(trip.auditEntries.sorted { $0.timestamp > $1.timestamp }) { AuditRow(entry: $0, showTrip: false) }
                }
            }

            if trip.status != .finalized {
                Section {
                    Button("Fahrt löschen", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Nur für Fehlaufzeichnungen. Das Löschen wird im Änderungsprotokoll vermerkt.")
                }
            }
        }
        .navigationTitle(trip.startDate.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Hinweis", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Fahrt festschreiben?", isPresented: $confirmFinalize, titleVisibility: .visible) {
            Button("Festschreiben") {
                do { try TripLedger.finalize(trip, in: context) } catch { errorMessage = error.localizedDescription }
            }
        } message: {
            Text("Danach sind keine Änderungen mehr möglich.")
        }
        .confirmationDialog("Fahrten zusammenführen?", isPresented: $confirmMerge, titleVisibility: .visible) {
            Button("Zusammenführen") {
                guard let next = mergeCandidate else { return }
                do {
                    try TripLedger.merge(trip, with: next, in: context)
                    category = trip.category; purpose = trip.purpose; partner = trip.businessPartner
                    detour = trip.detourNote; endAddress = trip.endAddress
                } catch { errorMessage = error.localizedDescription }
            }
        } message: {
            Text("Beide Fahrten werden zu einer Fahrt mit Zwischenstopp. Der Stopp wird als Bemerkung vermerkt.")
        }
        .confirmationDialog("Fahrt wirklich löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                do { try TripLedger.delete(trip, in: context); dismiss() } catch { errorMessage = error.localizedDescription }
            }
        }
        .sheet(item: $placeTarget) { target in
            let coordinate = target == .start ? trip.startCoordinate : trip.endCoordinate
            if let coordinate {
                SavePlaceSheet(coordinate: coordinate, address: target == .start ? trip.startAddress : trip.endAddress)
            }
        }
    }

    private func save() {
        do {
            try TripLedger.update(trip, category: category, purpose: purpose, partner: partner, detour: detour,
                                  startAddress: startAddress, endAddress: endAddress, in: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum PlaceTarget: String, Identifiable {
    case start, end
    var id: String { rawValue }
}

struct SavePlaceSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let coordinate: CLLocationCoordinate2D
    let address: String

    @State private var name = ""
    @State private var kind: PlaceKind = .customer
    @State private var defaultPurpose = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Art", selection: $kind) {
                        ForEach(PlaceKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    TextField(kind == .customer ? "Firmenname (z. B. Müller GmbH)" : "Name", text: $name)
                    if kind == .customer {
                        TextField("Standard-Reisezweck (z. B. Wartung)", text: $defaultPurpose)
                    }
                } footer: {
                    Text("Künftige Fahrten zu diesem Ort werden automatisch benannt und vorsortiert: Zuhause ↔ Büro = Arbeitsweg, Kunde = geschäftlich.")
                }
                Section("Adresse") { Text(address.isEmpty ? "Unbekannt" : address) }
            }
            .navigationTitle("Ort speichern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        let finalName = name.isEmpty ? kind.label : name
                        context.insert(SavedPlace(name: finalName, address: address, coordinate: coordinate,
                                                  kind: kind, defaultPurpose: defaultPurpose))
                        try? context.save()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
