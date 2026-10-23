# Eddie

A small video editor for the Mac, made to replace Adobe Premiere Rush. On the Mac App Store it's called **Edwell**. It has only the features that actually get used. The interface is in English and Danish.

## Features

- **First run** is an empty project and one tip above the timeline: drag media in, split with S, add a title with G, export with ⌘E. Close the tip and it stays closed; it also goes after the first export
- **Import** video, audio and images (the **+** button, ⌘I, or drag files into Media or straight onto a track)
- **Magnetic main track**: clips on V1 always follow each other, so deleting and trimming close the gap. Drag a clip to move it to a new place
- **More tracks**: 3 video tracks, 2 title tracks and 2 audio tracks, and you can add more. Each track can be hidden, muted and locked
- **Clips**: move (also between tracks), trim at the edges, split (S), ripple trim to the playhead (Q/W), duplicate (D), copy/cut/paste and separate the audio from the video (E)
- **Transitions**: cross dissolve, dip to black or white, and push in four directions, at the start and end of a clip. Between two clips on the main track they overlap, and the sound cross-fades too
- **Speed**: 10–1000 % per clip, with or without preserved pitch
- **Size and position**: fill the frame or show the whole picture, size, position, rotation, opacity, flipping, and crop with a soft edge
- **Titles**: font, weight (100–900), size, color, left/center/right alignment, line spacing, shadow, background box, position and fade. Drag the text directly in the preview. Outfit ships with the app (OFL, from the design system), so projects look the same on every Mac
- **Audio**: volume per clip (0–200 %), mute, fade in and out
- **Format**: 16:9, 9:16, 1:1 and 4:5
- **Export** to MP4 (H.264 or HEVC) in 1080p, the whole project or only between the in and out points
- **New Ambient Session**, the owner's own template, kept out of sight: hold ⌥ in the File menu and New Project turns into it (⌥⌘N). Choose the recording, and the app sets it up as it was done in Rush: the whole recording on V1 with a 0.5 s dip to black and a sound fade at both ends, and the title "Ambient / Session NNN" from 11.2 to 50.8 s, left-aligned in Outfit ExtraBold 177 px, in the session's own color. Then put the playhead where the session starts and press **Q**, and where it ends and press **W**. The title stays at 11.2 s
- Undo/redo, autosave, and projects saved as `.edwell` files (old `.eddie` files still open)
- **Trial and purchase**: everything works for 14 days, then export needs one purchase ($9.99 once, no subscription). Projects always open and edit. Restore Purchases is in the Edwell menu. A build you make yourself with `./build.sh` is unlocked
- **Media that moves**: the app remembers each file it's given, follows it when it's renamed or moved, and asks with **Find…** when it can't be read

## Shortcuts

| Key | Action |
|---|---|
| Space | Play / pause |
| J K L | Rewind / stop / forward (press again to go faster) |
| ← → | One frame back / forward (with ⇧: one second) |
| ↑ ↓ | Previous / next clip edge |
| S | Split the clip at the playhead |
| Q W | Trim the start / end to the playhead |
| D | Duplicate |
| G | New title |
| E | Separate audio |
| ⌫ | Delete |
| ⌘D | Add the default transition (cross dissolve) |
| ⌘C ⌘X ⌘V | Copy / cut / paste at the playhead |
| I O | Set the in / out point (⇧ goes there, ⌥ clears it, ⌥X clears both) |
| = − \ | Zoom in / out / the whole timeline |
| ⌘Y | Snap on/off |
| ⌘L | Loop playback |
| ⌘1 ⌘2 ⌘4 ⌘5 ⌘6 | Text, transitions, speed, audio, position |
| \` | Large preview |
| Y | Show/hide media |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘S, ⌘O, ⌘E | Save, open, export |

## Not there yet

See also [docs/rush-reference.md](docs/rush-reference.md): everything Rush could do, how it was used for the Ambient Sessions, and what is still missing.

Color filters, speed for only part of a clip (ramps), animated title templates, pan and zoom, auto reframe, auto ducking, noise reduction and voice-over recording.

## Design

The app uses the [IAMJARL design system](https://github.com/JarlLyng/iamjarl-design) (the Swift package `IAMJARLDesignTokens`): every color, spacing, radius and type size in the interface comes from there, and the app follows the system's light or dark mode. `Sources/EddieKit/Theme.swift` holds what the app derives from the tokens (the clips' neutral fill and the button styles). The colors in the video itself, such as title colors and the background, are the user's content and not part of the design system.

## Build

The app is built with Xcode from `App/Edwell.xcodeproj` (generated from `App/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)) and runs in the App Sandbox like the App Store version. The self test and `swift build` need only the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh            # builds build/Edwell.app
./build.sh --open     # builds and opens it
./build.sh --install  # builds and copies it to /Applications
```

The App Store version is built by Xcode Cloud from the `release` branch; see [XCODE_CLOUD.md](XCODE_CLOUD.md).

English is the development language and Danish a localization, both in `App/Edwell/Localizable.xcstrings`. After adding or changing text in the interface, update the catalog from the code, then add the Danish translation the script lists:

```bash
scripts/sync-strings.sh
```

Test with a real session (builds the template, trims as Rush did for session 011, exports and compares with Rush's video; `--full` exports the whole hour):

```bash
.build/debug/Eddie --session-test "<recording>.mov" /tmp/eddie-session "<Rush's finished video>.mp4"
```

The trial and the purchase are tested against Xcode's local StoreKit (`App/Edwell.storekit`), with no App Store account involved:

```bash
xcodebuild test -project App/Edwell.xcodeproj -scheme Edwell -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Self test (makes test videos, exports a project with every kind of clip, and tests the editing, media access, the store build and the translations):

```bash
swift build && .build/debug/Eddie --selftest /tmp/eddie-test
```

## Layout

| File | Contents |
|---|---|
| `Sources/EddieKit/` | The whole app; `App/` is the App Store target around it |
| `Model.swift` | Project, clips, media and title style (saved as JSON) |
| `Editor.swift` | State, editing, undo, playback, save and open |
| `CompositionBuilder.swift` | Turns the project into an AVFoundation composition |
| `Compositor.swift` | Draws every frame: scaling, layers and titles. Used by both preview and export |
| `Exporter.swift` | MP4 export |
| `Sandbox.swift` | Media access under the App Sandbox: bookmarks and Find… |
| `Store.swift` | The 14-day trial and the one-time purchase (StoreKit 2) |
| `Views/` | Media bin, preview, timeline, inspector and export |
