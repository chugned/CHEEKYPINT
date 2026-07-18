import SwiftUI

/// Friend-circle entry. No Apple, no email, no ceremony: type a surname and start the local pub.
struct AuthView: View {
    @Environment(SessionController.self) private var session

    @State private var surname = ""
    @State private var isWorking = false

    var body: some View {
        OnboardingScaffold(
            systemImage: "person.text.rectangle.fill",
            title: "Surname, please.",
            subtitle: "No Apple sign-in. No email code. Just your table name, so the group chat knows who to blame."
        ) {
            VStack(spacing: Theme.Spacing.md) {
                TextField("e.g. Vejo", text: $surname)
                    .textContentType(.familyName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.go)
                    .onSubmit { start() }

                Button {
                    start()
                } label: {
                    Label("Enter the nonsense", systemImage: "mug.fill")
                }
                .buttonStyle(PintButtonStyle())
                .disabled(cleanSurname.isEmpty || isWorking)
                .opacity(cleanSurname.isEmpty ? 0.55 : 1)

                Text("This stays on this phone. The official identity provider is now vibes.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            LegalLinksView()
        }
        .overlay { if isWorking { ProgressView().tint(Theme.Palette.accent) } }
        .navigationTitle("Enter")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var cleanSurname: String {
        surname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func start() {
        guard !cleanSurname.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            await session.enterFriendCircleMode(surname: cleanSurname)
            isWorking = false
        }
    }
}
