import SwiftUI
import CheekyPintCore

/// Create a pub session and share its join QR/code (master prompt §12).
struct CreateSessionView: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss

    private static let sanitizer = ProfileTextSanitizer()

    /// `pub_sessions.name`'s own bound: `char_length(name) <= 80` (a CHECK constraint), mirrored by
    /// `create_pub_session`'s `left(…, 80)`.
    static let nameLimit = 80

    /// How long the name will be **once stored**, in the code points Postgres counts.
    /// `allowNewlines: false` — a session name is a single line, and the column cannot hold a break
    /// anyway (`strip_ugc_control_chars` deletes `chr(10)`).
    static func nameLength(of raw: String) -> Int {
        sanitizer.sanitizedLength(raw, allowNewlines: false)
    }

    static func nameWithinLimit(_ raw: String) -> Bool {
        nameLength(of: raw) <= nameLimit
    }

    /// The name as it will be sent. `nil` for anything that cleans away to nothing, matching the
    /// RPC's own `nullif(…, '')`: an unnamed session shows "Session", which is better than a title
    /// that is present but blank.
    ///
    /// This is the surface the audit flagged as the worst of the two remaining raw ones —
    /// `ActiveSessionView` renders the name as the navigation title for **every member of the
    /// session**, so an unsanitised name is a bidi/zero-width payload on other people's screens, not
    /// the author's own. The server half is in `create_pub_session` (pinned by `t53`); this is the
    /// client half.
    static func sanitizedName(_ raw: String) -> String? {
        let clean = sanitizer.sanitize(raw, allowNewlines: false, maxLength: nameLimit)
        return clean.isEmpty ? nil : clean
    }

    @State private var name = ""
    @State private var selectedPub: Pub?
    @State private var showPubPicker = false
    @State private var created: CreatedSessionDTO?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let created, let token = FriendToken(rawValue: created.joinToken) {
                Section("Share to invite mates") {
                    QRCodeView(url: container.deepLinkParser.joinSessionURL(token)).frame(maxWidth: 220)
                    ShareLink(item: container.deepLinkParser.joinSessionURL(token, universal: true)) {
                        Label("Share join link", systemImage: "square.and.arrow.up")
                    }
                }
            } else {
                Section("Session") {
                    TextField("Name (optional), e.g. Friday at the Kings", text: $name)
                        .accessibilityIdentifier("create-session-name")
                        .accessibilityLabel("Session name")
                    HStack {
                        Spacer(minLength: 0)
                        // `verbatim:` — plain interpolation formats the number for the current
                        // locale, which turned a counter into "0/1.000" on a German device.
                        Text(verbatim: "\(nameLength)/\(Self.nameLimit)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(isNameOverLimit ? Theme.Palette.warning : Theme.Palette.textSecondary)
                            .accessibilityIdentifier("create-session-name-counter")
                            .accessibilityLabel("\(nameLength) of \(Self.nameLimit) characters used")
                    }
                    Button(selectedPub?.name ?? "Choose a pub (optional)") { showPubPicker = true }
                        .accessibilityIdentifier("create-session-pub")
                        .accessibilityLabel(selectedPub.map { "Pub: \($0.name)" } ?? "Choose a pub")
                }
                Section {
                    Button("Start session") { Task { await create() } }
                        .disabled(isWorking || isNameOverLimit)
                        .accessibilityIdentifier("create-session-start")
                        .accessibilityLabel("Start session")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.Palette.warning)
                        .accessibilityIdentifier("create-session-error")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.backgroundPrimary)
        .navigationTitle("Start a session")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPubPicker) { PubPickerView { selectedPub = $0 } }
    }

    private var nameLength: Int { Self.nameLength(of: name) }

    private var isNameOverLimit: Bool { !Self.nameWithinLimit(name) }

    private func create() async {
        // Re-checked here rather than left to `.disabled`: a second tap can be dispatched from its
        // own `Task` before the first re-render, and this gate decides whether the tail of the name
        // survives `left(…, 80)`.
        guard !isWorking, Self.nameWithinLimit(name) else { return }
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            created = try await container.sessions.createSession(
                pubID: selectedPub?.id, name: Self.sanitizedName(name))
            container.analytics.track(.sessionCreated)
        } catch let e as SupabaseError { errorMessage = e.friendlyMessage }
        catch { errorMessage = "Couldn't start the session." }
    }
}

/// Join a session from a deep link token (master prompt §12).
struct JoinSessionView: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    let token: FriendToken

    @State private var phase: Phase = .joining
    private enum Phase: Equatable { case joining, joined, failed(String) }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            switch phase {
            case .joining: ProgressView("Joining…").tint(Theme.Palette.accent)
            case .joined:
                Label("You're in. Cheers!", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.Palette.success)
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle())
            case .failed(let message):
                StatusView(systemImage: "xmark.circle", title: "Couldn't join", message: message,
                           actionTitle: "Close") { dismiss() }
            }
        }
        .padding(Theme.Spacing.lg).frame(maxWidth: .infinity, maxHeight: .infinity).pubBackground()
        .navigationTitle("Join session").navigationBarTitleDisplayMode(.inline)
        .task { await join() }
    }

    private func join() async {
        do {
            try await container.sessions.joinByToken(token.rawValue)
            container.analytics.track(.sessionJoined)
            phase = .joined
        } catch let e as SupabaseError { phase = .failed(e.friendlyMessage) }
        catch { phase = .failed("Please try again.") }
    }
}

/// Manual session-code entry.
struct JoinByCodeView: View {
    @Environment(\.container) private var container
    @State private var code = ""
    @State private var joinToken: FriendToken?

    var body: some View {
        Form {
            Section("Session code") {
                TextField("Paste code or link", text: $code).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Join") {
                    if let url = URL(string: code), case let .joinSession(token)? = container.deepLinkParser.parse(url) {
                        joinToken = token
                    } else { joinToken = FriendToken(rawValue: code.trimmingCharacters(in: .whitespaces)) }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.Palette.backgroundPrimary)
        .navigationTitle("Join a session").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $joinToken) { token in NavigationStack { JoinSessionView(token: token) } }
    }
}

/// The active session: members, clink, leave/end (master prompt §12).
struct ActiveSessionView: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    let session: PubSession
    @State private var members: [SessionMember] = []
    @State private var isHost = false

    var body: some View {
        List {
            Section("Who's here") {
                Text("\(members.count) at the session")
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Section {
                Button {
                    Task {
                        try? await container.sessions.createClink(sessionID: session.id, participants: members.map(\.userId))
                        Haptics.soft()
                    }
                } label: { Label("Clink with everyone here", systemImage: "hands.clap") }
            } footer: {
                Text("A clink is a shared memory. It doesn't change anyone's totals.")
            }
            Section {
                Button("Leave session") { Task { try? await container.sessions.leave(sessionID: session.id); dismiss() } }
                if isHost {
                    Button("End session for everyone", role: .destructive) {
                        Task { try? await container.sessions.end(sessionID: session.id); dismiss() }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.Palette.backgroundPrimary)
        .navigationTitle(session.name ?? "Session").navigationBarTitleDisplayMode(.inline)
        .task {
            members = (try? await container.sessions.fetchActiveMembers(sessionID: session.id)) ?? []
            isHost = await container.auth.currentUserID == session.hostUserId
        }
    }
}
