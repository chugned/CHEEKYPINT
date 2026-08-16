import Foundation

/// The two-step email one-time-code sign-in, as a state machine: enter an email, receive a
/// six-digit code, type it back. `AuthView` renders this and owns no logic of its own.
///
/// Split out of the view because every interesting rule here — when Resend unlocks, what a
/// rejected code is allowed to claim, which failures are the user's to fix and which are the
/// server's — is testable only if it isn't tangled in `body`.
///
/// The two network calls and the clock are injected. The clock in particular: a cooldown tested
/// by waiting for it is a test that sleeps, and this codebase has already shipped and then had to
/// remove one such delay. With `now` injected, "the cooldown has 43 seconds left" is an ordinary
/// pure-function assertion with a concrete input.
@MainActor
@Observable
final class EmailCodeSignIn {
    enum Step: Equatable { case email, code }

    /// What the screen is currently telling the user. Not all of these are failures — a
    /// successful resend needs saying too, because otherwise tapping "Send a new code" produces
    /// no visible change whatsoever and reads as a dead button.
    enum Notice: Equatable {
        case emailLooksWrong
        case codeIsSixDigits(typed: Int)
        /// GoTrue refuses a wrong code and an expired one identically — see
        /// `SupabaseError.invalidOrExpiredCode`.
        case codeRejected
        /// A 429 from the email sender. `serverSentence` is GoTrue's own wording, which carries
        /// the remaining wait in seconds; nothing on the client can work that number out.
        case sendThrottled(serverSentence: String?)
        case offline
        case failed(String)
        case codeSent(email: String)

        var isFailure: Bool {
            if case .codeSent = self { return false }
            return true
        }

        var text: String {
            switch self {
            case .emailLooksWrong:
                return "That doesn't look like an email address. Check it and try again."
            case let .codeIsSixDigits(typed):
                return typed == 0
                    ? "Type the six-digit code from your email."
                    : "The code is six digits — you've typed \(typed)."
            case .codeRejected:
                return SupabaseError.invalidOrExpiredCode.friendlyMessage
            case let .sendThrottled(sentence):
                // The server's sentence is appended, not paraphrased: it is the only source of
                // the actual wait, and a rate limit the user can't see the end of is the failure
                // this flow is most likely to hit (Supabase's built-in SMTP is throttled hard).
                let base = "Too many codes requested. The email service is rate-limiting us"
                guard let sentence, !sentence.isEmpty else { return base + " — give it a minute." }
                return base + ": " + sentence
            case .offline:
                return SupabaseError.offline.friendlyMessage
            case let .failed(message):
                return message
            case let .codeSent(email):
                return "New code sent to \(email). Use the newest one — the previous code stops working."
            }
        }
    }

    static let codeLength = 6

    /// Matches the 60s `SMTP_MAX_FREQUENCY` that hosted Supabase's built-in sender enforces per
    /// address. Held client-side purely so Resend is visibly disabled instead of inviting a tap
    /// that can only come back as a 429; the server remains the authority, and a 429 restarts
    /// this cooldown from whenever it arrived.
    static let resendCooldown: TimeInterval = 60

    private let send: (String) async throws -> Void
    private let verify: (String, String) async throws -> Void
    private let now: () -> Date

    private(set) var step: Step = .email
    private(set) var isWorking = false
    private(set) var notice: Notice?
    /// When Resend becomes available again. `nil` before the first send.
    private(set) var resendAvailableAt: Date?
    /// The address the code actually went to, shown on the code step so a typo is spottable
    /// without going back.
    private(set) var sentTo: String?

    var emailInput = ""
    var codeInput = ""

    init(
        send: @escaping (String) async throws -> Void,
        verify: @escaping (String, String) async throws -> Void,
        now: @escaping () -> Date = { Date() }
    ) {
        self.send = send
        self.verify = verify
        self.now = now
    }

    // MARK: Input shaping

    /// Trimmed and lowercased. Lowercasing matters: GoTrue treats addresses case-insensitively,
    /// but the address is also echoed back to the user on the code step, and iOS's own keyboard
    /// will happily capitalise the first letter of an address typed in a hurry.
    static func normalise(email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Deliberately permissive. A client-side email regex that rejects real addresses is worse
    /// than one that lets a typo through — the server rejects what it can't use, and this only
    /// exists so an obviously empty/spaceless-at-less entry fails instantly instead of costing a
    /// round trip and one of the user's scarce rate-limited sends.
    static func isPlausible(email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
            && !email.contains(" ")
    }

    /// Keeps digits only and stops at six. Handles the two ways a code arrives that aren't
    /// typing: pasting "Your code is 483920" and pasting the code with a stray space.
    static func digits(from raw: String) -> String {
        String(raw.filter(\.isNumber).prefix(codeLength))
    }

    // MARK: Cooldown

    func secondsUntilResend(now: Date) -> Int {
        guard let resendAvailableAt else { return 0 }
        return max(0, Int(resendAvailableAt.timeIntervalSince(now).rounded(.up)))
    }

    func canResend(now: Date) -> Bool {
        !isWorking && secondsUntilResend(now: now) == 0
    }

    // MARK: Steps

    /// Step 1 → step 2. Only advances if the code was actually accepted for sending: a throttled
    /// or offline send leaves the user on the email step, where the retry lives.
    func sendCode() async {
        guard !isWorking else { return }
        let address = Self.normalise(email: emailInput)
        guard Self.isPlausible(email: address) else {
            notice = .emailLooksWrong
            return
        }
        emailInput = address
        guard await performSend(to: address) else { return }
        sentTo = address
        codeInput = ""
        notice = nil
        step = .code
    }

    /// Step 2's "Send a new code". Same call as `sendCode`, but it must not silently no-op when
    /// the cooldown is still running, and on success it says so — see `Notice.codeSent`.
    func resendCode() async {
        guard let address = sentTo, canResend(now: now()) else { return }
        guard await performSend(to: address) else { return }
        codeInput = ""
        notice = .codeSent(email: address)
    }

    /// Back to step 1 with the address still in the field, so a one-character typo is a
    /// one-character fix.
    func editEmail() {
        guard !isWorking else { return }
        step = .email
        codeInput = ""
        notice = nil
    }

    func verifyCode() async {
        guard !isWorking, let address = sentTo else { return }
        let code = Self.digits(from: codeInput)
        guard code.count == Self.codeLength else {
            notice = .codeIsSixDigits(typed: code.count)
            return
        }
        isWorking = true
        notice = nil
        defer { isWorking = false }
        do {
            try await verify(address, code)
        } catch let error as SupabaseError {
            notice = Self.notice(for: error)
        } catch {
            notice = .failed("We couldn't check that code. Please try again.")
        }
    }

    // MARK: Internals

    /// `true` when the send was accepted. A 429 still arms the cooldown — the server has just
    /// told us it will refuse again, so leaving Resend enabled would only invite a second refusal.
    private func performSend(to address: String) async -> Bool {
        isWorking = true
        notice = nil
        defer { isWorking = false }
        do {
            try await send(address)
            resendAvailableAt = now().addingTimeInterval(Self.resendCooldown)
            return true
        } catch let error as SupabaseError {
            if case .rateLimited = error {
                resendAvailableAt = now().addingTimeInterval(Self.resendCooldown)
            }
            notice = Self.notice(for: error)
            return false
        } catch {
            notice = .failed("We couldn't send that code. Please try again.")
            return false
        }
    }

    /// The one place a `SupabaseError` becomes screen copy. `.server`/`.unknown`/`.decoding` keep
    /// `friendlyMessage`'s generic wording deliberately: those carry server strings that were
    /// never written for a user to read.
    static func notice(for error: SupabaseError) -> Notice {
        switch error {
        case .offline: return .offline
        case let .rateLimited(hint): return .sendThrottled(serverSentence: hint)
        case .invalidOrExpiredCode: return .codeRejected
        case let .validation(message): return .failed(message)
        case .notAuthenticated, .forbidden, .notFound, .server, .decoding, .unknown:
            return .failed(error.friendlyMessage)
        }
    }
}
