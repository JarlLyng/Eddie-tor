# Premiere Rush: reference for Eddie

Collected on 2026-10-22 from Adobe Premiere Rush 2.0 (build 12.10.0), installed on the MacBook Eddie was started on, and from Adobe's documentation. Rush's support ended on 30 September 2026, it can no longer be downloaded, and it may stop working at any time. This page is the record of what Rush could do and how it was used, so the work can go on without it.

Nothing here is copied from Adobe's files. Look files, title templates and presets belong to Adobe and are only listed by name.

## How Rush was used: Ambient Sessions

The recordings and the finished videos are in iCloud Drive:

`~/Library/Mobile Documents/com~apple~CloudDocs/Ableton/Music/LIVE Recordings/Twitch streams/`

- `Ambient session NNN - RAW.mov`: the Twitch recording, 1920×1080, H.264 at about 4.5 Mbit/s, AAC stereo at 192 kbit/s, usually close to an hour (011: 1 h 08 min).
- `Ambient session NNN.mp4`: the result from Rush, 1920×1080 16:9, H.264 at about **19 Mbit/s**, AAC stereo at **317 kbit/s**, 20 s to 3.5 min shorter than the recording.

The exact edit comes from the Rush project for session 011 (read on 2026-10-22, see *The Rush projects* below), checked against frames of the finished video:

| Step | In Rush (session 011) | Eddie |
|---|---|---|
| Trim the recording | One clip on V1, source **212.967 s to 4069.300 s** of the recording: 3 min 33 s cut from the start, 5.8 s from the end. Timeline 0 to 3856.333 s, 30 fps | ✓ trim on the main track |
| Fade in | **Dip to Black, 0.5 s**, at the head of the clip | ✓ "Dyk til sort" at the start, 0.5 s |
| Sound in and out | **Constant Power crossfade, 0.5 s**, at the head and the tail of the audio | ✓ set Lyd › "Fade ind" and "Fade ud" to 0.5 s on the clip. A dip at the very start or end doesn't fade the sound by itself; only a transition between two clips cross-fades it |
| Title | One graphic on V2 from **11.233 s to 50.767 s** (39.5 s), hard cut in and out. Text "Ambient⏎Session 011" in two lines | ✓ timing. See the title row below |
| Title face | **Soleil Extra Bold** (PostScript name `SoleilXb`), from Adobe Fonts | **Not on a Mac without Creative Cloud.** Choose a free face (Outfit ExtraBold from the design system is the closest in spirit) |
| Title size | about **177 px** in a 1080 px frame (177.27 is in the text data; the measured letter height agrees). Lines 166 px apart (tops of the ink at y 334 and 500) | Set size 177 in Eddie |
| Title colour | **#D622CE** in session 011 (measured in the video as #D828D0). A new colour every session, see below | ✓ |
| Title position | Left-aligned. The text box's left edge at **2.1 % of the width** (41 px; ink starts at x 44), its anchor at 52.5 % of the height: the left middle of the frame. Scale 100 %, no rotation, opacity 100 %. No box, no shadow | **Missing: left alignment.** Eddie centres all text |
| Fade out | **Dip to Black, 0.5 s**, at the tail | ✓ "Dyk til sort" at the end, 0.5 s |
| Audio | Audio type *music*, volume 0 dB, no auto volume (Loudness off), no tracks muted. Ducking is switched on in the clip's Essential Sound but there is nothing to duck under | ✓ nothing to add |
| Export | 1080p H.264, about 19 Mbit/s, AAC 317 kbit/s (measured on the finished files) | Partly: Eddie exports 1080p H.264 with Apple's "highest quality" preset, whose bitrate isn't set. Not yet compared |

### Title colours per session

Each session's project starts as a copy of the one before, so each holds the previous colour too; the colour that is new in a session is its own. 010 and 011 are confirmed in the finished videos.

| Session | 001 | 002 | 003 | 004 | 005 | 006 | 007 | 008 | 009 | 010 | 011 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Colour | #F10000 | #2BCB00 | #0019CB | #03A8A1 | #A6A301 | #623435 | #2595A6 | #D41717 | #AAB50E | #0E49B5 | #D622CE |

**Not yet tried in Eddie:** an hour-long recording. The timeline at the default zoom is then about 230,000 points wide, and the export runs every frame through Eddie's compositor. Both need a test with a real session.

## Still on the old Mac

| What | Where | Can it move? |
|---|---|---|
| Rush projects (17: the Ambient Sessions and others) | Creative Cloud, cached in `~/Library/Application Support/Adobe/Common/Team Projects Local Hub/2021/local/<id>.tp2/` | The settings that matter are read out and written on this page. The projects themselves only open in Rush |
| Title face | Adobe Fonts, through Creative Cloud | Not to a Mac without Creative Cloud. Pick a free face for Eddie |
| Rush itself | `/Applications/Adobe Premiere Rush 2.0` | No. It can't be downloaded any more |
| Test footage | `~/Documents/Adobe/Premiere Rush/Managed Media/Assets/…/Test01_Proxy.mp4` (117 MB) and `sound_Proxy.mp3` | Yes, if wanted. Not in git |

The recordings and finished videos are in iCloud Drive and follow the Apple ID.

## The Rush projects

Rush keeps a local copy of every Creative Cloud project as a small Git repository stored in SQLite: `…/Team Projects Local Hub/2021/local/<id>.tp2/git/odb.sqlite3`, table `ODB (OID, Size, Type, Data)`, with the objects gzip-compressed. `refs/heads/session` points at the latest commit; its tree holds one `assets/<id>/enclosures/enclosure/content` per asset, and the sequence (`"ppro:assetType":"sequence-rush"`) is Premiere's XML (`PremiereData`). Times are in ticks of 1/254,016,000,000 s. A title's text, face and colour are a base64 FlatBuffer in the `Source Text` parameter: the face's PostScript name and the text are plain strings in it, and the fill colour is the three bytes after a zero byte just before the text.

That is how this page was filled in. An importer for Eddie could read the same, but the projects can only be refreshed from the cloud by Rush.

What the 17 projects hold, besides the Ambient Sessions:

| Project | Media | Titles |
|---|---|---|
| Music video, "UNSIGHTLY hope" | `unslghtly hope.wav` and video | Soleil Extra Bold |
| Music video, "PERCEPTION PIZZA (demo)" | `PerceptionPizza.wav` and video | Soleil Extra Bold |
| Music video, "Then the Letting Go" | `Pose.wav`, `Pose.mp4` | Soleil Extra Bold |
| "YOU ARE" (chord) | `IMG_8143.mov` | Soleil Extra Bold |
| "Forbandet hviskelder // LIVE from the studio", Tobias Kankelborg & Then the Letting Go | OBS recordings from 2025-09-09 | Roboto Black, Roboto Thin, Source Sans Pro (Black, Light, Light Italic, Regular), Bebas Neue |
| A test from 2023 | `Test01.mov`, `sound.wav` | |

So Rush was also used for music videos: a song's audio file under video, with a title or two.

## Rush features and Eddie

| Area | Rush | Eddie (2026-10-22) |
|---|---|---|
| Tracks | 4 video, 3 audio; hide, mute, lock per track | ✓ 3 video, 2 title, 2 audio, more on demand; hide, mute, lock |
| Main track | magnetic: clips close up | ✓ |
| Editing | split, duplicate, copy/paste, ripple trim to playhead, in/out, separate audio, snapping | ✓ |
| Titles | 27 animated templates (Adobe Stock motion graphics), Adobe Fonts, colour, background, size, position, eyedropper | Static titles: face, size, colour, shadow, box, position, fade. **No left/right alignment, no templates, no animation** |
| Transitions | Cross Dissolve, Dip to Black, Dip to White, Push; the engine also has Slide, Split, Wipe, Iris, Cross Zoom, Whip, Film Dissolve. Duration slider; ⌘D applies the default | ✓ Cross dissolve, dip to black/white, push in four directions |
| Colour | 24 looks with an intensity slider, manual edit, saved presets | Missing |
| Speed | whole clip or a range, ramp, keep pitch | ✓ whole clip and keep pitch. **No range or ramp** |
| Size and position | position, scale, rotation, opacity, flip, crop, feather | ✓ |
| Effects | Auto Reframe, Pan and Zoom on stills | Missing |
| Audio | volume, auto volume, balance, reduce noise, reduce echo, auto ducking, voice/music type, voice-over recording | Volume, mute, fades. **The rest is missing** |
| Export | quality presets up to 4K, frame rate | 1080p H.264/HEVC, in/out range |

### Colour looks (names only)

Clean: Cool, Desaturated, LowContrast, Saturated, Warm. Extra: Cyan tone, Deep Shadow, Magenta tone. Extreme: Bleach Bypass, Monochromatic (Cool), Monochromatic (Warm), Orange and Teal, Washed out. Cinematic: Azure, Flat, LowSat, Moody, Neutral, Tangerine, Airy, Brightly, Deep and Low, Greenery, Magenta.

The manual colour edit in Rush has intensity, exposure, contrast, highlights, shadows, temperature, tint, vibrance, saturation, faded film, sharpen and vignette (from Rush's documentation; check against the app if it matters).

### Audio settings (Rush's Essential Sound defaults)

These are the numbers to aim for when Eddie gets automatic audio:

| Setting | Dialogue | Music |
|---|---|---|
| Auto volume target | −23 LUFS | −25 LUFS |
| Allowed loudness | −42 to −12 LUFS | −42 to −12 LUFS |
| Clip gain range | −60 to +15 dB | −60 to +15 dB |
| Ducking | | on: sensitivity 6, reduce by **−18 dB**, fades **800 ms** |

Dialogue also had noise, rumble and reverb reduction, and named EQ presets (Podcast Voice, Subtle Boost Female/Male, On the Telephone, Old Radio and others) and reverb presets (Auditorium, Church, Warm Room, Warm Voice and others).

### Keyboard shortcuts (Rush defaults, macOS)

| Rush command | Key | Eddie |
|---|---|---|
| Play / pause | Space | ✓ |
| Shuttle left / stop / right | J K L | ✓ |
| Step back / forward | ← → | ✓ |
| Previous / next edit | ↑ ↓ | ✓ |
| Sequence start / end | ⌘↑ / ⌘↓ | ✓ (also Home / End) |
| Razor at playhead (split) | S | ✓ |
| Trim start / end to playhead | Q W | ✓ |
| Duplicate | D | ✓ |
| Add title | G | ✓ |
| Separate audio | E | ✓ |
| Record voice-over | U | — |
| Delete | ⌫ | ✓ |
| Apply default transition | ⌘D | ✓ |
| Copy / cut / paste | ⌘C ⌘X ⌘V | ✓ |
| Select all / deselect all | ⌘A / ⇧⌘A | deselect ✓ |
| Set in / out | I O | ✓ |
| Go to in / out | ⇧I ⇧O | ✓ |
| Clear in / out / both | ⌥I ⌥O ⌥X | ✓ |
| Zoom in / out / to sequence | = − \ | ✓ |
| Snapping | ⌘Y | ✓ |
| Loop | ⌘L | ✓ |
| Inspector: titles, transitions, colour, speed, audio, position | ⌘1 ⌘2 ⌘3 ⌘4 ⌘5 ⌘6 | ✓ except ⌘3 (no colour yet) |
| Previous / next inspector tool | ⌘← ⌘→ | — |
| Media browser | Y | ✓ (media panel) |
| Maximise monitor | ` | ✓ |
| Audio scrubbing | A | — |
| Toggle track headers | ⌘T | — |
| Show audio tracks | ⌘R | — |
| Share (export) | ⌘E | ✓ |
| New project / save | ⌘N / ⌥⇧⌘S | ⌘N / ⌘S |
| Keyboard shortcuts | ⌥⌘K | — |

## Sources

- The installed app: `Keyboard Shortcuts/en/Rush/Rush_Defaults.kys`, `Lumetri/LUTs/Creative/`, `BundledMogrts/` (27 files), `Plug-Ins/Common/` (transitions), and the profile in `~/Documents/Adobe/Premiere Rush/2.0/Profile-jarllyng/` (Essential Sound presets, recent imports).
- [Premiere Rush User Guide (Adobe)](https://helpx.adobe.com/premiere-rush/user-guide.html)
- [Premiere Rush Discontinuation (Adobe)](https://helpx.adobe.com/premiere-rush/premiere-rush-discontinuation.html)
- [Adobe Premiere Rush – a concise guide (Macquarie University)](https://adobe.arts.mq.edu.au/support/time-based-media/adobe-premiere-rush-a-conscise-guide/)
- [Auto-reframe, transitions, pan and zoom (Adobe)](https://helpx.adobe.com/be_en/premiere-rush/desktop/edit-video/effects-panel.html)
