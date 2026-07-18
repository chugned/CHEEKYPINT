# App icon & brand assets

## Icon concept

A simple **cream pint-glass silhouette** with **one cheeky asymmetric foam detail**, on a dark
near-black background, with a restrained amber fill. Confident and premium — recognisable at small
sizes.

Do **not**: include text in the icon · resemble any existing alcohol/beer brand · use national
flags · use a childish cartoon face · use casino/neon/gaming aesthetics.

## Palette (matches the in-app tokens)

| Token | Dark (primary) | Light |
|-------|----------------|-------|
| Background | `#15110E` | `#F5EFE4` |
| Cream (glass/type) | `#F3E7CE` | `#211B16` |
| Amber (fill/accent) | `#E6A200` | `#B67A00` |

## Icon generation brief (for a designer or image tool)

> A minimalist app icon: a centered cream pint glass silhouette, filled with a restrained amber
> beer, one small off-center foam bubble rising asymmetrically for a "cheeky" character, flat
> design, generous negative space, dark near-black `#15110E` background, no text, no gradients
> beyond a very subtle amber glow, crisp at 1024×1024 and legible at 40×40.

## Asset catalogue

- `CheekyPint/Resources/Assets.xcassets/AppIcon.appiconset` — single 1024×1024 (Xcode 16
  single-size). Drop the exported PNG in and set `filename` in `Contents.json`.
- Colour sets already provided: `BackgroundPrimary/Secondary`, `TextPrimary/Secondary`,
  `AccentAmber`, `AccentColor`, `Warning`, `Success` (each with light + dark variants).

## Launch screen

Info.plist `UILaunchScreen` uses the `BackgroundPrimary` colour; the app's `LaunchView` renders
the wordmark + `PintGlassMark` for a seamless hand-off.

## Wordmark

"CheekyPint" set in SF Rounded, heavy weight, cream on dark. One word, camel-cased. Keep it calm —
no motion lines, no droplets.

## App Store screenshot storyboard (6.7" + 6.1")

1. **Home** — the big count + "LOG A PINT", caption: *"One tap. Cheers."*
2. **Log sheet** — serving + pub + alcohol-free, caption: *"Log it your way."*
3. **Standings** — friendly standings with a "Private" row, caption: *"Friendly standings, no
   global leaderboards."*
4. **My QR** — caption: *"Add mates with a private code."*
5. **Privacy settings** — caption: *"Friends-only by default. Your diary, your rules."*
6. **Responsible drinking** — caption: *"A diary, not a challenge."*

Use real seed data (Alice & mates). Avoid any copy implying competition to drink more.
