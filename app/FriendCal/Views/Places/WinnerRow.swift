import SwiftUI
import MapKit
import FriendCalCore

/// The place the lock froze (design PL-7), attached directly under the invite card: pin, name, address
/// and a 44pt "Open in Maps". It takes the stored `winner`, never the board's current leader: after the
/// lock the server's frozen result is authoritative.
struct WinnerRow: View {
    let place: Place

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill").font(.title2)
                .foregroundStyle(DesignTokens.Colors.accentHover).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let address = place.address {
                    Text(address).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(["Winner", place.name, place.address].compactMap { $0 }.joined(separator: ". ") + ".")
            .accessibilityIdentifier("places.winner.name")
            Spacer(minLength: 8)
            Button { Self.openInMaps(place) } label: {
                Text("Open in Maps").textStyle(.label).foregroundStyle(DesignTokens.Colors.accentHover)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(place.name) in Maps")
            .accessibilityIdentifier("places.winner.maps")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(DesignTokens.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).stroke(DesignTokens.Colors.border, lineWidth: 1))
    }

    /// Builds the item from the stored coordinate and name, so Maps opens on exactly the place voted for.
    static func openInMaps(_ place: Place) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)))
        item.name = place.name
        item.openInMaps()
    }
}

#Preview("Winner row") {
    WinnerRow(place: Place(proposalID: UUID(), suggestedBy: UUID(), name: "Cafe Lola", address: "2108 E Cesar Chavez St",
                           latitude: 30.2569, longitude: -97.7167, createdAt: .now))
        .padding().background(DesignTokens.Colors.background)
}
