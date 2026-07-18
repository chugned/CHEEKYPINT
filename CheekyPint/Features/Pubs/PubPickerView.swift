import SwiftUI
import CoreLocation
import CheekyPintCore

/// Pick a pub when logging (master prompt §11). Manual name/city search always works; a "Near
/// me" action requests When-In-Use location only on demand, with a manual fallback if declined.
struct PubPickerView: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Pub) -> Void

    @State private var query = ""
    @State private var results: [PubSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var location = LocationService()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { Task { await searchNearby() } } label: {
                        Label("Search near me", systemImage: "location.fill")
                    }
                    if location.status == .denied {
                        Text("Search for a pub manually, or enable location access in Settings.")
                            .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                if isSearching { ProgressView().tint(Theme.Palette.accent) }
                if let errorMessage { Text(errorMessage).foregroundStyle(Theme.Palette.warning) }
                ForEach(results) { result in
                    Button { Task { await select(result) } } label: { row(result) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.backgroundPrimary)
            .navigationTitle("Choose a pub")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Pub name or city")
            .onSubmit(of: .search) { Task { await search(near: nil) } }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ result: PubSearchResult) -> some View {
        VStack(alignment: .leading) {
            Text(result.name).foregroundStyle(Theme.Palette.textPrimary)
            if let address = result.address {
                Text(address).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    private func searchNearby() async {
        do {
            let loc = try await location.requestOneShotLocation()
            await search(near: loc.coordinate)
        } catch {
            errorMessage = "Couldn't get your location. Try searching by name."
        }
    }

    private func search(near coordinate: CLLocationCoordinate2D?) async {
        isSearching = true; errorMessage = nil
        defer { isSearching = false }
        do { results = try await container.pubs.search(matching: query, near: coordinate) }
        catch { errorMessage = "No pubs found. Try a different search." }
    }

    private func select(_ result: PubSearchResult) async {
        do {
            let pub = try await container.pubs.persist(result)
            onSelect(pub)
            dismiss()
        } catch let error as SupabaseError { errorMessage = error.friendlyMessage }
        catch { errorMessage = "Couldn't save that pub." }
    }
}
