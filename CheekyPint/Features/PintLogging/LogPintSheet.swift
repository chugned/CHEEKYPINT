import SwiftUI
import CheekyPintCore

/// The retry-safety rule behind `LogPintSheet.log(_:)`, pulled out to a pure function so it can be
/// unit tested without the view's `@Environment(\.container)` / `@Environment(\.dismiss)`
/// dependencies. Reuses `pending`'s key when it belongs to the *same* beer — a genuine retry the
/// server should dedupe — otherwise mints a fresh key via `generate` for a new pending attempt.
func resolveIdempotencyKey(
    for beerID: String,
    pending: (beerID: String, key: String)?,
    generate: () -> String
) -> (key: String, pending: (beerID: String, key: String)) {
    if let pending, pending.beerID == beerID {
        return (pending.key, pending)
    }
    let key = generate()
    return (key, (beerID: beerID, key: key))
}

/// The tap-to-log sheet for a pint (master prompt §7). Tapping a beer row logs it immediately —
/// there is no separate confirm step. Idempotency is tracked per pending attempt, not per sheet:
/// the first tap on a beer generates a fresh key; if that save fails and the *same* beer is tapped
/// again, the retry reuses that same key so the server's dedupe RPC returns the existing entry
/// instead of creating a second one. The key is cleared once that beer's save succeeds, and a tap
/// on a *different* beer always gets its own fresh key. `isSaving` blocks re-entrant taps while a
/// request is in flight.
struct LogPintSheet: View {
    let onLogged: (PintEntry) async -> Void

    private static let sanitizer = ProfileTextSanitizer()

    /// `pint_entries.private_note`'s own bound: `char_length(private_note) <= 280` (a CHECK
    /// constraint), mirrored by `create_pint_entry`'s `left(…, 280)`.
    static let noteColumnLimit = 280

    /// What is left of that 280 for the user's own words, once the longest `[Beer: …]` line the
    /// catalog can prepend and the space joining them are accounted for.
    ///
    /// Derived rather than hard-coded, so adding a beer with a longer name or glass note tightens
    /// this automatically instead of silently pushing a note that used to fit past the column bound.
    /// It is one limit for all 98 beers rather than one per beer: the beer is not chosen until the
    /// user taps a row, and a counter whose limit jumped around as they scrolled would be worse than
    /// a slightly conservative one.
    static let noteLimit = noteColumnLimit - 1 - (
        BeerCatalog.beers
            .map { sanitizer.sanitizedLength(BeerCatalog.beerLine(for: $0), allowNewlines: false) }
            .max() ?? 0
    )

    /// How long the note will be **once stored**, in the code points Postgres counts. Measured with
    /// `allowNewlines: false` because the column genuinely cannot hold a line break (see
    /// `BeerCatalog.diaryNote`), so a typed newline becomes a space here rather than being counted
    /// and then deleted server-side.
    static func noteLength(of raw: String) -> Int {
        sanitizer.sanitizedLength(raw, allowNewlines: false)
    }

    /// Logging is blocked past the limit rather than letting `left(…, 280)` drop the tail — the same
    /// rule the composers, the report sheet and the profile screens follow.
    static func noteWithinLimit(_ raw: String) -> Bool {
        noteLength(of: raw) <= noteLimit
    }

    /// The note as it will be sent: Trojan-Source-stripped, whitespace-collapsed, single-line.
    static func sanitizedNote(_ raw: String) -> String {
        sanitizer.sanitize(raw, allowNewlines: false, maxLength: noteLimit)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container

    @State private var serving: ServingType = .default
    @State private var customVolume = "500"
    @State private var alcoholFree = false
    @State private var occurredAt = Date()
    @State private var note = ""
    @State private var beerSearch = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDetails = false

    // Keyed by beer, not by sheet lifetime: a failed save leaves this set so a retry tap on the
    // *same* beer reuses the key (server dedupes it); a tap on a different beer gets a fresh one.
    @State private var pendingKey: (beerID: String, key: String)?

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.Palette.warning)
                        .accessibilityIdentifier("log-pint-error")
                }
                // Deliberately outside `detailsSection`'s DisclosureGroup, which is collapsed by
                // default: the note gate disables every beer row, so if the only explanation lived
                // inside the collapsed group, taps would silently do nothing.
                if isNoteOverLimit {
                    Text(verbatim: "Note too long: \(noteLength)/\(Self.noteLimit). Shorten it to log a beer.")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.warning)
                        .accessibilityIdentifier("log-pint-note-too-long")
                        .accessibilityLabel("Note too long: \(noteLength) of \(Self.noteLimit) characters")
                }
                detailsSection
                beerSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.backgroundPrimary)
            .navigationTitle("Beer evidence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("log-pint-cancel")
                        .accessibilityLabel("Cancel")
                }
            }
            .overlay { if isSaving { ProgressView().tint(Theme.Palette.accent) } }
        }
        .presentationDetents([.medium, .large])
    }

    private var beerSection: some View {
        Section("Tap a beer to log it") {
            TextField("Search the world's beer fridge", text: $beerSearch)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("log-pint-beer-search")
                .accessibilityLabel("Search beers")

            // Form rows are lazy, so all 98 cost nothing until scrolled into view.
            //
            // Tapping a row IS the submit action here — there is no separate confirm button — so the
            // note's length gate has to disable the rows, the way Post/Send is disabled elsewhere.
            ForEach(filteredBeers) { beer in
                BeerRow(beer: beer, isDisabled: isSaving || isNoteOverLimit) {
                    Task { await log(beer) }
                }
            }
        }
    }

    /// Everything that used to be its own section. Collapsed by default so the common case is
    /// one tap; whatever is set here applies to the next beer tapped.
    private var detailsSection: some View {
        Section {
            DisclosureGroup("Details", isExpanded: $showDetails) {
                Picker("Size", selection: $serving) {
                    ForEach(ServingType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if serving == .custom {
                    TextField("Millilitres", text: $customVolume)
                        .keyboardType(.numberPad)
                }
                Toggle("Alcohol-free", isOn: $alcoholFree)
                    .tint(Theme.Palette.accent)
                DatePicker("Time", selection: $occurredAt, in: ...Date(),
                           displayedComponents: [.date, .hourAndMinute])
                TextField("Private note, just for you...", text: $note, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("log-pint-note")
                    .accessibilityLabel("Private note")
                HStack {
                    Spacer(minLength: 0)
                    // `verbatim:` — plain interpolation goes through LocalizedStringKey, which
                    // applies the locale's digit grouping and renders a counter as "0/1.000" on a
                    // German device. Same reason as the two composers and the report sheet.
                    Text(verbatim: "\(noteLength)/\(Self.noteLimit)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(isNoteOverLimit ? Theme.Palette.warning : Theme.Palette.textSecondary)
                        .accessibilityIdentifier("log-pint-note-counter")
                        .accessibilityLabel("\(noteLength) of \(Self.noteLimit) characters used")
                }
            }
        } footer: {
            Text("Applies to the next beer you tap.")
        }
    }

    private var noteLength: Int { Self.noteLength(of: note) }

    private var isNoteOverLimit: Bool { !Self.noteWithinLimit(note) }

    private func log(_ beer: BeerChoice) async {
        // The rows are already disabled past the limit; re-checked here for the same reason every
        // other write surface re-checks its gate — `.disabled` is a render-time answer, and this one
        // decides whether the tail of the note survives.
        guard !isSaving, Self.noteWithinLimit(note) else { return }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        // Reuse the pending key only when this is a retry of the *same* beer — the server's
        // idempotent RPC recognises the repeated key and returns the existing entry instead of
        // creating a duplicate. Any other beer (first attempt, or a different beer entirely)
        // gets a fresh key. See `resolveIdempotencyKey` for the (unit-tested) rule itself.
        let (rawKey, newPending) = resolveIdempotencyKey(for: beer.id, pending: pendingKey) {
            IdempotencyKey.generate().rawValue
        }
        pendingKey = newPending
        let key = IdempotencyKey(rawValue: rawKey)
        let volume = serving == .custom ? Double(customVolume) : nil
        // Sanitised, not merely trimmed: this text is stored, returned by the RPC and included in
        // the Art. 15 export, and a trim leaves zero-width runs and bidi overrides untouched.
        let cleanNote = Self.sanitizedNote(note)
        do {
            let entry = try await container.diary.createPint(
                idempotencyKey: key,
                occurredAt: occurredAt,
                serving: serving,
                volumeMl: volume,
                alcoholFree: alcoholFree,
                pubID: nil,
                sessionID: nil,
                note: BeerCatalog.diaryNote(for: beer, userNote: cleanNote)
            )
            pendingKey = nil
            container.analytics.track(.pintSaved)
            Haptics.success()
            dismiss()
            try? await Task.sleep(for: .milliseconds(280))
            await onLogged(entry)
        } catch let error as SupabaseError {
            errorMessage = error.friendlyMessage
        } catch {
            errorMessage = "Couldn't save that beer. Please try again."
        }
    }

    private var filteredBeers: [BeerChoice] {
        let query = beerSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return BeerCatalog.beers }
        return BeerCatalog.beers.filter { beer in
            [beer.name, beer.nickname, beer.country, beer.style, beer.glassNote]
                .joined(separator: " ")
                .lowercased()
                .contains(query)
        }
    }
}

struct BeerChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let country: String
    let style: String
    let nickname: String
    let glassNote: String
    let roast: String
}

enum BeerCatalog {
    static let beers: [BeerChoice] = [
        beer(
            "puntigamer",
            name: "Puntigamer",
            country: "Austria",
            style: "Lager",
            nickname: "Graz passport",
            glassNote: "Bright gold in a branded glass with a proper white cap.",
            roast: "For when somebody says, 'just one' and immediately orders snacks."
        ),
        beer(
            "stiegl",
            name: "Stiegl",
            country: "Austria",
            style: "Lager",
            nickname: "Salzburg diplomat",
            glassNote: "Clear amber-gold, tidy foam, looks like it has weekend plans.",
            roast: "Polite enough for parents, suspicious enough for the group chat."
        ),
        beer(
            "ottakringer",
            name: "Ottakringer Helles",
            country: "Austria",
            style: "Helles",
            nickname: "Vienna alibi",
            glassNote: "Pale golden helles in a clean glass, bottle standing nearby like a witness.",
            roast: "The official beverage of 'I am only staying for half an hour.'"
        ),
        beer(
            "pilsner",
            name: "Pilsner Urquell",
            country: "Czech Republic",
            style: "Pilsner",
            nickname: "Crispy Czech homework",
            glassNote: "Deep gold in a tall glass with dense white foam.",
            roast: "Ordered by the mate who suddenly becomes a lager professor."
        ),
        beer(
            "guinness",
            name: "Guinness",
            country: "Ireland",
            style: "Stout",
            nickname: "Curtains closed",
            glassNote: "Dark stout body with that creamy beige head doing all the PR.",
            roast: "Counts as a beer, a meal, and a personality test."
        ),
        beer(
            "hoegaarden",
            name: "Hoegaarden",
            country: "Belgium",
            style: "Witbier",
            nickname: "Cloudy holiday mode",
            glassNote: "Hazy straw beer in a chunky white-beer glass.",
            roast: "For when your pint wants to wear linen trousers."
        ),
        worldBeer("augustiner-helles", "Augustiner Lagerbier Hell", "Germany", "Helles", "Munich homework", "Clear golden lager with a soft white foam cap.", "Quietly judges every other lager at the table."),
        worldBeer("weihenstephaner", "Weihenstephaner Hefeweissbier", "Germany", "Hefeweizen", "Wheat professor", "Cloudy gold with a tall fluffy head in a wheat glass.", "Banana notes, clove notes, lecture notes."),
        worldBeer("erdinger", "Erdinger Weissbier", "Germany", "Hefeweizen", "Tall-glass theatre", "Hazy amber wheat beer with mountain-range foam.", "Arrives looking like it paid for its own photoshoot."),
        worldBeer("paulaner", "Paulaner Munchner Hell", "Germany", "Helles", "Oktoberfest understudy", "Bright gold lager with clean foam and a soft sparkle.", "For when your outfit says sensible and your plans do not."),
        worldBeer("bitburger", "Bitburger Premium Pils", "Germany", "Pilsner", "Bitte discipline", "Pale gold, crisp bubbles, firm white head.", "The beer equivalent of correcting grammar."),
        worldBeer("becks", "Beck's", "Germany", "Pilsner", "Green-bottle diplomacy", "Pale lager with a brisk white head.", "Always somehow at the airport."),
        worldBeer("warsteiner", "Warsteiner Premium Verum", "Germany", "Pilsner", "Gold-label uncle", "Clear straw-gold beer with tidy foam.", "Looks formal, behaves casual."),
        worldBeer("leffe-blonde", "Leffe Blonde", "Belgium", "Abbey Ale", "Monk mode", "Deep golden ale with rounded foam.", "For when one beer wants to become a speech."),
        worldBeer("duvel", "Duvel", "Belgium", "Strong Golden Ale", "Tiny glass, big opinions", "Sparkling gold with a huge white head.", "Comes in smiling and leaves with receipts."),
        worldBeer("chimay-blue", "Chimay Blue", "Belgium", "Trappist Ale", "Abbey heavyweight", "Dark brown ale with a tan foam crown.", "For philosophical mistakes."),
        worldBeer("tripel-karmeliet", "Tripel Karmeliet", "Belgium", "Tripel", "Fancy danger", "Glowing gold, elegant foam, suspicious strength.", "Looks like brunch, hits like admin."),
        worldBeer("delirium-tremens", "Delirium Tremens", "Belgium", "Strong Golden Ale", "Pink-elephant paperwork", "Bright gold with lively foam.", "The label is already warning you."),
        worldBeer("westmalle-tripel", "Westmalle Tripel", "Belgium", "Tripel", "Monastery turbo", "Golden-orange with a creamy white head.", "Quiet name, loud consequences."),
        worldBeer("heineken", "Heineken", "Netherlands", "Lager", "Global default setting", "Clear pale gold with a neat foam line.", "Available wherever bad decisions need logistics."),
        worldBeer("amstel", "Amstel", "Netherlands", "Lager", "Canal casual", "Pale gold lager with soft foam.", "A perfectly acceptable shrug in a glass."),
        worldBeer("grolsch", "Grolsch", "Netherlands", "Pilsner", "Swing-top nostalgia", "Golden pilsner with crisp white foam.", "The bottle closure is doing most of the flirting."),
        worldBeer("carlsberg", "Carlsberg", "Denmark", "Pilsner", "Probably fine", "Pale gold and clean with light foam.", "A diplomatic answer to 'what's cheap?'"),
        worldBeer("tuborg", "Tuborg Green", "Denmark", "Pilsner", "Green-party lager", "Light gold lager with a bright white cap.", "Shows up early and somehow knows the playlist."),
        worldBeer("peroni", "Peroni Nastro Azzurro", "Italy", "Lager", "Vacation shirt", "Pale straw beer with polished foam.", "Orders itself in sunglasses."),
        worldBeer("birra-moretti", "Birra Moretti", "Italy", "Lager", "Pizza bodyguard", "Golden lager with friendly white foam.", "Pairs with loud hand gestures."),
        worldBeer("estrella-damm", "Estrella Damm", "Spain", "Lager", "Barcelona receipt", "Bright golden lager with light foam.", "Tastes like someone booked one more night."),
        worldBeer("mahou", "Mahou Cinco Estrellas", "Spain", "Lager", "Madrid engine oil", "Deep gold lager with compact foam.", "Five stars, several questionable ideas."),
        worldBeer("super-bock", "Super Bock", "Portugal", "Lager", "Beach meeting", "Golden lager with a clean white head.", "For when dinner starts at midnight."),
        worldBeer("sagres", "Sagres", "Portugal", "Lager", "Lisbon timeout", "Pale lager with gentle carbonation.", "Uncomplicated, unlike the walk home."),
        worldBeer("kronenbourg", "Kronenbourg 1664", "France", "Lager", "Blue-label excuse", "Clear golden beer with a white foam collar.", "Pretends to be fancier than the table."),
        worldBeer("stella", "Stella Artois", "Belgium", "Lager", "Chalice business", "Pale gold lager in a dramatic glass.", "Comes with glassware ambition."),
        worldBeer("budvar", "Budweiser Budvar", "Czech Republic", "Lager", "Czech legal department", "Rich golden lager with generous foam.", "The original argument starter."),
        worldBeer("staropramen", "Staropramen", "Czech Republic", "Pilsner", "Prague handshake", "Clear gold with a soft white head.", "Reliable enough to hide in plain sight."),
        worldBeer("kozel", "Velkopopovicky Kozel", "Czech Republic", "Lager", "Dark horse", "Amber-gold lager with sturdy foam.", "Sounds hard to pronounce after two."),
        worldBeer("zywiec", "Zywiec", "Poland", "Lager", "Polish punctuation test", "Golden lager with a frothy white head.", "Nobody agrees how you said it."),
        worldBeer("tyskie", "Tyskie", "Poland", "Lager", "Big glass energy", "Bright gold with a dense white cap.", "Arrives like it owns the table."),
        worldBeer("warka", "Warka", "Poland", "Lager", "Quiet cousin", "Light amber-gold with modest foam.", "Sneaks into the round and refuses drama."),
        worldBeer("pilsner-starobrno", "Starobrno", "Czech Republic", "Lager", "Brno side quest", "Golden lager with clean foam.", "For when Prague got too much attention."),
        worldBeer("asahi", "Asahi Super Dry", "Japan", "Dry Lager", "Crisp salaryman", "Very pale gold with sharp bubbles.", "Finishes sentences before you start them."),
        worldBeer("sapporo", "Sapporo Premium", "Japan", "Lager", "Silver can confidence", "Pale gold lager with a clean foam head.", "Looks engineered, drinks engineered."),
        worldBeer("kirin", "Kirin Ichiban", "Japan", "Lager", "First-press flex", "Clear straw-gold with delicate foam.", "Polite until the karaoke starts."),
        worldBeer("tsingtao", "Tsingtao", "China", "Lager", "Takeaway diplomat", "Light gold lager with crisp foam.", "Usually arrives with food and better timing."),
        worldBeer("singha", "Singha", "Thailand", "Lager", "Holiday thermostat", "Golden lager with white foam.", "Made for heat and questionable shirt choices."),
        worldBeer("chang", "Chang", "Thailand", "Lager", "Elephant logistics", "Pale gold beer with a soft foam top.", "The round that makes plans flexible."),
        worldBeer("tiger", "Tiger Beer", "Singapore", "Lager", "Hawker-centre hero", "Bright gold lager with clean white foam.", "Pairs with spice and confidence."),
        worldBeer("kingfisher", "Kingfisher Premium", "India", "Lager", "Curry co-pilot", "Pale golden lager with light foam.", "Does important cooling work."),
        worldBeer("cobra", "Cobra", "United Kingdom", "Lager", "Mild-mannered mediator", "Smooth gold lager with gentle foam.", "Here to de-escalate the vindaloo."),
        worldBeer("corona", "Corona Extra", "Mexico", "Lager", "Lime delivery system", "Pale straw beer with light sparkle.", "A beer wearing vacation marketing."),
        worldBeer("modelo-especial", "Modelo Especial", "Mexico", "Lager", "Gold-foil operator", "Rich golden lager with a small white head.", "Looks dressed for dinner."),
        worldBeer("negra-modelo", "Negra Modelo", "Mexico", "Dark Lager", "Dark lager smooth talker", "Amber-brown with cream foam.", "More composed than anyone holding it."),
        worldBeer("pacifico", "Pacifico Clara", "Mexico", "Lager", "Beach receipt", "Pale gold lager with breezy foam.", "Tastes like pretending tomorrow is free."),
        worldBeer("dos-equis", "Dos Equis Lager", "Mexico", "Lager", "Two-X witness", "Light gold lager with white foam.", "Not the most interesting beer, but close enough."),
        worldBeer("budweiser", "Budweiser", "United States", "Lager", "Red-label baseline", "Pale gold lager with fizzy white foam.", "The control group."),
        worldBeer("coors-light", "Coors Light", "United States", "Light Lager", "Mountain tap water", "Very pale gold with fast foam.", "Hydration with paperwork."),
        worldBeer("miller-lite", "Miller Lite", "United States", "Light Lager", "Low-calorie witness", "Pale straw beer with a thin white head.", "Counts if you tell nobody."),
        worldBeer("blue-moon", "Blue Moon Belgian White", "United States", "Witbier", "Orange-slice theatre", "Cloudy gold wheat beer with soft foam.", "A fruit bowl with a bar tab."),
        worldBeer("sam-adams", "Samuel Adams Boston Lager", "United States", "Vienna Lager", "Boston lecturer", "Amber lager with a creamy off-white head.", "Has a story about hops ready."),
        worldBeer("sierra-nevada", "Sierra Nevada Pale Ale", "United States", "Pale Ale", "Green-label elder", "Copper-gold ale with firm foam.", "The IPA parent who still has range."),
        worldBeer("lagunitas-ipa", "Lagunitas IPA", "United States", "IPA", "Hops with jokes", "Golden-orange IPA with sticky white foam.", "Smells louder than it speaks."),
        worldBeer("stone-ipa", "Stone IPA", "United States", "IPA", "Bitter gym bro", "Golden IPA with a sturdy head.", "Arrives flexing bitterness."),
        worldBeer("goose-island-ipa", "Goose Island IPA", "United States", "IPA", "Airport craft", "Amber-gold IPA with white foam.", "Craft beer with terminal access."),
        worldBeer("founders-all-day", "Founders All Day IPA", "United States", "Session IPA", "Responsible trouble", "Light amber IPA with a foamy top.", "Says 'session' like that helps."),
        worldBeer("fat-tire", "Fat Tire", "United States", "Amber Ale", "Bicycle pint", "Amber ale with an off-white cap.", "Outdoor hobby energy in a glass."),
        worldBeer("yuengling", "Yuengling Traditional Lager", "United States", "Amber Lager", "Oldest-guy-at-table", "Amber lager with light tan foam.", "Has been here before and will mention it."),
        worldBeer("molson", "Molson Canadian", "Canada", "Lager", "Maple default", "Pale gold lager with clean foam.", "Politely gets the job done."),
        worldBeer("labatt-blue", "Labatt Blue", "Canada", "Pilsner", "Blue-collar blue", "Light gold with white foam.", "A fridge staple with no speech prepared."),
        worldBeer("steam-whistle", "Steam Whistle", "Canada", "Pilsner", "Green-bottle manners", "Pale gold pilsner with tight foam.", "Looks tidy enough for company."),
        worldBeer("great-northern", "Great Northern", "Australia", "Lager", "Sunny esky logic", "Pale gold lager with light foam.", "Built for heat and poor planning."),
        worldBeer("victoria-bitter", "Victoria Bitter", "Australia", "Lager", "VB negotiation", "Golden lager with a firm white head.", "The round has entered tradie mode."),
        worldBeer("coopers-pale", "Coopers Pale Ale", "Australia", "Pale Ale", "Cloudy classic", "Hazy gold ale with natural sediment.", "Roll the bottle, roll the dice."),
        worldBeer("steinlager", "Steinlager", "New Zealand", "Lager", "Kiwi straight line", "Pale golden lager with crisp foam.", "No fuss, slightly suspicious competence."),
        worldBeer("lion-red", "Lion Red", "New Zealand", "Lager", "Red-can rugby", "Golden lager with a modest head.", "Sounds louder after kickoff."),
        worldBeer("castle-lager", "Castle Lager", "South Africa", "Lager", "Braai logistics", "Clear gold lager with white foam.", "Basically asks where the grill is."),
        worldBeer("windhoek", "Windhoek Lager", "Namibia", "Lager", "Desert clean", "Pale golden lager with crisp foam.", "Refreshment with dry humour."),
        worldBeer("club-colombia", "Club Colombia Dorada", "Colombia", "Lager", "Golden club stamp", "Golden lager with compact white foam.", "Looks like it knows a rooftop."),
        worldBeer("quilmes", "Quilmes", "Argentina", "Lager", "Match-day lager", "Light gold beer with lively foam.", "For football opinions at full volume."),
        worldBeer("brahma", "Brahma", "Brazil", "Lager", "Carnival fridge", "Pale gold lager with light white foam.", "A sunny yes to bad timing."),
        worldBeer("skol", "Skol", "Brazil", "Lager", "Circle logo chaos", "Pale lager with fizzy foam.", "Spins the night in one direction."),
        worldBeer("cusquena", "Cusquena Dorada", "Peru", "Lager", "Andes gold", "Golden lager with a bright foam top.", "Makes altitude sound like a plan."),
        worldBeer("mythos", "Mythos", "Greece", "Lager", "Island table beer", "Light gold lager with airy foam.", "Tastes better near water."),
        worldBeer("fix-hellas", "Fix Hellas", "Greece", "Lager", "Taverna default", "Pale gold lager with soft foam.", "Comes with chips, somehow."),
        worldBeer("efes", "Efes Pilsener", "Turkey", "Pilsner", "Kebab co-founder", "Bright gold pilsner with white foam.", "The late-night support act."),
        worldBeer("goldstar", "Goldstar", "Israel", "Lager", "Desert fridge logic", "Amber-gold lager with compact foam.", "Small bottle, big table presence."),
        worldBeer("estrella-galicia", "Estrella Galicia", "Spain", "Lager", "Northwest crisp", "Golden lager with a foamy white crown.", "For people who researched one extra beer."),
        worldBeer("beavertown-neck-oil", "Beavertown Neck Oil", "United Kingdom", "Session IPA", "Space-can chaos", "Hazy gold session IPA with fluffy foam.", "The can did most of the graphic design budget."),
        worldBeer("brewdog-punk-ipa", "BrewDog Punk IPA", "United Kingdom", "IPA", "Blue-can argument", "Golden IPA with a hoppy white head.", "Comes with opinions about craft beer."),
        worldBeer("camden-hells", "Camden Hells", "United Kingdom", "Helles Lager", "North London uniform", "Pale gold lager with clean foam.", "Wears trainers indoors."),
        worldBeer("fullers-london-pride", "Fuller's London Pride", "United Kingdom", "Bitter", "Pub carpet classic", "Amber ale with creamy off-white foam.", "Tastes like wooden tables."),
        worldBeer("newcastle-brown", "Newcastle Brown Ale", "United Kingdom", "Brown Ale", "Brown bottle veteran", "Brown ale with tan foam.", "Old-school enough to own a coat hook."),
        worldBeer("murphys", "Murphy's Irish Stout", "Ireland", "Stout", "Softer stout cousin", "Black stout with a creamy tan head.", "Guinness without the press conference."),
        worldBeer("smithwicks", "Smithwick's", "Ireland", "Red Ale", "Red ale diplomat", "Ruby-amber ale with off-white foam.", "Keeps the peace until round three."),
        worldBeer("kilkenny", "Kilkenny", "Ireland", "Cream Ale", "Nitro velvet", "Amber cream ale with dense foam.", "A pint wearing a soft jumper."),
        worldBeer("generic-house-lager", "House Lager", "Everywhere", "Lager", "Mystery tap", "Probably gold, probably wet, probably fine.", "For when the menu says 'lager' and refuses cross-examination."),
        worldBeer("generic-house-ipa", "House IPA", "Everywhere", "IPA", "Tap-room wildcard", "Golden to amber with a hoppy foam cap.", "Could be excellent. Could be homework."),
        worldBeer("generic-wheat", "Wheat Beer", "Everywhere", "Wheat Beer", "Cloudy committee", "Hazy gold with a fluffy white head.", "Looks innocent, starts debates about fruit."),
        worldBeer("generic-stout", "House Stout", "Everywhere", "Stout", "Dark matter", "Near-black with a tan foam blanket.", "The pint equivalent of closing the curtains."),
        worldBeer("generic-radler", "Radler", "Everywhere", "Radler", "Cyclist loophole", "Pale cloudy gold with soft fizz.", "A beer wearing lemonade as a disguise."),
    ]

    /// The app-authored half of a diary note. Pulled out of `diaryNote` so `LogPintSheet.noteLimit`
    /// can measure the longest one the catalog can produce — the user's own words get whatever is
    /// left of `pint_entries.private_note`'s 280 code points.
    static func beerLine(for beer: BeerChoice) -> String {
        "[Beer: \(beer.name)] \(beer.glassNote)"
    }

    /// **Joined with a space, not a newline.** `create_pint_entry` runs
    /// `strip_ugc_control_chars(p_private_note)`, which deletes `chr(10)` along with every other C0
    /// control character, so this column cannot hold a line break: a newline separator would be
    /// removed server-side and glue the glass note straight onto the user's first word
    /// (`…like a witness.My round`). Pinned by `t54` in `supabase/tests/rls_rpc_suite.sql`.
    static func diaryNote(for beer: BeerChoice, userNote: String) -> String {
        let beerLine = beerLine(for: beer)
        guard !userNote.isEmpty else { return beerLine }
        return "\(beerLine) \(userNote)"
    }

    static func beerName(in note: String?) -> String? {
        guard let note,
              let prefix = note.range(of: "[Beer: "),
              let closing = note[prefix.upperBound...].firstIndex(of: "]")
        else { return nil }
        return String(note[prefix.upperBound..<closing])
    }

    private static func beer(
        _ id: String,
        name: String,
        country: String,
        style: String,
        nickname: String,
        glassNote: String,
        roast: String
    ) -> BeerChoice {
        BeerChoice(id: id, name: name, country: country, style: style,
                   nickname: nickname, glassNote: glassNote, roast: roast)
    }

    private static func worldBeer(
        _ id: String,
        _ name: String,
        _ country: String,
        _ style: String,
        _ nickname: String,
        _ glassNote: String,
        _ roast: String
    ) -> BeerChoice {
        BeerChoice(id: id, name: name, country: country, style: style,
                   nickname: nickname, glassNote: glassNote, roast: roast)
    }
}

/// A single tappable catalog row. The tap is the logging action, so the whole row is a hit
/// target and the label reads as a verb.
private struct BeerRow: View {
    let beer: BeerChoice
    /// A save already in flight, or a note too long to store — either way the row must not fire.
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(beer.name)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Text("\(beer.country) · \(beer.style)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.xs)
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.Palette.accent)
            }
            .frame(minHeight: Theme.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier("log-pint-beer-\(beer.id)")
        .accessibilityLabel("Log \(beer.name)")
        .accessibilityHint("\(beer.country), \(beer.style)")
    }
}
