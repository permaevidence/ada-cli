import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Balance Monitor

/// Proactively warns the user when a metered web-service API key is about to
/// run out of credit, BEFORE it starts failing mid-task — the exact silent
/// degradation we otherwise can't detect until a search or an OCR pass breaks.
///
/// Covers the three services that actually expose a balance endpoint:
///   • OpenRouter — account credit balance (USD) AND the optional per-key
///     spend limit. These are two independent gates: a key can be blocked by
///     its own limit with account balance to spare, or vice versa, so both are
///     polled.
///   • Serper.dev — search credits (`GET /account` → `balance`).
///   • Jina.ai    — reader token balance (undocumented dashboard endpoint).
///
/// The other paid services Briglia can use have NO pollable balance API and are
/// deliberately not covered here:
///   • OpenCode / Zen (the main LLM) — no endpoint (open feature request);
///     protect it with the account's AUTO-RELOAD instead, which is strictly
///     better for the brain than a warning.
///   • OpenAI (voice / images) & Gemini (images) — optional features, no
///     supported balance API.
///
/// Alerting mirrors `MaintenanceAlertCenter`'s discipline: warn ONCE when a
/// balance first crosses below its threshold, re-warn at most daily while it
/// stays low, and send a short confirmation once it recovers (topped up) — so
/// the user is never spammed, and never silently degraded either.
actor BalanceMonitor {
    static let shared = BalanceMonitor()

    /// One independently-tracked gate. OpenRouter contributes two.
    enum Metric: String, Codable, CaseIterable {
        case openRouterAccount
        case openRouterKeyLimit
        case serper
        case jina
    }

    // MARK: Thresholds (defaults settled with the owner 2026-07-07; Keychain-overridable)

    private struct Thresholds {
        let openRouterUSD: Double
        let serperCredits: Double
        let jinaTokens: Double

        static func current() -> Thresholds {
            Thresholds(
                openRouterUSD: keychainDouble(KeychainHelper.balanceThresholdOpenRouterUSDKey, fallback: 5),
                serperCredits: keychainDouble(KeychainHelper.balanceThresholdSerperCreditsKey, fallback: 200),
                jinaTokens: keychainDouble(KeychainHelper.balanceThresholdJinaTokensKey, fallback: 1_000_000)
            )
        }
    }

    private static func keychainDouble(_ key: String, fallback: Double) -> Double {
        guard let raw = KeychainHelper.load(key: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(raw), value.isFinite, value >= 0 else {
            return fallback
        }
        return value
    }

    // MARK: Persisted state

    private struct MetricState: Codable {
        var below: Bool = false
        var lastAlertAt: Date? = nil
        var lastRemaining: Double? = nil
    }

    private struct Store: Codable {
        var metrics: [String: MetricState] = [:]
        var undelivered: [String] = []
    }

    private var store = Store()
    private var deliver: (@Sendable (String) async -> Bool)?
    private var started = false
    private var isFlushing = false

    /// Re-warn cadence while a balance stays below threshold.
    private let reWarnInterval: TimeInterval = 86_400 // 24h
    /// How often the background loop polls the services.
    private let pollInterval: TimeInterval = 6 * 3600 // 6h
    /// Grace after launch before the first poll, so startup settles first.
    private let initialDelay: TimeInterval = 45

    private let storeURL: URL = {
        let folder = StoragePaths.dataRoot
        try? PrivateStorage.ensureDirectory(folder)
        return folder.appendingPathComponent("balance_monitor.json")
    }()

    init() {
        if let data = try? Data(contentsOf: storeURL),
           let loaded = try? JSONDecoder().decode(Store.self, from: data) {
            store = loaded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(store) {
            try? PrivateStorage.writeAtomically(data, to: storeURL)
        }
    }

    // MARK: Delivery

    func setDeliveryHandler(_ handler: @escaping @Sendable (String) async -> Bool) {
        deliver = handler
    }

    private func emit(_ text: String) async {
        if let deliver, await deliver(text) { return }
        store.undelivered.append(text)
        save()
    }

    /// Re-attempt delivery of warnings whose original send failed.
    ///
    /// Actors are reentrant across `await`: while a delivery is in flight,
    /// another `emit()` can park a NEW message. So never write back a
    /// pre-await snapshot of the queue — re-read `store.undelivered` after
    /// each delivery and remove the delivered item by identity, leaving
    /// anything appended meanwhile untouched. `isFlushing` keeps a second
    /// concurrent flush from double-sending the same message.
    func flushUndelivered() async {
        guard !isFlushing, deliver != nil else { return }
        isFlushing = true
        defer { isFlushing = false }
        while let next = store.undelivered.first {
            guard let deliver, await deliver(next) else { return }
            if let idx = store.undelivered.firstIndex(of: next) {
                store.undelivered.remove(at: idx)
                save()
            }
        }
    }

    // MARK: Lifecycle

    /// Start the background poll loop (idempotent). Runs an immediate check
    /// after a short grace period, then every `pollInterval`.
    func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.initialDelay * 1_000_000_000))
            while !Task.isCancelled {
                await self.checkNow()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    /// Poll every configured service once and reconcile threshold state.
    /// Never throws: a service that errors (network/auth) is skipped this
    /// round — balance-fetch failures are NOT surfaced as low-credit warnings
    /// (a real outage is MaintenanceAlertCenter's job), and are never treated
    /// as "recovered" either, so no false all-clear can fire.
    func checkNow() async {
        let thresholds = Thresholds.current()

        // OpenRouter (account balance + per-key limit share one key).
        let openRouterKey = loadKey(KeychainHelper.openRouterApiKeyKey)
        if let openRouterKey {
            if let remaining = try? await fetchOpenRouterAccountRemaining(key: openRouterKey) {
                await reconcile(.openRouterAccount, remaining: remaining, threshold: thresholds.openRouterUSD)
            }
            // Per-key limit only exists if the user capped the key; nil = uncapped, skip.
            if let remaining = try? await fetchOpenRouterKeyLimitRemaining(key: openRouterKey) {
                await reconcile(.openRouterKeyLimit, remaining: remaining, threshold: thresholds.openRouterUSD)
            }
        }

        // Serper.
        if let serperKey = loadKey(KeychainHelper.serperApiKeyKey),
           let remaining = try? await fetchSerperRemaining(key: serperKey) {
            await reconcile(.serper, remaining: remaining, threshold: thresholds.serperCredits)
        }

        // Jina.
        if let jinaKey = loadKey(KeychainHelper.jinaApiKeyKey),
           let remaining = try? await fetchJinaRemaining(key: jinaKey) {
            await reconcile(.jina, remaining: remaining, threshold: thresholds.jinaTokens)
        }

        await flushUndelivered()
    }

    private func loadKey(_ key: String) -> String? {
        let value = (KeychainHelper.load(key: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: Threshold reconciliation (the anti-spam state machine)

    private func reconcile(_ metric: Metric, remaining: Double, threshold: Double) async {
        var state = store.metrics[metric.rawValue] ?? MetricState()
        state.lastRemaining = remaining
        let now = Date()

        if remaining < threshold {
            if !state.below {
                // First crossing below → entry warning.
                state.below = true
                state.lastAlertAt = now
                store.metrics[metric.rawValue] = state
                save()
                await emit(warningMessage(metric, remaining: remaining, threshold: threshold))
            } else if let last = state.lastAlertAt, now.timeIntervalSince(last) >= reWarnInterval {
                // Still low a day later → one reminder.
                state.lastAlertAt = now
                store.metrics[metric.rawValue] = state
                save()
                await emit(warningMessage(metric, remaining: remaining, threshold: threshold))
            } else {
                store.metrics[metric.rawValue] = state
                save()
            }
        } else {
            // At/above threshold.
            if state.below {
                // Recovered (topped up) → one confirmation, then reset so a
                // future drop warns again.
                state.below = false
                state.lastAlertAt = nil
                store.metrics[metric.rawValue] = state
                save()
                await emit(recoveryMessage(metric, remaining: remaining))
            } else {
                store.metrics[metric.rawValue] = state
                save()
            }
        }
    }

    // MARK: Messages

    private func warningMessage(_ metric: Metric, remaining: Double, threshold: Double) -> String {
        switch metric {
        case .openRouterAccount:
            return "⚠️ OpenRouter credit running low: \(usd(remaining)) left (threshold \(usd(threshold))). "
                + "Briglia uses OpenRouter for OCR only when it is the selected OCR backend. "
                + "Top up at openrouter.ai to avoid interruptions."
        case .openRouterKeyLimit:
            return "⚠️ OpenRouter key spend limit almost reached: \(usd(remaining)) left (threshold \(usd(threshold))). "
                + "This is the per-key cap, separate from the account credit: "
                + "raise or remove the key limit at openrouter.ai."
        case .serper:
            return "⚠️ Serper credits (web search) running low: \(credits(remaining)) left (threshold \(credits(threshold))). "
                + "Top up at serper.dev to keep searches running."
        case .jina:
            return "⚠️ Jina tokens (page reading) running low: \(tokens(remaining)) left (threshold \(tokens(threshold))). "
                + "Top up at jina.ai to keep page reading working."
        }
    }

    private func recoveryMessage(_ metric: Metric, remaining: Double) -> String {
        switch metric {
        case .openRouterAccount:
            return "✅ OpenRouter credit topped up: now \(usd(remaining)). I'll warn you again if it drops below the threshold."
        case .openRouterKeyLimit:
            return "✅ OpenRouter key limit back in range: \(usd(remaining)) now available on the key."
        case .serper:
            return "✅ Serper credits topped up: now \(credits(remaining))."
        case .jina:
            return "✅ Jina tokens topped up: now \(tokens(remaining))."
        }
    }

    private func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
    private func credits(_ v: Double) -> String { groupedInt(v) }
    private func tokens(_ v: Double) -> String { groupedInt(v) }

    private func groupedInt(_ v: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: v)) ?? String(Int(v))
    }

    // MARK: Fetchers

    /// OpenRouter account credit balance (USD) = total_credits − total_usage.
    /// `GET /api/v1/credits` → {"data":{"total_credits":Double,"total_usage":Double}}
    private func fetchOpenRouterAccountRemaining(key: String) async throws -> Double {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/credits")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let json = try await httpJSON(req)
        guard let data = json["data"] as? [String: Any],
              let total = asDouble(data["total_credits"]),
              let used = asDouble(data["total_usage"]) else {
            throw balanceError("unexpected /credits response shape")
        }
        return total - used
    }

    /// OpenRouter per-key spend limit remaining (USD), or throws to signal
    /// "no cap set / skip" when `limit` is null.
    /// `GET /api/v1/key` → {"data":{"limit":Double?,"limit_remaining":Double?,"usage":Double}}
    private func fetchOpenRouterKeyLimitRemaining(key: String) async throws -> Double {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let json = try await httpJSON(req)
        guard let data = json["data"] as? [String: Any] else {
            throw balanceError("unexpected /key response shape")
        }
        // No per-key limit configured → nothing to monitor here.
        guard let limit = asDouble(data["limit"]) else {
            throw balanceError("no per-key limit set")
        }
        if let remaining = asDouble(data["limit_remaining"]) {
            return remaining
        }
        let usage = asDouble(data["usage"]) ?? 0
        return limit - usage
    }

    /// Serper search credits. `GET /account` (header X-API-KEY) → {"balance":Double,"rateLimit":Int}
    private func fetchSerperRemaining(key: String) async throws -> Double {
        var req = URLRequest(url: URL(string: "https://google.serper.dev/account")!)
        req.setValue(key, forHTTPHeaderField: "X-API-KEY")
        let json = try await httpJSON(req)
        guard let balance = asDouble(json["balance"]) else {
            throw balanceError("unexpected /account response shape")
        }
        return balance
    }

    /// Jina reader token balance (undocumented dashboard endpoint — the same
    /// call jina.ai's billing page makes).
    /// `GET https://embeddings-dashboard-api.jina.ai/api/v1/api_key/user?api_key=KEY`
    ///
    /// Confirmed response shape (2026-07-07):
    /// {"wallet":{"trial_balance":Int,"regular_balance":Int,"total_balance":Int,…},…}
    /// Remaining tokens = `wallet.total_balance` (trial + regular combined).
    /// A couple of legacy field names are kept as fallbacks; if none resolve we
    /// THROW (→ skip) rather than return a fake 0, so a future schema change
    /// surfaces as "skipped", never as a false low-credit alarm.
    private func fetchJinaRemaining(key: String) async throws -> Double {
        var comps = URLComponents(string: "https://embeddings-dashboard-api.jina.ai/api/v1/api_key/user")!
        comps.queryItems = [URLQueryItem(name: "api_key", value: key)]
        let req = URLRequest(url: comps.url!)
        let json = try await httpJSON(req)

        if let wallet = json["wallet"] as? [String: Any] {
            for field in ["total_balance", "balance", "remaining_tokens"] {
                if let v = asDouble(wallet[field]) { return v }
            }
        }
        throw balanceError("could not locate wallet.total_balance in Jina response")
    }

    // MARK: HTTP + parsing helpers

    private func balanceError(_ message: String) -> Error {
        NSError(domain: "BalanceMonitor", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Marker for failures that retrying cannot fix (bad/revoked key, wrong
    /// endpoint). Must escape the retry loop instead of being folded into
    /// `lastError` like transient failures.
    private struct NonTransientError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// GET a JSON object with bounded retry. Retries transient failures
    /// (429 / 5xx / network); fails fast on 4xx auth/config errors so we don't
    /// hammer a bad key. Returns the top-level object as a dictionary.
    private func httpJSON(_ request: URLRequest, attempts: Int = 3) async throws -> [String: Any] {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                if http.statusCode == 200 {
                    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw balanceError("non-object JSON response")
                    }
                    return obj
                }
                if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                    lastError = balanceError("HTTP \(http.statusCode)")
                } else {
                    // 401/403/404 etc. — not transient, don't retry.
                    throw NonTransientError(message: "HTTP \(http.statusCode)")
                }
            } catch {
                if error is CancellationError || error is NonTransientError { throw error }
                lastError = error
            }
            if attempt < attempts {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    /// Coerce a JSON value (NSNumber / numeric string) to Double. Returns nil
    /// for JSON null or non-numeric values.
    private func asDouble(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            // Guard against JSON null bridged to NSNull elsewhere; NSNumber is safe.
            return n.doubleValue
        case let s as String:
            return Double(s.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }
}
