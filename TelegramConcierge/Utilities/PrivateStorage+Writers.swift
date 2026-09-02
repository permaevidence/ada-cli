import Foundation

extension PrivateStorage {
    /// Directory creation for a path that may or may not be in this policy's
    /// jurisdiction: env-overridable state locations and the excluded
    /// `projects/` / `toolchain/` areas. In scope, the private policy
    /// applies (`0700`, a wider existing leaf is tightened). Outside, plain
    /// creation under the process umask — those directories are not ours
    /// to tighten (a restored `projects/` tree keeps the user's modes).
    static func ensureDirectoryScoped(_ url: URL) throws {
        if classify(url.path) == .outside {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try ensureDirectory(url)
        }
    }
}
