# App Store submission

## Listing metadata

- **Name:** CheekyPint
- **Subtitle:** Your social pub diary
- **Promotional text:** Remember the good rounds. Log your pub visits, keep your favourite
  haunts, and hold friendly standings with your mates.
- **Description:**
  > CheekyPint is a warm, playful diary for your pub life. Tap once to log a pint, remember the
  > pubs you love, and keep light-hearted standings with your mates.
  >
  > • One-tap logging with a satisfying "Pint logged. Cheers."
  > • See your totals for the session, week, month, and year.
  > • Add friends with a private QR code — no phone numbers, no searching strangers.
  > • Friendly standings among mates. No global leaderboards, ever.
  > • Find and remember your favourite pubs.
  > • Strong privacy: friends-only by default, city off, and a private diary option.
  >
  > CheekyPint is a diary, not a challenge. There are no streaks, no "drink more" nudges, and
  > nothing that rewards heavy drinking. Please enjoy a pint responsibly. You must be of legal
  > drinking age where you live.
- **Keywords:** pub,pint,beer diary,drinks log,pub crawl,mates,social,cheers,brewery,local
  *(avoid: "drink the most", "beat your mates", competition framing)*
- **Primary category:** Lifestyle · **Secondary:** Social Networking
- **Marketing URL:** https://cheekypint.app (placeholder)
- **Support URL:** https://cheekypint.app/support (placeholder)
- **Privacy Policy URL:** https://cheekypint.app/privacy (placeholder)

## Age rating

Expect **17+** (Frequent/Intense Alcohol, Tobacco, or Drug Use or References) because the app is
about logging alcoholic drinks. The app defaults to an 18+ experience and requires local legal-age
confirmation. No gambling, no user-generated public content beyond profiles.

## Permission strings (Info.plist — already set)

- **Camera:** "CheekyPint uses the camera to scan friend and pub-session QR codes."
- **Location (When In Use):** "CheekyPint uses your location while the app is open to help you
  find nearby pubs. Your location is not shared automatically."
- **Photo Library:** "CheekyPint lets you choose a profile picture from your photo library."

No background location, no "Always" location capability.

## App Review notes (paste into App Review Information)

> CheekyPint is a personal diary for logging your own pub visits and drinks, and keeping friendly
> standings with accepted friends. It does **not** sell alcohol, facilitate alcohol delivery,
> promote binge drinking, or incentivise excessive consumption. There are no drinking challenges,
> streaks, "drink more" prompts, or global leaderboards. After several drinks are logged in a
> short time, the app replaces any celebration with a welfare message. Users confirm they are of
> legal drinking age (not pre-checked) before use.
>
> **Demo account:** email `alice@cheekypint.test`, one-time code delivered by the configured
> email provider (or use Sign in with Apple). The demo project is seeded with friends, a session,
> and sample entries. Account deletion is available in Settings → Delete account.

## Data collection summary (App Privacy questionnaire)

See [APP_PRIVACY_DATA_MAPPING.md](APP_PRIVACY_DATA_MAPPING.md). No tracking, no ads. Precise
location is on-demand and not linked/stored.

## Account deletion

In-app: Settings → Delete account (type-to-confirm). Anonymises + tears down app data immediately;
the `delete-account` Edge Function completes storage + auth-user removal. No email-to-support step.

## Submission checklist (see also RELEASE_CHECKLIST.md)

- [ ] Apple Developer account + App ID `app.cheekypint.CheekyPint`
- [ ] Bundle identifier + signing certs + provisioning profiles
- [ ] **Sign in with Apple** capability + Services ID + key; configured in Supabase Auth
- [ ] **Associated Domains** `applinks:cheekypint.app` + `apple-app-site-association` hosted
- [ ] Privacy manifest (`PrivacyInfo.xcprivacy`) for the app + any SDKs
- [ ] App Privacy questionnaire completed to match the data mapping
- [ ] Privacy Policy + Terms URLs live
- [ ] Screenshots (see [APP_ICON_BRIEF.md](APP_ICON_BRIEF.md) storyboard) + 1024 app icon
- [ ] Age rating questionnaire (17+/alcohol)
- [ ] Export compliance: `ITSAppUsesNonExemptEncryption = false` (standard HTTPS only)
- [ ] TestFlight build + crash/accessibility passes
- [ ] Demo account works against the review environment
