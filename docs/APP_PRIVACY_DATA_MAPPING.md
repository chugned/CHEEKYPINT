# App Store privacy data mapping

Maps every collected field to Apple's **App Privacy** categories, purpose, linkage, and whether
it is used for tracking. CheekyPint does **no** tracking and shows **no** ads.

Legend — Linked: tied to the user's identity. Tracking: used to track across apps/companies (always **No** here).

| Data | Apple category | Purpose | Linked | Tracking |
|------|----------------|---------|:------:|:--------:|
| Email address (or Apple private-relay) | Contact Info → Email | App functionality (auth) | Yes | No |
| User ID (auth uuid) | Identifiers → User ID | App functionality | Yes | No |
| Display name / username / bio | User Content / Identifiers | App functionality | Yes | No |
| Profile photo (avatar) | User Content → Photos or Videos | App functionality | Yes | No |
| Broad city (optional) | Location → Coarse Location | App functionality (profile) | Yes | No |
| Precise location (on-demand pub search) | Location → Precise Location | App functionality (find nearby pubs) | No¹ | No |
| Pint entries (serving, time, alcohol-free) | User Content → Other | App functionality (the diary) | Yes | No |
| Private notes | User Content → Other | App functionality | Yes | No |
| Pub selections / visit history | User Content → Other | App functionality | Yes | No |
| Friends / blocks / reports | User Content → Other · Contacts (no) | App functionality | Yes | No |
| Product analytics events | Usage Data → Product Interaction | Analytics (improve app) | No² | No |
| Diagnostics (crash, if enabled) | Diagnostics → Crash Data | App functionality / diagnostics | No | No |

¹ Precise location is requested When-In-Use, used transiently to bias MapKit search, and is not
stored or linked. ² Analytics events carry no identifiers and are disabled by default (no-op).

## Not collected

- Contacts, browsing history, search history (outside the app), financial info, health data,
  advertising data, purchases.
- Background location, "Always" location — the app never requests these.

## App Review notes hook

The app logs user-entered drinks; it does not sell alcohol, facilitate delivery, promote binge
drinking, or incentivise excessive consumption. See [APP_STORE_SUBMISSION.md](APP_STORE_SUBMISSION.md).
