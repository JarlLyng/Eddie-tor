# Raw Mac screenshots for the App Store

Window shots of build 3 (`release` at 3f83ed2), 2880 × 1800 (a 1440 × 900 window at 2x), in English
and dark mode. The hub composes them with `tools/appstore_screenshots.py` and uploads them.

| File | Shows |
|---|---|
| `1-timeline.png` | The timeline: five clips on the magnetic main track with four kinds of transition, two titles, a music bed, and the title "Slow Mornings" on the preview |
| `2-vertical-9x16.png` | The same project switched to 9:16 |
| `3-title-inspector.png` | The title inspector (Outfit, Semibold, colour, background box) with the styled title "After Dark" on the preview |
| `4-export.png` | The export sheet |

No trial screen: a build signed on this Mac is unlocked and never talks to StoreKit, so the sheet
can't be shown with its real price and state.

**The media is synthetic.** The four clips (hills at dawn, the sea, lights at night, an aurora), the
dunes still and the music were drawn and synthesised for these shots with Core Graphics and
AVFoundation. No people and no third-party footage.

**How they were made.** The app's own `EDDIE_SNAPSHOT` hook, captured through ScreenCaptureKit, from
3f83ed2 built by Xcode in Release. For the capture only, and never committed, the build had a longer
hook (window size, selection, inspector tab and scroll, playhead, the export sheet), the sandbox
entitlement off so it could read the test media outside its container, and the window drawn as the
frontmost one without taking focus from the desktop. The UI code is build 3's.
