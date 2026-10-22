# Eddie

A small macOS video editor that replaces Adobe Premiere Rush (discontinued; support ended 2026-09-30). The owner uses it for one job above all: cutting hour-long Ambient Session recordings (see `docs/rush-reference.md`, *How Rush was used*). The UI is in English with Danish as a localization; code, comments and commit messages are in English.

It ships on the Mac App Store as **Edwell** ("Edwell: Video Editor", bundle id `com.iamjarl.edwell`); Eddie stays the repo and working name. The road there is tracked in #10.

## Build and test

A Swift package: the library `EddieKit` (`Sources/EddieKit`, the whole app) and a one-line `Eddie` executable. `swift build` and the self test need only the Xcode Command Line Tools. The app itself is built by Xcode from `App/Edwell.xcodeproj`, a thin target around `EddieKit`.

```bash
swift build                                   # debug build
.build/debug/Eddie --selftest /tmp/eddie-test  # must end with SELFTEST OK
./build.sh                                    # build/Edwell.app (Xcode, release, sandboxed, ad-hoc signed)
./build.sh --open | --install
```

The self test (`Sources/EddieKit/SelfTest.swift`) generates test media, exports projects through the real pipeline and checks durations, sizes and pixels (dissolve, push, hidden and muted tracks, in/out export), then runs the editing logic (magnetic track, ripple trims, transitions, speed, copy/paste, separate audio, locks, old project files) checks the store build's declarations (bundle id, project type, entitlements) and media access (bookmarks, renamed and moved files, unreadable files, Find…). Extend it with every feature; there is no other test suite. It also runs inside the sandboxed app: `build/Edwell.app/Contents/MacOS/Edwell --selftest` writes to the app's container.

`App/Edwell.xcodeproj` is generated from `App/project.yml` with xcodegen and committed, because Xcode Cloud builds it. Run `cd App && xcodegen generate` after changing `project.yml`; new Swift files go in `Sources/EddieKit` and need no regeneration. Releases go through Xcode Cloud from the `release` branch (`XCODE_CLOUD.md`).

There is no screen-recording permission for `screencapture`, so look at the UI through the app's own debug hook:

```bash
EDDIE_SNAPSHOT=/tmp/ui.png EDDIE_OPEN=/path/project.eddie EDDIE_APPEARANCE=dark .build/debug/Eddie
```

It opens the project, selects the first image clip, writes the window to `ui.png` after 4 s and a frame from the preview player to `ui.png.preview.png`. With `EDDIE_SNAPSHOT` set the app never touches the owner's autosave. The same hook works on `build/Edwell.app/Contents/MacOS/Edwell`, but the sandbox only lets it write inside `~/Library/Containers/com.iamjarl.edwell/Data`.

## Gotchas

- **App Sandbox.** Edwell has two entitlements: the sandbox, and read-write access to files the user picks (open and save panels, drag and drop, Finder opening a project). App Review rejects entitlements nothing uses, and the self test fails on any other. Inside the sandbox `homeDirectoryForCurrentUser` and the standard folders point into the app's container; start panels from `FileManager.default.userHomeDirectory`.
- **Media under the sandbox** (`MediaAccess` in `Sandbox.swift`). The app may read a file only in the launch the user picked it in, so `MediaLoader.load` gives every item a security-scoped bookmark, and opening a project or the autosave resolves them (`MediaAccess.reach`) and holds their access until the project closes. Saving adds each file's path relative to the project. Inside the sandbox `fileExists` is true for files the app can't read, so test with `MediaAccess.canRead`. Media that can't be read is left out of preview and export and shown in red, with **Find…** (`Editor.locateMedia`), which takes the file or a folder to search. To check it for real, open a file in `build/Edwell.app` with `open -a`, then open the autosave from a fresh process with `EDDIE_OPEN` (both inside the container).
- **Every string in the UI goes through `App/Edwell/Localizable.xcstrings`** (English source, Danish translation). SwiftUI literals (`Text("…")`, `Button("…")`, `.help("…")`) are looked up in the app's main bundle by themselves; a helper that passes a title on takes `LocalizedStringKey`, and any other `String` shown to the user (alerts, errors, panel messages, enum labels) is `String(localized:)`. After changing UI text run `scripts/sync-strings.sh` (needs Xcode): the compiler lists the strings, the catalog is updated, and the script names those without Danish. The self test fails on a missing translation and on Danish letters in a string literal. `.build/debug/Eddie` has no bundle, so it always shows English; try Danish with `build/Edwell.app/Contents/MacOS/Edwell -AppleLanguages '(da)'`.
- **Trial and purchase** (`Store.swift`, `Views/PurchaseView.swift`). Two non-consumables: `com.iamjarl.edwell.trial` ($0, named "14-day Trial" as App Review requires) and `com.iamjarl.edwell.unlock` ($9.99). The 14 days run from the trial's purchase date, so a reinstall doesn't restart them. Only export waits for the trial or the purchase; projects always open, edit and save. The rules are `Access.compute`. Before the trial starts, the sheet must name its length, that export stops, and the price from StoreKit (guideline 3.1.1); the self test checks `PurchaseCopy` for that. A failed load, purchase or restore always says so. A build signed on this Mac (`swift build`, `./build.sh`, no team in the signature) is unlocked and never talks to StoreKit (`Store.isLocalBuild`); App Store, TestFlight and Xcode builds carry the team and go through StoreKit. The StoreKit cases (trial, expiry, buying, relaunch, refund, Ask to Buy, no network) are XCTests against `App/Edwell.storekit`: `xcodebuild test -project App/Edwell.xcodeproj -scheme Edwell -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`. They skip unless the products come from that file, because a purchase that reaches the real sandbox App Store puts dialogs on the owner's screen. `testDrawSheets` draws the sheet in each state to `purchase-sheets/` in the container's tmp folder.
- **Project type** `com.iamjarl.edwell.project` (`Editor.projectType`), declared in `App/project.yml`. Projects are saved as `.edwell`; `.eddie` files from before the rename open as the same type.

- **Fonts that ship with the app** live in `Resources/Fonts` (Outfit, OFL-1.1, with its licence), are copied into the app by the Xcode target and are registered at launch by `BundledFonts`. Outfit's variable font is called "Outfit Thin" by CoreText; the UI shows it as "Outfit". Weights go through the `wght` axis.

- **`@State` is a macro in the macOS 27 SDK** and its plugin ships only with Xcode. Use `@ViewState` (`typealias ViewState = SwiftUI.State` in `Model.swift`). Other SwiftUI macros (`#Preview`, `@Entry`) will fail the same way.
- Swift 6 compiler in Swift 5 language mode (`swiftLanguageModes: [.v5]`), so concurrency warnings don't block the build.
- Project files are JSON. New fields need a default in the hand-written `init(from:)` in `Model.swift`, or older `.eddie` files stop opening (the self test checks a version 1 file).

## How it fits together

- `EddieApp.swift`: `Launcher.run()`, the entry point both executables call (`App/Edwell/main.swift`, `Sources/Eddie/main.swift`), then the SwiftUI app and its menus.
- `Model.swift`: `Project`, `Clip`, `MediaItem`, `TitleStyle`, transitions, track flags. Times are seconds as `Double`; `Clip.duration` is timeline time, `sourceDuration = duration * speed`.
- `Editor.swift`: all state and every edit. Edits go through `edit {}` (one undo step, coalesced by key) or `beginInteraction`/`interact`/`endInteraction` for drags. `packMain` keeps V1 magnetic after every change. The Rush single-key shortcuts live in the key monitor (`handleKey`), never as menu key equivalents, so they don't fire while typing.
- `CompositionBuilder.swift`: project → `AVMutableComposition` + video composition + audio mix. Clips are packed onto as few composition tracks as possible; a stretched black filler track sets the length. Speed is `scaleTimeRange`; pitch per audio track via `audioTimePitchAlgorithm`.
- `Compositor.swift`: `EddieCompositor` (custom `AVVideoCompositing`) draws every frame with Core Image for both preview and export: placement, crop, rotation, opacity, transitions, titles (Core Text).
- `Views/`: media bin, preview, timeline, inspector (Rush-style tool tabs, ⌘1–⌘6), export sheet.

## Design system

The UI follows the IAMJARL design system (`iamjarl-design`, Swift package `IAMJARLDesignTokens`). Its rules apply here: no hard-coded colours, radii or spacing; light and dark mode; icons in the text colour, accent only for active or emphasised; `.ijFont` for type; `onPrimary` on `primary`. `Theme.swift` holds what Eddie derives (`Tokens.clipFill`, button styles). Colours in the video (title colours, project background) are the user's content, not UI. Never change the design repo from here: ask through an issue there (clip-type colours are asked for in JarlLyng/iamjarl-design#112).

## Open work, roughly in order

1. **The Ambient Session workflow** is in place: `AmbientSession.swift` (File › New Ambient Session, ⇧⌘N), checked against Rush's own video by `--session-test` (see README). Left: export bitrate is ~10.5 Mbit/s against Rush's ~19 (Apple's preset; a fixed bitrate needs an AVAssetReader/AVAssetWriter export); scrubbing and playback of an hour-long clip haven't been tried by hand.
2. Colour looks and adjustments, speed ramps over part of a clip, pan and zoom on stills, animated titles.
3. Auto volume (−23 LUFS dialogue, −25 LUFS music), auto ducking (−18 dB, 800 ms fades), noise reduction, voice-over recording, Auto Reframe.
