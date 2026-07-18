# CheekyPint Friend-Circle Build

This build is tuned for a private friend group rather than public auth.

## What Changed

- Entry is surname-only. No Apple sign-in, email OTP, or third-party login UI.
- The surname is stored locally on the phone and used as the local profile name.
- The main pint action is now a beer glass image that fills as pints are recorded.
- The logging sheet shows beers on display with remote glass photos and short descriptions.
- The beer picker has a searchable world-style catalog with country/style metadata.
- Tapping `Log beer` saves immediately, then beer overflows the whole screen from all sides.
- The full-screen celebration says `+1 succelance`.
- The saved private note includes the selected beer name, so the confirmation can call it out.
- The Pubs tab includes a live pub map based on current location, using on-demand When-In-Use
  location and MapKit local search for nearby pubs, bars, breweries, and beer-friendly venues.
- Tapping a live-map pub marker or pub row opens a detail sheet with the pub name, address,
  distance, Apple Look Around imagery when Apple has it, a fallback image state, and quick actions
  for Apple Maps, website, and phone.

## Beer Display

The current catalog starts with image-backed beers:

- Puntigamer
- Stiegl
- Ottakringer Helles
- Pilsner Urquell
- Guinness
- Hoegaarden

It then adds a larger international list covering common lagers, pilsners, wheat beers, stouts,
IPAs, ales, and house-beer fallbacks from Europe, Asia, the Americas, Africa, and Oceania.
Image-backed beers load from Wikimedia Commons via `Special:FilePath` URLs in
`LogPintSheet.swift`; every other beer renders generated bottle/can-and-glass artwork with its
own label, style, and country so the catalog always has a picture without relying on unsafe
hotlinked product photos.

## Build And Install

Simulator build check:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet -scheme CheekyPint -destination 'generic/platform=iOS Simulator' build
```

Device install flow used for the iPhone 14 Pro named `Gospodar Tvoje Majke`:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme CheekyPint -destination 'id=00008120-001C555C22EB401E' -configuration Debug DEVELOPMENT_TEAM=C5342YYG52 CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app --device F768B67E-E248-5A41-90E5-9A25AB582D5D ~/Library/Developer/Xcode/DerivedData/CheekyPint-atrlghyhsaqbxkeqmxtuqgyrmchs/Build/Products/Debug-iphoneos/CheekyPint.app
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device process launch --device F768B67E-E248-5A41-90E5-9A25AB582D5D app.cheekypint.CheekyPint.dev
```

The project defaults to `CheekyPint-personal.entitlements` so it can install with a free
personal Apple team. `CheekyPint.entitlements` is still present for a future paid-team build
that wants Associated Domains or Sign in with Apple back.

## Live Pub Map

Open `Pubs` -> `Live pub map`. The screen asks for current location only when opened or refreshed,
centres the map near the phone, runs several MapKit searches for pub/bar/brewery/beer-garden/local
terms, merges duplicate venues, drops mug markers for the closest results, and lists them below the
map sorted by distance from the current location.

Tap a pub marker or a row to see the pub details. Apple MapKit does not expose opening-hours data
to this app build, so the sheet links straight to Apple Maps and the pub website/phone when those
are provided by the map result for live opening times.
