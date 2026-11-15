import SwiftUI
import MapKit

struct TripMapView: View {
    let points: [RoutePoint]

    var body: some View {
        let coordinates = points.map(\.coordinate)
        Map(initialPosition: .automatic) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let first = coordinates.first {
                Marker("Start", systemImage: "flag.fill", coordinate: first).tint(.green)
            }
            if coordinates.count > 1, let last = coordinates.last {
                Marker("Ziel", systemImage: "flag.checkered", coordinate: last).tint(.red)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .overlay {
            if coordinates.isEmpty {
                Text("Keine Routendaten").font(.caption).padding(8).background(.thinMaterial, in: Capsule())
            }
        }
    }
}
