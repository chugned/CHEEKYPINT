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
    @State private var friendActivities: [FriendBeerActivity] = []
    @State private var selectedPub: PubSearchResult?
    @State private var detailPub: PubSearchResult?
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
                await loadFriendActivity()
                await refresh()
            }
        }
        .onChange(of: selectedPub) { _, pub in
            if let pub { detailPub = pub }
        }
        .sheet(item: $detailPub) { pub in
            PubLiveDetailSheet(pub: pub, userCoordinate: userCoordinate)
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
                ForEach(friendActivitiesWithCoordinates) { activity in
                    if let coordinate = activity.currentCoordinate {
                        Annotation(activity.displayName, coordinate: coordinate) {
                            VStack(spacing: 2) {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .padding(6)
                                    .background(Theme.Palette.warning, in: Circle())
                                Text(activity.displayName)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            .accessibilityLabel("\(activity.displayName), \(activity.nowText)")
                        }
                    }
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

            if !friendActivities.isEmpty {
                Section("Mates right now") {
                    ForEach(friendActivities) { activity in
                        Button {
                            if let coordinate = activity.currentCoordinate {
                                focus(on: coordinate)
                            }
                        } label: {
                            FriendActivityMapRow(
                                activity: activity,
                                avatarURL: container.avatarURL(for: activity.avatarPath)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ForEach(sortedPubs) { pub in
                Button {
                    selectedPub = pub
                    focus(on: pub)
                    detailPub = pub
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

    private var friendActivitiesWithCoordinates: [FriendBeerActivity] {
        friendActivities.filter { $0.currentCoordinate != nil }
    }

    private func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            await loadFriendActivity()
            let current = try await location.requestOneShotLocation()
            userCoordinate = current.coordinate
            position = .region(MKCoordinateRegion(
                center: current.coordinate,
                latitudinalMeters: 4200,
                longitudinalMeters: 4200
            ))
            pubs = try await container.pubs.nearbyPubs(near: current.coordinate, limit: 60)
            selectedPub = nil
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

    private func focus(on coordinate: CLLocationCoordinate2D) {
        position = .region(MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 900,
            longitudinalMeters: 900
        ))
    }

    private func loadFriendActivity() async {
        friendActivities = (try? await container.friendActivity.beerActivities()) ?? []
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

private struct PubLiveDetailSheet: View {
    let pub: PubSearchResult
    let userCoordinate: CLLocationCoordinate2D?

    @Environment(\.dismiss) private var dismiss
    @State private var lookAroundScene: MKLookAroundScene?
    @State private var lookAroundLoaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    lookAroundPanel
                    identityPanel
                    openingTimesPanel
                    actionPanel
                    miniMap
                }
                .padding(Theme.Spacing.lg)
            }
            .pubBackground()
            .navigationTitle(pub.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: pub.id) { await loadLookAround() }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var lookAroundPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Inside check")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Palette.textPrimary)

            if let scene = lookAroundScene {
                LookAroundPreview(scene: .constant(scene))
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            } else {
                ZStack {
                    Theme.Palette.backgroundSecondary
                    VStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: lookAroundLoaded ? "photo.on.rectangle.angled" : "hourglass")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Theme.Palette.beer)
                        Text(lookAroundLoaded ? "No Apple Look Around image for this pub yet." : "Loading pub image")
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(Theme.Spacing.md)
                }
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            }
        }
    }

    private var identityPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(pub.name)
                .font(Theme.Typography.largeTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            if let address = pub.address {
                Label(address, systemImage: "mappin")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            if let distanceText {
                Label(distanceText, systemImage: "figure.walk")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var openingTimesPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label("Opening times", systemImage: "clock.fill")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Apple Maps does not provide opening hours to this build. Use Maps or the pub website for live hours before walking over.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .coasterCard()
    }

    private var actionPanel: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Button {
                openInMaps()
            } label: {
                Label("Open in Apple Maps", systemImage: "map.fill")
            }
            .buttonStyle(PintButtonStyle())

            if let url = pub.url {
                Link(destination: url) {
                    Label("Open pub website", systemImage: "safari.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if let phoneURL {
                Link(destination: phoneURL) {
                    Label("Call pub", systemImage: "phone.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var miniMap: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: pub.coordinate,
            latitudinalMeters: 700,
            longitudinalMeters: 700
        ))) {
            Marker(pub.name, systemImage: "mug.fill", coordinate: pub.coordinate)
                .tint(Theme.Palette.accent)
            UserAnnotation()
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }

    private var distanceText: String? {
        guard let userCoordinate else { return nil }
        let meters = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
            .distance(from: CLLocation(latitude: pub.latitude, longitude: pub.longitude))
        if meters < 1000 { return "\(Int(meters.rounded())) m away" }
        return String(format: "%.1f km away", meters / 1000)
    }

    private var phoneURL: URL? {
        guard let phone = pub.phoneNumber else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel://\(digits)")
    }

    private func loadLookAround() async {
        lookAroundLoaded = false
        lookAroundScene = nil
        let request = MKLookAroundSceneRequest(coordinate: pub.coordinate)
        lookAroundScene = try? await request.scene
        lookAroundLoaded = true
    }

    private func openInMaps() {
        let placemark = MKPlacemark(coordinate: pub.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = pub.name
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
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

private struct FriendActivityMapRow: View {
    let activity: FriendBeerActivity
    let avatarURL: URL?

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            RemoteAvatar(url: avatarURL, name: activity.displayName, size: 38)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack {
                    Text(activity.displayName)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    if activity.currentCoordinate != nil {
                        Image(systemName: "location.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.accent)
                            .accessibilityHidden(true)
                    }
                }
                Text(activity.nowText)
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .lineLimit(2)
                if let latest = activity.recentLogs.first {
                    Text("Last: \(latest.beerName)\(latest.pubName.map { " at \($0)" } ?? "")")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
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
