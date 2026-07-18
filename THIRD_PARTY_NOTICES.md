# Third-party notices

CheekyPint deliberately minimises third-party dependencies (master prompt §4). The iOS app uses
**no third-party Swift packages** — only Apple frameworks. The backend and tooling use the
components below.

## iOS app — Apple frameworks only

SwiftUI, Foundation, Observation, Swift Concurrency, AuthenticationServices (Sign in with Apple),
VisionKit (`DataScannerViewController`), CoreImage (QR generation), CryptoKit (SHA-256, nonce),
MapKit + CoreLocation (pub search), PhotosUI (`PhotosPicker`), Security (Keychain), UIKit
(haptics, image resize). All governed by the Apple SDK/Xcode licence agreements.

Local package `CheekyPintCore` is first-party (this repository).

> If a third-party iOS dependency is ever added, it must be listed here with its licence, be
> actively maintained, be checked for privacy-manifest requirements, and be App Store compatible.

## Backend & tooling

| Component | Role | Licence |
|-----------|------|---------|
| Supabase (PostgreSQL, GoTrue, PostgREST, Storage, Edge Runtime) | Backend platform | Apache-2.0 / MIT (per component) |
| `@supabase/supabase-js` (Edge Function) | Deno client for `delete-account` | MIT |
| PostgreSQL + `pgcrypto`, `citext` | Database + extensions | PostgreSQL Licence |
| XcodeGen | Generates `CheekyPint.xcodeproj` from `project.yml` | MIT |

## Privacy manifests

The app ships a `PrivacyInfo.xcprivacy` declaring its data use and any required-reason APIs (e.g.
`UserDefaults`, file timestamp). Verify no linked SDK requires additional manifest entries before
submission (see [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md)).
