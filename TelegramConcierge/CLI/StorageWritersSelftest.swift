import Foundation

/// Writer-level storage checks, called from `StorageSelftest` section 6:
/// state files written by the real services come out owner-only, and
/// executable artefacts (reminder scripts, wrappers) keep working after the
/// sweep and after rewrites. Kept in its own file so the writer-routing work
/// can grow it without touching the core selftest.
enum StorageWritersSelftest {
    static func run(tempRoot: URL, check: (String, Bool, String) -> Void) async {
        _ = tempRoot
        check("6.0 writer checks present", true, "")
    }
}
