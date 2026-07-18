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
                    NavigationLink { PubLiveMapView() } label: {
                        Label("Live pub map", systemImage: "map.fill")
                    }
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

/// A current-location map of nearby places where a pint is a realistic option.
struct PubLiveMapView: View {
    @Environment(\.container) private var container

    @State private var location = LocationService()
    @State private var userCoordinate: CLLocationCoordinate2D?
    @State private var pubs: [PubSearchResult] = []
    @State private var selectedPub: PubSearchResult?
    @State private var position: MapCameraPosition = .automatic
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            map
                .frame(height: 360)
            nearbyList
        }
        .pubBackground()
        .navigationTitle("Live pub map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refresh() } } label: {
                    Image(systemName: "location.fill")
                }
                .disabled(isLoading)
                .accessibilityLabel("Refresh nearby pubs")
            }
        }
        .task {
            if pubs.isEmpty && !isLoading {
                await refresh()
            }
        }
    }

    private var map: some View {
        ZStack(alignment: .bottomLeading) {
            Map(position: $position, selection: $selectedPub) {
                UserAnnotation()
                ForEach(pubs) { pub in
                    Marker(pub.name, systemImage: "mug.fill", coordinate: pub.coordinate)
                        .tint(Theme.Palette.accent)
                        .tag(pub)
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }

            if isLoading {
                ProgressView("Finding pints nearby")
                    .font(Theme.Typography.caption)
                    .tint(Theme.Palette.accent)
                    .padding(Theme.Spacing.sm)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .padding(Theme.Spacing.md)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(Theme.Spacing.sm)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .padding(Theme.Spacing.md)
            }
        }
    }

    private var nearbyList: some View {
        List {
            if !pubs.isEmpty {
                Text("\(pubs.count) closest pint options near you")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .listRowBackground(Color.clear)
            }

            if pubs.isEmpty && !isLoading {
                StatusView(
                    systemImage: location.status == .denied ? "location.slash.fill" : "map.fill",
                    title: location.status == .denied ? "Location is off" : "No nearby pubs yet",
                    message: location.status == .denied
                        ? "Enable location access in Settings, or use manual pub search."
                        : "Tap the location button to scan nearby pubs."
                )
            }

            ForEach(sortedPubs) { pub in
                Button {
                    selectedPub = pub
                    focus(on: pub)
                } label: {
                    PubMapRow(
                        pub: pub,
                        distanceText: distanceText(to: pub),
                        isSelected: selectedPub == pub
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var sortedPubs: [PubSearchResult] {
        guard let userCoordinate else { return pubs }
        return pubs.sorted {
            distance(from: userCoordinate, to: $0.coordinate) < distance(from: userCoordinate, to: $1.coordinate)
        }
    }

    private func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let current = try await location.requestOneShotLocation()
            userCoordinate = current.coordinate
            position = .region(MKCoordinateRegion(
                center: current.coordinate,
                latitudinalMeters: 4200,
                longitudinalMeters: 4200
            ))
            pubs = try await container.pubs.nearbyPubs(near: current.coordinate, limit: 60)
            selectedPub = pubs.first
        } catch {
            errorMessage = "Couldn't get nearby pubs from your location. Try again outside or use manual search."
        }
    }

    private func focus(on pub: PubSearchResult) {
        position = .region(MKCoordinateRegion(
            center: pub.coordinate,
            latitudinalMeters: 900,
            longitudinalMeters: 900
        ))
    }

    private func distanceText(to pub: PubSearchResult) -> String? {
        guard let userCoordinate else { return nil }
        let meters = distance(from: userCoordinate, to: pub.coordinate)
        if meters < 1000 {
            return "\(Int(meters.rounded())) m"
        }
        return String(format: "%.1f km", meters / 1000)
    }

    private func distance(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }
}

private struct PubMapRow: View {
    let pub: PubSearchResult
    let distanceText: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "mug.fill")
                .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.beer)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack {
                    Text(pub.name)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if let distanceText {
                        Text(distanceText)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
                if let address = pub.address {
                    Text(address)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
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
