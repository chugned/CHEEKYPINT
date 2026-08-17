import SwiftUI
import CheekyPintCore

/// Add-a-friend hub: scan a QR (VisionKit) or enter a code manually, with a clear camera
/// fallback (master prompt §8, §22). Resolves to a safe preview before any request is sent.
struct AddFriendView: View {
    @Environment(\.container) private var container
    @State private var showScanner = false
    @State private var manualCode = ""
    @State private var resolvedToken: FriendToken?
    @State private var errorMessage: String?

    /// Which field, if any, currently holds the keyboard. Read only by `present(_:)`, which
    /// clears it — see the note there for why that has to happen before the sheet, not after it.
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case manualCode }

    var body: some View {
        List {
            Section {
                Button { showScanner = true } label: {
                    Label("Scan a friend's code", systemImage: "qrcode.viewfinder")
                }
                .disabled(!QRScannerView.isSupported)
                if !QRScannerView.isSupported {
                    Text("The camera is unavailable. Enter the friend code instead.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Section("Enter a code") {
                TextField("Paste a friend code or link", text: $manualCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .manualCode)
                Button("Find friend") { resolveManual() }
                    .disabled(manualCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(Theme.Palette.warning).font(Theme.Typography.caption)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.backgroundPrimary)
        .navigationTitle("Add a mate")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showScanner) { scannerScreen }
        .sheet(item: $resolvedToken) { token in
            NavigationStack { FriendPreviewView(token: token) }
        }
    }

    private var scannerScreen: some View {
        ZStack(alignment: .topTrailing) {
            if QRScannerView.isSupported {
                QRScannerView { payload in handleScanned(payload) }
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text("Point at a friend's CheekyPint QR")
                        .font(Theme.Typography.callout)
                        .padding(Theme.Spacing.md)
                        .background(.black.opacity(0.5), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, Theme.Spacing.xxl)
                }
            } else {
                StatusView(systemImage: "camera.slash", title: "Camera unavailable",
                           message: "Enter the friend code instead.").pubBackground()
            }
            Button { showScanner = false } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white)
            }
            .padding(Theme.Spacing.lg)
            .accessibilityLabel("Close scanner")
        }
    }

    private func handleScanned(_ payload: String) {
        container.analytics.track(.friendQRScanned)
        showScanner = false
        resolve(payload)
    }

    private func resolveManual() {
        resolve(manualCode.trimmingCharacters(in: .whitespaces))
    }

    /// Accepts either a full deep link or a bare token.
    private func resolve(_ input: String) {
        errorMessage = nil
        if let url = URL(string: input), case let .addFriend(token)? = container.deepLinkParser.parse(url) {
            present(token)
        } else if let token = FriendToken(rawValue: input) {
            present(token)
        } else {
            // Deliberately does *not* clear `focusedField`: a code that didn't parse is a code the
            // user still has to correct, so the keyboard stays where they need it.
            errorMessage = "That doesn't look like a valid friend code."
        }
    }

    /// The one place the preview sheet is presented — and the keyboard is given up *here*, before
    /// the presentation, rather than anywhere in the dismissal.
    ///
    /// UIKit restores first responder when a modal it presented goes away. So a `TextField` that
    /// was still focused when the sheet went up gets its keyboard back the instant the preview is
    /// closed, and that keyboard (`{{0,583},{402,233}}`) sits over the whole tab bar (the Settings
    /// tab is at `{{303,795},{74,54}}`): every tab button then computes a hit point of `{-1,-1}`
    /// and swallows the tap, leaving a real user stuck on this screen until they scroll or
    /// navigate. Resigning before presenting means there is nothing left for UIKit to restore,
    /// which is why this needs no delay, no `onDismiss` hook and no threshold to tune — the
    /// keyboard cannot come back from a first responder that no longer exists.
    ///
    /// Both routes in — a scanned QR (`handleScanned`) and a typed/pasted code (`resolveManual`) —
    /// funnel through here, so neither can present the sheet with the field still focused.
    private func present(_ token: FriendToken) {
        focusedField = nil
        resolvedToken = token
    }
}
