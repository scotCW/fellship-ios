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
    @State private var showAddContact = false
    @State private var showMyCard = false

    var body: some View {
        NavigationStack {
            Group {
                if engine.nearbyContacts.isEmpty {
                    VStack(spacing: 16) {
                        EmptyStateView(systemImage: "person.2",
                                       title: "No nodes yet",
                                       message: "Nodes appear automatically when their adverts are heard.")
                        HStack(spacing: 12) {
                            Button {
                                showAddContact = true
                            } label: {
                                Label("Add by code", systemImage: "qrcode.viewfinder")
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                showMyCard = true
                            } label: {
                                Label("Share mine", systemImage: "qrcode")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    nodeList
                }
            }
            .navigationTitle("Nodes")
            .searchable(text: $searchText, prompt: "Search nodes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showAddContact = true
                        } label: {
                            Label("Add contact by code", systemImage: "qrcode.viewfinder")
                        }
                        Button {
                            showMyCard = true
                        } label: {
                            Label("Share my contact card", systemImage: "qrcode")
                        }
                        Divider()
                        Picker("Sort", selection: $sort) {
                            ForEach(NodeSort.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        Button {
                            Task { await engine.refreshContacts() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(!app.transportState.isConnected)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Node actions: add, share, sort, refresh")
                }
            }
            .sheet(isPresented: $showAddContact) {
                AddContactSheet()
            }
            .sheet(isPresented: $showMyCard) {
                MyContactCardSheet()
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

/// Scan or paste a contact code, then save it to the radio.
struct AddContactSheet: View {
    @EnvironmentObject private var classic: ClassicStore
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var feedback: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                QRScannerView { code in
                    guard !busy else { return }
                    submit(code)
                }
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)

                Text("Scan another node's contact code, or paste one below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("Paste contact code", text: $pasted)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Add") { submit(pasted) }
                        .buttonStyle(.borderedProminent)
                        .disabled(pasted.isEmpty || busy)
                }
                .padding(.horizontal)

                if let feedback {
                    Text(feedback)
                        .font(.callout)
                        .foregroundStyle(feedback.hasPrefix("Added") ? .green : .red)
                }
                Spacer()
            }
            .navigationTitle("Add contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func submit(_ code: String) {
        busy = true
        Task {
            if let error = await classic.importContactCard(code) {
                feedback = error
                busy = false
            } else {
                feedback = "Added to your radio"
                try? await Task.sleep(nanoseconds: 700_000_000)
                dismiss()
            }
        }
    }
}

/// Shows the user's own contact card as a QR for others to scan.
struct MyContactCardSheet: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let info = app.selfInfo,
                   let image = QRSupport.generate(from: cardPayload(info)) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    Text(info.name.isEmpty ? "Your radio" : info.name)
                        .font(.headline)
                    Text("Have another Fellship user scan this from Nodes → + → Add contact by code to save you to their radio.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                } else {
                    EmptyStateView(systemImage: "qrcode",
                                   title: "No radio connected",
                                   message: "Connect a radio to share your contact card.")
                }
                Spacer()
            }
            .padding(.top, 28)
            .navigationTitle("My contact card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func cardPayload(_ info: MeshCore.SelfInfo) -> String {
        ContactCard.encode(publicKey: info.publicKey,
                           type: info.advertType,
                           flags: 0,
                           name: settings.displayName.isEmpty ? info.name : settings.displayName,
                           coordinate: info.advertCoordinate)
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
