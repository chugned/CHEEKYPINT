# CheekyPint Friend-Circle Build

This build is tuned for a private friend group rather than public auth.

## What Changed

- Entry is surname-only. No Apple sign-in, email OTP, or third-party login UI.
- The surname is stored locally on the phone and used as the local profile name.
- The main pint action is now a beer glass image that fills as pints are recorded.
- The logging sheet shows beers on display with remote glass photos and short descriptions.
- Tapping the fill control animates the glass; the pint is saved when the glass reaches full.
- The saved private note includes the selected beer name, so the confirmation can call it out.

## Beer Display

The current catalog includes:

- Puntigamer
- Stiegl
- Ottakringer Helles
- Pilsner Urquell
- Guinness
- Hoegaarden

Images are loaded from Wikimedia Commons via `Special:FilePath` URLs in `LogPintSheet.swift`.

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
