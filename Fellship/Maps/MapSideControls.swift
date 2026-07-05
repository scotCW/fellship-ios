import SwiftUI

/// The floating control stack on the side of every map: base-layer picker,
/// north-up reset, and recenter — the standard companion-app map controls.
struct MapSideControls: View {
    @EnvironmentObject private var settings: AppSettings

    var onResetNorth: () -> Void
    var onRecenter: () -> Void
    /// Optional extra button (e.g. Fellship's frame-the-room).
    var extra: (icon: String, label: String, action: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Menu {
                Picker("Base map", selection: $settings.tileSource) {
                    ForEach(TileSourceKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Choose base map")

            Button(action: onResetNorth) {
                Image(systemName: "location.north.line")
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Point north up")

            Button(action: onRecenter) {
                Image(systemName: "location")
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Center on my position")

            if let extra {
                Button(action: extra.action) {
                    Image(systemName: extra.icon)
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel(extra.label)
            }
        }
    }
}
