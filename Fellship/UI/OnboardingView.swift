import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var notifications: NotificationService
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var name = ""

    var body: some View {
        VStack {
            TabView(selection: $page) {
                welcome.tag(0)
                privacy.tag(1)
                setup.tag(2)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        }
        .background(Color(.systemBackground))
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 72))
                .foregroundStyle(.teal)
            Text("Fellship")
                .font(.system(size: 40, weight: .bold, design: .rounded))
            Text("Rooms for your crew, off the grid.\nMeshCore radios, offline maps, no servers, no accounts.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                withAnimation { page = 1 }
            } label: {
                Text("Get started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("How your data works")
                .font(.title.bold())
            row("externaldrive", "Everything stays on devices",
                "Rooms, messages and keys live only on members' phones and travel radio-to-radio. No cloud, ever.")
            row("mappin.slash", "Location is yours to share",
                "Positions are shared per room, only with members, only when that room's sharing is on.")
            row("trash", "Deleted means deleted",
                "Remove a room or the app and its data is gone for good — there's no backup or recovery, on purpose.")
            row("cross.case", "Not a safety device",
                "Mesh coverage is best-effort. Don't rely on Fellship as your only lifeline in the backcountry.")
            Spacer()
            Button {
                withAnimation { page = 2 }
            } label: {
                Text("Understood").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 28)
    }

    private var setup: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Set yourself up")
                .font(.title.bold())
            TextField("Your display name", text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 40)
            VStack(spacing: 10) {
                Button {
                    location.requestWhenInUseAuthorization()
                } label: {
                    Label("Allow location", systemImage: "location")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    notifications.requestAuthorization()
                } label: {
                    Label("Allow notifications", systemImage: "bell")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 40)
            Text("You can connect a radio in Settings — or try demo mode first, no hardware needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            VStack(spacing: 10) {
                Button {
                    finish(demo: true)
                } label: {
                    Label("Explore in demo mode", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    finish(demo: false)
                } label: {
                    Text("I have a radio — take me in")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.teal)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func finish(demo: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            settings.displayName = trimmed
        }
        settings.onboardingComplete = true
        if demo {
            Task { await app.enableDemoMode() }
        }
        dismiss()
    }
}
