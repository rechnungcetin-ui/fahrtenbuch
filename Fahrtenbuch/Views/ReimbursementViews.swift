import SwiftUI
import SwiftData
import CoreLocation
import MapKit

/// „Diesen Monat“: Kilometer und Fahrtgeld auf einen Blick.
struct MonthSummaryCard: View {
    let trips: [Trip]
    // Sorgt dafür, dass sich die Karte aktualisiert, wenn die Sätze geändert werden.
    @AppStorage(AppSettings.Key.rateBusinessCents) private var rateBusiness = 30
    @AppStorage(AppSettings.Key.rateCommuteCents) private var rateCommute = 38
    @AppStorage(AppSettings.Key.commutePerDrivenKm) private var perDrivenKm = false
    @AppStorage(AppSettings.Key.commuteDistanceKm) private var commuteDistance = 0.0

    var body: some View {
        let money = Reimbursement(trips: trips)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text(Fmt.euro(money.total)).font(.title.bold()).monospacedDigit()
                    Text("Fahrtgeld \(Fmt.monthName(Calendar.current.component(.month, from: .now)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(Fmt.km(money.totalKm)).font(.title3.weight(.semibold)).monospacedDigit()
                    Text("gefahren").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            row("Geschäftlich", "\(Fmt.km(money.businessKm)) × \(Fmt.euro(Reimbursement.businessRate))", money.businessAmount, .blue)
            if money.commuteDrivenKm > 0 {
                row("Arbeitsweg", money.commuteExplanation, money.commuteAmount, .purple)
            }
            row("Privat", Fmt.km(money.privateKm), nil, .green)
        }
        .padding(.vertical, 4)
    }

    private func row(_ title: String, _ detail: String, _ amount: Double?, _ color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let amount { Text(Fmt.euro(amount)).font(.subheadline.weight(.semibold)).monospacedDigit() }
        }
    }
}

/// Einstellungen: Sätze je Kilometer.
struct ReimbursementSettingsSection: View {
    @AppStorage(AppSettings.Key.rateBusinessCents) private var rateBusiness = 30
    @AppStorage(AppSettings.Key.rateCommuteCents) private var rateCommute = 38
    @AppStorage(AppSettings.Key.commutePerDrivenKm) private var perDrivenKm = false
    @AppStorage(AppSettings.Key.commuteDistanceKm) private var commuteDistance = 0.0

    var body: some View {
        Section {
            Stepper("Dienstfahrten: \(Fmt.euro(Double(rateBusiness) / 100)) je km", value: $rateBusiness, in: 0...150)
            Stepper("Arbeitsweg: \(Fmt.euro(Double(rateCommute) / 100)) je km", value: $rateCommute, in: 0...150)
            Picker("Arbeitsweg berechnen", selection: $perDrivenKm) {
                Text("Einfache Strecke je Arbeitstag").tag(false)
                Text("Jeder gefahrene Kilometer").tag(true)
            }
            if !perDrivenKm {
                Stepper("Entfernung: \(commuteDistance > 0 ? "\(Int(commuteDistance)) km" : "automatisch")",
                        value: $commuteDistance, in: 0...300, step: 1)
            }
        } header: {
            Text("Fahrtgeld")
        } footer: {
            Text("Voreingestellt sind die üblichen Pauschalen: 0,30 € je gefahrenem Kilometer für Dienstfahrten mit dem privaten Pkw und 0,38 € Entfernungspauschale für den Weg zwischen Wohnung und erster Betriebs- bzw. Tätigkeitsstätte (seit 2026 ab dem ersten Kilometer; zählt nur die einfache Strecke, einmal pro Arbeitstag, volle Kilometer). „Automatisch“ nimmt die kürzeste gefahrene Strecke des Tages.\nWichtig: Die Kilometerpauschale gilt für ein privates Auto. Gehört das Auto zum Betriebsvermögen und du setzt die tatsächlichen Kosten an (Fahrtenbuch-Methode), darf die Pauschale für Dienstfahrten nicht zusätzlich angesetzt werden.")
        }
    }
}

/// Einstellungen: Wohnung und Arbeitsstätte als Adresse hinterlegen.
struct HomeWorkSection: View {
    @Query private var places: [SavedPlace]
    @State private var editing: PlaceKind?

    var body: some View {
        Section {
            row(.home, "Wohnung")
            row(.work, "Arbeitsstätte / Büro")
        } header: {
            Text("Wohnung & Arbeitsstätte")
        } footer: {
            Text("Fahrten zwischen beiden Adressen werden automatisch als Arbeitsweg zugeordnet und mit dem Arbeitsweg-Satz abgerechnet. Die Entfernung (kürzeste Straßenverbindung) wird automatisch berechnet.")
        }
        .sheet(item: $editing) { PlaceAddressSheet(kind: $0) }
    }

    private func row(_ kind: PlaceKind, _ title: String) -> some View {
        let place = places.first { $0.kind == kind }
        return Button { editing = kind } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(.primary)
                    Text(place?.address ?? "Adresse eintragen").font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: kind.symbol)
            }
        }
    }
}

struct PlaceAddressSheet: View {
    let kind: PlaceKind
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var places: [SavedPlace]
    @State private var address = ""
    @State private var message: String?
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Straße Hausnummer, PLZ Ort", text: $address, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                } footer: {
                    if let message { Text(message).foregroundStyle(.red) }
                }
                if isBusy { ProgressView() }
            }
            .navigationTitle(kind == .home ? "Wohnung" : "Arbeitsstätte")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { address = places.first { $0.kind == kind }?.address ?? "" }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { Task { await save() } }
                        .disabled(address.trimmingCharacters(in: .whitespaces).count < 5 || isBusy)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        guard let placemark = try? await CLGeocoder().geocodeAddressString(address).first,
              let location = placemark.location else {
            message = "Adresse nicht gefunden – bitte genauer angeben."
            return
        }
        for old in places where old.kind == kind { context.delete(old) }
        let formatted = AddressResolver.format(placemark)
        context.insert(SavedPlace(name: kind == .home ? "Zuhause" : "Arbeitsstätte",
                                  address: formatted.isEmpty ? address : formatted,
                                  coordinate: location.coordinate, kind: kind))
        try? context.save()
        await updateCommuteDistance(newLocation: location)
        dismiss()
    }

    /// Kürzeste Straßenverbindung Wohnung ↔ Arbeitsstätte (maßgeblich für die Entfernungspauschale).
    private func updateCommuteDistance(newLocation: CLLocation) async {
        let otherKind: PlaceKind = kind == .home ? .work : .home
        guard let other = places.first(where: { $0.kind == otherKind }) else { return }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: newLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: other.location.coordinate))
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        guard let routes = try? await MKDirections(request: request).calculate().routes,
              let shortest = routes.map(\.distance).min() else { return }
        AppSettings.commuteDistanceKm = floor(shortest / 1000)
    }
}
