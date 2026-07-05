import SwiftUI

/// Attribution, themes, and honesty about what this mode is.
struct ClassicAboutView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                themesSection
                attributionSection
                creditsSection
            }
            .navigationTitle("About")
        }
    }

    /// Themes are free. All of them. Always.
    private var themesSection: some View {
        Section {
            Picker("Theme", selection: $settings.theme) {
                ForEach(AppTheme.allCases) { theme in
                    HStack {
                        Circle().fill(theme.accent).frame(width: 14, height: 14)
                        Text(theme.displayName)
                    }
                    .tag(theme)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearanceOverride.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Themes — free, all of them")
        } footer: {
            Text("Applies to the whole app, both modes.")
        }
    }

    private var attributionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Inspired by MeshCore One")
                    .font(.headline)
                Text("This mode recreates the classic MeshCore companion workflow that MeshCore One (by Avi0n) does brilliantly. It is an independent, from-scratch implementation — no MeshCore One code (GPLv3) is included — sharing one radio connection with Fellship's rooms.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            Link(destination: URL(string: "https://github.com/Avi0n/MeshCoreOne")!) {
                Label("MeshCore One on GitHub", systemImage: "arrow.up.right.square")
            }
            Link(destination: URL(string: "https://github.com/sponsors/Avi0n")!) {
                Label("Support MeshCore One's developer", systemImage: "heart")
            }
        } header: {
            Text("Attribution")
        }
    }

    private var creditsSection: some View {
        Section {
            Link("MeshCore protocol & firmware — meshcore-dev (MIT)",
                 destination: URL(string: "https://github.com/meshcore-dev/MeshCore")!)
            Link("Protocol reference — liamcottle/meshcore.js (MIT)",
                 destination: URL(string: "https://github.com/liamcottle/meshcore.js")!)
            Link("Maps — MapLibre Native (BSD)",
                 destination: URL(string: "https://github.com/maplibre/maplibre-native")!)
            Link("Map tiles — OpenFreeMap / OpenStreetMap contributors",
                 destination: URL(string: "https://openfreemap.org")!)
            Link("Satellite imagery — NASA GIBS",
                 destination: URL(string: "https://www.earthdata.nasa.gov/engage/open-data-services-software/earthdata-developer-portal/gibs-api")!)
        } header: {
            Text("Built on")
        } footer: {
            Text("Fellship itself is public-domain software (Unlicense). MeshCore is a trademark of its respective owners; this app is an independent client and is not affiliated with or endorsed by the MeshCore project or MeshCore One.")
        }
    }
}
