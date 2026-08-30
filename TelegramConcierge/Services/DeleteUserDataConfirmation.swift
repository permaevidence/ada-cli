import Foundation

/// Pure decision logic for the two-step `/deleteuserdata` command, kept
/// separate from ConversationManager so the selftest can pin the whole
/// matrix without constructing the manager.
///
/// Contract (settled with the owner 2026-08-20): the bare command never
/// deletes — it replies with the exact confirmation form. The confirmation
/// token is the stored user name (case-insensitive, whitespace-run-
/// insensitive), so the sender proves they know whose memory dies; when no
/// name was ever stored, the literal token CONFIRM stands in. A stored name
/// always wins over the literal: `/deleteuserdata CONFIRM` while a name
/// exists is a mismatch, not a wipe.
enum DeleteUserDataConfirmation {
    /// Fallback confirmation token when no user name is stored.
    static let fallbackToken = "CONFIRM"

    enum Decision: Equatable {
        /// Bare command: reply with instructions naming this exact token.
        case instructions(token: String)
        /// Argument matched the token: run the wipe.
        case confirmed
        /// Argument present but wrong: refuse, delete nothing.
        case mismatch
    }

    static func decide(argument: String, storedName: String?) -> Decision {
        let name = (storedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = name.isEmpty ? fallbackToken : name
        let given = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !given.isEmpty else { return .instructions(token: expected) }
        return normalize(given) == normalize(expected) ? .confirmed : .mismatch
    }

    /// Case-insensitive, interior-whitespace-run-insensitive comparison —
    /// "sofia  bruni" confirms "Sofia Bruni". Nothing looser (prefix
    /// match, accent folding) — that would weaken the fat-finger barrier
    /// the two-step design exists for.
    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

/// Validation for `/setname` — the post-wipe way to (re)store the user's
/// name. Kept pure for the selftest. The applied name also becomes the
/// `/deleteuserdata` confirmation token, so the literal "confirm" (the
/// command's own second step) is reserved.
enum UserNameChange {
    static let confirmToken = "confirm"
    static let maxLength = 80

    enum Validation: Equatable {
        /// Normalized name: trimmed, interior whitespace runs (including
        /// newlines) collapsed to single spaces.
        case valid(String)
        case empty
        case tooLong
        case reserved
    }

    static func validate(_ raw: String) -> Validation {
        let name = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if name.isEmpty { return .empty }
        if name.count > maxLength { return .tooLong }
        if name.lowercased() == confirmToken { return .reserved }
        return .valid(name)
    }
}

/// File-level wipe steps shared between ConversationManager's
/// `deleteAllMemory()` and the selftest (which has no manager). Every
/// removal is checked: absence is success, any other error is reported so
/// the wipe can tell the user honestly what survived.
enum UserDataWipe {
    /// Delete a file or directory. Returns nil on success or when the path
    /// doesn't exist; an error description otherwise.
    static func remove(_ path: String, label: String) -> String? {
        do {
            try FileManager.default.removeItem(atPath: path)
            return nil
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
               && error.code == NSFileNoSuchFileError {
            return nil
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == ENOENT {
            return nil
        } catch {
            return "\(label): \(error.localizedDescription)"
        }
    }

    /// User-data artifacts that live outside ConversationManager's own
    /// directories: the web-pipeline log (search queries and fetched-page
    /// diagnostics) and the temp tool-output directory (truncated tool
    /// outputs + bash spill files — redacted, but still the user's command
    /// output). Both regenerate on demand.
    static func wipeSharedArtifacts() -> [String] {
        var failures: [String] = []
        let targets: [(path: String, label: String)] = [
            (StoragePaths.dataRoot.appendingPathComponent("logs", isDirectory: true).path,
             "logs directory"),
            (TruncationService.truncationDir,
             "tool-output/spill directory"),
        ]
        for t in targets {
            if let failure = remove(t.path, label: t.label) { failures.append(failure) }
        }
        return failures
    }
}
