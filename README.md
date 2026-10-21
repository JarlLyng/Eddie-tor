# Eddie

En lille videoredigerer til Mac, lavet som afløser for Adobe Premiere Rush. Den har kun de funktioner, der faktisk bruges.

## Funktioner

- **Import** af video, lyd og billeder (knappen **+**, ⌘I eller træk filer ind i Medier)
- **Magnetisk hovedspor** som i Rush: klip på V1 ligger altid i forlængelse af hinanden, så sletning og trim lukker hullet. Træk et klip for at flytte det til en ny plads
- **Flere spor**: 3 videospor, 2 tekstspor og 2 lydspor, og du kan tilføje flere. Hvert spor kan skjules, have lyden slået fra og låses
- **Klip**: flyt (også mellem spor), trim i kanterne, del (S), ripple-trim til afspilningshovedet (Q/W), dupliker (D), kopiér/klip ud/sæt ind og adskil lyden fra videoen (E)
- **Overgange**: krydsfade, dyk til sort/hvid og skub i fire retninger, ved start og slut af et klip. Mellem to klip på hovedsporet overlapper de, og lyden krydsfades også
- **Hastighed**: 10–1000 % pr. klip, med eller uden bevaret tonehøjde
- **Størrelse og placering**: udfyld eller vis hele billedet, størrelse, placering, rotation, opacitet, spejling og beskæring med blød kant
- **Tekster**: skrifttype, størrelse, farve, skygge, baggrundsboks, placering og fade. Træk teksten direkte i preview
- **Lyd**: lydstyrke pr. klip (0–200 %), slå lyd fra, fade ind og ud
- **Format**: 16:9, 9:16, 1:1 og 4:5
- **Eksport** til MP4 (H.264 eller HEVC) i 1080p, hele projektet eller kun mellem ind- og udpunkt
- Fortryd/gentag, autogem og projekter gemt som `.eddie`-filer

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

Farvefiltre, hastighed for kun en del af et klip (ramp), animerede tekstskabeloner, pan & zoom, auto reframe, auto-ducking, støjreduktion og optagelse af voiceover.

## Byg

Kræver kun Xcode Command Line Tools (`xcode-select --install`), ikke hele Xcode.

```bash
./build.sh            # bygger build/Eddie.app
./build.sh --open     # bygger og åbner
./build.sh --install  # bygger og kopierer til /Programmer
```

Selvtest (laver testvideoer, eksporterer et projekt med alle typer klip og tester redigeringsfunktionerne):

```bash
swift build && .build/debug/Eddie --selftest /tmp/eddie-test
```

## Opbygning

| Fil | Indhold |
|---|---|
| `Model.swift` | Projekt, klip, medier og tekststil (gemmes som JSON) |
| `Editor.swift` | Tilstand, redigering, fortryd, afspilning, gem og åbn |
| `CompositionBuilder.swift` | Omsætter projektet til en AVFoundation-komposition |
| `Compositor.swift` | Tegner hvert billede: skalering, lag og tekster. Bruges af både preview og eksport |
| `Exporter.swift` | MP4-eksport |
| `Views/` | Mediebibliotek, preview, tidslinje, inspektør og eksport |
