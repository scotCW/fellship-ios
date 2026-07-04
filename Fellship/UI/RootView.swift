import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: RoomEngine
    /// Invites the user swiped away — they stay reachable from the Rooms tab.
    @State private var snoozedInviteIDs: Set<String> = []
    /// Initial tab; overridable at launch (`-launchTab 2`) for screenshots
    /// and UI automation.
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "launchTab")

    var body: some View {
        TabView(selection: $selectedTab) {
            MapScreen()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(0)
            RoomListView()
                .tabItem { Label("Rooms", systemImage: "person.3") }
                .badge(pendingInviteCount)
                .tag(1)
            NearbyView()
                .tabItem { Label("Nearby", systemImage: "dot.radiowaves.left.and.right") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
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
