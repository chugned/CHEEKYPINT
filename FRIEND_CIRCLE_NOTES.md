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

Device install flow:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme CheekyPint -destination 'id=<device-id>' build
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app --device <device-id> <path-to-CheekyPint.app>
```

The device build still depends on local Apple signing/provisioning being valid in Xcode.
