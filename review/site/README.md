# Review shots for the launch site (#31)

Full-page screenshots of the four pages at 1440 px (1x) and 375 px (2x), dark, with Reduce Motion on, so
the hero shows its poster frame. Taken in Chrome from `website/` on the `site/31-launch-home` branch, on
iamjarl-design v1.35.1 with the placeholders below still in place.

| File | Page |
|---|---|
| `home-1440.jpeg`, `home-375.jpeg` | `/` |
| `rush-1440.jpeg`, `rush-375.jpeg` | `/premiere-rush-alternative-mac` |
| `support-1440.jpeg`, `support-375.jpeg` | `/support` |
| `privacy-1440.jpeg`, `privacy-375.jpeg` | `/privacy` |

**Placeholders until iamjarl-design#114 is released:** the store buttons show the badge and
"[Facts line from the registry, with the price]", the nav's Download points at the store page, the
JSON-LD Offer has no price, and the footer shows its plain fallback line. Every one is marked
`data-ij-placeholder="iamjarl-design#114"` or with a `PLACEHOLDER` comment. Edwell's identity is held by
a stand-in block in `website/assets/site.css` until the registry's `dist/identity/edwell.css` replaces it.

## How the pictures in `website/assets/edwell/` were made

From the app as it is on this branch, built by Xcode in Release, in English and dark mode.

- **The media is synthetic.** The "Slow Mornings" project's four clips (hills at dawn, the sea, lights at
  night, an aurora), the dunes still and the pad were drawn and synthesised for these pictures with Core
  Graphics and AVFoundation. No people, no third-party footage, no one's own media.
- **The hero loop** (`hero-loop-*.mp4`, poster `hero-poster-2200.jpg`) is the real window, 1100 by 740
  points, shot frame by frame through ScreenCaptureKit while a scratch hook did the edits through the
  editor's own functions: play, select, split at the playhead (S), add a title (G), type "Slow Mornings",
  drag it up the picture, switch 16:9 to 9:16, play. A live screen recording would have put macOS's
  purple "window is being recorded" pill where the traffic lights are, so each frame is a window
  screenshot instead. The last half second dissolves into the first frame so the loop comes round
  without a jump. No sound.
- **The pieces** (`timeline-*`, `title-*`, `export-*`) are crops of window shots at 2x, shown at the
  size they were captured. **The four formats** (`format-*`) are one frame of the project rendered by
  the app's compositor in each format.
- **The social card** (`og.png`, 1200 by 630) is the name, the headline and the hero's poster frame. It is
  also the repo's GitHub social preview, which the owner uploads by hand (Settings, Social preview).

As with the App Store shots, the capture hook (window size, the active-window drawing, the scripted
edits) and the media generator were scratch tools and are not committed. The UI is this branch's.
