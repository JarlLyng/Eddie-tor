# Eddie

A small macOS video editor that replaces Adobe Premiere Rush (discontinued; support ended 2026-09-30). The owner uses it for one job above all: cutting hour-long Ambient Session recordings (see `docs/rush-reference.md`, *How Rush was used*). The UI is in Danish; code, comments and commit messages are in English.

## Build and test

Only the Xcode Command Line Tools are needed, not Xcode. Swift package, one executable target.

```bash
swift build                                   # debug build
.build/debug/Eddie --selftest /tmp/eddie-test  # must end with SELFTEST OK
./build.sh                                    # build/Eddie.app (release, ad-hoc signed)
./build.sh --open | --install
```

The self test (`Sources/Eddie/SelfTest.swift`) generates test media, exports projects through the real pipeline and checks durations, sizes and pixels (dissolve, push, hidden and muted tracks, in/out export), then runs the editing logic (magnetic track, ripple trims, transitions, speed, copy/paste, separate audio, locks, old project files). Extend it with every feature; there is no other test suite.

There is no screen-recording permission for `screencapture`, so look at the UI through the app's own debug hook:

```bash
EDDIE_SNAPSHOT=/tmp/ui.png EDDIE_OPEN=/path/project.eddie EDDIE_APPEARANCE=dark .build/debug/Eddie
```

It opens the project, selects the first image clip, writes the window to `ui.png` after 4 s and a frame from the preview player to `ui.png.preview.png`. With `EDDIE_SNAPSHOT` set the app never touches the owner's autosave.

## Gotchas

- **`@State` is a macro in the macOS 27 SDK** and its plugin ships only with Xcode. Use `@ViewState` (`typealias ViewState = SwiftUI.State` in `Model.swift`). Other SwiftUI macros (`#Preview`, `@Entry`) will fail the same way.
- Swift 6 compiler in Swift 5 language mode (`swiftLanguageModes: [.v5]`), so concurrency warnings don't block the build.
- Project files are JSON. New fields need a default in the hand-written `init(from:)` in `Model.swift`, or older `.eddie` files stop opening (the self test checks a version 1 file).

## How it fits together

- `Model.swift`: `Project`, `Clip`, `MediaItem`, `TitleStyle`, transitions, track flags. Times are seconds as `Double`; `Clip.duration` is timeline time, `sourceDuration = duration * speed`.
- `Editor.swift`: all state and every edit. Edits go through `edit {}` (one undo step, coalesced by key) or `beginInteraction`/`interact`/`endInteraction` for drags. `packMain` keeps V1 magnetic after every change. The Rush single-key shortcuts live in the key monitor (`handleKey`), never as menu key equivalents, so they don't fire while typing.
- `CompositionBuilder.swift`: project → `AVMutableComposition` + video composition + audio mix. Clips are packed onto as few composition tracks as possible; a stretched black filler track sets the length. Speed is `scaleTimeRange`; pitch per audio track via `audioTimePitchAlgorithm`.
- `Compositor.swift`: `EddieCompositor` (custom `AVVideoCompositing`) draws every frame with Core Image for both preview and export: placement, crop, rotation, opacity, transitions, titles (Core Text).
- `Views/`: media bin, preview, timeline, inspector (Rush-style tool tabs, ⌘1–⌘6), export sheet.

## Design system

The UI follows the IAMJARL design system (`iamjarl-design`, Swift package `IAMJARLDesignTokens`). Its rules apply here: no hard-coded colours, radii or spacing; light and dark mode; icons in the text colour, accent only for active or emphasised; `.ijFont` for type; `onPrimary` on `primary`. `Theme.swift` holds what Eddie derives (`Tokens.clipFill`, button styles). Colours in the video (title colours, project background) are the user's content, not UI. Never change the design repo from here: ask through an issue there (clip-type colours are asked for in JarlLyng/iamjarl-design#112).

## Open work, roughly in order

1. **The Ambient Session workflow** (`docs/rush-reference.md` has Rush's exact values): left-aligned titles (left edge at 2.1 % of the width); a free bold face to replace Soleil Extra Bold (Adobe Fonts), e.g. Outfit ExtraBold; check an hour-long recording (timeline width at default zoom, export time through the compositor); compare export bitrate with Rush's ~19 Mbit/s. A "new session" shortcut (trim, 0.5 s dips, title 11.2–50.8 s in the next colour) would save the most time.
2. Colour looks and adjustments, speed ramps over part of a clip, pan and zoom on stills, animated titles.
3. Auto volume (−23 LUFS dialogue, −25 LUFS music), auto ducking (−18 dB, 800 ms fades), noise reduction, voice-over recording, Auto Reframe.
