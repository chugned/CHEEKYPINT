import SwiftUI

/// Sign-in: an email address, then the six-digit code Supabase emails back. No password, no
/// Apple sign-in (that needs a paid developer account for the entitlement), no magic link (that
/// needs `apple-app-site-association` hosted at cheekypint.app, which isn't up yet). A typed code
/// needs nothing outside the app.
///
/// All of the logic lives in `EmailCodeSignIn`; this file is the surface.
struct AuthView: View {
    @Environment(SessionController.self) private var session

    @State private var model: EmailCodeSignIn?
    /// See `AccessibilityAnnouncer`'s doc — the notice below is a sibling `Text` that SwiftUI
    /// would never announce on its own, and it is the only feedback a rejected code produces.
    @State private var announcer = AccessibilityAnnouncer()
    @FocusState private var focused: Field?

    private enum Field: Hashable { case email, code }

    var body: some View {
        Group {
            if let model {
                switch model.step {
                case .email: emailStep(model)
                case .code: codeStep(model)
                }
            } else {
                // One frame at most: `.onAppear` below runs before the user can touch anything.
                OnboardingScaffold(systemImage: "envelope.fill", title: "One moment") {
                    ProgressView().tint(Theme.Palette.accent)
                } actions: {
                    EmptyView()
                }
            }
        }
        .onAppear {
            guard model == nil else { return }
            model = EmailCodeSignIn(
                send: { [session] address in try await session.sendSignInCode(to: address) },
                verify: { [session] address, code in try await session.signIn(email: address, code: code) }
            )
        }
        .navigationTitle("Sign in")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Step 1 — email

    private func emailStep(_ model: EmailCodeSignIn) -> some View {
        @Bindable var bindable = model
        return OnboardingScaffold(
            systemImage: "envelope.fill",
            title: "What's your email?",
            subtitle: "We'll send a six-digit code. No password to forget, and it's how your mates' phones find you."
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                TextField("you@example.com", text: $bindable.emailInput)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .focused($focused, equals: .email)
                    .onSubmit { Task { await model.sendCode() } }
                    .accessibilityIdentifier("auth-email-field")
                    .accessibilityLabel("Email address")

                Button {
                    focused = nil
                    Task { await model.sendCode() }
                } label: {
                    Label("Send my code", systemImage: "paperplane.fill")
                }
                .buttonStyle(PintButtonStyle())
                .disabled(model.isWorking || model.emailInput.isEmpty)
                .opacity(model.emailInput.isEmpty ? 0.55 : 1)
                .accessibilityIdentifier("auth-send-code")
                .accessibilityLabel("Send my code")

                notice(model)

                Text("Your address is used to sign you in and nothing else — no marketing, ever.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            LegalLinksView()
        }
        .overlay { if model.isWorking { ProgressView().tint(Theme.Palette.accent) } }
    }

    // MARK: Step 2 — code

    private func codeStep(_ model: EmailCodeSignIn) -> some View {
        OnboardingScaffold(
            systemImage: "envelope.open.fill",
            title: "Check your email",
            // The address goes in the caption below the field, not up here. At accessibility XXL
            // a subtitle carrying a full email address runs to eight or nine lines and pushes the
            // code field two screens down — see docs/ACCESSIBILITY_AUDIT.md's screenshots.
            subtitle: "Type the six-digit code we just sent you."
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                TextField("123456", text: Binding(
                    get: { model.codeInput },
                    // Filtered on the way in rather than validated on the way out, so pasting
                    // "Your code is 483920" out of the email lands as "483920".
                    set: { model.codeInput = EmailCodeSignIn.digits(from: $0) }
                ))
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .code)
                .accessibilityIdentifier("auth-code-field")
                .accessibilityLabel("Six-digit code")

                Button {
                    focused = nil
                    Task { await model.verifyCode() }
                } label: {
                    Label("Let me in", systemImage: "mug.fill")
                }
                .buttonStyle(PintButtonStyle())
                .disabled(model.isWorking)
                .accessibilityIdentifier("auth-verify-code")
                .accessibilityLabel("Let me in")

                notice(model)

                Text("Sent to \(model.sentTo ?? ""). It can take a moment, and it can land in spam.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("auth-sent-to")

                resendRow(model)
            }
        } actions: {
            VStack(spacing: Theme.Spacing.md) {
                Button("Use a different email") {
                    focused = nil
                    model.editEmail()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isWorking)
                .accessibilityIdentifier("auth-change-email")
                .accessibilityLabel("Use a different email")

                LegalLinksView()
            }
        }
        .overlay { if model.isWorking { ProgressView().tint(Theme.Palette.accent) } }
    }

    /// The countdown ticks on an *explicit* schedule that ends when the cooldown does, rather
    /// than `.periodic`, which would keep re-rendering this screen once a second for as long as
    /// it is on display — for nothing, since the label stops changing at zero.
    private func resendRow(_ model: EmailCodeSignIn) -> some View {
        TimelineView(.explicit(cooldownTicks(model))) { context in
            let remaining = model.secondsUntilResend(now: context.date)
            Button {
                Task { await model.resendCode() }
            } label: {
                Text(remaining == 0 ? "Send a new code" : "Send a new code in \(remaining)s")
                    .font(Theme.Typography.callout.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(remaining == 0 ? Theme.Palette.accent : Theme.Palette.textSecondary)
            .frame(minHeight: Theme.minTapTarget, alignment: .leading)
            .disabled(!model.canResend(now: context.date))
            .accessibilityIdentifier("auth-resend-code")
            .accessibilityLabel(remaining == 0
                                ? "Send a new code"
                                : "Send a new code, available in \(remaining) seconds")
        }
    }

    /// One tick a second up to the moment Resend unlocks, and always at least one entry —
    /// `TimelineView` renders nothing from an empty schedule.
    private func cooldownTicks(_ model: EmailCodeSignIn) -> [Date] {
        let start = Date()
        guard let until = model.resendAvailableAt, until > start else { return [start] }
        let seconds = Int(until.timeIntervalSince(start).rounded(.up))
        return (0...seconds).map { start.addingTimeInterval(TimeInterval($0)) }
    }

    /// An `HStack` with an explicitly wrapping `Text`, not a `Label`.
    ///
    /// `Label` rendered this on a single truncated line — "That code didn't work. It's either
    /// mistyped or past its ex…" — which drops both the second cause and the entire remedy, the
    /// only two things in the sentence a user can act on. The UI test did not catch it, because
    /// XCUITest reports the accessibility label (the full string) regardless of what was drawn;
    /// reading the screenshot did. `fixedSize(horizontal: false, vertical: true)` is what makes
    /// the text take the height it needs instead of being squeezed into the row.
    @ViewBuilder
    private func notice(_ model: EmailCodeSignIn) -> some View {
        if let notice = model.notice {
            HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                Image(systemName: notice.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .accessibilityHidden(true)
                Text(notice.text)
                    .font(Theme.Typography.caption)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("auth-notice")
                    .accessibilityLabel(notice.text)
            }
            .foregroundStyle(notice.isFailure ? Theme.Palette.warning : Theme.Palette.success)
            .onAppear { announcer.announce(notice.text) }
            .onChange(of: notice) { _, new in announcer.announce(new.text) }
        }
    }
}
