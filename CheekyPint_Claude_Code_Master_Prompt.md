# CheekyPint — Claude Code Master Prompt

You are Claude Code acting as a senior iOS engineer, backend engineer, product designer, security engineer, and App Store release manager.

Build a production-ready iPhone application called **CheekyPint**.

The application must be sufficiently complete, secure, polished, documented, and tested for submission to the Apple App Store. Do not create only a visual prototype. Build a functional MVP with a real backend, authentication, database migrations, QR-code friendship, privacy controls, tests, documentation, and App Store preparation materials.

## 1. Product concept

CheekyPint is a playful social beer diary for adults.

Users can:

- Record a pint by pressing one prominent button.
- See how many pints they have recorded:
  - during the current pub session;
  - today;
  - this week;
  - this month;
  - this calendar year;
  - all time.
- Add friends by showing or scanning a personal QR code.
- See a leaderboard among accepted friends.
- View a friend's profile, subject to that friend's privacy settings.
- See which pubs a friend visits most frequently.
- Optionally show a broad home location, such as “Graz, Austria,” but never an exact home address.
- Start or join a pub session with friends.
- See which accepted friends are currently participating in the same session.

The emotional character should be:

- cheeky;
- British-pub inspired;
- adult;
- social;
- simple;
- warm;
- witty;
- premium rather than childish;
- playful without encouraging dangerous drinking.

The experience must never reward, pressure, praise, or challenge users to consume excessive amounts of alcohol.

## 2. Important terminology

Internally distinguish these concepts:

- **Pint entry:** one drink recorded by a user.
- **Clink:** a social interaction between two or more users during a shared pub session.
- **Pub session:** a temporary gathering at a pub.
- **Friendship:** a mutually accepted connection.
- **Leaderboard:** a summary among friends, not a global drinking competition.

Do not use “clink” as an incorrect synonym for every beer. The primary action can say:

**Log a pint**

The satisfying confirmation after logging can say:

**Pint logged. Cheers.**

A clink is recorded separately when friends confirm that they are together.

## 3. Safety and product positioning

This requirement is critical.

The application must be positioned as a social drinking diary and pub memory application—not as a system that encourages users to drink the largest amount possible.

Implement the following safeguards:

1. Require users to confirm that they are of legal drinking age in their jurisdiction before creating an account.
2. The application should default to an 18+ adult experience, while clearly stating that users must satisfy the legal drinking age where they live.
3. Display a short responsible-drinking message during onboarding.
4. Do not include:
   - drinking challenges;
   - speed-drinking mechanics;
   - “drink more” notifications;
   - dangerous streaks;
   - unlimited-consumption achievements;
   - countdowns between drinks;
   - public global rankings;
   - rewards based purely on consuming high quantities.
5. A friend leaderboard may display logged totals, but use neutral language such as:
   - “Friend standings”
   - “Pints recorded”
   - “Pub regulars”
6. Avoid celebratory animations after unusually high consumption.
7. After repeated entries within a short period, replace celebratory feedback with a neutral welfare notice:
   - “Take it easy. Have some water and look after yourself.”
8. Do not diagnose intoxication or make medical claims.
9. Include a permanent “Drink responsibly” link in Settings.
10. Make it possible to hide all quantities from friends while continuing to use the private diary.
11. Prepare App Review notes explaining that the app logs user-entered drinks but does not sell alcohol, facilitate alcohol delivery, promote binge drinking, or incentivize excessive consumption.

## 4. Technology stack

Build the application using:

### iOS client

- Swift
- SwiftUI
- iOS 17 or later
- Xcode project using standard Apple-supported project structure
- Swift Concurrency with async/await
- Observation framework or a clean MVVM architecture
- NavigationStack
- Swift Charts where appropriate
- VisionKit DataScannerViewController for QR scanning
- Core Location only when the user explicitly requests nearby pubs or chooses to attach a location
- MapKit for pub search and pub display
- PhotosPicker for profile-picture selection
- Keychain for sensitive local credentials or session material
- Local caching for graceful loading and temporary offline support

Do not use a cross-platform framework unless an existing repository already requires it.

### Backend

Use Supabase for:

- PostgreSQL;
- authentication;
- row-level security;
- storage for profile images;
- server-side database functions;
- optional realtime session updates;
- Edge Functions where privileged backend logic is necessary.

Authentication methods:

- Sign in with Apple;
- email magic link as a secondary method.

Do not implement Google or Facebook authentication in the MVP.

### Dependency policy

Use as few third-party iOS dependencies as possible.

Prefer native Apple frameworks.

Every dependency must be:

- necessary;
- actively maintained;
- documented in THIRD_PARTY_NOTICES.md;
- checked for privacy-manifest requirements;
- compatible with App Store submission.

## 5. Visual direction

The interface must be extremely simple.

The home screen should feel like a premium digital pub coaster.

Visual style:

- dark stout-brown or near-black background;
- warm cream typography;
- one restrained amber accent;
- subtle red accent only when necessary;
- large confident typography;
- rounded but not bubbly;
- tactile pressed-button animation;
- plenty of empty space;
- no gradients unless extremely subtle;
- no generic AI-dashboard aesthetic;
- no excessive cards;
- no glassmorphism overload;
- no casino-like visuals;
- no neon gaming interface.

Use SF Symbols wherever suitable.

Create a small design-token system:

- backgroundPrimary
- backgroundSecondary
- textPrimary
- textSecondary
- accentAmber
- warning
- success
- spacing scale
- corner-radius scale
- typography scale

Support:

- Dark Mode as the primary appearance;
- Light Mode as a fully functional alternative;
- Dynamic Type;
- VoiceOver;
- Reduce Motion;
- sufficient contrast;
- minimum 44-point interaction targets.

## 6. Information architecture

Use a maximum of four primary destinations:

1. Home
2. Friends
3. Pubs
4. Profile

Use a discreet bottom tab bar or another native navigation pattern.

The logging button must remain the visual centre of the application.

## 7. Home screen

The home screen must contain:

### Header

- Current user's small profile image.
- “CheekyPint” wordmark.
- QR-code shortcut.

### Main count

Display the current pub-session count prominently:

**2 pints this session**

If there is no active session:

**No active pub session**

Do not require an active session to log a private pint.

### Primary action

One large central button:

**LOG A PINT**

Button interaction:

1. User taps the button.
2. Present a lightweight confirmation sheet.
3. Default timestamp is now.
4. User may optionally:
   - select the pub;
   - attach the pint to an active session;
   - change drink size;
   - mark it alcohol-free;
   - add a private note.
5. The pint is stored only after confirmation.
6. Provide an Undo action immediately after saving.
7. Prevent accidental double taps by disabling submission while the request is processing.
8. Use an idempotency key so retrying a request cannot create duplicate entries.

Do not assume every recorded beer is literally one imperial pint.

Supported serving sizes:

- Half pint
- Pint
- 330 ml
- 500 ml
- Custom
- Alcohol-free

The leaderboard should count entries or standardised servings according to an explicit, documented rule. For the MVP, display “pints recorded” based on user entries while preserving the actual serving size in the database.

### Period selector

Provide a compact segmented control:

- Now
- Week
- Month
- Year

“Now” means the currently active pub session, not the current instant or current day.

The selected period changes the compact friend standings shown below.

### Friend standings preview

Show the top three accepted friends for the selected period:

- rank;
- profile image;
- display name;
- recorded total.

Include the current user even when they are not in the top three.

Selecting the section opens the complete friends leaderboard.

### Active friends

When friends are part of the same confirmed pub session, show:

- profile image;
- first name or display name;
- session status;
- optional clink action.

Do not expose a user's live location merely because they logged a pint.

## 8. Friends and QR-code flow

Each account receives a random, revocable public friend code.

The personal QR code must contain a secure deep link such as:

```text
cheekypint://friend/<opaque-token>
```

Never place any of the following directly in the QR payload:

- email address;
- database UUID;
- exact location;
- access token;
- session token;
- personal profile data.

Friend flow:

1. User A opens “My QR”.
2. User B scans it.
3. App resolves the opaque token through the backend.
4. User B sees a safe profile preview:
   - profile image;
   - display name;
   - broad city only if public;
   - mutual friends if implemented later.
5. User B sends a friend request.
6. User A accepts or declines.
7. Only accepted friends enter each other's private leaderboard scope.
8. A user can:
   - remove a friend;
   - block a user;
   - regenerate their QR friend code;
   - report a profile;
   - hide their statistics.

Also support:

- scanning through the camera;
- importing a QR code from an image when practical;
- manually entering a short friend code;
- universal-link fallback for recipients who do not have the app installed.

Provide clear camera permission copy:

“CheekyPint uses the camera only to scan friend QR codes.”

## 9. Friend leaderboard

Leaderboard periods:

- Current session
- This week
- This month
- This year

Use calendar-aware date calculations.

Default rules:

- Week follows the user's locale and calendar settings.
- Month means local calendar month.
- Year means local calendar year.
- Store timestamps in UTC.
- Calculate display periods using the user's configured time zone.
- Session totals come from the explicit session membership and session time range.

Leaderboard rows show:

- rank;
- profile image;
- display name;
- total;
- subtle marker for the current user.

Privacy rules:

- Only accepted friends are visible.
- Users can separately control visibility for:
  - session total;
  - weekly total;
  - monthly total;
  - yearly total;
  - favourite pubs;
  - city;
  - profile picture.
- Blocked users must never appear.
- Users who hide totals can appear as:
  - “Private”
  rather than being silently assigned zero.
- There is no global leaderboard in the MVP.

Use neutral visual treatment. Do not make the highest alcohol total look heroic or medically desirable.

## 10. User profiles

A profile contains:

- profile picture;
- display name;
- optional username;
- optional short biography;
- broad city and country;
- selected visibility controls;
- period totals;
- favourite pubs;
- recent shared pub sessions, when both users participated;
- date friendship was established.

Never show an exact residential address.

Never infer a user's home from their pub activity.

The “where he lives” requirement must be implemented as an optional, user-entered broad location, for example:

- Graz, Austria
- Vienna, Austria
- Berlin, Germany

This field must be:

- optional;
- private by default;
- editable;
- separately hideable from friends;
- excluded from QR payloads;
- excluded from analytics.

Favourite pubs should be calculated from confirmed pub-linked entries, with the user able to hide or exclude particular visits.

Show a maximum of five favourite pubs:

- pub name;
- city;
- visit count;
- last visit month;
- optional shared-visit count.

Do not show the precise time of another user's visit unless it was a mutually joined session and the session remains visible.

## 11. Pub system

Allow users to:

- search for nearby pubs;
- search by name and city;
- select a pub when logging a pint;
- create a missing pub suggestion;
- view pub details;
- see their own visit history;
- see accepted friends who deliberately joined the same active session.

Prefer Apple MapKit and local search for the MVP.

Persist a stable internal pub record after selection:

- internal ID;
- MapKit identifier when available;
- name;
- formatted public address;
- latitude;
- longitude;
- city;
- country;
- source;
- created_at;
- updated_at.

Pub coordinates are public business locations, but a user's visit history remains private user data.

Do not automatically begin background location tracking.

Do not request “Always” location permission.

Request “When In Use” location only after the user explicitly opens nearby-pub functionality.

Provide a manual pub-search fallback if location permission is declined.

## 12. Pub sessions and clinks

A user may create a temporary pub session.

Session fields:

- ID;
- optional selected pub;
- host;
- start timestamp;
- end timestamp;
- status;
- join code;
- QR join token;
- visibility;
- created_at.

Joining:

- through session QR;
- through short code;
- through an invitation from an accepted friend.

A user must explicitly join.

Do not infer session participation from proximity.

A clink can be created only when:

- both users are accepted friends or accepted session participants;
- both are members of the same active session;
- the clink is confirmed by the initiating user;
- duplicate clinks are rate-limited.

Clinks are decorative social memories and do not increase the beer total.

## 13. Database design

Create SQL migrations for at least the following tables:

### profiles

- id UUID primary key, references auth.users
- display_name
- username
- bio
- avatar_path
- city
- country_code
- legal_age_confirmed_at
- timezone
- locale
- created_at
- updated_at
- deleted_at

### privacy_settings

- user_id
- profile_visibility
- avatar_visibility
- city_visibility
- session_total_visibility
- weekly_total_visibility
- monthly_total_visibility
- yearly_total_visibility
- favourite_pubs_visibility
- shared_sessions_visibility
- created_at
- updated_at

Visibility enum:

- private
- friends

Do not build public visibility in the MVP.

### friend_tokens

- id
- user_id
- token_hash
- expires_at
- revoked_at
- created_at

Store only a cryptographic hash of the raw friend token where practical.

### friendships

- id
- requester_id
- addressee_id
- status: pending, accepted, declined, removed
- requested_at
- responded_at
- updated_at

Add uniqueness constraints preventing duplicate active relationships in either direction.

### blocks

- blocker_id
- blocked_id
- created_at

### reports

- id
- reporter_id
- reported_user_id
- category
- details
- status
- created_at
- reviewed_at

### pubs

- id
- external_source
- external_identifier
- name
- formatted_address
- city
- country_code
- latitude
- longitude
- created_by
- created_at
- updated_at

### pub_sessions

- id
- pub_id
- host_user_id
- name
- status
- started_at
- ended_at
- join_token_hash
- created_at
- updated_at

### session_members

- session_id
- user_id
- role
- joined_at
- left_at
- visibility_status

### pint_entries

- id
- user_id
- pub_id nullable
- session_id nullable
- occurred_at
- serving_type
- volume_ml nullable
- alcohol_free boolean
- private_note nullable
- source
- idempotency_key
- created_at
- updated_at
- deleted_at

Apply a unique constraint to user_id plus idempotency_key.

### clinks

- id
- session_id
- created_by
- created_at

### clink_participants

- clink_id
- user_id
- confirmed_at

### user_pub_preferences

Use this table only if necessary for explicit user overrides such as hiding a pub from favourite-pub calculations.

Create:

- indexes;
- foreign keys;
- check constraints;
- enum types where appropriate;
- update timestamp triggers;
- soft-deletion strategy;
- test seed data.

## 14. Security and row-level security

Treat Row Level Security as mandatory.

Create explicit RLS policies for every exposed table.

Core principles:

- Users can update only their own profile.
- Users can read another profile only when the privacy rules and accepted friendship permit it.
- A pending friend request exposes only the minimum safe profile preview.
- Users can see friendship rows involving themselves.
- Users can read only their own pint entries.
- Friend totals must be returned through a secure database function or backend endpoint that applies privacy and friendship rules.
- Users must never receive raw private pint-entry rows belonging to friends.
- Users can view sessions only when they are members or have a valid invitation.
- Block relationships override every friendship, profile, leaderboard, and session rule.
- Service-role credentials must never appear in the iOS client.
- Validate all token redemption server-side.
- Rate-limit:
  - friend-token resolution;
  - friend requests;
  - session joins;
  - pint creation;
  - report submission.
- Sanitize all user-provided profile text.
- Prevent username enumeration where possible.
- Do not expose sequential IDs.
- Add authorization tests for all important RLS paths.

Build secure database functions such as:

- get_friend_leaderboard(period_start, period_end, session_id)
- get_friend_profile(friend_user_id)
- resolve_friend_token(raw_token)
- create_pint_entry(...)
- undo_recent_pint_entry(entry_id)
- get_favourite_pubs(profile_user_id)
- block_user(target_user_id)
- delete_account()

Use SECURITY DEFINER only when truly necessary. Lock down search_path and permissions for every privileged function.

## 15. Date and counting rules

Document the exact counting behaviour.

A pint entry counts when:

- it has not been soft deleted;
- occurred_at falls within the selected period;
- it belongs to the relevant user;
- visibility rules permit an aggregate to be shown.

Alcohol-free entries:

- appear in the user's personal diary;
- are clearly labelled alcohol-free;
- are excluded from alcohol-related friend totals by default;
- may be included in a separate “drinks logged” statistic later.

Current session:

- includes entries connected to the selected active session;
- starts at the session's started_at;
- ends at ended_at or now when active.

Undo:

- should work immediately;
- should soft-delete the entry;
- should not leave leaderboard caches inconsistent.

Do not trust the device clock as the only authoritative timestamp. Record a server-created timestamp and optionally retain the user-selected occurred_at value.

## 16. Anti-cheating and data integrity

This is a casual social application, not a certified measurement system, but basic abuse protection is required.

Implement:

- idempotency keys;
- server-side timestamps;
- rate limits;
- impossible-frequency flagging;
- transactional leaderboard calculations;
- audit metadata;
- soft deletion;
- server validation of session membership;
- clear indication that totals are self-reported.

Do not publicly accuse users of cheating.

Do not create invasive identity verification.

## 17. Authentication and onboarding

Onboarding sequence:

1. Brand introduction.
2. Responsible-use statement.
3. Legal-drinking-age confirmation.
4. Sign in with Apple or email magic link.
5. Choose display name.
6. Add optional profile picture.
7. Add optional broad city.
8. Configure initial privacy:
   - recommended default: friends only for profile;
   - city off;
   - favourite pubs off;
   - totals visible to accepted friends;
   - recent shared sessions on.
9. Optional invitation to add the first friend.
10. Home screen.

Requirements:

- Do not pre-check age confirmation.
- Provide links to:
  - Privacy Policy;
  - Terms of Use;
  - Community Guidelines;
  - Responsible Drinking information.
- Explain why each permission is needed before showing the system permission prompt.
- Users may skip profile image and city.
- Support Sign in with Apple private relay email addresses.
- Handle cancelled or failed authentication gracefully.
- Preserve onboarding progress locally when safe.

## 18. Settings

Include:

### Account

- Edit profile
- Change username
- Change broad location
- Regenerate friend QR code
- Sign out
- Delete account

### Privacy

- Profile visibility
- Profile-picture visibility
- City visibility
- Period-total visibility
- Favourite-pub visibility
- Shared-session visibility
- Blocked users
- Download or export my data

### Safety

- Drink responsibly
- Community Guidelines
- Report a problem
- Support

### Legal

- Privacy Policy
- Terms of Use
- App version
- Open-source notices

Account deletion must be initiated inside the app.

Deletion flow:

1. Explain what will be deleted.
2. Ask for explicit confirmation.
3. Reauthenticate when required.
4. Delete or anonymise data according to the documented retention policy.
5. Remove profile images from storage.
6. Revoke active sessions.
7. Sign the user out.
8. Present confirmation.

Do not require users to email support to delete an account.

## 19. Moderation

Because users can upload profile pictures and profile text, implement basic user-generated-content protection:

- block user;
- report user;
- remove friend;
- profile-text limits;
- profile-image limits;
- community guidelines;
- backend report queue;
- support contact;
- ability for an administrator to disable an abusive profile.

Do not add public posts, comments, direct messaging, anonymous chat, or image feeds in the MVP.

Keeping the social surface constrained will simplify moderation and App Store review.

## 20. Analytics and privacy

Default to privacy-preserving analytics.

Track only product events necessary to improve the application, such as:

- onboarding completed;
- pint-entry flow opened;
- pint saved;
- pint undone;
- friend QR opened;
- friend QR scanned;
- friend request accepted;
- session created;
- session joined.

Never send to analytics:

- exact location;
- pub visit history;
- drink notes;
- friend names;
- profile pictures;
- email addresses;
- friend QR payloads;
- raw alcohol totals tied to an external analytics identity.

Provide a central AnalyticsService protocol so analytics can initially be disabled or replaced.

Do not include advertising SDKs.

Do not enable cross-app tracking.

Create an APP_PRIVACY_DATA_MAPPING.md file mapping every collected field to the appropriate App Store privacy-disclosure category and purpose.

## 21. Accessibility

Implement and test:

- VoiceOver labels for the main button;
- VoiceOver announcement after logging and undoing;
- Dynamic Type without truncating essential values;
- sufficient contrast;
- accessible leaderboard rows;
- non-colour indicators for rank and status;
- Reduce Motion support;
- logical keyboard and switch-control order;
- descriptive camera-scanner instructions;
- haptic feedback that is supplementary, not required.

Example VoiceOver label:

“Log a pint. Opens a confirmation screen.”

Do not make the central button trigger immediately without accessible confirmation.

## 22. Error handling and states

Every screen must support:

- loading;
- empty;
- offline;
- permission denied;
- authentication expired;
- request failed;
- retry;
- blocked or unavailable content.

Examples:

Leaderboard empty state:

**No standings yet. Add a mate or log your first pub visit.**

No favourite pubs:

**No regular haunt yet. Your favourite pubs will appear after a few visits.**

Camera unavailable:

**The camera is unavailable. Enter the friend code instead.**

Location denied:

**Search for a pub manually, or enable location access in Settings.**

Use friendly language, but never sacrifice clarity.

## 23. Offline behaviour

Provide reasonable offline support:

- cache the current user's profile;
- cache the last successfully loaded leaderboard;
- allow viewing recent personal entries;
- queue a pint entry only when safe;
- attach a stable idempotency key;
- clearly show pending synchronization;
- retry automatically when connectivity returns;
- avoid silently showing stale data as current.

Do not allow offline friend-token redemption or session joining.

## 24. Testing

Create:

### Unit tests

- period calculations;
- week/month/year boundaries;
- time-zone changes;
- daylight-saving transitions;
- leaderboard transformations;
- privacy visibility logic;
- idempotency behaviour;
- serving-size mapping;
- session totals;
- favourite-pub calculations;
- username validation.

### Integration tests

- authentication;
- profile creation;
- friend request and acceptance;
- block overriding friendship;
- QR-token redemption;
- pint creation;
- pint undo;
- leaderboard visibility;
- pub-session joining;
- account deletion;
- storage cleanup.

### RLS tests

Test both allowed and denied paths:

- stranger cannot read private profile;
- friend can read permitted aggregate;
- friend cannot read raw entries;
- blocked user cannot read profile or leaderboard;
- user cannot edit another user's entry;
- user cannot join a private session without a valid invitation;
- revoked QR token cannot resolve;
- deleted account does not remain visible.

### UI tests

- onboarding;
- log and undo a pint;
- scan-code fallback;
- add friend;
- switch leaderboard period;
- open friend profile;
- change privacy;
- delete account.

Provide deterministic fixtures and seed data.

## 25. Required application screens

Build all of these screens:

1. Launch screen
2. Welcome screen
3. Responsible-use and age-confirmation screen
4. Authentication screen
5. Profile setup
6. Privacy setup
7. Home
8. Pint confirmation sheet
9. Personal history
10. Full friend leaderboard
11. Friends list
12. Pending requests
13. My QR code
14. QR scanner
15. Manual friend-code entry
16. Friend preview
17. Friend profile
18. Pub search
19. Pub details
20. Create session
21. Active session
22. Join session
23. Edit profile
24. Privacy settings
25. Blocked users
26. Report user
27. Responsible-use information
28. Account deletion
29. Legal and support screen

## 26. Repository structure

Use a clean feature-oriented structure similar to:

```text
CheekyPint/
  App/
  Core/
    Authentication/
    Networking/
    Database/
    DesignSystem/
    Analytics/
    Location/
    QR/
    Utilities/
  Features/
    Onboarding/
    Home/
    PintLogging/
    Friends/
    Leaderboard/
    Profiles/
    Pubs/
    Sessions/
    Settings/
    Moderation/
  Models/
  Resources/
  PreviewContent/
  Tests/
  UITests/

supabase/
  migrations/
  functions/
  seed.sql
  tests/

docs/
  ARCHITECTURE.md
  DATABASE.md
  PRIVACY.md
  SECURITY.md
  APP_STORE_SUBMISSION.md
  APP_PRIVACY_DATA_MAPPING.md
  MODERATION.md
  RESPONSIBLE_DRINKING.md
  RELEASE_CHECKLIST.md
  TESTING.md
  THREAT_MODEL.md
```

Also create:

- README.md
- CONTRIBUTING.md
- THIRD_PARTY_NOTICES.md
- .env.example
- configuration instructions
- local development instructions

Never commit real secrets.

## 27. Environment configuration

Use separate configurations:

- Development
- Staging
- Production

Use xcconfig files or another safe configuration system.

Never place production secrets in source control.

Document:

- Supabase project setup;
- bundle identifiers;
- associated domains;
- Sign in with Apple configuration;
- URL schemes;
- universal links;
- storage bucket policies;
- Edge Function secrets;
- staging and production separation;
- migration deployment.

## 28. App Store readiness

Prepare the project for App Store submission.

Create APP_STORE_SUBMISSION.md containing:

- proposed app name;
- subtitle;
- promotional text;
- full description;
- keywords;
- primary and secondary categories;
- age-rating considerations;
- privacy-policy URL placeholder;
- support URL placeholder;
- marketing URL placeholder;
- review contact placeholders;
- demo-account instructions;
- review notes;
- permission explanations;
- data collection summary;
- account-deletion instructions.

Suggested positioning:

**Name:** CheekyPint  
**Subtitle:** Your social pub diary

Suggested description direction:

“Log your pub visits, remember your favourite haunts, and keep friendly standings with mates.”

Avoid marketing language such as:

- Drink the most
- Beat your mates
- Become the biggest drinker
- Never stop
- Another round
- Ultimate drinking competition

Suggested categories:

- Primary: Lifestyle
- Secondary: Social Networking

Evaluate the current App Store classification and choose the most defensible categories.

Prepare permission strings for Info.plist:

Camera:

“CheekyPint uses the camera to scan friend and pub-session QR codes.”

Location When In Use:

“CheekyPint uses your location while the app is open to help you find nearby pubs. Your location is not shared automatically.”

Photo Library:

“CheekyPint lets you choose a profile picture from your photo library.”

Do not include background-location capability.

Create a complete checklist covering:

- Apple Developer account;
- App ID;
- bundle identifier;
- signing certificates;
- provisioning;
- Sign in with Apple;
- associated domains;
- privacy manifest;
- third-party SDK signatures;
- App Privacy questionnaire;
- privacy policy;
- terms;
- account deletion;
- screenshots;
- app icon;
- support contact;
- review account;
- TestFlight;
- crash testing;
- accessibility testing;
- IPv6 networking;
- export compliance;
- age rating;
- App Review notes.

## 29. Legal-document drafts

Create editable draft documents—not false claims of legal approval—for:

- Privacy Policy
- Terms of Use
- Community Guidelines
- Responsible Drinking Notice
- Data Retention Policy
- Account Deletion Policy

Mark clearly:

**Template requiring review by a qualified legal professional before production launch.**

The documents should reflect:

- an Austrian or EU-based operator placeholder;
- GDPR rights;
- data access;
- correction;
- deletion;
- portability;
- withdrawal of consent where applicable;
- international processors;
- Supabase hosting configuration placeholder;
- user-generated profile content;
- precise distinction between business pub locations and personal location data;
- no sale of personal data;
- no targeted advertising in the MVP.

Do not invent company registration data, addresses, or a Data Protection Officer.

## 30. App icon and brand assets

Create specifications for an original app icon.

Concept:

- a simple cream pint-glass silhouette;
- one cheeky asymmetric foam detail;
- dark near-black background;
- restrained amber fill;
- recognisable at small sizes;
- no text inside the icon;
- no resemblance to an existing alcohol brand;
- no national flags;
- no childish cartoon face.

Create:

- icon-generation brief;
- required asset catalogue structure;
- launch-screen direction;
- wordmark treatment;
- screenshot storyboard for App Store listings.

Do not use copyrighted pub logos or beer-brand assets.

## 31. Performance

Targets:

- responsive launch;
- no blocking network work on the main thread;
- paginated personal history;
- efficient aggregate queries;
- cached profile images;
- resized image uploads;
- cancellation-aware async tasks;
- graceful realtime disconnection;
- no unnecessary continuous polling;
- no continuous location updates.

Add database query plans or performance notes for leaderboard and favourite-pub queries.

## 32. Deliverables

Do not stop after describing the solution.

Produce:

1. Working Xcode project.
2. Functional SwiftUI screens.
3. Supabase migrations.
4. RLS policies.
5. Backend functions.
6. Authentication.
7. QR scanning and QR generation.
8. Friend-request system.
9. Pint logging and undo.
10. Leaderboards.
11. Pub search.
12. Profiles and privacy controls.
13. Sessions and clinks.
14. Reporting and blocking.
15. Account deletion.
16. Tests.
17. Seed data.
18. Setup documentation.
19. App Store submission documentation.
20. Legal-document templates.
21. Privacy mapping.
22. Threat model.
23. Release checklist.

## 33. Working method

Follow this sequence:

### Phase 1: Inspect

- Inspect the entire existing repository.
- Identify what already exists.
- Do not overwrite working components unnecessarily.
- Report architecture, missing pieces, and risks.

### Phase 2: Plan

Create a concrete implementation plan in IMPLEMENTATION_PLAN.md with:

- milestones;
- file changes;
- database changes;
- dependencies;
- test strategy;
- unresolved decisions.

Resolve minor decisions independently using the requirements in this prompt. Do not repeatedly stop for confirmation.

### Phase 3: Foundation

- Create the project structure.
- Add design tokens.
- Add environment configuration.
- Add authentication.
- Add database schema and RLS.
- Add reusable services and models.

### Phase 4: Core loop

Complete the highest-value vertical slice first:

1. Create account.
2. Complete profile.
3. Log a pint.
4. Undo it.
5. See personal totals.
6. Generate QR code.
7. Add a friend.
8. See friend standings.

This must work end to end before adding secondary polish.

### Phase 5: Social and pubs

- Friend profiles;
- privacy settings;
- pub search;
- favourite pubs;
- sessions;
- clinks;
- blocking and reporting.

### Phase 6: Hardening

- tests;
- offline handling;
- accessibility;
- security review;
- performance;
- error states;
- account deletion.

### Phase 7: Release preparation

- App Store metadata;
- screenshots plan;
- privacy documentation;
- legal templates;
- TestFlight checklist;
- final release checklist.

## 34. Definition of done

The project is not complete merely because it compiles.

It is complete when:

- a new user can create an account;
- age confirmation is recorded;
- Sign in with Apple works in the configured environment;
- the user can set a profile;
- the user can log and undo a pint;
- duplicate submissions are prevented;
- period totals are correct;
- the user can generate and scan a secure QR friend code;
- friend requests work;
- privacy settings are respected;
- blocked users disappear from all relevant surfaces;
- friend leaderboard aggregates work without exposing raw friend data;
- the user can search for and attach a pub;
- favourite-pub calculations work;
- sessions can be created and joined;
- clinks do not affect drink totals;
- exact residential location is never requested or exposed;
- location permission is optional;
- account deletion works from inside the app;
- RLS denial tests pass;
- core UI tests pass;
- accessibility labels exist;
- all empty and failure states exist;
- no production secret is committed;
- all App Store preparation documents are present;
- the README allows a new developer to run the project from scratch.

## 35. Initial output

Begin by returning:

1. Repository assessment.
2. Proposed architecture.
3. Database entity diagram in Mermaid.
4. Screen map in Mermaid.
5. Security and privacy risks.
6. App Store rejection risks.
7. Implementation milestones.
8. Exact files you will create or modify.

Then begin implementation immediately.

Do not stop after the assessment unless a genuinely blocking credential or external-account configuration is required. Where credentials are missing, create the complete implementation with documented placeholders and continue with everything that can be completed locally.
