import Foundation

/// Which backend supplies ambient email + calendar context (system-prompt
/// blocks, the 5-minute unread poller, and the calendar surface).
///
/// - `none`      — no email/calendar at all: no prompt sections, no polling,
///                 no calendar tool. The default for fresh installs.
/// - `agentmail` — a dedicated agent inbox on AgentMail (api.agentmail.to,
///                 key in secrets.json) plus Briglia's local calendar store with
///                 the `manage_calendar` tool. The recommended easy path.
/// - `gws`       — the user's own Gmail/Google Calendar via the `gws` CLI
///                 with a user-provided Google Cloud OAuth client. Calendar
///                 context comes from Google Calendar; no local calendar tool.
enum EmailCalendarProvider: String, CaseIterable {
    case none
    case agentmail
    case gws

    /// Test seam: when set, `current` uses the returned raw value (nil =
    /// simulate "no stored choice") instead of reading secrets.json. Selftests
    /// set and clear this; production never does.
    nonisolated(unsafe) static var storedOverrideForTesting: (() -> String?)?
    /// Test seam for the legacy-inference path (gws binary presence probe).
    nonisolated(unsafe) static var gwsInstalledOverrideForTesting: (() -> Bool)?

    /// Single source of truth for the active provider. Every reader — the
    /// startup poller wiring, the frozen-context builders, the calendar tool
    /// gate, the system-prompt guidance bullet, the email-arrival envelope,
    /// the wizard, and doctor — must go through this so they can never
    /// disagree.
    ///
    /// Resolution: an explicitly stored choice wins. When unset (installs
    /// predating the provider setting), fall back to the legacy behavior,
    /// which was "gws when the binary is installed, nothing otherwise" — so
    /// existing gws users keep working without reconfiguration and fresh
    /// installs default to none.
    static var current: EmailCalendarProvider {
        let stored: String?
        if let override = storedOverrideForTesting {
            stored = override()
        } else {
            stored = KeychainHelper.load(key: KeychainHelper.emailCalendarProviderKey)
        }
        if let stored, let provider = EmailCalendarProvider(rawValue: stored) {
            return provider
        }
        let gwsPresent = gwsInstalledOverrideForTesting?() ?? GoogleWorkspaceService.gwsInstalled()
        return gwsPresent ? .gws : .none
    }

    var displayName: String {
        switch self {
        case .none: return "none"
        case .agentmail: return "AgentMail + local calendar"
        case .gws: return "Google Workspace (gws)"
        }
    }

    /// The agent's dedicated inbox address (stored at wizard time from the
    /// live key probe). Empty when unknown — prompt text degrades gracefully.
    static var agentMailInboxAddress: String {
        KeychainHelper.load(key: KeychainHelper.agentMailInboxAddressKey) ?? ""
    }

    /// The "Tool-use guidance" bullet for the system prompt. Nil = omit the
    /// line entirely (provider none — never tell the model to use a CLI that
    /// isn't configured).
    var toolGuidanceBullet: String? {
        switch self {
        case .none:
            return nil
        case .agentmail:
            let inbox = Self.agentMailInboxAddress
            let inboxNote = inbox.isEmpty ? "" : " (\(inbox))"
            return "- You have a dedicated email inbox\(inboxNote) on AgentMail. Use the `agentmail` CLI via `bash` for email actions — it authenticates itself automatically (e.g. `agentmail inboxes:messages list --inbox-id \(inbox.isEmpty ? "<inbox>" : inbox) --limit 10`, `… get --message-id '<id>'`, `… reply`, `… send`). For raw API calls, `briglia __agentmail-key` prints the key. Use `manage_calendar` for the calendar."
        case .gws:
            return "- Use `gws` for Google Workspace actions."
        }
    }

    /// Follow-up hint inside the [SYSTEM: NEW EMAILS ARRIVED] envelope.
    /// Rendered at message-creation time by the provider that produced the
    /// poll, so it always names a CLI the model actually has.
    var emailFollowUpHint: String {
        switch self {
        case .none:
            return ""  // provider none never polls, so this never renders
        case .agentmail:
            let inbox = Self.agentMailInboxAddress
            let inboxArg = inbox.isEmpty ? "<inbox>" : inbox
            return "Use the `agentmail` CLI via `bash` for follow-up actions when needed (e.g. `agentmail inboxes:messages get --inbox-id \(inboxArg) --message-id '<id>'`, `… reply --inbox-id \(inboxArg) --message-id '<id>' --text \"…\"`)."
        case .gws:
            return "Use `gws` via `bash` for follow-up actions when needed (e.g. `gws gmail +read --id <id>`, `gws gmail +reply`)."
        }
    }
}

/// Email-credential wipe for /deleteuserdata (user decision, 2026-08-22): a
/// handoff wipe must sever email ACCESS, not just local memory — otherwise
/// the machine's next owner can read the old owner's inbox through the
/// surviving credentials. Deletes the AgentMail key + inbox address, the
/// user-provided gws OAuth client id/secret, and the whole ~/.config/gws
/// directory (client_secret.json plus gws's own OAuth token store), then
/// resets the provider to an EXPLICIT "none" — leaving it unset would let
/// the legacy "gws if installed" inference resurrect a token-less gws
/// configuration and spam maintenance alerts. Server-side mailboxes are
/// deliberately untouched: deleting the key severs Briglia's access, and remote
/// mail belongs to the account owner (an AgentMail key is inbox-scoped, so a
/// new owner's key cannot see the old inbox anyway).
enum EmailCredentialWipe {
    /// Returns wipe failures in the same format deleteAllMemory reports.
    static func execute(gwsConfigDir: URL = GoogleWorkspaceService.gwsConfigDirectory) -> [String] {
        var failures: [String] = []
        func deleteSecret(_ key: String, _ label: String) {
            do { try KeychainHelper.delete(key: key) }
            catch { failures.append("\(label): \(error.localizedDescription)") }
        }
        deleteSecret(KeychainHelper.agentMailApiKeyKey, "AgentMail API key")
        deleteSecret(KeychainHelper.agentMailInboxAddressKey, "AgentMail inbox address")
        deleteSecret(KeychainHelper.gwsOAuthClientIDKey, "gws OAuth client id")
        deleteSecret(KeychainHelper.gwsOAuthClientSecretKey, "gws OAuth client secret")
        do {
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey,
                                    value: EmailCalendarProvider.none.rawValue)
        } catch {
            failures.append("email provider reset: \(error.localizedDescription)")
        }
        if FileManager.default.fileExists(atPath: gwsConfigDir.path),
           let failure = UserDataWipe.remove(gwsConfigDir.path, label: "gws config/token directory") {
            failures.append(failure)
        }
        return failures
    }
}
