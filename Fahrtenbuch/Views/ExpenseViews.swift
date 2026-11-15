import SwiftUI
import SwiftData
import PhotosUI

struct ExpenseListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]
    @Query(sort: \Trip.startDate) private var trips: [Trip]
    @State private var showNew = false
    @State private var editing: Expense?

    private struct MonthGroup: Identifiable {
        let month: Date
        let items: [Expense]
        var id: Date { month }
    }

    private var grouped: [MonthGroup] {
        Dictionary(grouping: expenses) { expense -> Date in
            Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: expense.date)) ?? expense.date
        }
        .sorted { $0.key > $1.key }
        .map { MonthGroup(month: $0.key, items: $0.value) }
    }

    private var year: Int { Calendar.current.component(.year, from: .now) }

    var body: some View {
        NavigationStack {
            List {
                let yearExpenses = expenses.filter { Calendar.current.component(.year, from: $0.date) == year }
                let yearKm = trips.filter { Calendar.current.component(.year, from: $0.startDate) == year && $0.status != .recording }
                    .reduce(0) { $0 + $1.distanceKm }
                let summary = CostSummary(yearExpenses)

                if !yearExpenses.isEmpty {
                    Section("Fahrzeugkosten \(String(year))") {
                        LabeledContent("Gesamt", value: Fmt.euro(summary.total))
                        if let perKm = summary.costPerKm(yearKm) {
                            LabeledContent("Kosten je km", value: Fmt.euro(perKm))
                        }
                        if let consumption = summary.consumption(yearKm) {
                            LabeledContent("Verbrauch (ca.)", value: "\(Fmt.kmValue(consumption)) l/100 km")
                        }
                    }
                }

                if expenses.isEmpty {
                    ContentUnavailableView("Noch keine Belege", systemImage: "doc.text.viewfinder",
                                           description: Text("Scanne Tank- und Werkstattbelege. Mit dem Tachostand vom Beleg bleibt dein Kilometerstand exakt – und du kennst deine echten Kosten je Kilometer."))
                }

                ForEach(grouped) { group in
                    Section {
                        ForEach(group.items) { expense in
                            Button { editing = expense } label: { ExpenseRow(expense: expense) }
                                .foregroundStyle(.primary)
                        }
                        .onDelete { offsets in
                            for index in offsets { context.delete(group.items[index]) }
                            try? context.save()
                        }
                    } header: {
                        HStack {
                            Text(group.month.formatted(.dateTime.month(.wide).year()))
                            Spacer()
                            Text(Fmt.euro(group.items.reduce(0) { $0 + $1.amount }))
                        }
                    }
                }
            }
            .navigationTitle("Belege")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNew = true } label: { Label("Beleg erfassen", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showNew) { ExpenseEditView(expense: nil) }
            .sheet(item: $editing) { ExpenseEditView(expense: $0) }
        }
    }
}

private struct ExpenseRow: View {
    let expense: Expense

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: expense.kind.symbol).font(.title3).foregroundStyle(.blue).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.vendor.isEmpty ? expense.kind.label : expense.vendor).font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Text(Fmt.date.string(from: expense.date))
                    if !expense.vendor.isEmpty { Text("· \(expense.kind.label)") }
                    if expense.quantity > 0 { Text("· \(Fmt.kmValue(expense.quantity)) \(expense.kind.quantityUnit)") }
                    if expense.odometer > 0 { Text("· \(expense.odometer) km") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if expense.receiptImage != nil { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
            Text(Fmt.euro(expense.amount)).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }
}

struct ExpenseEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let expense: Expense?

    @State private var kind: ExpenseKind
    @State private var date: Date
    @State private var amountText: String
    @State private var quantityText: String
    @State private var fullTank: Bool
    @State private var odometerText: String
    @State private var vendor: String
    @State private var note: String
    @State private var imageData: Data?
    @State private var adjustOdometer = true
    @State private var showScanner = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isReading = false
    @State private var isSending = false
    @State private var sevDeskMessage: String?

    init(expense: Expense?) {
        self.expense = expense
        _kind = State(initialValue: expense?.kind ?? .fuel)
        _date = State(initialValue: expense?.date ?? .now)
        _amountText = State(initialValue: expense.map { Fmt.kmValue($0.amount) } ?? "")
        _quantityText = State(initialValue: (expense?.quantity ?? 0) > 0 ? Fmt.kmValue(expense?.quantity ?? 0) : "")
        _fullTank = State(initialValue: expense?.isFullTank ?? true)
        _odometerText = State(initialValue: (expense?.odometer ?? 0) > 0 ? String(expense?.odometer ?? 0) : "")
        _vendor = State(initialValue: expense?.vendor ?? "")
        _note = State(initialValue: expense?.note ?? "")
        _imageData = State(initialValue: expense?.receiptImage)
    }

    private var amount: Double? { Fmt.parseDecimal(amountText) }
    private var odometer: Int? { Int(odometerText).flatMap { $0 > 0 ? $0 : nil } }

    /// Abgleich nur bei neuen Belegen von heute – sonst wäre der Tachostand schon veraltet.
    private var canAdjustOdometer: Bool {
        guard expense == nil, let odometer, Calendar.current.isDateInToday(date),
              !TripRecorder.shared.isRecording else { return false }
        return odometer != AppSettings.odometerKm
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if DocumentScanner.isAvailable {
                        Button { showScanner = true } label: { Label("Beleg scannen", systemImage: "doc.text.viewfinder") }
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Foto aus Mediathek wählen", systemImage: "photo")
                    }
                    if isReading {
                        HStack { ProgressView(); Text("Beleg wird gelesen …").foregroundStyle(.secondary) }
                    }
                    if let imageData, let image = UIImage(data: imageData) {
                        HStack {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Spacer()
                            Button("Entfernen", role: .destructive) { self.imageData = nil }.buttonStyle(.borderless)
                        }
                    }
                } footer: {
                    Text("Betrag, Menge, Datum und Anbieter werden automatisch erkannt – bitte kurz prüfen.")
                }

                Section("Beleg") {
                    Picker("Art", selection: $kind) {
                        ForEach(ExpenseKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    DatePicker("Datum", selection: $date, in: ...Date.now, displayedComponents: .date)
                    LabeledContent("Betrag (€)") {
                        TextField("0,00", text: $amountText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    if kind.hasQuantity {
                        LabeledContent("Menge (\(kind.quantityUnit))") {
                            TextField("0,00", text: $quantityText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                        if kind == .fuel { Toggle("Vollgetankt", isOn: $fullTank) }
                    }
                    TextField("Anbieter (Tankstelle, Werkstatt …)", text: $vendor)
                    TextField("Notiz", text: $note, axis: .vertical)
                }

                Section {
                    LabeledContent("Km-Stand laut Tacho") {
                        TextField("optional", text: $odometerText).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    if canAdjustOdometer, let odometer {
                        let diff = odometer - AppSettings.odometerKm
                        Toggle("App-Kilometerstand angleichen (\(diff > 0 ? "+" : "")\(diff) km)", isOn: $adjustOdometer)
                    }
                } header: {
                    Text("Kilometerstand")
                } footer: {
                    Text("Stand der App: \(AppSettings.odometerKm) km. Der Tachostand vom Beleg gleicht kleine GPS-Abweichungen aus – die Korrektur wird protokolliert.")
                }

                if let expense, SevDeskClient.isConfigured {
                    Section {
                        if !expense.sevDeskVoucherID.isEmpty {
                            Label("In sevDesk als Entwurf angelegt (Beleg \(expense.sevDeskVoucherID))", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button { Task { await sendToSevDesk(expense) } } label: {
                                Label("Als Entwurf an sevDesk senden", systemImage: "paperplane")
                            }
                            .disabled(isSending)
                        }
                        if let sevDeskMessage { Text(sevDeskMessage).font(.caption).foregroundStyle(.secondary) }
                    } header: {
                        Text("sevDesk")
                    } footer: {
                        Text("Gesendet wird der gespeicherte Stand des Belegs. Der Steuersatz ist vorbelegt und in sevDesk änderbar.")
                    }
                }
            }
            .navigationTitle(expense == nil ? "Beleg erfassen" : "Beleg bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save).disabled((amount ?? 0) <= 0)
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner { image in Task { await handle(image) } }.ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        await handle(image)
                    }
                }
            }
        }
    }

    private func handle(_ image: UIImage) async {
        let prepared = image.resized(maxSide: 1600)
        imageData = prepared.jpegData(compressionQuality: 0.5)
        isReading = true
        let result = await ReceiptReader.read(prepared)
        isReading = false

        // Nur leere Felder füllen – bereits Eingetipptes bleibt.
        if amountText.isEmpty, let value = result.amount { amountText = Fmt.kmValue(value) }
        if quantityText.isEmpty, let value = result.quantity { quantityText = Fmt.kmValue(value) }
        if vendor.isEmpty, let value = result.vendor { vendor = value }
        if expense == nil, let value = result.date { date = value }
    }

    private func sendToSevDesk(_ expense: Expense) async {
        isSending = true
        defer { isSending = false }
        guard AppSettings.sevDeskVehicleAccount != nil else {
            sevDeskMessage = "Bitte zuerst unter Einstellungen › sevDesk das Konto für Kfz-Belege wählen."
            return
        }
        do {
            try await SevDeskSync.send(expense)
            try? context.save()
            sevDeskMessage = "Entwurf angelegt – bitte in sevDesk prüfen und buchen."
        } catch {
            sevDeskMessage = error.localizedDescription
        }
    }

    private func save() {
        guard let amount else { return }
        let target = expense ?? Expense()
        if expense == nil { context.insert(target) }

        target.kind = kind
        target.date = date
        target.amount = amount
        target.quantity = kind.hasQuantity ? (Fmt.parseDecimal(quantityText) ?? 0) : 0
        target.isFullTank = fullTank
        target.odometer = odometer ?? 0
        target.vendor = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        target.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        target.receiptImage = imageData

        if canAdjustOdometer, adjustOdometer, let odometer {
            try? TripLedger.correctOdometer(to: odometer, in: context)
        }
        try? context.save()
        dismiss()
    }
}
