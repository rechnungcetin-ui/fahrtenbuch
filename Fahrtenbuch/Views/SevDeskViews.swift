import SwiftUI

struct SevDeskSettingsView: View {
    @State private var token = SevDeskClient.token ?? ""
    @State private var status: String?
    @State private var isBusy = false
    @State private var accounts: [SevDeskAccount] = []
    @State private var travelAccount = AppSettings.sevDeskTravelAccount
    @State private var vehicleAccount = AppSettings.sevDeskVehicleAccount

    var body: some View {
        Form {
            Section {
                SecureField("API-Token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Verbindung testen") { Task { await connect() } }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                if isBusy { ProgressView() }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Zugang")
            } footer: {
                Text("Den Token findest du in sevDesk unter Einstellungen › Benutzer › dein Benutzer › API-Token. Er wird nur im Schlüsselbund dieses iPhones gespeichert.")
            }

            Section {
                NavigationLink {
                    SevDeskAccountPicker(title: "Konto für Fahrtgeld", accounts: accounts, selection: $travelAccount)
                } label: {
                    LabeledContent("Fahrtgeld", value: travelAccount?.label ?? "wählen")
                }
                NavigationLink {
                    SevDeskAccountPicker(title: "Konto für Kfz-Belege", accounts: accounts, selection: $vehicleAccount)
                } label: {
                    LabeledContent("Tank-/Kfz-Belege", value: vehicleAccount?.label ?? "wählen")
                }
            } header: {
                Text("Buchungskonten")
            } footer: {
                Text("Üblich: Fahrtgeld auf „Reisekosten Unternehmer Fahrtkosten“ (SKR03 4673 / SKR04 6673), Tankbelege auf „Laufende Kfz-Betriebskosten“ (4530 / 6530). Alle Belege landen in sevDesk als Entwurf – gebucht wird erst, wenn du sie dort prüfst und bestätigst.")
            }
            .disabled(accounts.isEmpty)
        }
        .navigationTitle("sevDesk")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: travelAccount) { AppSettings.sevDeskTravelAccount = travelAccount }
        .onChange(of: vehicleAccount) { AppSettings.sevDeskVehicleAccount = vehicleAccount }
        .task { if SevDeskClient.isConfigured { await connect() } }
    }

    private func connect() async {
        isBusy = true
        defer { isBusy = false }
        SevDeskClient.token = token
        do {
            let version = try await SevDeskClient.bookkeepingVersion()
            guard version.hasPrefix("2") else { throw SevDeskError.unsupportedVersion(version) }
            accounts = try await SevDeskClient.expenseAccounts()
            status = "Verbunden ✓ (\(accounts.count) Konten geladen)"
        } catch {
            accounts = []
            status = error.localizedDescription
        }
    }
}

struct SevDeskAccountPicker: View {
    let title: String
    let accounts: [SevDeskAccount]
    @Binding var selection: SevDeskAccount?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [SevDeskAccount] {
        search.isEmpty ? accounts : accounts.filter { $0.label.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(filtered) { account in
            Button {
                selection = account
                dismiss()
            } label: {
                HStack {
                    Text(account.label).foregroundStyle(.primary)
                    Spacer()
                    if account.id == selection?.id { Image(systemName: "checkmark") }
                }
            }
        }
        .searchable(text: $search, prompt: "Kontonummer oder Name")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Gemeinsame Sende-Logik für Belege und Fahrtgeld.
@MainActor
enum SevDeskSync {
    static func send(_ expense: Expense) async throws {
        guard let account = AppSettings.sevDeskVehicleAccount else { throw SevDeskError.noToken }
        let file = expense.receiptImage.map { (data: $0, name: "Beleg_\(Fmt.date.string(from: expense.date)).jpg", mimeType: "image/jpeg") }
        let quantity = expense.quantity > 0 ? " · \(Fmt.kmValue(expense.quantity)) \(expense.kind.quantityUnit)" : ""
        let odometer = expense.odometer > 0 ? " · Km-Stand \(expense.odometer)" : ""
        expense.sevDeskVoucherID = try await SevDeskClient.createDraftVoucher(
            date: expense.date,
            supplier: expense.vendor.isEmpty ? expense.kind.label : expense.vendor,
            description: "\(expense.kind.label) \(Fmt.date.string(from: expense.date))",
            amount: expense.amount, taxRate: expense.kind.defaultTaxRate, account: account,
            comment: "\(expense.kind.label) \(AppSettings.vehicleDisplayName)\(quantity)\(odometer)", file: file)
    }

    /// Fahrtgeld eines Monats als Eigenbeleg mit dem Fahrtenbuch-PDF als Anhang.
    static func sendReimbursement(_ money: Reimbursement, period: ExportPeriod, pdf: URL) async throws {
        guard let account = AppSettings.sevDeskTravelAccount else { throw SevDeskError.noToken }
        let lastDay = period.lastDay
        let id = try await SevDeskClient.createDraftVoucher(
            date: min(lastDay, .now), supplier: "Eigenbeleg Fahrtkosten",
            description: "Fahrtgeld \(period.title)",
            amount: money.total, taxRate: 0, account: account,
            comment: "Kilometerpauschale \(period.title): \(Fmt.km(money.businessKm)) Dienstfahrten"
                + (money.commuteAmount > 0 ? ", Arbeitsweg \(money.commuteExplanation)" : "")
                + " – Nachweis: Fahrtenbuch im Anhang",
            file: (data: try Data(contentsOf: pdf), name: pdf.lastPathComponent, mimeType: "application/pdf"))
        var sent = AppSettings.sevDeskSentPeriods
        sent[period.fileStem] = id
        AppSettings.sevDeskSentPeriods = sent
    }
}
