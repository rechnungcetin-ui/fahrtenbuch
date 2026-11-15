import Foundation
import SwiftData

enum ExpenseKind: String, Codable, CaseIterable, Identifiable {
    case fuel, charging, service, repair, tires, insurance, tax, leasing, depreciation, care, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fuel: "Tanken"
        case .charging: "Laden (E-Auto)"
        case .service: "Wartung / Inspektion"
        case .repair: "Reparatur"
        case .tires: "Reifen"
        case .insurance: "Versicherung"
        case .tax: "Kfz-Steuer"
        case .leasing: "Leasing / Finanzierung"
        case .depreciation: "Abschreibung (AfA)"
        case .care: "Pflege / Wäsche"
        case .other: "Sonstiges"
        }
    }

    var symbol: String {
        switch self {
        case .fuel: "fuelpump.fill"
        case .charging: "bolt.car.fill"
        case .service: "wrench.and.screwdriver.fill"
        case .repair: "hammer.fill"
        case .tires: "circle.dashed"
        case .insurance: "shield.fill"
        case .tax: "building.columns.fill"
        case .leasing: "creditcard.fill"
        case .depreciation: "chart.line.downtrend.xyaxis"
        case .care: "sparkles"
        case .other: "ellipsis.circle.fill"
        }
    }

    var hasQuantity: Bool { self == .fuel || self == .charging }
    var quantityUnit: String { self == .charging ? "kWh" : "Liter" }
}

/// Kfz-Beleg (Tanken, Werkstatt, Versicherung …) – optional mit Foto und Kilometerstand laut Tacho.
@Model
final class Expense {
    var id: UUID = UUID()
    var date: Date = Date.now
    var kindRaw: String = ExpenseKind.fuel.rawValue
    var amountCents: Int = 0
    /// Liter bzw. kWh
    var quantity: Double = 0
    var isFullTank: Bool = true
    /// Kilometerstand laut Tacho, 0 = nicht angegeben
    var odometer: Int = 0
    var vendor: String = ""
    var note: String = ""
    @Attribute(.externalStorage) var receiptImage: Data?
    var createdAt: Date = Date.now
    /// ID des Entwurfsbelegs in sevDesk (leer = noch nicht übertragen).
    var sevDeskVoucherID: String = ""

    init(date: Date = .now, kind: ExpenseKind = .fuel) {
        self.id = UUID()
        self.date = date
        self.kindRaw = kind.rawValue
        self.createdAt = .now
    }

    var kind: ExpenseKind {
        get { ExpenseKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var amount: Double {
        get { Double(amountCents) / 100 }
        set { amountCents = Int((newValue * 100).rounded()) }
    }
}

/// Kostenübersicht für einen Zeitraum.
struct CostSummary {
    let total: Double
    struct Item: Identifiable {
        let kind: ExpenseKind
        let amount: Double
        var id: String { kind.rawValue }
    }

    let byKind: [Item]
    let fuelLiters: Double

    init(_ expenses: [Expense]) {
        total = expenses.reduce(0) { $0 + $1.amount }
        byKind = ExpenseKind.allCases.compactMap { kind in
            let sum = expenses.filter { $0.kind == kind }.reduce(0) { $0 + $1.amount }
            return sum > 0 ? Item(kind: kind, amount: sum) : nil
        }
        fuelLiters = expenses.filter { $0.kind == .fuel }.reduce(0) { $0 + $1.quantity }
    }

    func costPerKm(_ km: Double) -> Double? { km > 0 && total > 0 ? total / km : nil }
    func consumption(_ km: Double) -> Double? { km > 0 && fuelLiters > 0 ? fuelLiters / km * 100 : nil }
}

extension Fmt {
    static func euro(_ value: Double) -> String {
        value.formatted(.currency(code: "EUR").locale(locale))
    }

    /// Liest „1.234,56“, „12,5“ oder „12.50“ ein.
    static func parseDecimal(_ text: String) -> Double? {
        var s = text.replacingOccurrences(of: "€", with: "").replacingOccurrences(of: " ", with: "")
        if s.contains(",") && s.contains(".") { s = s.replacingOccurrences(of: ".", with: "") }
        s = s.replacingOccurrences(of: ",", with: ".")
        return Double(s)
    }
}
