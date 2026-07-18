import Foundation
import CheekyPintCore

/// The diary: creating, undoing, and reading the caller's own pint entries. Totals are computed
/// locally by CheekyPintCore from the fetched entries, so period math stays in the tested core.
struct DiaryRepository: Sendable {
    let data: SupabaseData

    private func uid() async throws -> UUID {
        guard let uid = await data.auth.currentUserID else { throw SupabaseError.notAuthenticated }
        return uid
    }

    /// Log a pint via the idempotent RPC. Passing the same `idempotencyKey` again returns the
    /// same entry rather than creating a duplicate (master prompt §7.8).
    func createPint(
        idempotencyKey: IdempotencyKey,
        occurredAt: Date,
        serving: ServingType,
        volumeMl: Double?,
        alcoholFree: Bool,
        pubID: UUID?,
        sessionID: UUID?,
        note: String?,
        source: EntrySource = .manual
    ) async throws -> PintEntry {
        if await DemoWorld.shared.isActive {
            return await DemoWorld.shared.createPint(
                idempotencyKey: idempotencyKey.rawValue, occurredAt: occurredAt, serving: serving,
                volumeMl: volumeMl, alcoholFree: alcoholFree, pubID: pubID, sessionID: sessionID, note: note)
        }
        let params = CreatePintParams(
            pIdempotencyKey: idempotencyKey.rawValue,
            pOccurredAt: occurredAt,
            pServingType: serving.rawValue,
            pVolumeMl: serving == .custom ? volumeMl : nil,
            pAlcoholFree: alcoholFree,
            pPubId: pubID,
            pSessionId: sessionID,
            pPrivateNote: note,
            pSource: source.rawValue
        )
        return try await data.rpc("create_pint_entry", params: params)
    }

    @discardableResult
    func undoPint(id: UUID) async throws -> PintEntry {
        if await DemoWorld.shared.isActive {
            guard let entry = await DemoWorld.shared.undoPint(id: id) else { throw SupabaseError.notFound }
            return entry
        }
        return try await data.rpc("undo_recent_pint_entry", params: EntryIDParams(pEntryId: id))
    }

    /// Fetch the caller's recent live entries, newest first, for history + local totals.
    /// Paginated by `occurredAt` for the personal-history screen (master prompt §31).
    func fetchEntries(limit: Int = 200, before: Date? = nil) async throws -> [PintEntry] {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.liveEntries(limit: limit, before: before) }
        let id = try await uid()
        var query: [URLQueryItem] = [
            URLQueryItem(name: "user_id", value: "eq.\(id)"),
            URLQueryItem(name: "deleted_at", value: "is.null"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "occurred_at.desc"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let before {
            query.append(URLQueryItem(name: "occurred_at", value: "lt.\(SupabaseJSON.iso8601.string(from: before))"))
        }
        return try await data.select("pint_entries", query: query)
    }
}
