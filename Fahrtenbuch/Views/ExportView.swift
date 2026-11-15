import SwiftUI
import SwiftData

struct ExportView: View {
    @Query(sort: \Trip.startDate) private var trips: [Trip]
    @Query(sort: \AuditEntry.timestamp) private var audit: [AuditEntry]
    @Query(sort: \Expense.date) private var expenses: [Expense]

    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var month = Calendar.current.component(.month, from: .now) // 0 = ganzes Jahr
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @State private var sevDeskMessage: String?
    @State private var isSending = false

    private var period: ExportPeriod { ExportPeriod(year: year, month: month == 0 ? nil : month) }

    private var periodTrips: [Trip] {
        trips.filter { $0.status != .recording && period.contains($0.startDate) }
    }

    private var periodAudit: [AuditEntry] {
        audit.filter { entry in
            if let trip = entry.trip { return period.contains(trip.startDate) }
            return period.contains(entry.timestamp)
        }
    }

    private var periodExpenses: [Expense] { expenses.filter { period.contains($0.date) } }

    private var totalKm: Double { periodTrips.reduce(0) { $0 + $1.distanceKm } }

    private func km(_ category: TripCategory) -> Double {
        periodTrips.filter { $0.category == category }.reduce(0) { $0 + $1.distanceKm }
    }

    var body: some View {
        NavigationStack {
            Form {
                periodSection
                overviewSection
                sharesSection
                reimbursementSection
                costsSection
                deductibleSection
                openSection
                exportSection
            }
            .navigationTitle("Auswertung")
            .onChange(of: year) { exportURL = nil }
            .onChange(of: month) { exportURL = nil }
            .alert("Export fehlgeschlagen", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder private var periodSection: some View {
        Section("Zeitraum") {
            Picker("Monat", selection: $month) {
                Text("Ganzes Jahr").tag(0)
                ForEach(1...12, id: \.self) { Text(Fmt.monthName($0)).tag($0) }
            }
            Stepper("Jahr \(String(year))", value: $year, in: 2020...2100)
        }
    }

    @ViewBuilder private var overviewSection: some View {
        Section("Übersicht \(period.title)") {
            let total = periodTrips.reduce(0) { $0 + $1.distanceKm }
            LabeledContent("Fahrten", value: "\(periodTrips.count)")
            LabeledContent("Gesamt", value: Fmt.km(total))
            LabeledContent("Geschäftlich", value: Fmt.km(km(.business)))
            LabeledContent("Privat", value: Fmt.km(km(.privateTrip)))
            LabeledContent("Arbeitsweg", value: Fmt.km(km(.commute)))
        }
    }

    @ViewBuilder private var sharesSection: some View {
        // Anteile: Grundlage für alles, was sich absetzen lässt.
        let total = periodTrips.reduce(0) { $0 + $1.distanceKm }
        if total > 0 {
            Section {
                shareRow("Geschäftlich", km(.business), total, .blue)
                shareRow("Arbeitsweg", km(.commute), total, .purple)
                shareRow("Privat", km(.privateTrip), total, .green)
                if km(.unassigned) > 0 { shareRow("Noch offen", km(.unassigned), total, .orange) }
            } header: {
                Text("Nutzungsanteile")
            } footer: {
                Text("Anteil an den gefahrenen Kilometern im Zeitraum.")
            }
        }
    }

    @ViewBuilder private var reimbursementSection: some View {
        Section {
            let money = Reimbursement(trips: periodTrips)
            LabeledContent("Dienstfahrten", value: Fmt.euro(money.businessAmount))
            Text("\(Fmt.km(money.businessKm)) × \(Fmt.euro(Reimbursement.businessRate))").font(.caption).foregroundStyle(.secondary)
            if money.commuteDrivenKm > 0 {
                LabeledContent("Arbeitsweg", value: Fmt.euro(money.commuteAmount))
                Text(money.commuteExplanation).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Fahrtgeld \(period.title)", value: Fmt.euro(money.total)).font(.headline)

            if SevDeskClient.isConfigured, month != 0, money.total > 0 {
                if let id = AppSettings.sevDeskSentPeriods[period.fileStem] {
                    Label("In sevDesk als Entwurf angelegt (Beleg \(id))", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Button { Task { await sendToSevDesk(money) } } label: {
                        Label("Fahrtgeld als Entwurf an sevDesk senden", systemImage: "paperplane")
                    }
                    .disabled(isSending)
                }
            }
            if let sevDeskMessage { Text(sevDeskMessage).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Fahrtgeld")
        } footer: {
            Text("Die Sätze stellst du unter Einstellungen › Fahrtgeld ein.")
        }
    }

    @ViewBuilder private var costsSection: some View {
        if !periodExpenses.isEmpty {
            Section {
                let costs = CostSummary(periodExpenses)
                let total = periodTrips.reduce(0) { $0 + $1.distanceKm }
                LabeledContent("Kosten gesamt", value: Fmt.euro(costs.total))
                ForEach(costs.byKind) { item in
                    LabeledContent(item.kind.label, value: Fmt.euro(item.amount)).font(.subheadline)
                }
                if let perKm = costs.costPerKm(total) {
                    LabeledContent("Kosten je km", value: Fmt.euro(perKm))
                    LabeledContent("Anteil Dienstfahrten", value: Fmt.euro(costs.total * km(.business) / total))
                }
                if let consumption = costs.consumption(total) {
                    LabeledContent("Verbrauch (ca.)", value: "\(Fmt.kmValue(consumption)) l/100 km")
                }
            } header: {
                Text("Fahrzeugkosten")
            } footer: {
                Text("Für die Rechnung mit tatsächlichen Kosten zählen alle Kosten des Fahrzeugs – auch Versicherung, Steuer, Leasing bzw. Abschreibung. Trage sie als Beleg ein, damit die Summe vollständig ist.")
            }
        }
    }

    @ViewBuilder private var deductibleSection: some View {
        let total = totalKm
        if total > 0 {
            Section {
                let money = Reimbursement(trips: periodTrips)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Privates Auto – Pauschale").font(.subheadline.weight(.semibold))
                    LabeledContent("Fahrtgeld", value: Fmt.euro(money.total))
                    Text("Dienstfahrten und Arbeitsweg mit den Sätzen aus den Einstellungen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !periodExpenses.isEmpty {
                    let costs = CostSummary(periodExpenses)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Firmenauto – tatsächliche Kosten").font(.subheadline.weight(.semibold))
                        LabeledContent("Geschäftlicher Anteil", value: Fmt.euro(costs.total * km(.business) / total))
                        LabeledContent("Privater Anteil", value: Fmt.euro(costs.total * km(.privateTrip) / total))
                        if km(.commute) > 0 {
                            LabeledContent("Anteil Arbeitsweg", value: Fmt.euro(costs.total * km(.commute) / total))
                        }
                        Text("Kosten laut Belegen (\(Fmt.euro(costs.total))), aufgeteilt nach Kilometeranteilen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Was du absetzen kannst – zur Orientierung")
            } footer: {
                Text("Je nachdem, ob das Auto privat ist oder zum Betrieb gehört, gilt nur eine der beiden Rechnungen. \(AppInfo.disclaimer)")
            }
        }
    }

    @ViewBuilder private var openSection: some View {
        let open = periodTrips.filter(\.needsAttention).count
        if open > 0 {
            Section {
                Label("\(open) Fahrt\(open == 1 ? " ist" : "en sind") noch nicht vollständig. Bitte vor dem Export ergänzen.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var exportSection: some View {
        Section {
            Button { make { try ExportService.pdf(trips: periodTrips, period: period, audit: periodAudit, expenses: periodExpenses) } } label: {
                Label("PDF-Fahrtenbuch erstellen", systemImage: "doc.richtext")
            }
            Button { make { try ExportService.csv(trips: periodTrips, period: period) } } label: {
                Label("CSV für Excel / Steuerberater", systemImage: "tablecells")
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("\(exportURL.lastPathComponent) teilen / sichern", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("Export")
        } footer: {
            Text("Das PDF enthält alle Fahrten mit Kilometerständen, die Zusammenfassung und das vollständige Änderungsprotokoll. Bei Privatfahrten werden nur die Kilometer ausgewiesen.")
        }
    }

    private func sendToSevDesk(_ money: Reimbursement) async {
        isSending = true
        defer { isSending = false }
        do {
            guard AppSettings.sevDeskTravelAccount != nil else {
                sevDeskMessage = "Bitte zuerst unter Einstellungen › sevDesk das Konto für Fahrtgeld wählen."
                return
            }
            let pdf = try ExportService.pdf(trips: periodTrips, period: period, audit: periodAudit, expenses: periodExpenses)
            try await SevDeskSync.sendReimbursement(money, period: period, pdf: pdf)
            sevDeskMessage = "Entwurf angelegt – bitte in sevDesk prüfen und buchen."
        } catch {
            sevDeskMessage = error.localizedDescription
        }
    }

    private func shareRow(_ title: String, _ value: Double, _ total: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\((value / total).formatted(.percent.precision(.fractionLength(1)))) · \(Fmt.km(value))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: value, total: total).tint(color)
        }
    }

    private func make(_ build: () throws -> URL) {
        do { exportURL = try build() } catch { errorMessage = error.localizedDescription }
    }
}
