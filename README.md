# Eddie

En lille videoredigerer til Mac, lavet som afløser for Adobe Premiere Rush. I Mac App Store hedder den **Edwell**. Den har kun de funktioner, der faktisk bruges.

## Funktioner

- **Ny Ambient Session** (⇧⌘N, eller knappen i Medier): vælg optagelsen, og Eddie sætter den op som i Rush: hele optagelsen på V1 med 0,5 s dyk til sort og lydfade i begge ender, og titlen "Ambient / Session NNN" fra 11,2 til 50,8 s, venstrestillet i Outfit ExtraBold 177 px, i sessionens egen farve. Sæt så afspilningshovedet, hvor sessionen begynder, og tryk **Q**; hvor den slutter, og tryk **W**. Titlen bliver stående ved 11,2 s
- **Import** af video, lyd og billeder (knappen **+**, ⌘I eller træk filer ind i Medier)
- **Magnetisk hovedspor** som i Rush: klip på V1 ligger altid i forlængelse af hinanden, så sletning og trim lukker hullet. Træk et klip for at flytte det til en ny plads
- **Flere spor**: 3 videospor, 2 tekstspor og 2 lydspor, og du kan tilføje flere. Hvert spor kan skjules, have lyden slået fra og låses
- **Klip**: flyt (også mellem spor), trim i kanterne, del (S), ripple-trim til afspilningshovedet (Q/W), dupliker (D), kopiér/klip ud/sæt ind og adskil lyden fra videoen (E)
- **Overgange**: krydsfade, dyk til sort/hvid og skub i fire retninger, ved start og slut af et klip. Mellem to klip på hovedsporet overlapper de, og lyden krydsfades også
- **Hastighed**: 10–1000 % pr. klip, med eller uden bevaret tonehøjde
- **Størrelse og placering**: udfyld eller vis hele billedet, størrelse, placering, rotation, opacitet, spejling og beskæring med blød kant
- **Tekster**: skrifttype, vægt (100–900), størrelse, farve, venstre-/midt-/højrestilling, linjeafstand, skygge, baggrundsboks, placering og fade. Træk teksten direkte i preview. Outfit følger med appen (OFL, fra designsystemet), så projekter ser ens ud på alle Mac'er
- **Lyd**: lydstyrke pr. klip (0–200 %), slå lyd fra, fade ind og ud
- **Format**: 16:9, 9:16, 1:1 og 4:5
- **Eksport** til MP4 (H.264 eller HEVC) i 1080p, hele projektet eller kun mellem ind- og udpunkt
- Fortryd/gentag, autogem og projekter gemt som `.edwell`-filer (gamle `.eddie`-filer kan stadig åbnes)

## Genveje (som i Rush)

| Tast | Handling |
|---|---|
| Mellemrum | Afspil / pause |
| J K L | Spol tilbage / stop / frem (tryk flere gange for hurtigere) |
| ← → | Et billede tilbage / frem (med ⇧: et sekund) |
| ↑ ↓ | Forrige / næste klipkant |
| S | Del klip ved afspilningshovedet |
| Q W | Trim start / slut til afspilningshovedet |
| D | Dupliker |
| G | Ny tekst |
| E | Adskil lyd |
| ⌫ | Slet |
| ⌘D | Tilføj standardovergang (krydsfade) |
| ⌘C ⌘X ⌘V | Kopiér / klip ud / sæt ind ved afspilningshovedet |
| I O | Sæt ind- / udpunkt (⇧ går dertil, ⌥ rydder, ⌥X rydder begge) |
| = − \ | Zoom ind / ud / hele tidslinjen |
| ⌘Y | Snap til/fra |
| ⌘L | Gentag afspilning |
| ⌘1 ⌘2 ⌘4 ⌘5 ⌘6 | Tekst, overgange, hastighed, lyd, placering |
| \` | Stort preview |
| Y | Vis/skjul medier |
| ⌘Z / ⇧⌘Z | Fortryd / gentag |
| ⌘S, ⌘O, ⌘E | Gem, åbn, eksporter |

## Endnu ikke med

Se også [docs/rush-reference.md](docs/rush-reference.md): alt, hvad Rush kunne, hvordan det blev brugt til Ambient Sessions, og hvad Eddie mangler.

Farvefiltre, hastighed for kun en del af et klip (ramp), animerede tekstskabeloner, pan & zoom, auto reframe, auto-ducking, støjreduktion og optagelse af voiceover.

## Design

Eddie bruger [IAMJARL-designsystemet](https://github.com/JarlLyng/iamjarl-design) (Swift-pakken `IAMJARLDesignTokens`): alle farver, afstande, hjørner og skriftstørrelser i brugerfladen kommer derfra, og appen følger systemets lyse eller mørke tilstand. `Sources/EddieKit/Theme.swift` samler det, Eddie selv udleder af tokens (klippenes neutrale fyld og knapstilene). Farverne i selve videoen, som tekstfarver og baggrund, er brugerens indhold og ikke en del af designsystemet.

## Byg

Appen bygges med Xcode fra `App/Edwell.xcodeproj` (lavet af `App/project.yml` med [XcodeGen](https://github.com/yonaskolb/XcodeGen)) og kører i App Sandbox som App Store-versionen. Selvtesten og `swift build` kræver kun Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh            # bygger build/Edwell.app
./build.sh --open     # bygger og åbner
./build.sh --install  # bygger og kopierer til /Programmer
```

App Store-versionen bygges af Xcode Cloud fra grenen `release`; se [XCODE_CLOUD.md](XCODE_CLOUD.md).

Test med en rigtig session (bygger skabelonen, trimmer som Rush gjorde for session 011, eksporterer og sammenligner med Rush' video; `--full` eksporterer hele timen):

```bash
.build/debug/Eddie --session-test "<optagelse>.mov" /tmp/eddie-session "<Rush' færdige video>.mp4"
```

Selvtest (laver testvideoer, eksporterer et projekt med alle typer klip og tester redigeringsfunktionerne):

```bash
swift build && .build/debug/Eddie --selftest /tmp/eddie-test
```

## Opbygning

| Fil | Indhold |
|---|---|
| `Sources/EddieKit/` | Hele appen; `App/` er App Store-målet rundt om den |
| `Model.swift` | Projekt, klip, medier og tekststil (gemmes som JSON) |
| `Editor.swift` | Tilstand, redigering, fortryd, afspilning, gem og åbn |
| `CompositionBuilder.swift` | Omsætter projektet til en AVFoundation-komposition |
| `Compositor.swift` | Tegner hvert billede: skalering, lag og tekster. Bruges af både preview og eksport |
| `Exporter.swift` | MP4-eksport |
| `Views/` | Mediebibliotek, preview, tidslinje, inspektør og eksport |
