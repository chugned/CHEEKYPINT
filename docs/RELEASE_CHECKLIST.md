# Release checklist

## Backend

- [ ] `supabase link` to the target project; `supabase db push` migrations
- [ ] `supabase functions deploy delete-account`; set `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_URL`,
      `SUPABASE_ANON_KEY` function secrets
- [ ] Configure Auth: enable Sign in with Apple (Services ID, key, team id) + email OTP; set
      Site URL + redirect URLs (`cheekypint://auth-callback`, `https://cheekypint.app/auth-callback`)
- [ ] Create the `avatars` storage bucket (migration does this) and confirm policies
- [ ] Schedule `prune_rate_limit_events` (daily) and any leaderboard cache jobs if added
- [ ] Verify RLS suite against a staging DB: `supabase/tests/run_local_pg.sh`

## App configuration

- [ ] Set `SUPABASE_URL` + `SUPABASE_ANON_KEY` in `Staging.xcconfig` / `Production.xcconfig`
- [ ] Bundle ids, `DEVELOPMENT_TEAM`, signing (Automatic or profiles)
- [ ] Host `apple-app-site-association` at `https://cheekypint.app/.well-known/`
- [ ] Confirm URL scheme + associated domains match entitlements

## Quality gates

- [ ] `cd CheekyPintCore && swift test` (or `swift run corecheck`) green
- [ ] App unit + UI tests green in Xcode
- [ ] Accessibility pass: VoiceOver on Home/log/undo/leaderboard; Dynamic Type XXL; Reduce Motion;
      contrast; 44pt targets
- [ ] Error/empty/offline/permission-denied states verified on each screen
- [ ] IPv6-only network test (App Review requirement)
- [ ] Crash-free smoke on a physical device + TestFlight

## Store

- [ ] Metadata, keywords, categories ([APP_STORE_SUBMISSION.md](APP_STORE_SUBMISSION.md))
- [ ] 1024 icon + screenshots per the storyboard
- [ ] App Privacy questionnaire matches [APP_PRIVACY_DATA_MAPPING.md](APP_PRIVACY_DATA_MAPPING.md)
- [ ] Age rating (17+/alcohol), export compliance, review notes + demo account
- [ ] Privacy Policy / Terms / Guidelines URLs live and reviewed by counsel

## Legal (before production launch)

- [ ] All `docs/legal/*` templates reviewed by a qualified professional
- [ ] Operator entity, address, DPO/contact, and processor/region details filled in
- [ ] GDPR data-subject request process in place
