import Foundation

/// Fahrtgeld (Kilometerpauschale) für einen Zeitraum.
///
/// - Dienstfahrten: jeder gefahrene Kilometer × Satz (Standard 0,30 €).
/// - Arbeitsweg (Wohnung ↔ erste Betriebs-/Tätigkeitsstätte): Entfernungspauschale – nur die einfache Strecke,
///   einmal pro Arbeitstag, volle Kilometer (Standard 0,38 € seit 2026). Alternativ: jeder gefahrene Kilometer.
struct Reimbursement {
    let businessKm: Double
    let businessAmount: Double
    let commuteDrivenKm: Double
    let commuteBillableKm: Double
    let commuteDays: Int
    let commuteAmount: Double
    let privateKm: Double
    let totalKm: Double

    var total: Double { businessAmount + commuteAmount }

    static var businessRate: Double { Double(AppSettings.rateBusinessCents) / 100 }
    static var commuteRate: Double { Double(AppSettings.rateCommuteCents) / 100 }

    init(trips: [Trip]) {
        func km(_ category: TripCategory) -> Double {
            trips.filter { $0.category == category }.reduce(0) { $0 + $1.distanceKm }
        }
        func cents(_ value: Double) -> Double { (value * 100).rounded() / 100 }

        totalKm = trips.reduce(0) { $0 + $1.distanceKm }
        privateKm = km(.privateTrip)
        businessKm = km(.business)
        businessAmount = cents(businessKm * Self.businessRate)

        let commutes = trips.filter { $0.category == .commute }
        commuteDrivenKm = km(.commute)
        let byDay = Dictionary(grouping: commutes) { Calendar.current.startOfDay(for: $0.startDate) }
        commuteDays = byDay.count

        if AppSettings.commutePerDrivenKm {
            commuteBillableKm = commuteDrivenKm
        } else {
            let fixed = AppSettings.commuteDistanceKm
            commuteBillableKm = byDay.values.reduce(0) { sum, dayTrips in
                sum + (fixed > 0 ? fixed : floor(dayTrips.map(\.distanceKm).min() ?? 0))
            }
        }
        commuteAmount = cents(commuteBillableKm * Self.commuteRate)
    }

    var commuteExplanation: String {
        AppSettings.commutePerDrivenKm
            ? "\(Fmt.km(commuteBillableKm)) × \(Fmt.euro(Self.commuteRate))"
            : "\(commuteDays) Tag\(commuteDays == 1 ? "" : "e"), \(Fmt.km(commuteBillableKm)) einfache Strecke × \(Fmt.euro(Self.commuteRate))"
    }
}
