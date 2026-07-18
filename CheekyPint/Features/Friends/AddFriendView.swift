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
            resolvedToken = token
        } else if let token = FriendToken(rawValue: input) {
            resolvedToken = token
        } else {
            errorMessage = "That doesn't look like a valid friend code."
        }
    }
}
