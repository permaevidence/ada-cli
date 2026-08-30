import Foundation

/// Result of a diagnostics request. `skipped` carries a human-readable reason
/// the caller can include in its tool-result payload (missing server, unknown
/// extension, etc.) without treating the write as failed.
enum DiagnosticsResult {
    case diagnostics([LSPDiagnostic], serverID: String)
    case skipped(reason: String)
}

/// Singleton actor: owns all live `LSPClient` instances, keyed by
/// (serverID, workspaceRoot). Spawn-on-demand; idle clients are reaped
/// lazily on each access after `idleTTL`. Negative-caches missing
/// executables so we don't probe `which` on every write.
actor LSPRegistry {

    static let shared = LSPRegistry()

    /// Disk state of a document at the moment it was last synced to the
    /// server, so external modifications (bash, git checkout, another editor)
    /// can be detected and re-synced before a query runs against a stale copy.
    private struct DocStamp {
        let mtime: Date
        let size: Int
    }

    private struct Entry {
        let client: LSPClient
        var lastUsed: Date
        let serverID: String
        let rootURI: URL
        var openedDocs: [String: DocStamp] = [:]
    }

    private var entries: [String: Entry] = [:]
    private var spawnTasks: [String: Task<Void, Never>] = [:]

    /// Negative cache for missing executables. Entries expire after
    /// `missingCacheTTL` so a server installed mid-session (e.g. user pip-
    /// installs pylsp while chatting) eventually gets picked up without an
    /// app relaunch.
    private var missingExecutables: [String: Date] = [:]
    private let missingCacheTTL: TimeInterval = 300   // 5 minutes

    /// Negative cache for servers that spawned but failed/timed out during
    /// initialization. Without it, every write in the workspace would re-pay
    /// the full spawn + initialize timeout against a wedged server; with it,
    /// writes proceed immediately with diagnostics_skipped until the TTL
    /// expires and one fresh attempt is made.
    private var failedSpawns: [String: Date] = [:]
    private let failedSpawnTTL: TimeInterval = 300    // 5 minutes

    /// Reap clients idle for longer than this. 10 minutes matches OpenCode's
    /// default — typescript-language-server is slow (~2-5s) to spawn so we
    /// want to amortize over a realistic development session.
    private let idleTTL: TimeInterval = 600

    private init() {}

    // MARK: - Public API

    /// Main entry: open/update the file in its language server, then wait
    /// up to the server's configured `diagnosticsTimeout` for
    /// publishDiagnostics. The `waitFor` parameter is retained for override
    /// but defaults to the per-server timeout from LSPLanguages.
    /// Transparently spawns the server on first use.
    func diagnostics(
        forPath path: String,
        updatedText: String,
        waitFor overrideTimeout: TimeInterval? = nil
    ) async -> DiagnosticsResult {
        reapIdleLocked()

        let ext = (path as NSString).pathExtension.lowercased()
        guard let cfg = LSPLanguages.serverConfig(forExtension: ext) else {
            return .skipped(reason: "no language support for .\(ext)")
        }
        guard let languageId = LSPLanguages.languageId(forExtension: ext) else {
            return .skipped(reason: "no languageId mapping for .\(ext)")
        }
        if isMissingCacheHit(executable: cfg.executable) {
            return .skipped(reason: "\(cfg.executable) not installed")
        }
        let timeout = overrideTimeout ?? cfg.diagnosticsTimeout

        let root = LSPLanguages.workspaceRoot(forFilePath: path, markers: cfg.workspaceMarkers)
        let key = entryKey(serverID: cfg.serverID, root: root)

        guard let client = await ensureClient(key: key, config: cfg, root: root) else {
            // ensureClient returns nil both when the binary is absent and when a
            // present server failed to spawn/initialize (e.g. init timeout).
            // Only the former goes in the global missing-executable cache — a
            // wedged server is already cooled down per-workspace by failedSpawns
            // and must not suppress other workspaces or be reported as "not
            // installed".
            if LSPLanguages.locateExecutable(cfg.executable) == nil {
                markMissing(executable: cfg.executable)
                return .skipped(reason: "\(cfg.executable) not installed (install to enable diagnostics)")
            }
            return .skipped(reason: "\(cfg.executable) failed to start; diagnostics skipped while it cools down")
        }

        let fileURL = URL(fileURLWithPath: path)
        let uriKey = fileURL.absoluteString

        // Ensure the document is known to the server. First touch → didOpen;
        // subsequent touches → didChange. Always followed by didSave to nudge
        // servers that only publish on save (rust-analyzer, some pylsp setups).
        let opened = entries[key]?.openedDocs[uriKey] != nil
        do {
            if opened {
                try await client.didChange(uri: fileURL, text: updatedText)
            } else {
                try await client.didOpen(uri: fileURL, text: updatedText, languageId: languageId)
            }
            try await client.didSave(uri: fileURL)
        } catch {
            return .skipped(reason: "LSP sync failed: \(error)")
        }
        entries[key]?.openedDocs[uriKey] =
            fileStamp(path: path) ?? DocStamp(mtime: Date(), size: updatedText.utf8.count)

        entries[key]?.lastUsed = Date()

        let diags = await client.diagnostics(for: fileURL, waitFor: timeout)
        return .diagnostics(remapDiagnosticColumns(diags, text: updatedText), serverID: cfg.serverID)
    }

    /// On-demand diagnostics for a file as it currently exists on disk —
    /// the same pipeline the write tools use, without requiring a write.
    func diagnosticsPayload(path: String) async -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return jsonError("cannot read \(path) as UTF-8 text")
        }
        let outcome = await diagnostics(forPath: path, updatedText: text)
        switch outcome {
        case .skipped(let reason):
            return jsonSkipped(path: path, reason: reason)
        case .diagnostics(let diags, let serverID):
            var payload: [String: Any] = ["success": true, "path": path, "server": serverID]
            let total = diags.count
            let capped = Array(diags.prefix(LSPDiagnosticsReporter.perFileDiagnosticsCap))
            payload["diagnostics"] = capped.map { diag -> [String: Any] in
                var d: [String: Any] = [
                    "line": diag.line,
                    "column": diag.column,
                    "severity": diag.severity,
                    "message": diag.message
                ]
                if let endLine = diag.endLine { d["end_line"] = endLine }
                if let endCol = diag.endColumn { d["end_column"] = endCol }
                if let source = diag.source { d["source"] = source }
                if let code = diag.code { d["code"] = code }
                return d
            }
            if total > LSPDiagnosticsReporter.perFileDiagnosticsCap {
                payload["diagnostics_truncated"] = true
                payload["diagnostics_total"] = total
            }
            let errorCount = diags.filter { $0.severity == "error" }.count
            let warnCount = diags.filter { $0.severity == "warning" }.count
            payload["diagnostics_summary"] = errorCount > 0 || warnCount > 0
                ? "\(errorCount) error(s), \(warnCount) warning(s)"
                : "clean"
            let (truncJson, _, _) = TruncationService.truncateJSONPayload(payload)
            return truncJson
        }
    }

    /// Remap UTF-16 wire columns (already +1'd by LSPDiagnostic.from) to
    /// display columns using the document text. No-op for pure-ASCII text.
    private func remapDiagnosticColumns(_ diags: [LSPDiagnostic], text: String) -> [LSPDiagnostic] {
        guard !diags.isEmpty, !text.allSatisfy({ $0.isASCII }) else { return diags }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func display(_ line: Int?, _ column: Int?) -> Int? {
            guard let line, let column, line >= 1, line <= lines.count else { return column }
            return LSPPositionConverter.displayColumn(utf16Offset: column - 1, in: lines[line - 1])
        }
        return diags.map { d in
            LSPDiagnostic(
                line: d.line,
                column: display(d.line, d.column) ?? d.column,
                endLine: d.endLine,
                endColumn: display(d.endLine, d.endColumn),
                severity: d.severity,
                source: d.source,
                message: d.message,
                code: d.code
            )
        }
    }

    // MARK: - Symbol queries
    //
    // These convert 1-indexed line/column (what the agent sees in read_file
    // output) to 0-indexed positions the LSP server expects, and return
    // JSON-ready strings for the tool layer. If the server is missing or
    // errors, a JSON object with `error` or `skipped` is returned — we never
    // throw out of these methods.

    func hover(path: String, line: Int, column: Int) async -> String {
        guard let (client, uri, serverID) = await prepareForQuery(path: path) else {
            return jsonSkipped(path: path, reason: "no language server available for \(path)")
        }
        do {
            var cache = LineCache()
            let wireColumn = utf16Column(path: path, line: line, column: column, cache: &cache)
            let text = try await client.hover(uri: uri, line: max(line - 1, 0), column: wireColumn)
            let (truncJson, _, _) = TruncationService.truncateJSONPayload([
                "success": true,
                "path": path,
                "server": serverID,
                "hover": text ?? NSNull()
            ])
            return truncJson
        } catch {
            return jsonError("hover failed: \(error)")
        }
    }

    func definition(path: String, line: Int, column: Int) async -> String {
        guard let (client, uri, serverID) = await prepareForQuery(path: path) else {
            return jsonSkipped(path: path, reason: "no language server available for \(path)")
        }
        do {
            var cache = LineCache()
            let wireColumn = utf16Column(path: path, line: line, column: column, cache: &cache)
            let locs = try await client.definition(uri: uri, line: max(line - 1, 0), column: wireColumn)
            let (truncJson, _, _) = TruncationService.truncateJSONPayload([
                "success": true,
                "path": path,
                "server": serverID,
                "locations": locs.map { locationPayload($0, cache: &cache) }
            ])
            return truncJson
        } catch {
            return jsonError("definition failed: \(error)")
        }
    }

    func references(path: String, line: Int, column: Int, includeDeclaration: Bool = true) async -> String {
        guard let (client, uri, serverID) = await prepareForQuery(path: path) else {
            return jsonSkipped(path: path, reason: "no language server available for \(path)")
        }
        do {
            var cache = LineCache()
            let wireColumn = utf16Column(path: path, line: line, column: column, cache: &cache)
            let locs = try await client.references(
                uri: uri,
                line: max(line - 1, 0),
                column: wireColumn,
                includeDeclaration: includeDeclaration
            )
            // Cap references at 100 locations — large codebases can return
            // many hundreds of hits for a common identifier.
            let cap = 100
            let total = locs.count
            let capped = Array(locs.prefix(cap))
            var payload: [String: Any] = [
                "success": true,
                "path": path,
                "server": serverID,
                "locations": capped.map { locationPayload($0, cache: &cache) }
            ]
            if total > cap {
                payload["references_truncated"] = true
                payload["references_total"] = total
            }
            let (truncJson, _, _) = TruncationService.truncateJSONPayload(payload)
            return truncJson
        } catch {
            return jsonError("references failed: \(error)")
        }
    }

    /// Structural outline of a file: every class/struct/function/method with
    /// its line range, flattened depth-first with a `depth` field preserving
    /// the nesting. Far cheaper than paging a large file through read_file.
    func documentSymbols(path: String) async -> String {
        guard let (client, uri, serverID) = await prepareForQuery(path: path) else {
            return jsonSkipped(path: path, reason: "no language server available for \(path)")
        }
        do {
            let raw = try await client.documentSymbols(uri: uri)
            var cache = LineCache()
            var flat: [[String: Any]] = []
            flattenSymbols(raw, depth: 0, path: path, cache: &cache, into: &flat)
            let cap = 500
            let total = flat.count
            let capped = Array(flat.prefix(cap))
            var payload: [String: Any] = [
                "success": true,
                "path": path,
                "server": serverID,
                "symbols": capped,
                "symbol_count": capped.count
            ]
            if total > cap {
                payload["truncated"] = true
                payload["total_symbols"] = total
            }
            let (truncJson, _, _) = TruncationService.truncateJSONPayload(payload)
            return truncJson
        } catch {
            return jsonError("document_symbols failed: \(error)")
        }
    }

    /// Find symbols by name across the whole workspace. `path` is any file in
    /// the target workspace — it selects the language server and root.
    func workspaceSymbols(query: String, path: String) async -> String {
        guard let (client, _, serverID) = await prepareForQuery(path: path) else {
            return jsonSkipped(path: path, reason: "no language server available for \(path)")
        }
        do {
            let raw = try await client.workspaceSymbols(query: query)
            var cache = LineCache()
            let cap = 100
            let total = raw.count
            let mapped: [[String: Any]] = raw.prefix(cap).map { s in
                var e: [String: Any] = ["name": s["name"] as? String ?? ""]
                if let kind = s["kind"] as? Int { e["kind"] = Self.symbolKindName(kind) }
                if let container = s["containerName"] as? String, !container.isEmpty {
                    e["container"] = container
                }
                if let loc = s["location"] as? [String: Any] {
                    for (k, v) in locationPayload(loc, cache: &cache) { e[k] = v }
                }
                return e
            }
            var payload: [String: Any] = [
                "success": true,
                "query": query,
                "server": serverID,
                "symbols": mapped,
                "symbol_count": mapped.count
            ]
            if total > cap {
                payload["truncated"] = true
                payload["total_symbols"] = total
            }
            let (truncJson, _, _) = TruncationService.truncateJSONPayload(payload)
            return truncJson
        } catch {
            return jsonError("workspace_symbols failed: \(error)")
        }
    }

    /// Flatten DocumentSymbol[] (hierarchical) or SymbolInformation[] (flat)
    /// into 1-indexed entries with a depth marker.
    private func flattenSymbols(_ symbols: [[String: Any]], depth: Int, path: String, cache: inout LineCache, into out: inout [[String: Any]]) {
        for s in symbols {
            guard let name = s["name"] as? String else { continue }
            var entry: [String: Any] = ["name": name, "depth": depth]
            if let kind = s["kind"] as? Int { entry["kind"] = Self.symbolKindName(kind) }
            // DocumentSymbol: selectionRange points at the identifier; range
            // spans the whole declaration body.
            if let sel = (s["selectionRange"] as? [String: Any]) ?? (s["range"] as? [String: Any]),
               let start = sel["start"] as? [String: Any],
               let line = start["line"] as? Int {
                entry["line"] = line + 1
                if let ch = start["character"] as? Int {
                    entry["column"] = displayColumn(path: path, line0: line, utf16: ch, cache: &cache)
                }
            }
            if let range = s["range"] as? [String: Any],
               let end = range["end"] as? [String: Any],
               let endLine = end["line"] as? Int {
                entry["end_line"] = endLine + 1
            }
            // SymbolInformation (flat legacy form) carries a location instead.
            if entry["line"] == nil,
               let loc = s["location"] as? [String: Any],
               let range = loc["range"] as? [String: Any],
               let start = range["start"] as? [String: Any],
               let line = start["line"] as? Int {
                entry["line"] = line + 1
                if let ch = start["character"] as? Int {
                    entry["column"] = displayColumn(path: path, line0: line, utf16: ch, cache: &cache)
                }
            }
            if let container = s["containerName"] as? String, !container.isEmpty {
                entry["container"] = container
            }
            out.append(entry)
            if let children = s["children"] as? [[String: Any]] {
                flattenSymbols(children, depth: depth + 1, path: path, cache: &cache, into: &out)
            }
        }
    }

    /// LSP SymbolKind (1-26) → readable name.
    private static func symbolKindName(_ kind: Int) -> String {
        let names = [
            "file", "module", "namespace", "package", "class", "method",
            "property", "field", "constructor", "enum", "interface", "function",
            "variable", "constant", "string", "number", "boolean", "array",
            "object", "key", "null", "enum_member", "struct", "event",
            "operator", "type_parameter"
        ]
        return (kind >= 1 && kind <= names.count) ? names[kind - 1] : "kind_\(kind)"
    }

    /// Get-or-spawn the client for a path and ensure the current file
    /// contents are open in the server, so symbol queries have a document
    /// to work with. Re-syncs the document when the file changed on disk
    /// outside the write tools (bash, git, external editors) — otherwise the
    /// server would silently answer from a stale copy.
    private func prepareForQuery(path: String) async -> (LSPClient, URL, String)? {
        reapIdleLocked()
        if Task.isCancelled { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        guard let cfg = LSPLanguages.serverConfig(forExtension: ext),
              let languageId = LSPLanguages.languageId(forExtension: ext) else {
            return nil
        }
        if isMissingCacheHit(executable: cfg.executable) { return nil }
        let root = LSPLanguages.workspaceRoot(forFilePath: path, markers: cfg.workspaceMarkers)
        let key = entryKey(serverID: cfg.serverID, root: root)
        guard let client = await ensureClient(key: key, config: cfg, root: root) else {
            // Same distinction as the diagnostics path: only cache the
            // executable as missing when it genuinely isn't on disk; spawn/init
            // failures are cooled down per-workspace by failedSpawns.
            if LSPLanguages.locateExecutable(cfg.executable) == nil {
                markMissing(executable: cfg.executable)
            }
            return nil
        }
        let fileURL = URL(fileURLWithPath: path)
        let uriKey = fileURL.absoluteString
        let stamp = fileStamp(path: path)
        if let known = entries[key]?.openedDocs[uriKey] {
            if let stamp, stamp.mtime != known.mtime || stamp.size != known.size {
                guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return nil
                }
                do {
                    try await client.didChange(uri: fileURL, text: data)
                    entries[key]?.openedDocs[uriKey] = stamp
                } catch {
                    return nil
                }
            }
        } else {
            guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
                return nil
            }
            do {
                try await client.didOpen(uri: fileURL, text: data, languageId: languageId)
                entries[key]?.openedDocs[uriKey] = stamp ?? DocStamp(mtime: .distantPast, size: -1)
            } catch {
                return nil
            }
        }
        entries[key]?.lastUsed = Date()
        return (client, fileURL, cfg.serverID)
    }

    /// Convert a raw LSP Location dict to a 1-indexed, path-rooted payload
    /// that matches read_file's line and column numbering (LSP wire columns
    /// are UTF-16 code units; converted via the target file's line content).
    private func locationPayload(_ loc: [String: Any], cache: inout LineCache) -> [String: Any] {
        let uriString = loc["uri"] as? String ?? ""
        let decoded = URL(string: uriString)?.path ?? uriString
        var out: [String: Any] = ["path": decoded]
        if let range = loc["range"] as? [String: Any],
           let start = range["start"] as? [String: Any],
           let line = start["line"] as? Int,
           let char = start["character"] as? Int {
            out["line"] = line + 1
            out["column"] = displayColumn(path: decoded, line0: line, utf16: char, cache: &cache)
        }
        if let range = loc["range"] as? [String: Any],
           let end = range["end"] as? [String: Any],
           let line = end["line"] as? Int,
           let char = end["character"] as? Int {
            out["end_line"] = line + 1
            out["end_column"] = displayColumn(path: decoded, line0: line, utf16: char, cache: &cache)
        }
        return out
    }

    // MARK: - Position conversion (UTF-16 wire ⇄ display columns)

    /// Lazy per-payload line lookup: splits each touched file once and caches
    /// the lines for the duration of one query's payload build.
    private struct LineCache {
        private var byPath: [String: [String]] = [:]
        mutating func line(_ number0: Int, inFileAt path: String) -> String? {
            if byPath[path] == nil {
                if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                    byPath[path] = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                } else {
                    byPath[path] = []
                }
            }
            guard let lines = byPath[path], number0 >= 0, number0 < lines.count else { return nil }
            return lines[number0]
        }
    }

    /// Model's 1-indexed display column → 0-indexed UTF-16 wire offset.
    /// Falls back to a plain -1 shift when the line can't be read.
    private func utf16Column(path: String, line: Int, column: Int, cache: inout LineCache) -> Int {
        guard let content = cache.line(max(line - 1, 0), inFileAt: path) else {
            return max(column - 1, 0)
        }
        return LSPPositionConverter.utf16Offset(displayColumn: column, in: content)
    }

    /// 0-indexed UTF-16 wire offset → 1-indexed display column.
    /// Falls back to a plain +1 shift when the line can't be read.
    private func displayColumn(path: String, line0: Int, utf16: Int, cache: inout LineCache) -> Int {
        guard let content = cache.line(line0, inFileAt: path) else {
            return utf16 + 1
        }
        return LSPPositionConverter.displayColumn(utf16Offset: utf16, in: content)
    }

    /// Current disk stamp for change detection; nil if the file is unreadable.
    private func fileStamp(path: String) -> DocStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let mtime = attrs[.modificationDate] as? Date ?? .distantPast
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        return DocStamp(mtime: mtime, size: size)
    }

    private func jsonString(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"failed to encode response\"}"
    }

    private func jsonError(_ msg: String) -> String {
        jsonString(["error": msg])
    }

    private func jsonSkipped(path: String, reason: String) -> String {
        jsonString(["success": false, "skipped": reason, "path": path])
    }

    /// Set once shutdownAll has run. A spawn that was in flight at quit time
    /// isn't in `entries` yet — finishSpawn checks this flag and kills the
    /// freshly-initialized client instead of repopulating a dying registry.
    private var isShuttingDown = false

    /// Terminate every live server immediately. Called from
    /// applicationWillTerminate, where the graceful shutdown handshake
    /// (a 15s request timeout per server) can't be afforded — SIGTERM is
    /// enough for every server we spawn.
    func shutdownAll() async {
        isShuttingDown = true
        // Cancel in-flight spawns; whether they honor cancellation (throw into
        // their catch path, which shuts the client down) or run to completion,
        // finishSpawn sees the flag and terminates the client either way.
        for (_, task) in spawnTasks { task.cancel() }
        for (_, entry) in entries {
            await entry.client.terminateNow()
        }
        entries.removeAll()
        spawnTasks.removeAll()
    }

    /// Introspection for debugging / status surfaces.
    func status() -> [(serverID: String, root: String, lastUsed: Date, openDocs: Int)] {
        entries.values.map {
            ($0.serverID, $0.rootURI.path, $0.lastUsed, $0.openedDocs.count)
        }
    }

    // MARK: - Private

    private func ensureClient(
        key: String,
        config: LSPServerConfig,
        root: URL
    ) async -> LSPClient? {
        if let entry = entries[key] {
            let alive = await entry.client.isAlive
            if alive { return entry.client }
            // Stale entry from a crashed server — drop and respawn below.
            entries.removeValue(forKey: key)
        }

        if spawnTasks[key] == nil {
            // Recent spawn/init failure — skip until the cooldown expires so a
            // wedged server can't tax every write with a fresh init timeout.
            if let failedAt = failedSpawns[key] {
                if Date().timeIntervalSince(failedAt) < failedSpawnTTL {
                    return nil
                }
                failedSpawns.removeValue(forKey: key)
            }

            let executable = config.executable
            let arguments = config.arguments
            let serverID = config.serverID
            let env = LSPLanguages.augmentedEnvironment()
            // The spawn task reports its result back into actor state via
            // finishSpawn rather than being awaited directly: awaiting
            // task.value is not cancellation-responsive, and a /stop during a
            // cold 60s init must release the caller while the spawn continues
            // in the background for the next caller.
            spawnTasks[key] = Task { [weak self] in
                guard let exePath = LSPLanguages.locateExecutable(executable) else {
                    await self?.finishSpawn(key: key, client: nil, config: config, root: root)
                    return
                }
                let client = LSPClient(executable: exePath, arguments: arguments, environment: env)
                do {
                    try await client.start()
                    try await client.initialize(rootURI: root)
                    await self?.finishSpawn(key: key, client: client, config: config, root: root)
                } catch {
                    print("[LSPRegistry] \(serverID) failed to initialize for \(root.path): \(error)")
                    await client.shutdown()
                    await self?.finishSpawn(key: key, client: nil, config: config, root: root)
                }
            }
        }

        // Preemptible wait: poll actor state (updated by finishSpawn) so a
        // cancelled turn stops waiting immediately instead of riding out the
        // full initialize timeout.
        while spawnTasks[key] != nil {
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return entries[key]?.client
    }

    /// Completion callback for a spawn task: publish the result into actor
    /// state and clear the in-flight marker so waiting callers unblock.
    private func finishSpawn(key: String, client: LSPClient?, config: LSPServerConfig, root: URL) {
        spawnTasks.removeValue(forKey: key)
        guard let client else {
            failedSpawns[key] = Date()
            return
        }
        if isShuttingDown {
            // App is quitting: this spawn raced shutdownAll. Kill the server
            // instead of orphaning it in a registry nothing will read again.
            Task { await client.terminateNow() }
            return
        }
        entries[key] = Entry(
            client: client,
            lastUsed: Date(),
            serverID: config.serverID,
            rootURI: root
        )
    }

    private func reapIdleLocked() {
        let now = Date()
        let stale = entries.filter { now.timeIntervalSince($0.value.lastUsed) > idleTTL }
        guard !stale.isEmpty else { return }
        for (key, entry) in stale {
            entries.removeValue(forKey: key)
            // Fire-and-forget shutdown so we don't block the main path.
            Task { await entry.client.shutdown() }
        }
    }

    private func entryKey(serverID: String, root: URL) -> String {
        "\(serverID)|\(root.standardizedFileURL.path)"
    }

    // MARK: - Missing-executable cache with TTL

    private func isMissingCacheHit(executable: String) -> Bool {
        guard let markedAt = missingExecutables[executable] else { return false }
        if Date().timeIntervalSince(markedAt) > missingCacheTTL {
            missingExecutables.removeValue(forKey: executable)
            return false
        }
        return true
    }

    private func markMissing(executable: String) {
        missingExecutables[executable] = Date()
    }
}
