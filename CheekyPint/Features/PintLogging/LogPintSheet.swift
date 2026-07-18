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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(BeerCatalog.beers) { beer in
                        BeerCard(beer: beer, isSelected: beer == selectedBeer) {
                            selectedBeer = beer
                            pourProgress = 0.18
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
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
    let nickname: String
    let glassNote: String
    let roast: String
    let imageURL: URL
    let sourceURL: URL
}

enum BeerCatalog {
    static let beers: [BeerChoice] = [
        beer(
            "puntigamer",
            name: "Puntigamer",
            nickname: "Graz passport",
            glassNote: "Bright gold in a branded glass with a proper white cap.",
            roast: "For when somebody says, 'just one' and immediately orders snacks.",
            file: "Puntigamer_beer.jpg"
        ),
        beer(
            "stiegl",
            name: "Stiegl",
            nickname: "Salzburg diplomat",
            glassNote: "Clear amber-gold, tidy foam, looks like it has weekend plans.",
            roast: "Polite enough for parents, suspicious enough for the group chat.",
            file: "Stiegl-bier.jpg"
        ),
        beer(
            "ottakringer",
            name: "Ottakringer Helles",
            nickname: "Vienna alibi",
            glassNote: "Pale golden helles in a clean glass, bottle standing nearby like a witness.",
            roast: "The official beverage of 'I am only staying for half an hour.'",
            file: "Ottakringer_Helles_bottle_with_glass.jpg"
        ),
        beer(
            "pilsner",
            name: "Pilsner Urquell",
            nickname: "Crispy Czech homework",
            glassNote: "Deep gold in a tall glass with dense white foam.",
            roast: "Ordered by the mate who suddenly becomes a lager professor.",
            file: "Pilsener_Urquell_hohes_Glas.jpg"
        ),
        beer(
            "guinness",
            name: "Guinness",
            nickname: "Curtains closed",
            glassNote: "Dark stout body with that creamy beige head doing all the PR.",
            roast: "Counts as a beer, a meal, and a personality test.",
            file: "GuinnessPint.jpg"
        ),
        beer(
            "hoegaarden",
            name: "Hoegaarden",
            nickname: "Cloudy holiday mode",
            glassNote: "Hazy straw beer in a chunky white-beer glass.",
            roast: "For when your pint wants to wear linen trousers.",
            file: "HoegaardenGlass.jpg"
        ),
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
        nickname: String,
        glassNote: String,
        roast: String,
        file: String
    ) -> BeerChoice {
        let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        return BeerChoice(
            id: id,
            name: name,
            nickname: nickname,
            glassNote: glassNote,
            roast: roast,
            imageURL: URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)?width=700")!,
            sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:\(encoded)")!
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
                AsyncImage(url: beer.imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        ZStack {
                            Theme.Palette.backgroundSecondary
                            Image(systemName: "mug.fill")
                                .font(.system(size: 36, weight: .semibold))
                                .foregroundStyle(Theme.Palette.beer)
                        }
                    case .empty:
                        ZStack {
                            Theme.Palette.backgroundSecondary
                            ProgressView().tint(Theme.Palette.accent)
                        }
                    @unknown default:
                        Theme.Palette.backgroundSecondary
                    }
                }
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
                Text(beer.glassNote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(3)
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
