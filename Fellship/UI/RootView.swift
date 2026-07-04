import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: RoomEngine
    /// Invites the user swiped away — they stay reachable from the Rooms tab.
    @State private var snoozedInviteIDs: Set<String> = []

    var body: some View {
        TabView {
            MapScreen()
                .tabItem { Label("Map", systemImage: "map") }
            RoomListView()
                .tabItem { Label("Rooms", systemImage: "person.3") }
                .badge(pendingInviteCount)
            NearbyView()
                .tabItem { Label("Nearby", systemImage: "dot.radiowaves.left.and.right") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: onboardingBinding) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
        .sheet(item: incomingInviteBinding) { invite in
            InviteAcceptSheet(invite: invite)
                .presentationDetents([.medium])
        }
    }

    private var pendingInviteCount: Int {
        engine.invites.filter { $0.state == .received }.count
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(get: { !settings.onboardingComplete },
                set: { settings.onboardingComplete = !$0 })
    }

    /// Surfaces the newest unanswered invite as a sheet; swiping it away
    /// snoozes it rather than looping it forever.
    private var incomingInviteBinding: Binding<Invite?> {
        Binding(get: {
            engine.invites
                .filter { $0.state == .received && !$0.isOutgoing && !snoozedInviteIDs.contains($0.id) }
                .sorted { $0.createdAt > $1.createdAt }
                .first
        }, set: { newValue in
            if newValue == nil,
               let current = engine.invites.first(where: {
                   $0.state == .received && !$0.isOutgoing && !snoozedInviteIDs.contains($0.id)
               }) {
                snoozedInviteIDs.insert(current.id)
            }
        })
    }
}
