import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Policy-aware tree restoration (Mind import) and owner-only validation.
extension PrivateStorage {

    /// Copies `source` (a file or directory tree) to `destination` under the
    /// storage policy: directories are created `0700`, regular files are
    /// written atomically with the source's OWNER bits (never wider than
    /// `0700`, never narrower than `0600` — a `0755` reminder script becomes
    /// `0700`, a `0644` data file `0600`), symlinks are recreated as links
    /// unless their destination is a harness-owned state path (refused —
    /// a link at `conversation.json` or `archive/` would redirect the
    /// harness's own reads), and anything else (socket, FIFO, device) is
    /// refused. Bounded depth; never follows symlinks while walking.
    static func copyTree(from source: URL, to destination: URL, depth: Int = 0) throws {
        guard depth < 64 else {
            throw StorageError(description: "restore tree too deep at \(source.path)")
        }
        var st = stat()
        guard lstat(source.path, &st) == 0 else {
            throw StorageError(description: "cannot stat \(source.path): \(String(cString: strerror(errno)))")
        }
        let fmt = st.st_mode & S_IFMT
        let perm = st.st_mode & 0o7777
        switch fmt {
        case S_IFDIR:
            try ensureDirectory(destination)
            let names = try FileManager.default.contentsOfDirectory(atPath: source.path)
            for name in names.sorted() {
                try copyTree(from: source.appendingPathComponent(name),
                             to: destination.appendingPathComponent(name), depth: depth + 1)
            }
        case S_IFREG:
            let data = try Data(contentsOf: source)
            let mode: mode_t = (perm & 0o700) | 0o600
            try writeAtomically(data, to: destination, mode: mode)
        case S_IFLNK:
            if classify(destination.path) == .harnessState {
                throw StorageError(description: "refusing to restore a symlink at harness-owned path \(destination.path)")
            }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(source.path, &buffer, buffer.count - 1)
            guard n > 0 else {
                throw StorageError(description: "cannot read symlink \(source.path)")
            }
            buffer[n] = 0
            let target = String(cString: buffer)
            unlink(destination.path)
            guard symlink(target, destination.path) == 0 else {
                throw StorageError(description: "cannot recreate symlink \(destination.path): \(String(cString: strerror(errno)))")
            }
        default:
            throw StorageError(description: "refusing to restore \(source.path): not a regular file, directory or symlink")
        }
    }

    /// Entries under `root` (never following symlinks) that carry group/other
    /// bits — regular files and directories only. For post-restore checks.
    static func wideEntries(under root: URL, limit: Int = 50) -> [String] {
        var out: [String] = []
        func visit(_ path: String, depth: Int) {
            guard depth < 64, out.count < limit else { return }
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            let fmt = st.st_mode & S_IFMT
            let perm = st.st_mode & 0o7777
            guard fmt == S_IFREG || fmt == S_IFDIR else { return }
            if perm & groupOtherBits != 0 { out.append("\(path) (\(String(perm, radix: 8)))") }
            if fmt == S_IFDIR, let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
                for name in names.sorted() { visit(path + "/" + name, depth: depth + 1) }
            }
        }
        visit(root.standardizedFileURL.path, depth: 0)
        return out
    }
}
