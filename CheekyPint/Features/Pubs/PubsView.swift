import SwiftUI
import MapKit
import CheekyPintCore

/// The Pubs tab — a hub for sessions and pub search (master prompt §6, §11).
struct PubsView: View {
    @Environment(\.container) private var container
    @State private var activeSession: PubSession?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                Section("Pub session") {
                    if let activeSession {
                        NavigationLink { ActiveSessionView(session: activeSession) } label: {
                            Label("Your current session", systemImage: "person.3.fill")
                        }
                    } else {
                        NavigationLink { CreateSessionView() } label: {
                            Label("Start a session", systemImage: "plus.circle.fill")
                        }
                        NavigationLink { JoinByCodeView() } label: {
                            Label("Join by code", systemImage: "number")
                        }
                    }
                }
                Section("Find a pub") {
                    NavigationLink { PubBrowseView() } label: {
                        Label("Search pubs", systemImage: "magnifyingglass")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.backgroundPrimary)
            .navigationTitle("Pubs")
        }
        .task {
            if !loaded { activeSession = try? await container.sessions.fetchActiveSession(); loaded = true }
        }
    }
}

/// Browse/search pubs and view details.
struct PubBrowseView: View {
    @Environment(\.container) private var container
    @State private var query = ""
    @State private var results: [PubSearchResult] = []
    @State private var isSearching = false

    var body: some View {
        List {
            if isSearching { ProgressView().tint(Theme.Palette.accent) }
            if results.isEmpty && !isSearching {
                StatusView(systemImage: "magnifyingglass", title: "Search for a pub",
                           message: "Find your local by name or city.")
            }
            ForEach(results) { result in
                NavigationLink { PubDetailView(result: result) } label: {
                    VStack(alignment: .leading) {
                        Text(result.name).foregroundStyle(Theme.Palette.textPrimary)
                        if let address = result.address {
                            Text(address).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.backgroundPrimary)
        .navigationTitle("Search pubs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Pub name or city")
        .onSubmit(of: .search) { Task { await search() } }
    }

    private func search() async {
        isSearching = true; defer { isSearching = false }
        results = (try? await container.pubs.search(matching: query, near: nil)) ?? []
    }
}

/// A pub's public details with a map. A user's own visit history is private and not shown here.
struct PubDetailView: View {
    let result: PubSearchResult

    var body: some View {
        let coordinate = CLLocationCoordinate2D(latitude: result.latitude, longitude: result.longitude)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                    latitudinalMeters: 500, longitudinalMeters: 500))) {
                    Marker(result.name, coordinate: coordinate)
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))

                Text(result.name).font(Theme.Typography.largeTitle).foregroundStyle(Theme.Palette.textPrimary)
                if let address = result.address {
                    Label(address, systemImage: "mappin").font(Theme.Typography.callout).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .pubBackground()
        .navigationTitle(result.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
