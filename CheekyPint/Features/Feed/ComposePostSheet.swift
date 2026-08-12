import SwiftUI
import PhotosUI
import CheekyPintCore

/// The composer for a new feed post: body text, an optional photo, and an optional place tag
/// (`PlacePickerSheet`, wired in via `placeSection`). Mirrors `LogPintSheet`'s shape — plain
/// `@State`, no view model, inline error `Text`, an `isPosting` overlay, dismiss-then-callback —
/// since there's no paging/reconciliation state here that would justify one.
struct ComposePostSheet: View {
    /// Mirrors `create_post`'s `left(v_body, 500)` clamp (`20260811000500_rpc_feed_posts.sql`).
    static let bodyLimit = 500
    /// Mirrors `create_post`'s `left(v_label, 80)` clamp.
    static let placeLabelLimit = 80

    /// Mirrors `create_post`'s `if v_body is null and v_image is null` guard, so the user sees
    /// this locally instead of a round trip. Trimmed the same way the server's `btrim` does —
    /// whitespace-only text does not count as "words".
    static func canPost(body: String, hasPhoto: Bool) -> Bool {
        hasPhoto || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether Post should be enabled: `canPost`'s "photo or words" gate, plus the over-limit
    /// guard the body counter also reflects. Static (like `canPost`/`storagePath`) so "501
    /// characters blocks submission" is testable without a view instance — disabling Post past
    /// `bodyLimit` rather than letting the server's `left(v_body, 500)` clamp silently drop the
    /// tail of what the user typed.
    ///
    /// Measured with `bodyLength(of:)`, not `body.count`: `left(v_body, 500)` counts code points,
    /// and gating on grapheme clusters would re-open the exact silent truncation this guard
    /// exists to prevent (see `ProfileTextSanitizer`'s own doc for the NFD/flag/variation-selector
    /// cases). For pure ASCII the two are identical.
    static func canSubmit(body: String, hasPhoto: Bool) -> Bool {
        canPost(body: body, hasPhoto: hasPhoto) && bodyLength(of: body) <= bodyLimit
    }

    /// The number the counter shows and `canSubmit` gates on: how long this body will be **once
    /// stored**, in the server's own unit. See `ProfileTextSanitizer.sanitizedLength`.
    static func bodyLength(of body: String) -> Int {
        sanitizer.sanitizedLength(body, allowNewlines: true)
    }

    /// `<uid>/<uuid>.jpg` — `create_post` checks the first folder segment against
    /// `auth.uid()::text` and rejects any path containing `..`. Mirrors
    /// `ProfileRepository.avatarStoragePath`, which builds exactly this shape for avatars.
    ///
    /// **Both segments are lowercased.** `UUID.uuidString` is always uppercase
    /// (`586C6ED5-6494-...`), but Postgres always renders `auth.uid()::text` lowercase, and every
    /// comparison against it — the `post-images` storage policies
    /// (`20260811000200_feed_storage.sql:20,25,26,30`) and `create_post`'s own ownership guard
    /// (`20260811000500_rpc_feed_posts.sql:53`) — is plain `text` equality, not `citext`, with no
    /// `lower()` call anywhere. An uppercase folder segment fails RLS on upload and, if that were
    /// somehow bypassed, fails `create_post`'s guard too — so real (non-demo) photo posting could
    /// never succeed before this fix. The filename segment's case doesn't matter to any check;
    /// it's lowercased too purely for consistency with the folder segment.
    static func storagePath(uid: UUID) -> String {
        "\(uid.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
    }

    let onPosted: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container

    @State private var postBody = ""
    @State private var pickedItem: PhotosPickerItem?
    @State private var photoJPEG: Data?
    @State private var isPosting = false
    @State private var errorMessage: String?
    @State private var selectedPlace: SelectedPlace?
    @State private var showingPlacePicker = false

    /// `static` so `canSubmit`/`bodyLength` — the pure, directly-tested gate — can share the one
    /// instance the view's own `submit()` uses, rather than each measuring with a different tool.
    private static let sanitizer = ProfileTextSanitizer()

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.Palette.warning)
                }
                bodySection
                photoSection
                placeSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.backgroundPrimary)
            .navigationTitle("New post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("compose-post-cancel")
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { Task { await submit() } }
                        .disabled(!canSubmit || isPosting)
                        .accessibilityIdentifier("compose-post-submit")
                        .accessibilityLabel("Post")
                }
            }
            .overlay { if isPosting { ProgressView().tint(Theme.Palette.accent) } }
        }
        .presentationDetents([.large])
    }

    // MARK: - Sections

    private var bodySection: some View {
        Section {
            TextField("What's in the glass?", text: $postBody, axis: .vertical)
                .lineLimit(3...8)
                .accessibilityIdentifier("compose-post-body")
                .accessibilityLabel("Post text")
            HStack {
                Spacer(minLength: 0)
                Text("\(bodyLength)/\(Self.bodyLimit)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(isOverLimit ? Theme.Palette.warning : Theme.Palette.textSecondary)
                    .accessibilityIdentifier("compose-post-counter")
                    .accessibilityLabel("\(bodyLength) of \(Self.bodyLimit) characters used")
            }
        }
    }

    private var photoSection: some View {
        Section("Photo") {
            // Bind to a differently-named local: shadowing the `photoJPEG` @State property here
            // would make "Remove photo" below assign into the shadowed immutable `let`, not the
            // @State var — a compile error, but one worth a comment so it isn't reintroduced.
            if let jpeg = photoJPEG, let uiImage = UIImage(data: jpeg) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, minHeight: Theme.Sizing.photoPreview, maxHeight: Theme.Sizing.photoPreview)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .accessibilityHidden(true)
                Button(role: .destructive) {
                    photoJPEG = nil
                    pickedItem = nil
                } label: {
                    Text("Remove photo")
                }
                .accessibilityIdentifier("compose-post-remove-photo")
                .accessibilityLabel("Remove photo")
            }
            PhotosPicker(selection: $pickedItem, matching: .images) {
                Label(photoJPEG == nil ? "Add a photo" : "Change photo", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("compose-post-photo")
            .accessibilityLabel(photoJPEG == nil ? "Add a photo" : "Change photo")
            .onChange(of: pickedItem) { _, item in Task { await loadPhoto(item) } }
        }
    }

    /// Opens `PlacePickerSheet` (an `MKLocalSearchCompleter` search plus `PubsRepository.persist`
    /// for a matched pub) and shows the chosen label with a "Remove" affordance once set. No
    /// location permission is ever requested — see `PlacePickerSheet`'s doc.
    private var placeSection: some View {
        Section {
            Button {
                showingPlacePicker = true
            } label: {
                HStack {
                    Image(systemName: "mappin.and.ellipse")
                    Text(selectedPlace?.label ?? "Add a location")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                }
            }
            .foregroundStyle(selectedPlace == nil ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
            .accessibilityIdentifier("compose-post-place")
            .accessibilityLabel(selectedPlace?.label ?? "Add a location")
            if selectedPlace != nil {
                Button(role: .destructive) {
                    selectedPlace = nil
                } label: {
                    Text("Remove location")
                }
                .accessibilityIdentifier("compose-post-remove-place")
                .accessibilityLabel("Remove location")
            }
        }
        .sheet(isPresented: $showingPlacePicker) {
            PlacePickerSheet { place in
                selectedPlace = place
            }
        }
    }

    // MARK: - Derived state

    /// Both read through `Self.bodyLength` so what the counter shows and what Post gates on are
    /// the same number, measured the same way the server will measure it.
    private var bodyLength: Int { Self.bodyLength(of: postBody) }

    private var isOverLimit: Bool { bodyLength > Self.bodyLimit }

    private var canSubmit: Bool {
        Self.canSubmit(body: postBody, hasPhoto: photoJPEG != nil)
    }

    // MARK: - Actions

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = ImageResizer.jpeg(from: image, maxDimension: 1600, quality: 0.8)
        else {
            errorMessage = "Couldn't read that photo. Try another image."
            return
        }
        photoJPEG = jpeg
        errorMessage = nil
    }

    private func submit() async {
        guard !isPosting else { return }
        isPosting = true
        errorMessage = nil
        defer { isPosting = false }

        let cleanBody = Self.sanitizer.sanitize(postBody, allowNewlines: true, maxLength: Self.bodyLimit)
        guard Self.canPost(body: cleanBody, hasPhoto: photoJPEG != nil) else {
            errorMessage = "A post needs a photo or a few words."
            return
        }

        do {
            var imagePath: String?
            if let photoJPEG {
                if await DemoWorld.shared.isActive {
                    // Demo mode has no storage backend — write into Application Support
                    // instead, same as ProfileRepository.uploadAvatar's demo branch for avatars.
                    imagePath = try container.profiles.writeLocalPostImage(photoJPEG)
                } else {
                    guard let uid = await container.auth.currentUserID else {
                        throw SupabaseError.notAuthenticated
                    }
                    let path = Self.storagePath(uid: uid)
                    // Upload BEFORE createPost. If createPost then fails, the result is an
                    // orphaned storage object — the retention GC sweeps those. Reversing the
                    // order would leave a post row pointing at a photo that was never written,
                    // which renders as FeedPostCard's "Photo unavailable" state forever.
                    _ = try await container.data.uploadObject(
                        bucket: "post-images", path: path, data: photoJPEG, contentType: "image/jpeg")
                    imagePath = path
                }
            }
            try await container.feed.createPost(
                body: cleanBody.isEmpty ? nil : cleanBody,
                imagePath: imagePath,
                placeLabel: selectedPlace?.label,
                pubID: selectedPlace?.pubID
            )
            dismiss()
            await onPosted()
        } catch let error as SupabaseError {
            errorMessage = error.friendlyMessage
        } catch {
            errorMessage = "Couldn't post that. Please try again."
        }
    }
}
