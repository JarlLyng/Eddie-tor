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
