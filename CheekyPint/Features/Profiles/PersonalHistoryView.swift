import SwiftUI
import CheekyPintCore

/// The personal diary — the user's own entries, newest first, with undo (master prompt §25).
/// Paginated for performance (§31). Alcohol-free entries are clearly labelled.
struct PersonalHistoryView: View {
    @Environment(\.container) private var container
    @State private var entries: [PintEntry] = []
    @State private var isLoading = false
    @State private var canLoadMore = true

    var body: some View {
        List {
            if entries.isEmpty && !isLoading {
                StatusView(systemImage: "book", title: "Your diary is empty",
                           message: "Log your first pint and it'll appear here.")
            }
            ForEach(entries) { entry in
                row(entry)
                    .swipeActions {
                        Button("Undo", role: .destructive) { Task { await undo(entry) } }
                    }
            }
            if canLoadMore && !entries.isEmpty {
                ProgressView().tint(Theme.Palette.accent)
                    .frame(maxWidth: .infinity)
                    .task { await loadMore() }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.backgroundPrimary)
        .navigationTitle("My diary")
        .navigationBarTitleDisplayMode(.inline)
        .task { if entries.isEmpty { await loadMore() } }
    }

    private func row(_ entry: PintEntry) -> some View {
        HStack {
            Image(systemName: entry.alcoholFree ? "drop.fill" : "mug.fill")
                .foregroundStyle(entry.alcoholFree ? Theme.Palette.accent : Theme.Palette.beer)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(entry.servingType.displayName).foregroundStyle(Theme.Palette.textPrimary)
                    if entry.alcoholFree {
                        Text("Alcohol-free")
                            .font(Theme.Typography.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.Palette.success.opacity(0.2), in: Capsule())
                            .foregroundStyle(Theme.Palette.success)
                    }
                }
                Text(entry.occurredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
        }
        .listRowBackground(Theme.Palette.backgroundSecondary)
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true; defer { isLoading = false }
        let before = entries.last?.occurredAt
        let page = (try? await container.diary.fetchEntries(limit: 50, before: before)) ?? []
        entries.append(contentsOf: page)
        canLoadMore = page.count == 50
    }

    private func undo(_ entry: PintEntry) async {
        try? await container.diary.undoPint(id: entry.id)
        container.analytics.track(.pintUndone)
        entries.removeAll { $0.id == entry.id }
    }
}
