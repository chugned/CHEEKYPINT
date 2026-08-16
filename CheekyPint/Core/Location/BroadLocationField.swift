import SwiftUI
import MapKit
import CheekyPintCore

/// The "Where's your local?" / "Broad location" field, shared by `ProfileSetupFlowView` and
/// `EditProfileView` so the one privacy-critical rule below lives in one place, not two.
///
/// Wired to `PlaceCompleter` (no location permission, ever — see that type's header) for
/// optional autocomplete over a plain `TextField` bound straight to `city`. Typed free text is
/// untouched by any of this: nothing here requires picking a suggestion, so typing "Graz" and
/// moving on to Next/Save works exactly as a bare `TextField` always did — there is no separate
/// commit step here the way `PlacePickerSheet` needs one, because there is no sheet to dismiss.
///
/// **The one rule this file exists to enforce.** `profiles.city` is documented, in the schema
/// and in this field's own on-screen copy, as a *broad* area only — never a street address
/// (`supabase/migrations/20260101000200_core_tables.sql`: "BROAD, user-entered location only —
/// never a street address, never inferred from activity"). Autocomplete is the one thing that
/// can put a street address into this field *without the user having typed it themselves*,
/// because `MKLocalSearchCompleter` configured for `.address` results happily returns
/// house-level addresses alongside bare place names. Two defences, of deliberately unequal
/// strength:
/// - `isLikelyStreetLevel` filters the suggestion list itself — cheap, and known to leak (a
///   place name that happens to contain a digit is filtered out too aggressively; conversely
///   nothing here can guarantee every genuine address is caught). This is a courtesy, not the
///   guarantee — see that function's own doc.
/// - `reduceToBroadArea` is the guarantee. Tapping a suggestion resolves it via `MKLocalSearch`
///   and rebuilds the stored value from the resolved placemark's `locality`/
///   `administrativeArea`/`country` **alone** — `thoroughfare` and `subThoroughfare` are not
///   parameters to that function and appear nowhere in this file, so there is no code path by
///   which either can reach `city`, no matter what the suggestion list showed or what the
///   resolved placemark carries. A resolution failure (offline, or a completion `MKLocalSearch`
///   can't back up) leaves `city` exactly as it was rather than falling back to the completion's
///   own unreduced title/subtitle — contrast `PlacePickerSheet.resolve`, which *can* fall back to
///   raw text on failure, because that picker has no such restriction to begin with.
struct BroadLocationField: View {
    @Binding var city: String
    var placeholder: String = "e.g. Graz, Austria"
    var fieldAccessibilityLabel: String = "Broad location"
    let identifier: String

    @State private var completer = PlaceCompleter(resultTypes: .address)
    @State private var isResolving = false

    private static let sanitizer = ProfileTextSanitizer()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            TextField(placeholder, text: cityBinding)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(fieldAccessibilityLabel)
            // No fixed frame/max-height on this block, deliberately: `docs/ACCESSIBILITY_AUDIT.md`
            // already found one bounded-height suggestion list (`PostCommentsSheet`'s mention
            // popover) that left room for only one row at accessibility XXL. Letting this grow
            // with its content and rely on the surrounding scroll container is what keeps a tall
            // list from clipping instead of just relocating the same bug here.
            if !broadSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(broadSuggestions.enumerated()), id: \.offset) { index, completion in
                        if index > 0 { Divider() }
                        suggestionRow(completion, index: index)
                    }
                }
                .padding(.vertical, Theme.Spacing.xxs)
                .background(Theme.Palette.backgroundSecondary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            if isResolving {
                HStack(spacing: Theme.Spacing.xs) {
                    ProgressView().tint(Theme.Palette.accent)
                    Text("Looking that up…")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Looking that up")
            }
        }
    }

    /// The suggestion list, filtered through `isLikelyStreetLevel` — see this file's header for
    /// why that filter is a courtesy, not the guarantee.
    private var broadSuggestions: [MKLocalSearchCompletion] {
        completer.results.filter { !Self.isLikelyStreetLevel(title: $0.title) }
    }

    /// Every keystroke updates `city` (the real, saved value) and the completer's query together,
    /// deterministically, in the same call — not via a separate `.onChange`, whose ordering
    /// relative to `selectSuggestion`'s own later statements isn't something to depend on.
    private var cityBinding: Binding<String> {
        Binding(
            get: { city },
            set: { newValue in
                city = newValue
                completer.query = newValue
            }
        )
    }

    private func suggestionRow(_ completion: MKLocalSearchCompletion, index: Int) -> some View {
        Button {
            Task { await selectSuggestion(completion) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(completion.title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if !completion.subtitle.isEmpty {
                    Text(completion.subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isResolving)
        .accessibilityIdentifier("\(identifier)-result-\(index)")
        .accessibilityLabel(completion.subtitle.isEmpty ? completion.title : "\(completion.title), \(completion.subtitle)")
    }

    // MARK: - Actions

    /// Resolve the tapped completion and reduce it to a broad area before ever touching `city`.
    /// See this file's header for why a failed resolve leaves `city` untouched rather than
    /// falling back to the completion's own text.
    private func selectSuggestion(_ completion: MKLocalSearchCompletion) async {
        guard !isResolving else { return }
        isResolving = true
        defer { isResolving = false }

        let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        let placemark = response?.mapItems.first?.placemark

        let reduced = Self.reduceToBroadArea(
            locality: placemark?.locality,
            administrativeArea: placemark?.administrativeArea,
            country: placemark?.country
        )
        let clamped = Self.sanitizer.sanitizeCity(reduced)
        guard !clamped.isEmpty else { return } // nothing broad-safe came back; leave `city` alone

        city = clamped
        completer.query = "" // collapse the list — the field now shows the reduced value alone
    }

    // MARK: - Pure helpers (unit tested; see BroadLocationFieldTests)

    /// A cheap, known-imperfect signal that a completion is street-level rather than a bare place
    /// name: any digit in the title, front or back — "123 Main St" and "Hauptplatz 1" both trip
    /// it, which covers a house number in either order. Filters the suggestion *list only*;
    /// `reduceToBroadArea` is what actually guarantees nothing street-level reaches `city` — see
    /// this file's header. A place whose real name contains a digit (rare) is filtered out too;
    /// that false positive is the accepted cost of a filter this cheap.
    static func isLikelyStreetLevel(title: String) -> Bool {
        title.rangeOfCharacter(from: .decimalDigits) != nil
    }

    /// The structural guarantee. Reads only locality, administrative area, and country —
    /// `thoroughfare`/`subThoroughfare` are not parameters here, so no call site can pass them in
    /// and no future edit can leak them in without changing this signature first.
    ///
    /// Locality wins when present; administrative area is a fallback *for* it, not an addition to
    /// it — resolving "Hauptplatz 1, Graz, Steiermark, Austria" reduces to "Graz, Austria", not
    /// "Graz, Steiermark, Austria", matching what this field already shows for a bare city typed
    /// by hand today. Administrative area only surfaces on its own when a placemark has no
    /// locality at all (e.g. a search that resolves to a region rather than a city).
    static func reduceToBroadArea(locality: String?, administrativeArea: String?, country: String?) -> String {
        let area = nonEmpty(locality) ?? nonEmpty(administrativeArea)
        return [area, nonEmpty(country)].compactMap { $0 }.joined(separator: ", ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
