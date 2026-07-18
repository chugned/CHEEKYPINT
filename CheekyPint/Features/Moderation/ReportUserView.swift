import SwiftUI
import CheekyPintCore

/// Report a user (master prompt §19). Queues a moderation report server-side.
struct ReportUserView: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    let userID: UUID

    @State private var category: ReportCategory = .inappropriateText
    @State private var details = ""
    @State private var isSending = false
    @State private var sent = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    Picker("Reason", selection: $category) {
                        ForEach(ReportCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Details (optional)") {
                    TextField("Anything we should know?", text: $details, axis: .vertical).lineLimit(3...6)
                }
                if sent {
                    Label("Thanks — our team will take a look.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Palette.success)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(Theme.Palette.warning) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.backgroundPrimary)
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await send() } }.disabled(isSending || sent)
                }
            }
        }
    }

    private func send() async {
        isSending = true; errorMessage = nil
        defer { isSending = false }
        do {
            try await container.friends.report(userID, category: category, details: details.isEmpty ? nil : details)
            sent = true
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        } catch let error as SupabaseError { errorMessage = error.friendlyMessage }
        catch { errorMessage = "Please try again." }
    }
}
