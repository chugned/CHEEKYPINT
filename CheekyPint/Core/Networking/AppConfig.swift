import Foundation

/// Which backend the running build points at. Injected from the active xcconfig via Info.plist.
enum AppEnvironmentKind: String {
    case development, staging, production
}

/// Read-only configuration loaded from Info.plist (which the xcconfig files populate). This
/// keeps the Supabase URL + anon key (both non-secret) out of source and per-environment.
/// No service-role key ever reaches the client (master prompt §14).
struct AppConfig: Sendable {
    let environment: AppEnvironmentKind
    let supabaseURL: URL
    let supabaseAnonKey: String
    let universalHost: String

    static let current: AppConfig = {
        let bundle = Bundle.main
        func string(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String) ?? ""
        }

        let env = AppEnvironmentKind(rawValue: string("CheekyPintEnvironment")) ?? .development
        let urlString = string("SupabaseURL")
        guard let url = URL(string: urlString), url.scheme != nil else {
            fatalError("SupabaseURL missing/invalid in Info.plist — check the active xcconfig. Got: '\(urlString)'")
        }
        return AppConfig(
            environment: env,
            supabaseURL: url,
            supabaseAnonKey: string("SupabaseAnonKey"),
            universalHost: string("CheekyPintUniversalHost")
        )
    }()

    var restURL: URL { supabaseURL.appendingPathComponent("rest/v1") }
    var authURL: URL { supabaseURL.appendingPathComponent("auth/v1") }
    var storageURL: URL { supabaseURL.appendingPathComponent("storage/v1") }
    var functionsURL: URL { supabaseURL.appendingPathComponent("functions/v1") }
}
