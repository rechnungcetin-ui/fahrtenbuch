import SwiftUI

extension TripCategory {
    var color: Color {
        switch self {
        case .unassigned: .orange
        case .business: .blue
        case .privateTrip: .green
        case .commute: .purple
        }
    }
}

struct CategoryBadge: View {
    let category: TripCategory

    var body: some View {
        Label(category.label, systemImage: category.symbol)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(category.color.opacity(0.15), in: Capsule())
            .foregroundStyle(category.color)
    }
}

struct TripRow: View {
    let trip: Trip

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: trip.category.symbol)
                .font(.title3)
                .foregroundStyle(trip.category.color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(trip.timeRangeText).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(trip.distanceText).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Text(trip.displayStart).lineLimit(1)
                Text("→ \(trip.displayEnd)").lineLimit(1)
                HStack(spacing: 6) {
                    CategoryBadge(category: trip.category)
                    if !trip.purpose.isEmpty && trip.category == .business {
                        Text(trip.purpose).font(.caption).lineLimit(1)
                    }
                    Spacer()
                    if trip.status == .finalized {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    } else if trip.needsAttention {
                        Text("Bitte ergänzen").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
    }
}
