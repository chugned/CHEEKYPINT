import SwiftUI
import CheekyPintCore

/// The home screen — a premium digital pub coaster (master prompt §7). The "Log a pint" button
/// is the visual centre; everything else is calm and secondary.
struct HomeView: View {
    @Environment(SessionController.self) private var session
    @Environment(\.container) private var container
    @State private var model: HomeViewModel?
    @State private var showLogSheet = false
    @State private var showQR = false
    @State private var showPourCelebration = false
    @State private var pendingPourCelebration = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    LaunchView()
                }
            }
            .pubBackground()
            .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(isPresented: $showPourCelebration) {
            PintPourView { showPourCelebration = false }
                .presentationBackground(.clear)
        }
        .onChange(of: showLogSheet) { _, isPresented in
            if !isPresented && pendingPourCelebration {
                presentPourCelebrationAfterSheetDismissal()
            }
        }
        .task {
            if model == nil, let profile = session.currentProfile {
                let vm = HomeViewModel(container: container, profile: profile)
                model = vm
                await vm.onAppear()
            }
        }
        .onChange(of: session.currentProfile) { _, profile in
            if let profile {
                model?.syncProfile(profile)
            }
        }
    }

    private func queuePourCelebration() {
        pendingPourCelebration = true
        if !showLogSheet {
            presentPourCelebrationAfterSheetDismissal()
        }
    }

    private func presentPourCelebrationAfterSheetDismissal() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard pendingPourCelebration, !showLogSheet else { return }
            pendingPourCelebration = false
            showPourCelebration = true
        }
    }

    @ViewBuilder
    private func content(_ model: HomeViewModel) -> some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                header(model)
                sessionCount(model)
                logButton(model)
                undoBanner(model)
                periodSelector(model)
                StandingsPreview(
                    rows: model.standings,
                    period: model.selectedPeriod,
                    activities: model.beerActivities
                )
                    .onTapGesture { } // navigation below
                NavigationLink {
                    LeaderboardView(profile: model.profile, activeSession: model.activeSession)
                } label: {
                    Label("See full standings", systemImage: "chevron.right")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.accent)
                }
                if model.hasActiveSession {
                    ActiveFriendsStrip(members: model.activeMembers, session: model.activeSession)
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .refreshable { await model.load(); await model.loadStandings() }
        .sheet(isPresented: $showLogSheet) {
            LogPintSheet(profile: model.profile, activeSession: model.activeSession) { entry in
                await model.didLog(entry)
                showLogSheet = false
                queuePourCelebration()
            }
        }
        .sheet(isPresented: $showQR) { MyQRView() }
    }

    private func header(_ model: HomeViewModel) -> some View {
        HStack {
            RemoteAvatar(url: model.avatarURL, name: model.profile.displayName, size: 36)
            Spacer()
            Text("CheekyPint").font(Theme.Typography.wordmark).foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            Button { showQR = true } label: {
                Image(systemName: "qrcode").font(.title3)
            }
            .tint(Theme.Palette.accent)
            .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)
            .accessibilityLabel("Show my friend QR code")
        }
    }

    private func sessionCount(_ model: HomeViewModel) -> some View {
        VStack(spacing: Theme.Spacing.xxs) {
            Text(model.hasActiveSession ? "\(model.totals.session?.recordedCount ?? 0)" : "—")
                .font(Theme.Typography.count)
                .foregroundStyle(Theme.Palette.textPrimary)
                .contentTransition(.numericText())
            Text(model.sessionCountText)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.sessionCountText)
    }

    private func logButton(_ model: HomeViewModel) -> some View {
        Button {
            container.analytics.track(.pintFlowOpened)
            showLogSheet = true
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.Palette.backgroundSecondary)
                    .overlay(Circle().stroke(Theme.Palette.accent.opacity(0.65), lineWidth: 3))
                    .shadow(color: Theme.Palette.beer.opacity(0.36), radius: 24, y: 12)
                PintGlass(fill: model.homeGlassFill, edge: Theme.Palette.textPrimary)
                    .padding(38)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: model.homeGlassFill)
            }
            .frame(width: 188, height: 188)
        }
        .buttonStyle(ScaleButtonStyle())
        .padding(.vertical, Theme.Spacing.sm)
        .accessibilityLabel("Choose and log a beer")
    }

    @ViewBuilder
    private func undoBanner(_ model: HomeViewModel) -> some View {
        if let entry = model.lastLogged {
            HStack(alignment: .top) {
                Image(systemName: model.lastWasWelfare ? "drop.fill" : "checkmark.circle.fill")
                    .foregroundStyle(Theme.Palette.accent)
                    .accessibilityHidden(true)
                Text(model.confirmationMessage)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Button("Undo") { Task { await model.undoLast() } }
                    .font(Theme.Typography.callout.weight(.semibold))
                    .tint(Theme.Palette.accent)
            }
            .coasterCard()
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: entry.id) {
                // Auto-dismiss the undo affordance after a short grace period.
                try? await Task.sleep(for: .seconds(6))
                if model.lastLogged?.id == entry.id { model.lastLogged = nil }
            }
        }
    }

    private func periodSelector(_ model: HomeViewModel) -> some View {
        Picker("Period", selection: Binding(
            get: { model.selectedPeriod },
            set: { period in Task { await model.selectPeriod(period) } }
        )) {
            ForEach(LeaderboardPeriod.allCases) { period in
                Text(period.shortLabel).tag(period)
            }
        }
        .pickerStyle(.segmented)
    }
}
