import Foundation

extension FileManager {
    /// The user's own home folder. Inside the App Sandbox `homeDirectoryForCurrentUser` and the standard
    /// folders point into the app's container, which is no place to start an open or save panel.
    var userHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return homeDirectoryForCurrentUser
    }
}

/// Media files under the App Sandbox. The sandbox lets the app read a file only in the launch the user
/// picked it in, so every media item keeps a security-scoped bookmark, made on import. Opening a project
/// resolves the bookmarks and holds their access until the project closes. A file that can't be reached
/// that way is looked for where it was and next to the project, and otherwise waits for the user to locate it.
/// Inside the sandbox `fileExists` is true for files the app may not read, so readability is the test.
final class MediaAccess {
    /// Files whose security scope is open for the current project.
    private var scoped: [URL] = []

    static func canRead(_ url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
    }

    /// A security-scoped bookmark while the app can reach the file, or a plain one where the system
    /// won't make that. Either way it follows the file when it is moved or renamed on its volume.
    static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// Resolves a bookmark and opens its security scope, which the caller closes. `stale` means the
    /// bookmark should be made again.
    static func resolve(_ bookmark: Data) -> (url: URL, stale: Bool, scoped: Bool)? {
        var stale = false
        let quiet: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        guard let url = (try? URL(resolvingBookmarkData: bookmark, options: quiet.union(.withSecurityScope),
                                  relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bookmark, options: quiet, relativeTo: nil, bookmarkDataIsStale: &stale))
        else { return nil }
        return (url, stale, url.startAccessingSecurityScopedResource())
    }

    /// `url` relative to `folder`, with `..` where it lies outside it. Nil when they share only the root.
    static func relativePath(of url: URL, from folder: URL) -> String? {
        let base = folder.standardizedFileURL.pathComponents, path = url.standardizedFileURL.pathComponents
        var common = 0
        while common < min(base.count, path.count), base[common] == path[common] { common += 1 }
        guard common > 1 else { return nil }
        return (Array(repeating: "..", count: base.count - common) + path[common...]).joined(separator: "/")
    }

    /// Finds every item's file: through its bookmark, then where it was, then relative to the project.
    /// A file found by a stale bookmark or by its path gets a new bookmark. Items that can't be read
    /// come back unchanged.
    func reach(_ media: [MediaItem], projectURL: URL?) -> [MediaItem] {
        let folder = projectURL?.deletingLastPathComponent()
        return media.map { item in
            var item = item
            if let data = item.bookmark, let found = Self.resolve(data) {
                if found.scoped { scoped.append(found.url) }
                if Self.canRead(found.url) {
                    if found.stale || found.url.standardizedFileURL != item.url.standardizedFileURL {
                        item.url = found.url
                        item.bookmark = Self.bookmark(for: found.url) ?? data
                    }
                    return item
                }
            }
            var candidates = [item.url]
            if let folder, let relative = item.relativePath {
                candidates.append(folder.appendingPathComponent(relative).standardizedFileURL)
            }
            if let url = candidates.first(where: Self.canRead) {
                item.url = url
                item.bookmark = Self.bookmark(for: url)
            }
            return item
        }
    }

    /// Closes the security scopes of the project that is closing.
    func release() {
        scoped.forEach { $0.stopAccessingSecurityScopedResource() }
        scoped.removeAll()
    }

    /// The items found in a file or folder the user picked, with new bookmarks. A file is the one item
    /// asked for, or the item with its name. In a folder each item is looked for where it was, where it
    /// was relative to the project, and then by name anywhere below the folder.
    static func locate(_ items: [MediaItem], in picked: URL, projectURL: URL?) -> [MediaItem] {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: picked.path, isDirectory: &isFolder)
        var found: [MediaItem] = []
        func relink(_ item: MediaItem, to url: URL) {
            var item = item
            item.url = url
            item.bookmark = bookmark(for: url)
            found.append(item)
        }

        guard isFolder.boolValue else {
            let named = items.filter { $0.name.caseInsensitiveCompare(picked.lastPathComponent) == .orderedSame }
            if let item = items.count == 1 ? items.first : named.first, canRead(picked) { relink(item, to: picked) }
            return found
        }

        let folder = picked.standardizedFileURL
        let projectFolder = projectURL?.deletingLastPathComponent()
        var byName: [String: [URL]]?
        for item in items {
            var candidates: [URL] = []
            if item.url.standardizedFileURL.path.hasPrefix(folder.path + "/") { candidates.append(item.url) }
            if let relative = item.relativePath {
                candidates.append(folder.appendingPathComponent(relative).standardizedFileURL)
                if let projectFolder { candidates.append(projectFolder.appendingPathComponent(relative).standardizedFileURL) }
            }
            candidates.append(folder.appendingPathComponent(item.name))
            if let url = candidates.first(where: canRead) {
                relink(item, to: url)
                continue
            }
            if byName == nil { byName = filesByName(in: folder) }
            if let url = byName?[item.name.lowercased()]?.first(where: canRead) { relink(item, to: url) }
        }
        return found
    }

    /// Every file below a folder by lowercased name, stopping after enough files that a picked home
    /// folder doesn't hang the app.
    private static func filesByName(in folder: URL, limit: Int = 50_000) -> [String: [URL]] {
        var index: [String: [URL]] = [:]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return index }
        var count = 0
        for case let url as URL in files {
            index[url.lastPathComponent.lowercased(), default: []].append(url)
            count += 1
            if count >= limit { break }
        }
        return index
    }
}
