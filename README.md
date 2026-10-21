# Eddie

En lille videoredigerer til Mac, lavet som afløser for Adobe Premiere Rush. Den har kun de funktioner, der faktisk bruges.

## Funktioner

- **Import** af video, lyd og billeder (knappen **+**, ⌘I eller træk filer ind i Medier)
- **Flere spor**: 3 videospor, 2 tekstspor og 2 lydspor. Du kan tilføje flere med knappen til spor på tidslinjen
- **Klip**: træk klip for at flytte dem (også mellem spor), træk i kanterne for at trimme, og del ved afspilningshovedet med **S** eller ⌘B
- **Tekster**: skrifttype, størrelse, farve, skygge, baggrundsboks og placering. Træk teksten direkte i preview
- **Musik og lyd**: lydstyrke pr. klip (0–200 %), slå lyd fra, fade ind og ud
- **Format**: 16:9, 9:16, 1:1 og 4:5. Vælg mellem at udfylde rammen og at vise hele billedet, og indstil størrelse og placering pr. klip
- **Eksport** til MP4 (H.264 eller HEVC) i 1080p
- Fortryd/gentag, autogem og projekter gemt som `.eddie`-filer

## Genveje

| Tast | Handling |
|---|---|
| Mellemrum | Afspil / pause |
| S eller ⌘B | Del klip ved afspilningshovedet |
| ⌫ | Slet valgt klip |
| T | Tilføj tekst |
| ← → | Et billede tilbage / frem (med ⇧: et sekund) |
| + − | Zoom på tidslinjen |
| ⌘Z / ⇧⌘Z | Fortryd / gentag |
| ⌘S, ⌘O, ⌘E | Gem, åbn, eksporter |

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
