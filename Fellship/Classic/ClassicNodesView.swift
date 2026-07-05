import SwiftUI

/// The Nodes screen, companion-app style: search, type filters, favorites,
/// sort — every radio the mesh has heard, at a glance.
struct ClassicNodesView: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var classic: ClassicStore
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var app: AppState

    enum NodeFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case companions = "Companions"
        case repeaters = "Repeaters"
        case favorites = "Favorites"
        var id: String { rawValue }
    }

    enum NodeSort: String, CaseIterable, Identifiable {
        case recent = "Recently heard"
        case name = "Name"
        case distance = "Distance"
        var id: String { rawValue }
    }

    @State private var searchText = ""
    @State private var filter: NodeFilter = .all
    @State private var sort: NodeSort = .recent

    var body: some View {
        NavigationStack {
            Group {
                if engine.nearbyContacts.isEmpty {
                    EmptyStateView(systemImage: "person.2",
                                   title: "No nodes yet",
                                   message: "Nodes appear automatically when their adverts are heard. Send yours from Tools to announce yourself.")
                } else {
                    nodeList
                }
            }
            .navigationTitle("Nodes")
            .searchable(text: $searchText, prompt: "Search nodes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(NodeSort.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        Divider()
                        Button {
                            Task { await engine.refreshContacts() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(!app.transportState.isConnected)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Sort and refresh")
                }
            }
        }
    }

    private var nodeList: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(NodeFilter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            List(filteredAndSorted, id: \.publicKey) { contact in
                NavigationLink {
                    ClassicContactDetailView(contact: contact)
                } label: {
                    NodeRow(contact: contact,
                            distance: distanceTo(contact),
                            isFavorite: classic.favorites.contains(contact.publicKey.prefix(6).hexEncoded))
                }
                .swipeActions(edge: .leading) {
                    Button {
                        classic.toggleFavorite(contact.publicKey.prefix(6).hexEncoded)
                    } label: {
                        Label("Favorite", systemImage: "star")
                    }
                    .tint(.yellow)
                }
            }
            .listStyle(.plain)
        }
    }

    private var filteredAndSorted: [MeshCore.Contact] {
        var nodes = engine.nearbyContacts

        switch filter {
        case .all: break
        case .companions: nodes = nodes.filter { $0.type != 2 }
        case .repeaters: nodes = nodes.filter { $0.type == 2 }
        case .favorites:
            nodes = nodes.filter { classic.favorites.contains($0.publicKey.prefix(6).hexEncoded) }
        }

        if !searchText.isEmpty {
            nodes = nodes.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.publicKey.hexEncoded.hasPrefix(searchText.lowercased())
            }
        }

        switch sort {
        case .recent:
            nodes.sort { $0.lastAdvert > $1.lastAdvert }
        case .name:
            nodes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .distance:
            nodes.sort { (distanceTo($0) ?? .infinity) < (distanceTo($1) ?? .infinity) }
        }
        return nodes
    }

    private func distanceTo(_ contact: MeshCore.Contact) -> Double? {
        guard contact.coordinate.isPlausible,
              let mine = location.lastFix?.coordinate else { return nil }
        return GeoMath.distanceMeters(mine, contact.coordinate)
    }
}

private struct NodeRow: View {
    @EnvironmentObject private var settings: AppSettings
    let contact: MeshCore.Contact
    let distance: Double?
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: contact.type == 2
                  ? "antenna.radiowaves.left.and.right.circle.fill"
                  : "person.circle.fill")
                .font(.title2)
                .foregroundStyle(contact.type == 2 ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(contact.name.isEmpty
                         ? "Radio \(contact.publicKey.prefix(4).hexEncoded)"
                         : contact.name)
                        .font(.headline)
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                HStack(spacing: 6) {
                    Text(contact.type == 2 ? "Repeater" : "Companion")
                    Text("·")
                    Text(Format.ago(contact.lastAdvert))
                    if contact.outPathLength > 0 {
                        Text("·")
                        Text("\(contact.outPathLength) hop\(contact.outPathLength == 1 ? "" : "s")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let distance {
                Text(Format.distance(distance, units: settings.units))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
