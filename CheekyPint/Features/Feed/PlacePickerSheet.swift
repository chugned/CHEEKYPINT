import SwiftUI
import MapKit
import CheekyPintCore

/// What the composer attaches to a post: a label always, and a pub id only when the picked
/// result resolved to a matched venue. A bare city like "Prague" has a label and no pub row.
struct SelectedPlace: Equatable, Sendable {
    let label: String
    let pubID: UUID?
}

/// Tag a post with a place — a city or a specific pub — without ever asking for location
/// permission (master requirement, verbatim: "you can just add prague, and thats it so the
/// locations can be cities too but also pubs"). Typed free text is always a complete, valid
/// place on its own; a completion below it is an optional shortcut, never a requirement.
///
/// `PubsRepository.search` is deliberately not reused here: it drives `MKLocalSearch` with
/// `MKPointOfInterestFilter(including: [.brewery, .restaurant, .nightlife])`, which is right for
/// "find a pub near me" but wrong for a bare city lookup — "Prague" would come back as
/// restaurants *in* Prague, not the city. `MKLocalSearchCompleter` with `resultTypes = [.address,
/// .pointOfInterest]` and no `region` returns both without needing a coordinate.
///
/// Deliberately does not depend on CoreLocation's permission surface — no location manager, no
/// authorization request, ever. See `PlaceCompleter`'s header for the concurrency shape.
struct PlacePickerSheet: View {
    let onSelect: (SelectedPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container

    @State private var query = ""
    @State private var completer = PlaceCompleter()
    @State private var isResolving = false
    @State private var errorMessage: String?

    private static let sanitizer = ProfileTextSanitizer()

    private static let pubCategories: Set<MKPointOfInterestCategory> = [
        .brewery, .restaurant, .nightlife, .cafe, .bakery,
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("City or pub name", text: $query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("place-search-field")
                        .accessibilityLabel("Search for a city or pub")
                        .onChange(of: query) { _, newValue in completer.query = newValue }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.Palette.warning)
                }
                // Always reachable in one tap when there's typed text — this is the row that
                // makes "just add Prague, and that's it" true, independent of anything MapKit
                // returns (or fails to return).
                if let typed = Self.freeTextPlace(from: query) {
                    Button {
                        select(typed)
                    } label: {
                        Label {
                            Text("Use \u{201C}\(typed.label)\u{201D}")
                        } icon: {
                            Image(systemName: "checkmark.circle")
                        }
                    }
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .accessibilityIdentifier("place-use-typed")
                    .accessibilityLabel("Use \(typed.label)")
                }
                ForEach(Array(completer.results.enumerated()), id: \.offset) { index, completion in
                    resultRow(completion, index: index)
                }
                if isResolving {
                    HStack {
                        Spacer(minLength: 0)
                        ProgressView().tint(Theme.Palette.accent)
                        Spacer(minLength: 0)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.backgroundPrimary)
            .navigationTitle("Add a location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("place-picker-cancel")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Rows

    private func resultRow(_ completion: MKLocalSearchCompletion, index: Int) -> some View {
        Button {
            Task { await resolve(completion) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(completion.title).foregroundStyle(Theme.Palette.textPrimary)
                if !completion.subtitle.isEmpty {
                    Text(completion.subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
        .disabled(isResolving)
        .accessibilityIdentifier("place-result-\(index)")
        .accessibilityLabel(completion.subtitle.isEmpty ? completion.title : "\(completion.title), \(completion.subtitle)")
    }

    // MARK: - Actions

    private func select(_ place: SelectedPlace) {
        onSelect(place)
        dismiss()
    }

    /// Completions carry no coordinate or POI category, so resolving one means asking
    /// `MKLocalSearch` for the full `MKMapItem`. Any failure past this point — the search itself,
    /// an invalid coordinate, or `persist` — falls back to the completion's own text as a
    /// label-only place. A failed lookup must never block posting.
    private func resolve(_ completion: MKLocalSearchCompletion) async {
        guard !isResolving else { return }
        guard let fallbackLabel = Self.clampedLabel(completion.title.isEmpty ? completion.subtitle : completion.title) else {
            return // an empty title and subtitle can't become a place; nothing to do
        }

        isResolving = true
        errorMessage = nil
        defer { isResolving = false }

        let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let mapItem = response?.mapItems.first,
              Self.isPubCategory(mapItem.pointOfInterestCategory)
        else {
            select(SelectedPlace(label: fallbackLabel, pubID: nil))
            return
        }

        let placemark = mapItem.placemark
        guard CLLocationCoordinate2DIsValid(placemark.coordinate) else {
            select(SelectedPlace(label: fallbackLabel, pubID: nil))
            return
        }

        let result = PubSearchResult(
            name: mapItem.name ?? fallbackLabel,
            address: placemark.title,
            city: placemark.locality,
            countryCode: placemark.isoCountryCode,
            latitude: placemark.coordinate.latitude,
            longitude: placemark.coordinate.longitude,
            phoneNumber: mapItem.phoneNumber,
            url: mapItem.url
        )

        guard let pub = try? await container.pubs.persist(result) else {
            select(SelectedPlace(label: fallbackLabel, pubID: nil))
            return
        }

        select(SelectedPlace(label: Self.clampedLabel(pub.name) ?? fallbackLabel, pubID: pub.id))
    }

    // MARK: - Pure helpers (unit tested; see PlacePickerTests)

    /// The one shared clamp for every label this picker can produce — typed free text and a
    /// resolved venue's name alike — so neither can silently diverge from `create_post`'s
    /// `left(v_label, 80)` (`20260811000500_rpc_feed_posts.sql`). `nil` means "not a usable
    /// label" (empty after trimming), not "the clamp failed."
    static func clampedLabel(_ raw: String) -> String? {
        let trimmed = sanitizer.sanitize(raw, allowNewlines: false, maxLength: ComposePostSheet.placeLabelLimit)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The product requirement this whole picker exists to satisfy: typed free text alone —
    /// "Prague", nothing else — is a complete, valid place. Never requires picking a suggestion.
    static func freeTextPlace(from raw: String) -> SelectedPlace? {
        clampedLabel(raw).map { SelectedPlace(label: $0, pubID: nil) }
    }

    /// Whether a resolved `MKMapItem`'s POI category counts as a pub (worth a
    /// `PubsRepository.persist` call) rather than a plain place. `nil` — no category, e.g. a
    /// city or a bare address — is not a pub.
    static func isPubCategory(_ category: MKPointOfInterestCategory?) -> Bool {
        guard let category else { return false }
        return pubCategories.contains(category)
    }
}
