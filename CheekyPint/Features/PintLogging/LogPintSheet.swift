import SwiftUI
import CheekyPintCore

/// The lightweight confirmation sheet for logging a pint (master prompt §7). A stable
/// idempotency key is generated once when the sheet opens and reused on every retry, so a
/// double-tap or a flaky network can't create duplicates. Submission is disabled while in
/// flight. Nothing is stored until the user confirms.
struct LogPintSheet: View {
    let profile: Profile
    let activeSession: PubSession?
    let onLogged: (PintEntry) async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container

    @State private var serving: ServingType = .default
    @State private var customVolume = "500"
    @State private var alcoholFree = false
    @State private var occurredAt = Date()
    @State private var note = ""
    @State private var attachToSession = true
    @State private var selectedBeer = BeerCatalog.beers[0]
    @State private var beerSearch = ""
    @State private var selectedPub: Pub?
    @State private var showPubPicker = false
    @State private var isSaving = false
    @State private var isPouring = false
    @State private var pourProgress: CGFloat = 0.18
    @State private var errorMessage: String?

    // Generated once for the lifetime of this sheet — the idempotency guarantee.
    @State private var idempotencyKey = IdempotencyKey.generate()

    var body: some View {
        NavigationStack {
            Form {
                beerSection
                servingSection
                detailsSection
                if activeSession != nil { sessionSection }
                pubSection
                noteSection
                fillToLogSection
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.Palette.warning)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.backgroundPrimary)
            .navigationTitle("Beer evidence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay { if isSaving { ProgressView().tint(Theme.Palette.accent) } }
            .sheet(isPresented: $showPubPicker) {
                PubPickerView { pub in selectedPub = pub }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var beerSection: some View {
        Section("Beer on display") {
            TextField("Search the world's beer fridge", text: $beerSearch)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(filteredBeers) { beer in
                        BeerCard(beer: beer, isSelected: beer == selectedBeer) {
                            selectedBeer = beer
                            pourProgress = 0.18
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            Text("\(BeerCatalog.beers.count) beers loaded. Not literally all of Earth, but enough to start arguments.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
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

    private var servingSection: some View {
        Section("Serving") {
            Picker("Size", selection: $serving) {
                ForEach(ServingType.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if serving == .custom {
                HStack {
                    TextField("Volume", text: $customVolume).keyboardType(.numberPad)
                    Text("ml").foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Toggle("Alcohol-free", isOn: $alcoholFree)
                .tint(Theme.Palette.accent)
        }
    }

    private var detailsSection: some View {
        Section("When") {
            DatePicker("Time", selection: $occurredAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
        }
    }

    private var sessionSection: some View {
        Section {
            Toggle("Add to current session", isOn: $attachToSession).tint(Theme.Palette.accent)
        } footer: {
            Text("Counts toward this session's standings with the mates who joined.")
        }
    }

    private var pubSection: some View {
        Section("Pub (optional)") {
            Button {
                showPubPicker = true
            } label: {
                HStack {
                    Text(selectedPub?.name ?? "Choose a pub")
                        .foregroundStyle(selectedPub == nil ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            if selectedPub != nil {
                Button("Clear pub", role: .destructive) { selectedPub = nil }
            }
        }
    }

    private var noteSection: some View {
        Section("Private note (optional)") {
            TextField("Just for you...", text: $note, axis: .vertical).lineLimit(1...3)
        }
    }

    private var fillToLogSection: some View {
        Section {
            PourToLogButton(
                beer: selectedBeer,
                progress: pourProgress,
                isWorking: isSaving || isPouring
            ) {
                Task { await pourAndSave() }
            }
        } footer: {
            Text("The record is created when the glass fills up. Science, probably.")
        }
    }

    private func pourAndSave() async {
        guard !isSaving, !isPouring else { return }
        isPouring = true
        errorMessage = nil
        pourProgress = 0.18
        withAnimation(.easeInOut(duration: 0.85)) { pourProgress = 1 }
        try? await Task.sleep(for: .milliseconds(900))
        await save()
        if errorMessage != nil {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { pourProgress = 0.18 }
        }
        isPouring = false
    }

    private func save() async {
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        let volume = serving == .custom ? Double(customVolume) : nil
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let entry = try await container.diary.createPint(
                idempotencyKey: idempotencyKey,
                occurredAt: occurredAt,
                serving: serving,
                volumeMl: volume,
                alcoholFree: alcoholFree,
                pubID: selectedPub?.id,
                sessionID: (attachToSession ? activeSession?.id : nil),
                note: BeerCatalog.diaryNote(for: selectedBeer, userNote: cleanNote)
            )
            container.analytics.track(.pintSaved)
            Haptics.success()
            await onLogged(entry)
            dismiss()
        } catch let error as SupabaseError {
            errorMessage = error.friendlyMessage
        } catch {
            errorMessage = "Couldn't save that pint. Please try again."
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
    let imageURL: URL?
    let sourceURL: URL?
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
            roast: "For when somebody says, 'just one' and immediately orders snacks.",
            file: "Puntigamer_beer.jpg"
        ),
        beer(
            "stiegl",
            name: "Stiegl",
            country: "Austria",
            style: "Lager",
            nickname: "Salzburg diplomat",
            glassNote: "Clear amber-gold, tidy foam, looks like it has weekend plans.",
            roast: "Polite enough for parents, suspicious enough for the group chat.",
            file: "Stiegl-bier.jpg"
        ),
        beer(
            "ottakringer",
            name: "Ottakringer Helles",
            country: "Austria",
            style: "Helles",
            nickname: "Vienna alibi",
            glassNote: "Pale golden helles in a clean glass, bottle standing nearby like a witness.",
            roast: "The official beverage of 'I am only staying for half an hour.'",
            file: "Ottakringer_Helles_bottle_with_glass.jpg"
        ),
        beer(
            "pilsner",
            name: "Pilsner Urquell",
            country: "Czech Republic",
            style: "Pilsner",
            nickname: "Crispy Czech homework",
            glassNote: "Deep gold in a tall glass with dense white foam.",
            roast: "Ordered by the mate who suddenly becomes a lager professor.",
            file: "Pilsener_Urquell_hohes_Glas.jpg"
        ),
        beer(
            "guinness",
            name: "Guinness",
            country: "Ireland",
            style: "Stout",
            nickname: "Curtains closed",
            glassNote: "Dark stout body with that creamy beige head doing all the PR.",
            roast: "Counts as a beer, a meal, and a personality test.",
            file: "GuinnessPint.jpg"
        ),
        beer(
            "hoegaarden",
            name: "Hoegaarden",
            country: "Belgium",
            style: "Witbier",
            nickname: "Cloudy holiday mode",
            glassNote: "Hazy straw beer in a chunky white-beer glass.",
            roast: "For when your pint wants to wear linen trousers.",
            file: "HoegaardenGlass.jpg"
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

    static func diaryNote(for beer: BeerChoice, userNote: String) -> String {
        let beerLine = "[Beer: \(beer.name)] \(beer.glassNote)"
        guard !userNote.isEmpty else { return beerLine }
        return "\(beerLine)\n\(userNote)"
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
        roast: String,
        file: String
    ) -> BeerChoice {
        let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        return BeerChoice(
            id: id,
            name: name,
            country: country,
            style: style,
            nickname: nickname,
            glassNote: glassNote,
            roast: roast,
            imageURL: URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)?width=700")!,
            sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:\(encoded)")!
        )
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
        BeerChoice(
            id: id,
            name: name,
            country: country,
            style: style,
            nickname: nickname,
            glassNote: glassNote,
            roast: roast,
            imageURL: nil,
            sourceURL: nil
        )
    }
}

private struct BeerCard: View {
    let beer: BeerChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                beerImage
                .frame(width: 168, height: 126)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))

                Text(beer.name)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(beer.nickname)
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .lineLimit(1)
                Text("\(beer.country) - \(beer.style)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                Text(beer.glassNote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(beer.roast)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textPrimary.opacity(0.85))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 168, height: 282, alignment: .topLeading)
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.Palette.backgroundPrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .stroke(isSelected ? Theme.Palette.accent : Theme.Palette.textSecondary.opacity(0.22),
                            lineWidth: isSelected ? 3 : 1)
            )
        }
        .buttonStyle(.plain)
            .accessibilityLabel("\(beer.name), \(beer.glassNote)")
    }

    @ViewBuilder
    private var beerImage: some View {
        if let imageURL = beer.imageURL {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    fallbackImage
                case .empty:
                    ZStack {
                        Theme.Palette.backgroundSecondary
                        ProgressView().tint(Theme.Palette.accent)
                    }
                @unknown default:
                    fallbackImage
                }
            }
        } else {
            fallbackImage
        }
    }

    private var fallbackImage: some View {
        ZStack {
            Theme.Palette.backgroundSecondary
            PintGlass(fill: fallbackFill, edge: Theme.Palette.textPrimary)
                .frame(width: 48, height: 82)
            VStack {
                Spacer()
                Text(beer.style)
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .padding(.bottom, Theme.Spacing.xs)
            }
        }
    }

    private var fallbackFill: CGFloat {
        switch beer.style.lowercased() {
        case let style where style.contains("stout") || style.contains("brown"):
            return 0.92
        case let style where style.contains("wheat") || style.contains("wit"):
            return 0.76
        case let style where style.contains("ipa") || style.contains("ale"):
            return 0.84
        default:
            return 0.78
        }
    }
}

private struct PourToLogButton: View {
    let beer: BeerChoice
    let progress: CGFloat
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                PintGlass(fill: progress, edge: Theme.Palette.textPrimary)
                    .frame(width: 58, height: 84)
                    .shadow(color: Theme.Palette.beer.opacity(0.25), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(isWorking ? "Filling..." : "Fill to record")
                        .font(Theme.Typography.headline.weight(.bold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(beer.name)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isWorking ? "hourglass" : "hand.tap.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.Palette.accent)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel("Fill glass to record \(beer.name)")
    }
}
