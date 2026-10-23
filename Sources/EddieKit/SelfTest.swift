import AVFoundation
import AppKit
import Security
import UniformTypeIdentifiers

/// `Eddie --selftest <dir>`: generates test media, builds a project with every clip type,
/// exports it and saves frames as PNG so the result can be checked without the UI.
enum SelfTest {
    static func run(outputDirectory dir: URL) -> Never {
        Task {
            do {
                try await perform(dir)
                print("SELFTEST OK")
                exit(0)
            } catch {
                print("SELFTEST FAILED: \(error)")
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func perform(_ dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let landscape = dir.appendingPathComponent("landscape.mov")
        let rotated = dir.appendingPathComponent("rotated.mov")
        let image = dir.appendingPathComponent("image.png")
        let tone = dir.appendingPathComponent("tone.m4a")

        try await writeVideo(to: landscape, seconds: 3, transform: .identity)
        // Like an iPhone held upright: landscape pixels plus a 90° rotation.
        try await writeVideo(to: rotated, seconds: 3, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0))
        try writeImage(to: image)
        try writeTone(to: tone, seconds: 6)

        var project = Project()
        project.aspect = .portrait
        for url in [landscape, rotated, image, tone] {
            guard let item = await MediaLoader.load(url) else { throw err("Kunne ikke indlæse \(url.lastPathComponent)") }
            project.media.append(item)
            print("media", item.name, item.kind, item.duration, item.width, "x", item.height)
        }
        let m = project.media
        project.clips = [
            Clip(kind: .video, track: 0, start: 0, duration: 3, mediaID: m[0].id),
            Clip(kind: .video, track: 0, start: 3, duration: 3, mediaID: m[1].id, fill: false),
            Clip(kind: .image, track: 1, start: 1, duration: 1.5, mediaID: m[2].id, scale: 0.4, offsetY: -0.3),
            Clip(kind: .title, track: 0, start: 0.5, duration: 4, fadeIn: 0.25, fadeOut: 0.25,
                 title: TitleStyle(text: "Hej Eddie\nanden linje", background: true)),
            Clip(kind: .audio, track: 0, start: 0, duration: 6, mediaID: m[3].id, volume: 0.5, fadeOut: 1),
        ]

        let data = try JSONEncoder().encode(project)
        guard try JSONDecoder().decode(Project.self, from: data) == project else { throw err("JSON round trip") }
        try data.write(to: dir.appendingPathComponent("demo.eddie"))

        let output = dir.appendingPathComponent("selftest.mp4")
        try await Exporter.export(project, to: output, codec: .h264) { _ in }

        let result = AVURLAsset(url: output)
        let duration = try await result.load(.duration).seconds
        let video = try await result.loadTracks(withMediaType: .video)
        let audio = try await result.loadTracks(withMediaType: .audio)
        let size = try await video.first?.load(.naturalSize) ?? .zero
        print("export duration \(duration) size \(size) videoTracks \(video.count) audioTracks \(audio.count)")
        guard abs(duration - 6) < 0.1, size == CGSize(width: 1080, height: 1920), video.count == 1, audio.count == 1 else {
            throw err("Uventet eksport")
        }

        for t in [0.25, 1.5, 4.0, 5.9] {
            try await saveFrame(of: result, at: t, to: dir.appendingPathComponent(String(format: "frame-%.2f.png", t)))
        }
        try await saveFrame(of: AVURLAsset(url: rotated), at: 0.5, to: dir.appendingPathComponent("reference-rotated.png"))

        // Every aspect ratio must build and render.
        for aspect in AspectRatio.allCases {
            var p = project
            p.aspect = aspect
            let url = dir.appendingPathComponent("aspect-\(aspect.rawValue).mp4")
            try await Exporter.export(p, to: url, codec: .hevc) { _ in }
            let s = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.naturalSize)
            print("aspect \(aspect.label): \(s ?? .zero)")
            try await saveFrame(of: AVURLAsset(url: url), at: 1.5, to: dir.appendingPathComponent("aspect-\(aspect.rawValue).png"))
        }

        // A project with only a title and no media still exports.
        var titleOnly = Project()
        titleOnly.clips = [Clip(kind: .title, track: 0, start: 0, duration: 2, title: TitleStyle(text: "Kun tekst"))]
        try await Exporter.export(titleOnly, to: dir.appendingPathComponent("title-only.mp4"), codec: .h264) { _ in }
        print("title-only export ok")

        try await MainActor.run { try editingTests(media: m) }
        print("editing tests ok")

        let withAudio = await MediaLoader.load(output)!
        try await MainActor.run { try rushEditingTests(media: m, videoWithAudio: withAudio) }
        print("rush editing tests ok")

        try await renderTests(dir, media: m)
        print("render tests ok")

        try await titleAndSessionTests(dir, media: m)
        print("title and session tests ok")

        try await firstRunTests(dir, video: landscape, image: image, music: tone)
        print("first run tests ok")

        try await MainActor.run { try storeBuildTests(dir, demo: data) }
        print("store build tests ok")

        try feedbackTests()
        print("feedback tests ok")

        try await mediaAccessTests(dir, source: landscape)
        print("media access tests ok")

        try localizationTests()
        print("localization tests ok")

        try await MainActor.run { try purchaseTests() }
        print("purchase tests ok")
    }

    /// The trial and the purchase without the App Store (the StoreKit cases are in App/StoreTests): when
    /// export opens and closes, that a build signed on this Mac is unlocked, that Edwell.storekit matches
    /// the product ids, and that the screen that starts the trial says what guideline 3.1.1 asks for.
    @MainActor
    private static func purchaseTests() throws {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw err("Køb: \(message)") } }
        let now = Date()
        let day: TimeInterval = 86_400
        func access(_ unlocked: Bool, startedDaysAgo: Double?) -> Access {
            Access.compute(unlocked: unlocked, trialStart: startedDaysAgo.map { now.addingTimeInterval(-$0 * day) }, now: now)
        }
        try check(access(false, startedDaysAgo: nil) == .notStarted && !Access.notStarted.canExport, "ikke startet")
        try check(access(false, startedDaysAgo: 0) == .trial(daysLeft: 14), "første dag \(access(false, startedDaysAgo: 0))")
        try check(access(false, startedDaysAgo: 0.5) == .trial(daysLeft: 14), "første døgn")
        try check(access(false, startedDaysAgo: 13.5) == .trial(daysLeft: 1), "sidste dag")
        try check(access(false, startedDaysAgo: 14.01) == .trialEnded && !Access.trialEnded.canExport, "udløbet")
        try check(access(true, startedDaysAgo: 30) == .unlocked && access(true, startedDaysAgo: nil) == .unlocked, "købt")
        try check(Access.trial(daysLeft: 3).canExport && Access.unlocked.canExport, "eksport i prøveperioden")

        // `swift build` and ./build.sh sign on this Mac, so those builds are unlocked without StoreKit.
        try check(Store.isLocalBuild && Store(localBuild: true).access == .unlocked, "lokalt build")

        // Before the trial starts: its length, that export stops, and the price, all on the screen.
        let start = (PurchaseCopy.title(.notStarted) + " " + PurchaseCopy.paragraphs(.notStarted, price: "$9.99").joined(separator: " "))
        let danish = Bundle.main.preferredLocalizations.first == "da"
        let expected = danish ? ["14 dage", "$9.99", "eksport"] : ["14 days", "$9.99", "export"]
        try check(expected.allSatisfy { start.localizedCaseInsensitiveContains($0) }, "3.1.1: \(start)")
        try check(!PurchaseCopy.paragraphs(.trialEnded, price: "$9.99").joined().localizedCaseInsensitiveContains("free"), "aldrig gratis")

        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("App/Edwell.storekit"))) as? [String: Any]
        let products = config?["products"] as? [[String: Any]] ?? []
        func product(_ id: String) -> [String: Any]? { products.first { $0["productID"] as? String == id } }
        let trial = product(Store.trialID), unlock = product(Store.unlockID)
        try check(products.count == 2 && trial?["type"] as? String == "NonConsumable" && unlock?["type"] as? String == "NonConsumable",
                  "produkter i Edwell.storekit")
        try check(trial?["displayPrice"] as? String == "0.00" && unlock?["displayPrice"] as? String == "9.99", "priser")
        // App Review wants the $0 trial named "XX-day Trial", as reference name and display name.
        let trialName = ((trial?["localizations"] as? [[String: Any]])?.first?["displayName"] as? String)
        try check(trial?["referenceName"] as? String == "14-day Trial" && trialName == "14-day Trial", "navnet på prøveperioden")
    }

    /// English is the development language and Danish a full localization: every string in the catalog
    /// has its Danish translation (scripts/sync-strings.sh adds new ones without), and no Danish is left
    /// in the code. Inside Edwell.app it checks the compiled Danish strings instead.
    private static func localizationTests() throws {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw err("Lokalisering: \(message)") } }
        if Bundle.main.bundleURL.pathExtension == "app" {
            try check(Bundle.main.developmentLocalization == "en" && Bundle.main.localizations.contains("da"),
                      "sprog \(Bundle.main.localizations)")
            guard let url = Bundle.main.url(forResource: "da", withExtension: "lproj"), let danish = Bundle(url: url) else {
                throw err("Lokalisering: ingen da.lproj")
            }
            try check(danish.localizedString(forKey: "Save", value: nil, table: nil) == "Gem", "Save")
            try check(danish.localizedString(forKey: "Edwell Project", value: nil, table: "InfoPlist") == "Edwell-projekt", "dokumenttype")
            let format = danish.localizedString(forKey: "%lld media files can't be read", value: nil, table: nil)
            try check(String.localizedStringWithFormat(format, 1) == "1 mediefil kan ikke læses"
                      && String.localizedStringWithFormat(format, 3) == "3 mediefiler kan ikke læses", "flertal")
            return
        }

        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["Localizable", "InfoPlist"] {
            let data = try Data(contentsOf: repo.appendingPathComponent("App/Edwell/\(name).xcstrings"))
            let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            try check(catalog["sourceLanguage"] as? String == "en", "\(name): kildesprog")
            let strings = catalog["strings"] as? [String: [String: Any]] ?? [:]
            let untranslated = strings.filter { _, entry in
                guard entry["shouldTranslate"] as? Bool != false else { return false }
                let danish = (entry["localizations"] as? [String: Any])?["da"] as? [String: Any]
                let unit = danish?["stringUnit"] as? [String: Any]
                return unit?["state"] as? String != "translated" && danish?["variations"] == nil
            }
            try check(untranslated.isEmpty, "\(name) mangler dansk: \(untranslated.keys.sorted())")
        }
        let project = try String(contentsOf: repo.appendingPathComponent("App/Edwell.xcodeproj/project.pbxproj"), encoding: .utf8)
        try check(project.contains("developmentRegion = en;"), "udviklingssprog")

        // Danish letters in a string literal mean a string that never went through the catalog.
        let sources = repo.appendingPathComponent("Sources/EddieKit")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && !$0.lastPathComponent.hasSuffix("Test.swift") } ?? []
        let literal = try NSRegularExpression(pattern: #""[^"\n]*[æøåÆØÅ][^"\n]*""#)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let s = String(line)
                try check(literal.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil,
                          "dansk i \(file.lastPathComponent): \(s.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// Media under the sandbox: an import gets a bookmark, which follows a renamed file and is made again;
    /// a project copied with its media finds them next to it; media that can't be read is left out of
    /// export and found again in a picked folder or as a picked file; an old project gets bookmarks.
    @MainActor
    private static func mediaAccessTests(_ dir: URL, source: URL) async throws {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw err("Medieadgang: \(message)") } }
        func same(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.path == b.standardizedFileURL.path }
        let fm = FileManager.default
        let root = dir.appendingPathComponent("access")
        try? fm.removeItem(at: root)
        let folder = root.appendingPathComponent("Projekt")
        try fm.createDirectory(at: folder.appendingPathComponent("medier"), withIntermediateDirectories: true)
        let recording = folder.appendingPathComponent("medier/optagelse.mov")
        try fm.copyItem(at: source, to: recording)

        guard let item = await MediaLoader.load(recording), item.bookmark != nil else { throw err("Medieadgang: bogmærke ved import") }
        let editor = Editor(persist: false)
        editor.edit {
            $0.media = [item]
            $0.clips = [Clip(kind: .video, track: 0, start: 0, duration: 2, mediaID: item.id)]
        }
        let projectURL = folder.appendingPathComponent("film.edwell")
        try check(editor.write(to: projectURL), "gem")
        let saved = try JSONDecoder().decode(Project.self, from: Data(contentsOf: projectURL))
        try check(saved.media.first?.relativePath == "medier/optagelse.mov", "relativ sti \(saved.media.first?.relativePath ?? "ingen")")

        // Renamed: the bookmark follows the file and is made again, so it isn't stale next time.
        let renamed = folder.appendingPathComponent("medier/omdoebt.mov")
        try fm.moveItem(at: recording, to: renamed)
        editor.open(projectURL)
        try check(same(editor.project.media[0].url, renamed) && editor.unreadableMedia.isEmpty, "omdøbt fil \(editor.project.media[0].url.path)")
        guard let bookmark = editor.project.media[0].bookmark, let again = MediaAccess.resolve(bookmark) else { throw err("Medieadgang: nyt bogmærke") }
        if again.scoped { again.url.stopAccessingSecurityScopedResource() }
        try check(!again.stale, "bogmærket er stadig forældet")
        try check(editor.write(to: projectURL), "gem igen")

        // Copied with its media to another drive (new files, so the bookmark can't follow): found next to the project.
        let copy = root.appendingPathComponent("Kopi")
        try fm.copyItem(at: folder, to: copy)
        try fm.removeItem(at: folder)
        editor.open(copy.appendingPathComponent("film.edwell"))
        let copied = copy.appendingPathComponent("medier/omdoebt.mov")
        try check(same(editor.project.media[0].url, copied) && editor.unreadableMedia.isEmpty, "flyttet med projektet")

        // A file that exists but can't be read, as in the sandbox: left out of export instead of failing it.
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: copied.path)
        try check(editor.unreadableMedia.count == 1, "ulæselig fil ikke opdaget")
        let without = root.appendingPathComponent("uden-medier.mp4")
        try await Exporter.export(editor.project, to: without, codec: .h264) { _ in }
        // Only the one second of black filler is left; the two second clip would have made it longer.
        let length = try await AVURLAsset(url: without).load(.duration).seconds
        try check(length < 1.5, "ulæselig fil kom med i eksporten (\(length) s)")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copied.path)

        // Gone from where the project expects it: found by name in a picked folder, as one undo step.
        let elsewhere = root.appendingPathComponent("Andet/dybt/omdoebt.mov")
        try fm.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: copied, to: elsewhere)
        try fm.removeItem(at: copied)
        editor.open(copy.appendingPathComponent("film.edwell"))
        try check(editor.unreadableMedia.count == 1, "manglende fil ikke opdaget")
        editor.relink(editor.unreadableMedia, in: root.appendingPathComponent("Andet"))
        try check(same(editor.project.media[0].url, elsewhere) && editor.unreadableMedia.isEmpty && editor.isDirty
                  && editor.errorMessage == nil, "fundet i mappe")

        // A single file picked under another name.
        let other = root.appendingPathComponent("andet navn.mov")
        try fm.copyItem(at: elsewhere, to: other)
        try fm.removeItem(at: elsewhere)
        editor.open(copy.appendingPathComponent("film.edwell"))
        editor.relink(editor.unreadableMedia, in: other)
        try check(same(editor.project.media[0].url, other) && editor.unreadableMedia.isEmpty, "fundet som fil")

        // An old project without bookmarks opens and gets them.
        var old = Project()
        old.media = [MediaItem(url: other, kind: .video, duration: item.duration, width: item.width, height: item.height, hasAudio: item.hasAudio)]
        let oldURL = root.appendingPathComponent("gammelt.eddie")
        try JSONEncoder().encode(old).write(to: oldURL)
        try check(!String(decoding: try Data(contentsOf: oldURL), as: UTF8.self).contains("bookmark"), "gammel fil har bogmærke")
        editor.open(oldURL)
        try check(editor.project.media[0].bookmark != nil && editor.unreadableMedia.isEmpty, "gammelt projekt")
    }

    /// The path a new user takes on a first run: an empty project, files dragged from Finder straight onto
    /// the timeline, a split, a title and an export.
    @MainActor
    private static func firstRunTests(_ dir: URL, video: URL, image: URL, music: URL) async throws {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw err("Første gang: \(message)") } }
        let editor = Editor(persist: false)
        try check(editor.project.clips.isEmpty && editor.project.media.isEmpty && editor.fileURL == nil, "tomt projekt")

        let v1 = TrackRow(group: .visual, index: 0), a1 = TrackRow(group: .audio, index: 0)
        await editor.dropFiles([video, image], at: 0, row: v1)
        // Music dropped on a video track goes to the first audio track.
        await editor.dropFiles([music], at: 0, row: v1)
        // The same file again is one more clip, not one more media item.
        await editor.dropFiles([video], at: 100, row: v1)
        let main = editor.clips(in: v1)
        try check(editor.project.media.count == 3 && editor.errorMessage == nil, "medier \(editor.project.media.count)")
        try check(main.map(\.kind) == [.video, .image, .video] && main.map(\.start) == [0, 3, 7], "V1 \(main.map(\.start))")
        try check(editor.clips(in: a1).map(\.kind) == [.audio], "musik på A1")

        editor.selection = nil
        editor.seek(1.5)
        editor.splitAtPlayhead()
        editor.addTitle()
        try check(editor.clips(in: v1).count == 4 && editor.project.clips.contains { $0.kind == .title }, "del og titel")

        let url = dir.appendingPathComponent("first-run.mp4")
        try await Exporter.export(editor.project, to: url, codec: .h264) { _ in }
        let length = try await AVURLAsset(url: url).load(.duration).seconds
        try check(abs(length - 10) < 0.1, "eksport \(length) s")
    }

    /// Send Feedback… opens a draft to support with the versions in it, encoded so nothing is cut short,
    /// and About links the same draft.
    private static func feedbackTests() throws {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw err("Feedback: \(message)") } }
        let facts = Feedback.Facts(version: "1.0", build: "7", system: "27.0.1, Apple silicon")
        let url = Feedback.url(facts)
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func value(_ name: String) -> String? { parts?.queryItems?.first { $0.name == name }?.value }
        try check(parts?.scheme == "mailto" && parts?.path == "support@iamjarl.com", "adresse \(url)")
        try check(value("subject") == Feedback.subject(facts) && Feedback.subject(facts).contains("1.0"), "emne \(value("subject") ?? "")")
        try check(value("body") == Feedback.body(facts), "brødtekst")
        try check(Feedback.body(facts).contains("Edwell 1.0 (7)\nmacOS 27.0.1, Apple silicon"), "versioner")
        try check(!url.absoluteString.contains(" ") && !url.absoluteString.contains("\n"), "kodning")
        // A value with the characters `queryItems` would leave alone still comes back whole.
        let odd = Feedback.Facts(version: "1&2=3+4", build: "?", system: "x")
        let back = URLComponents(url: Feedback.url(odd), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value
        try check(back == Feedback.body(odd), "& = +")

        let credits = About.credits
        let range = (credits.string as NSString).range(of: Feedback.address)
        try check(range.location != NSNotFound && credits.attribute(.link, at: range.location, effectiveRange: nil) as? URL != nil, "link i Om")
    }

    /// The Mac App Store build declares what the code expects: the bundle id and copyright, the project type
    /// with `.edwell` first and old `.eddie` files still opening, and no entitlement beyond the sandbox and
    /// files the user picks. Inside Edwell.app it checks the app itself; from `swift build` it reads App/.
    @MainActor
    private static func storeBuildTests(_ dir: URL, demo: Data) throws {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw err("App Store-build: \(message)") } }
        let insideApp = Bundle.main.bundleURL.pathExtension == "app"
        let info: [String: Any]
        if insideApp {
            info = Bundle.main.infoDictionary ?? [:]
            try check(info["CFBundleIdentifier"] as? String == "com.iamjarl.edwell", "bundle id")
            let task = SecTaskCreateFromSelf(nil)!
            let sandboxed = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool
            try check(sandboxed == true, "ikke i sandkassen")
        } else {
            let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("App")
            func plist(_ path: String) throws -> [String: Any] {
                let data = try Data(contentsOf: app.appendingPathComponent(path))
                return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
            }
            info = try plist("Edwell/Info.plist")
            let entitlements = try plist("Edwell/Edwell.entitlements")
            try check(Set(entitlements.keys) == ["com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write"]
                      && entitlements.values.allSatisfy { $0 as? Bool == true }, "entitlements \(entitlements.keys.sorted())")
            let project = try String(contentsOf: app.appendingPathComponent("Edwell.xcodeproj/project.pbxproj"), encoding: .utf8)
            try check(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.iamjarl.edwell;"), "bundle id")
        }
        try check(info["CFBundleDisplayName"] as? String == "Edwell", "navn")
        try check(info["NSHumanReadableCopyright"] as? String == "© 2026 IAMJARL" && About.copyright == "© 2026 IAMJARL", "copyright")
        try check(info["LSApplicationCategoryType"] as? String == "public.app-category.video", "kategori")

        let types = info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
        let type = types.first { $0["UTTypeIdentifier"] as? String == Editor.projectType.identifier }
        let tags = type?["UTTypeTagSpecification"] as? [String: Any]
        try check(tags?["public.filename-extension"] as? [String] == Editor.projectExtensions, "projekttype \(types)")
        let documents = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        try check(documents.contains { ($0["LSItemContentTypes"] as? [String])?.contains(Editor.projectType.identifier) == true },
                  "dokumenttype")

        // An old .eddie file opens, and Save As offers it back as .edwell.
        let editor = Editor(persist: false)
        try check(editor.suggestedFileName == String(localized: "My Project") + ".edwell", "nyt navn \(editor.suggestedFileName)")
        let old = dir.appendingPathComponent("Gammelt projekt.eddie")
        try demo.write(to: old)
        editor.open(old)
        try check(editor.fileURL == old && editor.errorMessage == nil && !editor.project.clips.isEmpty, "åbn .eddie")
        try check(editor.suggestedFileName == "Gammelt projekt.edwell", "gem som \(editor.suggestedFileName)")
    }

    /// Magnetic main track, ripple trims, transitions, speed, track flags, copy/paste and in/out.
    @MainActor
    private static func rushEditingTests(media: [MediaItem], videoWithAudio: MediaItem) throws {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw err("Rush-redigering: \(message)") } }
        let editor = Editor(persist: false)
        editor.edit { $0.media = media + [videoWithAudio] }
        let video = media[0]
        func main() -> [Clip] { editor.project.clips.filter { editor.project.isMagnetic($0) }.sorted { $0.start < $1.start } }

        editor.add(video); editor.add(video); editor.add(video)
        try check(main().map(\.start) == [0, 3, 6], "tre klip i træk")

        // Deleting closes the gap.
        editor.selection = main()[0].id
        editor.deleteSelection()
        try check(main().map(\.start) == [0, 3], "slet lukker hullet")

        // W trims the end to the playhead and the next clip follows.
        editor.selection = nil
        editor.currentTime = 1
        editor.trimToPlayhead(start: false)
        try check(abs(main()[0].duration - 1) < 1e-9 && abs(main()[1].start - 1) < 1e-9, "W ripple-trim")

        // Q trims the start: the source moves on, and the clip stays where it is.
        editor.currentTime = 1.5
        editor.selection = main()[1].id
        editor.trimToPlayhead(start: true)
        try check(abs(main()[1].start - 1) < 1e-9 && abs(main()[1].sourceIn - 0.5) < 1e-9 && abs(main()[1].duration - 2.5) < 1e-9, "Q ripple-trim")

        // Dropping in the middle of a clip inserts before or after it.
        editor.add(video, at: 0.2)
        try check(main().count == 3 && main()[0].duration == 3 && main()[0].start == 0, "indsæt før første klip")

        // Dragging a clip past its neighbour reorders the main track.
        let first = main()[0].id, second = main()[1].id
        editor.beginInteraction()
        editor.floating = first
        editor.interact { p in if let i = p.clips.firstIndex(where: { $0.id == first }) { p.clips[i].start = 3.5 } }
        editor.endInteraction()
        try check(main()[0].id == second && main().last?.id == first && main().map(\.start)[1] == main()[0].end, "træk omsorterer")

        // A transition makes the clip overlap the one before it.
        let before = main()
        editor.selection = before[1].id
        editor.applyDefaultTransition()
        let after = main()
        try check(abs(after[1].start - (before[1].start - 0.5)) < 1e-9 && after[1].transitionIn?.kind == .crossDissolve, "overgang overlapper")

        // Speed keeps the same source and changes the length.
        let speedID = after[2].id
        let sourceBefore = after[2].sourceDuration
        editor.setSpeed(speedID, 2)
        let sped = editor.project.clips.first { $0.id == speedID }!
        try check(abs(sped.duration - sourceBefore / 2) < 1e-9 && abs(sped.sourceDuration - sourceBefore) < 1e-9, "hastighed")
        editor.currentTime = sped.start + 0.5
        editor.selection = speedID
        editor.splitAtPlayhead()
        let right = editor.project.clips.first { $0.id == editor.selection }!
        try check(abs(right.sourceIn - (sped.sourceIn + 1)) < 1e-9, "del med hastighed")

        // Copy and paste.
        let count = editor.project.clips.count
        editor.copySelection()
        editor.currentTime = 0
        editor.paste()
        try check(editor.project.clips.count == count + 1 && main().first?.id == editor.selection, "kopiér og sæt ind")

        // Separate audio.
        editor.add(videoWithAudio, at: 0, track: 1)
        editor.separateAudio()
        let detached = editor.project.clips.first { $0.mediaID == videoWithAudio.id && $0.kind == .video }!
        let audio = editor.project.clips.first { $0.mediaID == videoWithAudio.id && $0.kind == .audio }
        try check(detached.audioDetached && audio?.start == detached.start && audio?.duration == detached.duration, "adskil lyd")

        // Locked tracks can't be edited.
        editor.toggleFlag(TrackRow(group: .visual, index: 0), \.locked)
        let locked = main()[0]
        editor.selection = locked.id
        try check(editor.selection == locked.id || editor.selection == nil, "valg")
        editor.deleteSelection()
        try check(main().contains { $0.id == locked.id }, "låst spor")
        editor.toggleFlag(TrackRow(group: .visual, index: 0), \.locked)

        // In and out points.
        editor.currentTime = 1; editor.markIn()
        editor.currentTime = 2; editor.markOut()
        try check(editor.project.inPoint == 1 && editor.project.outPoint == 2, "ind og ud")

        // Files from the first version still open.
        let old = #"{"version":1,"aspect":"portrait","fps":30,"background":{"r":0,"g":0,"b":0,"a":1},"titleTracks":2,"visualTracks":3,"audioTracks":2,"media":[],"clips":[{"id":"9C3A1F43-2D19-4C59-9E47-2F1D7E7C1A10","kind":"title","track":0,"start":0,"duration":2,"sourceIn":0,"volume":1,"fadeIn":0,"fadeOut":0,"scale":1,"offsetX":0,"offsetY":0,"fill":true,"title":{"text":"Hej","fontFamily":"Helvetica Neue","bold":true,"size":90,"color":{"r":1,"g":1,"b":1,"a":1},"shadow":true,"background":false,"backgroundColor":{"r":0,"g":0,"b":0,"a":0.6},"x":0.5,"y":0.8}}]}"#
        let decoded = try JSONDecoder().decode(Project.self, from: Data(old.utf8))
        try check(decoded.clips.first?.speed == 1 && decoded.magneticMain && decoded.clips.first?.opacity == 1, "gammelt projekt")
    }

    /// Exports a 16:9 project and checks pixels inside a dissolve, a push and on hidden or muted tracks.
    private static func renderTests(_ dir: URL, media m: [MediaItem]) async throws {
        var project = Project()
        project.aspect = .landscape
        project.media = m
        // The test video is red, green, blue for one second each.
        var a = Clip(kind: .video, track: 0, start: 0, duration: 3, mediaID: m[0].id)
        var b = Clip(kind: .video, track: 0, start: 3, duration: 3, mediaID: m[0].id)
        b.transitionIn = Transition(kind: .crossDissolve, duration: 1)
        var c = Clip(kind: .video, track: 0, start: 6, duration: 1.5, mediaID: m[0].id)
        c.speed = 2
        c.transitionIn = Transition(kind: .pushLeft, duration: 0.5)
        var overlay = Clip(kind: .image, track: 1, start: 0, duration: 1, mediaID: m[2].id)
        overlay.scale = 0.5; overlay.rotation = 30; overlay.opacity = 0.6; overlay.cropLeft = 0.3; overlay.feather = 20
        var tone = Clip(kind: .audio, track: 0, start: 0, duration: 6, mediaID: m[3].id)
        tone.fadeOut = 1
        a.fadeIn = 0
        project.clips = [a, b, c, overlay, tone]
        Editor.packMain(&project)
        let starts = project.clips.filter { project.isMagnetic($0) }.map(\.start)
        guard starts == [0, 2, 4.5] else { throw err("pakning \(starts)") }

        var demo = project
        demo.inPoint = 1; demo.outPoint = 5
        demo.clips.append(Clip(kind: .title, track: 0, start: 0.5, duration: 3, fadeIn: 0.25, fadeOut: 0.25, title: TitleStyle(text: "Eddie")))
        try JSONEncoder().encode(demo).write(to: dir.appendingPathComponent("demo-rush.eddie"))

        let url = dir.appendingPathComponent("render.mp4")
        try await Exporter.export(project, to: url, codec: .h264) { _ in }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard abs(duration - 6) < 0.05 else { throw err("varighed \(duration)") }
        try await saveFrame(of: asset, at: 0.5, to: dir.appendingPathComponent("render-overlay.png"))
        try await saveFrame(of: asset, at: 2.5, to: dir.appendingPathComponent("render-dissolve.png"))
        try await saveFrame(of: asset, at: 4.75, to: dir.appendingPathComponent("render-push.png"))

        func near(_ p: (Double, Double, Double), _ q: (Double, Double, Double), _ tolerance: Double = 0.12) -> Bool {
            abs(p.0 - q.0) < tolerance && abs(p.1 - q.1) < tolerance && abs(p.2 - q.2) < tolerance
        }
        let red = (0.8, 0.2, 0.2), blue = (0.2, 0.3, 0.8)
        // Middle of the dissolve: half blue (end of A), half red (start of B).
        let mid = try await pixel(asset, at: 2.5, x: 0.5, y: 0.5)
        let early = try await pixel(asset, at: 2.1, x: 0.5, y: 0.5), late = try await pixel(asset, at: 2.9, x: 0.5, y: 0.5)
        print("dissolve", early, mid, late)
        // Mixed in the middle, and moving from blue towards red.
        guard mid.0 > 0.3, mid.0 < 0.7, mid.2 > 0.3, mid.2 < 0.7, early.0 < mid.0, mid.0 < late.0, early.2 > mid.2, mid.2 > late.2 else {
            throw err("krydsfade \(early) \(mid) \(late)")
        }
        // Middle of the push: B (blue at its end) on the left, C (red at its start) on the right.
        let left = try await pixel(asset, at: 4.75, x: 0.2, y: 0.5), rightSide = try await pixel(asset, at: 4.75, x: 0.8, y: 0.5)
        print("push", left, rightSide)
        guard near(left, blue), near(rightSide, red) else { throw err("skub \(left) \(rightSide)") }
        guard try await asset.loadTracks(withMediaType: .audio).count == 1 else { throw err("lyd mangler") }

        // Hidden V2 and muted A1: no overlay and no sound.
        project.trackFlags[TrackRow(group: .visual, index: 1).id] = TrackFlags(hidden: true)
        project.trackFlags[TrackRow(group: .audio, index: 0).id] = TrackFlags(muted: true)
        let hiddenURL = dir.appendingPathComponent("render-hidden.mp4")
        try await Exporter.export(project, to: hiddenURL, codec: .h264, range: 0.25...1.25) { _ in }
        let hidden = AVURLAsset(url: hiddenURL)
        let plain = try await pixel(hidden, at: 0.25, x: 0.5, y: 0.5)
        guard near(plain, red), try await hidden.loadTracks(withMediaType: .audio).isEmpty else { throw err("skjult/stum \(plain)") }
        let rangeDuration = try await hidden.load(.duration).seconds
        guard abs(rangeDuration - 1) < 0.05 else { throw err("ind/ud-eksport \(rangeDuration)") }
    }

    /// Left- and right-aligned titles land where `x` says, the session template is set up as in Rush,
    /// and a version 1 title (with a bold switch) still opens.
    private static func titleAndSessionTests(_ dir: URL, media m: [MediaItem]) async throws {
        var project = Project()
        project.aspect = .landscape
        project.background = .black
        project.clips = [
            Clip(kind: .title, track: 0, start: 0, duration: 1,
                 title: TitleStyle(text: "Venstre", fontFamily: BundledFonts.outfit, weight: 800, size: 120, shadow: false, align: .left, x: 0.1, y: 0.25)),
            Clip(kind: .title, track: 1, start: 0, duration: 1,
                 title: TitleStyle(text: "Højre", fontFamily: BundledFonts.outfit, weight: 800, size: 120, shadow: false, align: .right, x: 0.9, y: 0.75)),
        ]
        let url = dir.appendingPathComponent("align.mp4")
        try await Exporter.export(project, to: url, codec: .h264) { _ in }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        let (image, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        try saveFrame(image, to: dir.appendingPathComponent("align.png"))
        let (topLeft, topRight) = inkColumns(image, rows: 0..<image.height / 2)
        let (bottomLeft, bottomRight) = inkColumns(image, rows: image.height / 2..<image.height)
        print("align: left text \(topLeft)–\(topRight), right text \(bottomLeft)–\(bottomRight)")
        guard abs(topLeft - 192) < 25, abs(bottomRight - 1728) < 25 else { throw err("justering") }

        // The template.
        let recording = MediaItem(url: URL(fileURLWithPath: "/tmp/Ambient session 012 - RAW.mov"), kind: .video,
                                  duration: 3600, width: 1920, height: 1080, hasAudio: true)
        guard AmbientSession.number(from: recording.url) == 12,
              AmbientSession.number(from: URL(fileURLWithPath: "Ambient Session 004 - RAW.mov")) == 4,
              AmbientSession.color(for: 11) == AmbientSession.colors[10],
              AmbientSession.color(for: 12) != AmbientSession.colors[10],
              AmbientSession.color(for: 13) != AmbientSession.color(for: 12) else { throw err("sessionsnummer og farve") }
        let session = AmbientSession.project(for: recording)
        guard let video = session.clips.first(where: { $0.kind == .video }),
              let title = session.clips.first(where: { $0.kind == .title }),
              video.transitionIn?.kind == .dipToBlack, video.transitionIn?.duration == 0.5,
              video.transitionOut?.kind == .dipToBlack, video.fadeIn == 0.5, video.fadeOut == 0.5,
              abs(title.start - 11.233) < 1e-9, abs(title.end - 50.767) < 1e-9,
              title.title?.text == "Ambient\nSession 012", title.title?.align == .left,
              session.aspect == .landscape else { throw err("sessionsskabelon") }

        let old = #"{"text":"Hej","fontFamily":"Helvetica Neue","bold":false,"size":90,"color":{"r":1,"g":1,"b":1,"a":1},"shadow":true,"background":false,"backgroundColor":{"r":0,"g":0,"b":0,"a":0.6},"x":0.5,"y":0.8}"#
        let decoded = try JSONDecoder().decode(TitleStyle.self, from: Data(old.utf8))
        guard decoded.weight == 400, decoded.align == .center else { throw err("gammel tekststil") }
    }

    /// The leftmost and rightmost columns with bright pixels in the given rows.
    private static func inkColumns(_ image: CGImage, rows: Range<Int>) -> (Int, Int) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var low = w, high = 0
        for y in rows {
            for x in 0..<w where data[(y * w + x) * 4] > 128 {
                low = min(low, x); high = max(high, x)
            }
        }
        return (low, high)
    }

    private static func saveFrame(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func pixel(_ asset: AVAsset, at seconds: Double, x: Double, y: Double) async throws -> (Double, Double, Double) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw the image so the wanted pixel lands on the single pixel of the context (y from the top).
        let w = CGFloat(image.width), h = CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: -x * w, y: -(1 - y) * h, width: w, height: h))
        return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }

    @MainActor
    private static func editingTests(media: [MediaItem]) throws {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw err("Redigering: \(message)") } }
        let editor = Editor(persist: false)
        editor.edit { $0.media = media }
        let video = media[0], tone = media[3]

        // Appending puts clips back to back on V1.
        editor.add(video)
        editor.add(video)
        let v1 = editor.project.clips.filter { $0.group == .visual }.sorted { $0.start < $1.start }
        try check(v1.count == 2 && v1[0].start == 0 && abs(v1[1].start - 3) < 1e-9, "tilføj i forlængelse")

        // Dropping onto an occupied spot slides to the next free one.
        try check(editor.freeStart(.visual, track: 0, desired: 1, duration: 2) == 6, "fri plads")

        // Splitting keeps the source position continuous.
        editor.selection = v1[0].id
        editor.seek(0)
        editor.currentTime = 1.2
        editor.splitAtPlayhead()
        let parts = editor.project.clips.filter { $0.mediaID == video.id }.sorted { $0.start < $1.start }
        try check(parts.count == 3, "del giver tre klip")
        try check(abs(parts[0].duration - 1.2) < 1e-9 && abs(parts[1].start - 1.2) < 1e-9 && abs(parts[1].sourceIn - 1.2) < 1e-9
                  && abs(parts[1].end - 3) < 1e-9, "del bevarer timing")

        // Undo and redo.
        editor.undo()
        try check(editor.project.clips.filter { $0.mediaID == video.id }.count == 2, "fortryd del")
        editor.redo()
        try check(editor.project.clips.filter { $0.mediaID == video.id }.count == 3, "gentag del")

        // Titles and music.
        editor.currentTime = 0.5
        editor.addTitle()
        try check(editor.selectedClip?.kind == .title && editor.selectedClip?.start == 0.5, "tilføj tekst")
        editor.add(tone)
        try check(editor.selectedClip?.group == .audio && editor.selectedClip?.track == 0, "musik på lydspor")

        // Coalesced edits make one undo step.
        let id = editor.selectedClip!.id
        let before = editor.project
        for v in stride(from: 0.9, through: 0.3, by: -0.1) { editor.updateClip(id, coalesce: "volume") { $0.volume = v } }
        editor.undo()
        try check(editor.project == before, "samlet fortryd for skyder")

        // Delete.
        editor.selection = id
        editor.deleteSelection()
        try check(!editor.project.clips.contains { $0.id == id } && editor.selection == nil, "slet")
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func saveFrame(of asset: AVAsset, at seconds: Double, to url: URL) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    /// 1920×1080 frames whose colour changes each second, with a white marker in the top-left
    /// and a yellow one in the top-right corner so rotation and mirroring are visible.
    private static func writeVideo(to url: URL, seconds: Int, transform: CGAffineTransform) async throws {
        try? FileManager.default.removeItem(at: url)
        let width = 1920, height = 1080, fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let colors: [CGColor] = [
            CGColor(srgbRed: 0.8, green: 0.2, blue: 0.2, alpha: 1),
            CGColor(srgbRed: 0.2, green: 0.7, blue: 0.3, alpha: 1),
            CGColor(srgbRed: 0.2, green: 0.3, blue: 0.8, alpha: 1),
        ]
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(colors[(frame / fps) % colors.count])
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 40, y: height - 240, width: 200, height: 200))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.9, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: width - 140, y: height - 140, width: 100, height: 100))
            // A bar moving left to right shows time passing.
            ctx.setFillColor(.black)
            ctx.fill(CGRect(x: frame * (width / (seconds * fps)), y: 100, width: 20, height: 300))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? err("video") }
    }

    private static func writeImage(to url: URL) throws {
        let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 250, y: 150, width: 300, height: 300))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func writeTone(to url: URL, seconds: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let rate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            samples[i] = Float(0.5 * sin(2 * Double.pi * 440 * Double(i) / rate))
        }
        try file.write(from: buffer)
    }
}
