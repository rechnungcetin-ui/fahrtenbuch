import SwiftUI
import SwiftData

/// Fahrt nachtragen – z. B. wenn der Akku leer war. Wird als „nachgetragen“ gekennzeichnet und protokolliert.
struct ManualTripView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var start = Calendar.current.date(byAdding: .hour, value: -1, to: .now) ?? .now
    @State private var end = Date.now
    @State private var kmText = ""
    @State private var startAddress = ""
    @State private var endAddress = ""
    @State private var category: TripCategory = .business
    @State private var purpose = ""
    @State private var partner = ""
    @State private var reason = ""
    @State private var errorMessage: String?

    private var km: Double? { Double(kmText.replacingOccurrences(of: ",", with: ".")) }

    private var isValid: Bool {
        guard let km, km > 0, end > start, !reason.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return category != .business || !purpose.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Wann?") {
                    DatePicker("Abfahrt", selection: $start)
                    DatePicker("Ankunft", selection: $end, in: start...)
                }
                Section("Strecke") {
                    TextField("Startadresse", text: $startAddress, axis: .vertical)
                    TextField("Zieladresse", text: $endAddress, axis: .vertical)
                    TextField("Gefahrene Kilometer", text: $kmText).keyboardType(.decimalPad)
                }
                Section {
                    Picker("Fahrtart", selection: $category) {
                        ForEach(TripCategory.allCases.filter { $0 != .unassigned }) {
                            Label($0.label, systemImage: $0.symbol).tag($0)
                        }
                    }
                    if category == .business {
                        TextField("Reisezweck", text: $purpose, axis: .vertical)
                        TextField("Besuchte Firma / Geschäftspartner", text: $partner)
                    }
                } header: {
                    Text("Angaben zur Fahrt")
                } footer: {
                    Text(category.hint)
                }
                Section {
                    TextField("Grund (z. B. iPhone-Akku leer)", text: $reason)
                } header: {
                    Text("Warum nachgetragen?")
                } footer: {
                    Text("Nachgetragene Fahrten werden gekennzeichnet und im Änderungsprotokoll vermerkt. Liegen danach schon Fahrten, verschieben sich deren Kilometerstände – das geht nur, solange sie noch nicht festgeschrieben sind.")
                }
            }
            .navigationTitle("Fahrt nachtragen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Sichern", action: save).disabled(!isValid) }
            }
            .alert("Nachtragen nicht möglich", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        guard let km else { return }
        do {
            try TripLedger.addManualTrip(start: start, end: end, km: km, startAddress: startAddress, endAddress: endAddress,
                                         category: category, purpose: purpose, partner: partner, reason: reason, in: context)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
