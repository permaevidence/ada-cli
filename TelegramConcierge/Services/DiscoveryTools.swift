import Foundation

/// Discovery tools: grep, glob, list_dir, list_recent_files.
/// These never modify disk — they only inspect.
///
/// Implementation notes:
/// - grep uses ripgrep (`rg`) if present on PATH, otherwise falls back to a native Swift
///   regex sweep. Ripgrep is dramatically faster on large trees; the native path keeps
///   the tool working on a fresh machine without `brew install ripgrep`.
/// - glob uses native FileManager enumeration.
/// - list_dir uses FileManager, respects a baked-in ignore list.
/// - list_recent_files simply reads FilesLedger.
enum DiscoveryTools {

    static let maxResults = 100
    static let maxResultsHardCap = 500
    static let maxLineLength = 2000
    /// Upper bound on parsed output lines when computing totals — keeps a
    /// pathological match-everything grep from ballooning memory.
    static let parseBound = 5000

    static let bakedInIgnores: Set<String> = [
        ".git", "node_modules", "__pycache__", ".venv", "venv",
        "dist", "build", ".build", ".swiftpm", "DerivedData",
        ".next", ".nuxt", ".turbo", ".cache", ".DS_Store",
        "target", "out", "coverage", ".pytest_cache", ".mypy_cache",
        ".idea", ".vscode"
    ]

    struct OpResult {
        let content: String
    }

    // MARK: - grep

    enum GrepOutputMode: String {
        case content
        case filesWithMatches = "files_with_matches"
        case count
    }

    /// Search file contents for a pattern.
    /// - Parameters:
    ///   - pattern: regex pattern
    ///   - searchPath: directory root (absolute path)
    ///   - include: optional glob filter (e.g. "*.swift")
    ///   - type: optional ripgrep type filter (e.g. "swift", "ts"); requires ripgrep
    ///   - outputMode: .content (default, match lines), .filesWithMatches (paths only), .count (matches-per-file)
    ///   - caseInsensitive: case-insensitive matching (-i)
    ///   - multiline: allow patterns to span newlines (`-U --multiline-dotall`); requires ripgrep
    ///   - contextBefore/contextAfter: number of lines of surrounding context (content mode only)
    ///   - maxResults: cap on returned lines/files (default 100)
    ///   - registerProcess/unregisterProcess: hooks into ToolExecutor's running-process
    ///     registry so turn-cancel and app-shutdown sweeps can kill the rg subprocess
    static func grep(
        pattern: String,
        searchPath: String,
        include: String? = nil,
        type: String? = nil,
        outputMode: GrepOutputMode = .content,
        caseInsensitive: Bool = false,
        multiline: Bool = false,
        contextBefore: Int = 0,
        contextAfter: Int = 0,
        maxResults: Int = DiscoveryTools.maxResults,
        registerProcess: ((Process) -> Void)? = nil,
        unregisterProcess: ((Process) -> Void)? = nil
    ) async -> OpResult {
        let path = FilesystemTools.normalizePath(searchPath)
        guard FilesystemTools.isAbsolute(path) else {
            return OpResult(content: jsonError("search path must be absolute: \(searchPath)"))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return OpResult(content: jsonError("search path does not exist: \(path)"))
        }
        let isFile = !isDir.boolValue

        // Single-file mode: reject non-regular files up front. The native fallback's
        // Data(contentsOf:) on a FIFO/device blocks forever (cancellation and the 30s
        // deadline only run between candidates), and even ripgrep would stall until
        // the process kill. Same guard read_file applies.
        if isFile {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if let type = (try? FileManager.default.attributesOfItem(atPath: resolved))?[.type] as? FileAttributeType,
               type != .typeRegular {
                return OpResult(content: jsonError("cannot grep \(path): not a regular file (\(type.rawValue)). FIFOs, sockets, and device files cannot be searched."))
            }
        }

        if let rgResult = await grepViaRipgrep(
            pattern: pattern,
            searchPath: path,
            include: include,
            type: type,
            outputMode: outputMode,
            caseInsensitive: caseInsensitive,
            multiline: multiline,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            maxResults: maxResults,
            register: registerProcess,
            unregister: unregisterProcess
        ) {
            return rgResult
        }
        return grepNative(
            pattern: pattern,
            searchPath: path,
            isFile: isFile,
            include: include,
            type: type,
            outputMode: outputMode,
            caseInsensitive: caseInsensitive,
            multiline: multiline,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            maxResults: maxResults
        )
    }

    private static func grepViaRipgrep(
        pattern: String,
        searchPath: String,
        include: String?,
        type: String?,
        outputMode: GrepOutputMode,
        caseInsensitive: Bool,
        multiline: Bool,
        contextBefore: Int,
        contextAfter: Int,
        maxResults: Int,
        register: ((Process) -> Void)? = nil,
        unregister: ((Process) -> Void)? = nil
    ) async -> OpResult? {
        let rg = await locateExecutable("rg")
        guard let rg else { return nil }

        // NOTE: no --sort=modified — sorting forces ripgrep into single-threaded
        // mode, which is dramatically slower on large trees. We run the search
        // fully parallel and sort the parsed results by file mtime in Swift below.
        // --max-columns-preview: without it rg OMITS over-length lines entirely
        // ("[Omitted long matching line]") — exactly on minified files where the
        // match matters. With it rg emits a clipped preview that still parses.
        // --with-filename: when the search path is a single file, rg normally
        // prints "N:text" / "N" with NO path prefix, which the "path:N:text"
        // parsers below then discard — silently turning every single-file
        // content/count search into 0 matches. -H pins the path prefix on.
        var args: [String] = [
            "--color=never",
            "--with-filename",
            "--max-columns=\(maxLineLength)",
            "--max-columns-preview"
        ]
        if caseInsensitive { args.append("-i") }
        if multiline { args.append("-U"); args.append("--multiline-dotall") }

        switch outputMode {
        case .content:
            args.append("--no-heading")
            args.append("--line-number")
            args.append("--max-count=\(maxResults)")
            if contextBefore > 0 { args.append("-B"); args.append(String(contextBefore)) }
            if contextAfter > 0 { args.append("-A"); args.append(String(contextAfter)) }
        case .filesWithMatches:
            args.append("-l")
        case .count:
            args.append("-c")
        }

        for ignore in bakedInIgnores {
            args.append("--glob")
            args.append("!\(ignore)/")
        }
        if let include {
            args.append("--glob")
            args.append(include)
        }
        if let type, !type.isEmpty {
            args.append("-t")
            args.append(type)
        }
        args.append("--")
        args.append(pattern)
        args.append(searchPath)

        let (out, err, status) = await runProcess(
            executable: rg, args: args, timeoutSeconds: 30,
            register: register, unregister: unregister
        )
        if status == -3 {
            return OpResult(content: jsonError("grep was cancelled"))
        }
        if status == -2 {
            return OpResult(content: jsonError("grep timed out after 30s — narrow the path or pattern, or add an include/type filter"))
        }
        // rg exits 1 when no matches — treat that as success with empty results.
        guard status == 0 || status == 1 else {
            // ripgrep ran but errored — could be an unknown type filter. Surface it.
            let trimmedErr = err.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedErr.isEmpty {
                return OpResult(content: jsonError("ripgrep error: \(trimmedErr)"))
            }
            return nil
        }

        switch outputMode {
        case .filesWithMatches:
            // Parse everything (bounded), sort by mtime, then cap — so the
            // returned slice is the most-recently-modified files and the
            // total is known.
            var allFiles: [String] = []
            var totalExact = true
            for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                if allFiles.count >= parseBound { totalExact = false; break }
                allFiles.append(String(line))
            }
            let sortedFiles = sortPathsByMtime(allFiles)
            let truncated = sortedFiles.count > maxResults || !totalExact
            let capped = Array(sortedFiles.prefix(maxResults))
            var payload: [String: Any] = [
                "success": true,
                "backend": "ripgrep",
                "mode": "files_with_matches",
                "pattern": pattern,
                "path": searchPath,
                "files": capped,
                "count": capped.count,
                "truncated": truncated,
                "total_files": sortedFiles.count
            ]
            if !totalExact { payload["total_is_lower_bound"] = true }
            return OpResult(content: jsonString(payload))

        case .count:
            var counts: [[String: Any]] = []
            var totalExact = true
            for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                if counts.count >= parseBound { totalExact = false; break }
                // rg -c format: "path:N"
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let n = Int(parts[1]) else { continue }
                counts.append(["file": String(parts[0]), "count": n])
            }
            let sortedCounts = sortEntriesByFileMtime(counts)
            let truncated = sortedCounts.count > maxResults || !totalExact
            let capped = Array(sortedCounts.prefix(maxResults))
            var payload: [String: Any] = [
                "success": true,
                "backend": "ripgrep",
                "mode": "count",
                "pattern": pattern,
                "path": searchPath,
                "files": capped,
                "file_count": capped.count,
                "truncated": truncated,
                "total_files": sortedCounts.count
            ]
            if !totalExact { payload["total_is_lower_bound"] = true }
            return OpResult(content: jsonString(payload))

        case .content:
            var entries: [[String: Any]] = []
            var totalMatches = 0        // all match lines seen (context lines excluded)
            var totalExact = true
            var parsedLines = 0
            var perFileMatchCounts: [String: Int] = [:]
            let wantContext = contextBefore > 0 || contextAfter > 0
            let redactor = BashTools.SecretRedactor()
            for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                parsedLines += 1
                if parsedLines > parseBound { totalExact = false; break }
                let raw = String(line)
                if raw == "--" { continue } // ripgrep context-group separator
                // Matches use `file:N:text`; context lines use `file-N-text`.
                // We only need to detect which is which; record `kind` for context.
                guard let (filePath, lineNo, text, kind) = parseRgLine(raw, wantContext: wantContext) else { continue }
                if kind == "match" {
                    totalMatches += 1
                    perFileMatchCounts[filePath, default: 0] += 1
                }
                var clipped = text
                if clipped.count > maxLineLength {
                    clipped = String(clipped.prefix(maxLineLength)) + "… [truncated]"
                }
                var entry: [String: Any] = [
                    "file": filePath,
                    "line": lineNo,
                    "text": redactor.redact(clipped)
                ]
                if wantContext { entry["kind"] = kind }
                entries.append(entry)
            }
            // Sort by file mtime BEFORE capping so the returned slice is the
            // most-recently-modified files' matches. Capping first would keep an
            // arbitrary sample of rg's parallel output order and the sort would
            // be purely cosmetic — the model would believe it saw the newest
            // matches when it saw a random 100.
            let sorted = sortEntriesByFileMtime(entries)
            var capped: [[String: Any]] = []
            var appendedMatches = 0     // only kind=="match" counts toward the cap
            var truncated = false
            for entry in sorted {
                let isMatch = (entry["kind"] as? String ?? "match") == "match"
                if isMatch, appendedMatches >= maxResults {
                    truncated = true
                    break
                }
                capped.append(entry)
                if isMatch { appendedMatches += 1 }
            }
            // --max-count caps matches PER FILE; a file that hit the cap hides
            // an unknown number of further matches, so the total is a floor.
            if perFileMatchCounts.values.contains(where: { $0 >= maxResults }) { totalExact = false }
            var payload: [String: Any] = [
                "success": true,
                "backend": "ripgrep",
                "mode": "content",
                "pattern": pattern,
                "path": searchPath,
                "matches": capped,
                "match_count": appendedMatches,
                "truncated": truncated || !totalExact,
                "total_matches": totalMatches
            ]
            if !totalExact { payload["total_is_lower_bound"] = true }
            let (truncJson, _, _) = TruncationService.truncateJSONPayload(payload)
            return OpResult(content: truncJson)
        }
    }

    /// Parse a ripgrep output line where match lines use "path:N:text" and context
    /// lines use "path-N-text". Returns (path, lineNumber, text, kind) where kind is
    /// "match" or "context". Returns nil if the line can't be parsed.
    private static func parseRgLine(_ line: String, wantContext: Bool) -> (String, Int, String, String)? {
        // Search for the first separator sequence: path ends before `:N:` (match) or `-N-` (context).
        // We walk from the end-ish to find a numeric segment bracketed by one of the separators.
        // Simpler approach: try `:` first, then if that gives a non-numeric line segment, try `-`.
        if let tuple = splitRgLine(line, separator: ":") {
            return (tuple.0, tuple.1, tuple.2, "match")
        }
        if wantContext, let tuple = splitRgLine(line, separator: "-") {
            return (tuple.0, tuple.1, tuple.2, "context")
        }
        return nil
    }

    private static func splitRgLine(_ line: String, separator: Character) -> (String, Int, String)? {
        // Find the LAST valid "path<sep>N<sep>text" where N is an integer.
        // We do this by scanning for a substring "<sep><digits><sep>" from the left,
        // taking the FIRST occurrence so paths with colons (unusual) still parse.
        let chars = Array(line)
        var idx = 0
        while idx < chars.count {
            if chars[idx] == separator {
                // Look for digits followed by same separator.
                var j = idx + 1
                while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
                if j > idx + 1, j < chars.count, chars[j] == separator {
                    let path = String(chars[0..<idx])
                    guard let lineNo = Int(String(chars[(idx + 1)..<j])) else { idx = j; continue }
                    let text = j + 1 <= chars.count ? String(chars[(j + 1)..<chars.count]) : ""
                    return (path, lineNo, text)
                }
                idx = j
            } else {
                idx += 1
            }
        }
        return nil
    }

    /// Stable-sort grep entries by their file's mtime (descending), preserving
    /// the original per-file line order. Replaces ripgrep's --sort=modified,
    /// which would force the search itself into single-threaded mode.
    private static func sortEntriesByFileMtime(_ entries: [[String: Any]]) -> [[String: Any]] {
        guard entries.count > 1 else { return entries }
        var order: [String] = []
        var groups: [String: [[String: Any]]] = [:]
        for e in entries {
            let f = e["file"] as? String ?? ""
            if groups[f] == nil { order.append(f) }
            groups[f, default: []].append(e)
        }
        let mtimes = mtimeLookup(for: order)
        let sortedFiles = order.sorted {
            (mtimes[$0] ?? .distantPast) > (mtimes[$1] ?? .distantPast)
        }
        return sortedFiles.flatMap { groups[$0] ?? [] }
    }

    /// Sort plain file paths by mtime descending.
    private static func sortPathsByMtime(_ paths: [String]) -> [String] {
        guard paths.count > 1 else { return paths }
        let mtimes = mtimeLookup(for: paths)
        return paths.sorted {
            (mtimes[$0] ?? .distantPast) > (mtimes[$1] ?? .distantPast)
        }
    }

    private static func mtimeLookup(for paths: [String]) -> [String: Date] {
        var mtimes: [String: Date] = [:]
        mtimes.reserveCapacity(paths.count)
        for p in paths where mtimes[p] == nil {
            let attrs = try? FileManager.default.attributesOfItem(atPath: p)
            mtimes[p] = attrs?[.modificationDate] as? Date ?? .distantPast
        }
        return mtimes
    }

    private static func grepNative(
        pattern: String,
        searchPath: String,
        isFile: Bool,
        include: String?,
        type: String?,
        outputMode: GrepOutputMode,
        caseInsensitive: Bool,
        multiline: Bool,
        contextBefore: Int,
        contextAfter: Int,
        maxResults: Int
    ) -> OpResult {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if multiline { options.insert(.dotMatchesLineSeparators) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return OpResult(content: jsonError("invalid regex pattern: \(pattern)"))
        }
        let includePattern: NSRegularExpression? = {
            guard let include else { return nil }
            return try? NSRegularExpression(pattern: globToRegex(include))
        }()

        // The native backend degrades relative to ripgrep in ways the model must
        // know about, or it will trust results that silently mean something else.
        var warnings: [String] = []
        if type != nil, !type!.isEmpty {
            warnings.append("the 'type' filter requires ripgrep and was IGNORED — all file types were searched; use 'include' instead, or install ripgrep")
        }
        if multiline, outputMode == .content {
            warnings.append("multiline is not supported by the native backend in content mode — the pattern was matched line by line")
        }
        var timedOut = false
        let deadline = Date().addingTimeInterval(30)

        struct Candidate { let url: URL; let mtime: Date }
        var candidates: [Candidate] = []

        if isFile {
            let url = URL(fileURLWithPath: searchPath)
            let mtime = (try? FileManager.default.attributesOfItem(atPath: searchPath))?[.modificationDate] as? Date
            candidates = [Candidate(url: url, mtime: mtime ?? .distantPast)]
        } else {
            let root = URL(fileURLWithPath: searchPath, isDirectory: true)
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            while let item = enumerator?.nextObject() as? URL {
                if Task.isCancelled {
                    return OpResult(content: jsonError("grep was cancelled"))
                }
                if Date() >= deadline { timedOut = true; break }
                let name = item.lastPathComponent
                if bakedInIgnores.contains(name) {
                    enumerator?.skipDescendants()
                    continue
                }
                let resource = try? item.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard resource?.isRegularFile == true else { continue }
                if let includePattern {
                    let nameRange = NSRange(name.startIndex..<name.endIndex, in: name)
                    if includePattern.firstMatch(in: name, range: nameRange) == nil { continue }
                }
                candidates.append(Candidate(url: item, mtime: resource?.contentModificationDate ?? .distantPast))
            }
        }
        candidates.sort { $0.mtime > $1.mtime }

        // files_with_matches / count: iterate files, short-circuit on first match per file.
        if outputMode == .filesWithMatches || outputMode == .count {
            var files: [String] = []
            var counts: [[String: Any]] = []
            var truncated = false
            for candidate in candidates {
                if Task.isCancelled {
                    return OpResult(content: jsonError("grep was cancelled"))
                }
                if Date() >= deadline { timedOut = true; truncated = true; break }
                if (outputMode == .filesWithMatches ? files.count : counts.count) >= maxResults { truncated = true; break }
                guard let data = try? Data(contentsOf: candidate.url, options: .mappedIfSafe) else { continue }
                if data.prefix(4096).contains(0) { continue }
                guard let text = String(data: data, encoding: .utf8) else { continue }
                let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
                if multiline {
                    let n = regex.numberOfMatches(in: text, range: nsRange)
                    if n > 0 {
                        if outputMode == .filesWithMatches { files.append(candidate.url.path) }
                        else { counts.append(["file": candidate.url.path, "count": n]) }
                    }
                } else {
                    var fileMatchCount = 0
                    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        let s = String(line)
                        let r = NSRange(s.startIndex..<s.endIndex, in: s)
                        fileMatchCount += regex.numberOfMatches(in: s, range: r)
                        if outputMode == .filesWithMatches, fileMatchCount > 0 { break }
                    }
                    if fileMatchCount > 0 {
                        if outputMode == .filesWithMatches { files.append(candidate.url.path) }
                        else { counts.append(["file": candidate.url.path, "count": fileMatchCount]) }
                    }
                }
            }
            if timedOut {
                warnings.append("search hit the 30s time budget — results are partial; narrow the path or pattern")
            }
            if outputMode == .filesWithMatches {
                var payload: [String: Any] = [
                    "success": true,
                    "backend": "native",
                    "mode": "files_with_matches",
                    "pattern": pattern,
                    "path": searchPath,
                    "files": files,
                    "count": files.count,
                    "truncated": truncated,
                    "total_files": files.count
                ]
                if truncated { payload["total_is_lower_bound"] = true }
                if !warnings.isEmpty { payload["warnings"] = warnings }
                return OpResult(content: jsonString(payload))
            }
            var payload: [String: Any] = [
                "success": true,
                "backend": "native",
                "mode": "count",
                "pattern": pattern,
                "path": searchPath,
                "files": counts,
                "file_count": counts.count,
                "truncated": truncated,
                "total_files": counts.count
            ]
            if truncated { payload["total_is_lower_bound"] = true }
            if !warnings.isEmpty { payload["warnings"] = warnings }
            return OpResult(content: jsonString(payload))
        }

        // content mode
        var matches: [[String: Any]] = []
        var appendedMatches = 0   // only actual match lines count toward the cap
        var truncated = false
        let wantContext = contextBefore > 0 || contextAfter > 0
        let redactor = BashTools.SecretRedactor()

        for candidate in candidates {
            if Task.isCancelled {
                return OpResult(content: jsonError("grep was cancelled"))
            }
            if Date() >= deadline { timedOut = true; truncated = true; break }
            if appendedMatches >= maxResults { truncated = true; break }
            guard let data = try? Data(contentsOf: candidate.url, options: .mappedIfSafe) else { continue }
            if data.prefix(4096).contains(0) { continue }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var matchedLines: Set<Int> = []
            for (idx, line) in lines.enumerated() {
                let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, range: nsRange) != nil {
                    matchedLines.insert(idx)
                }
            }
            if matchedLines.isEmpty { continue }

            // Compute the set of line indices to emit: matches plus surrounding context.
            var emitSet: Set<Int> = matchedLines
            if wantContext {
                for m in matchedLines {
                    let lo = max(0, m - contextBefore)
                    let hi = min(lines.count - 1, m + contextAfter)
                    for k in lo...hi { emitSet.insert(k) }
                }
            }
            let emit = emitSet.sorted()

            for i in emit {
                let isMatch = matchedLines.contains(i)
                if isMatch, appendedMatches >= maxResults { truncated = true; break }
                var t = lines[i]
                if t.count > maxLineLength {
                    t = String(t.prefix(maxLineLength)) + "… [truncated]"
                }
                var entry: [String: Any] = [
                    "file": candidate.url.path,
                    "line": i + 1,
                    "text": redactor.redact(t)
                ]
                if wantContext { entry["kind"] = isMatch ? "match" : "context" }
                matches.append(entry)
                if isMatch { appendedMatches += 1 }
            }
        }

        if timedOut {
            warnings.append("search hit the 30s time budget — results are partial; narrow the path or pattern")
        }
        var payload: [String: Any] = [
            "success": true,
            "backend": "native",
            "mode": "content",
            "pattern": pattern,
            "path": searchPath,
            "matches": matches,
            "match_count": appendedMatches,
            "truncated": truncated,
            "total_matches": appendedMatches
        ]
        if truncated { payload["total_is_lower_bound"] = true }
        if !warnings.isEmpty { payload["warnings"] = warnings }
        let (truncJson, _, _) = TruncationService.truncateJSONPayload(payload)
        return OpResult(content: truncJson)
    }

    // MARK: - glob

    /// Find files by glob pattern. Basename-only patterns match immediate children;
    /// path-qualified or ** patterns match relative paths under the search root.
    static func glob(
        pattern: String,
        searchPath: String? = nil,
        maxResults: Int = DiscoveryTools.maxResults,
        registerProcess: ((Process) -> Void)? = nil,
        unregisterProcess: ((Process) -> Void)? = nil
    ) async -> OpResult {
        let root: String
        if let searchPath {
            root = FilesystemTools.normalizePath(searchPath)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.path
        }
        guard FilesystemTools.isAbsolute(root) else {
            return OpResult(content: jsonError("search path must be absolute: \(searchPath ?? root)"))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return OpResult(content: jsonError("search path does not exist or is not a directory: \(root)"))
        }

        let matchPattern = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
        let pathQualified = matchPattern.contains("/")
        let recursive = matchPattern.contains("**") || pathQualified

        // Prefer ripgrep's parallel, .gitignore-aware file walker. Falls back
        // to the native FileManager sweep when rg is missing or errors —
        // but NOT on timeout/cancel: a walk rg couldn't finish in 30s would
        // only fare worse in the untimed native sweep.
        if let rgResult = await globViaRipgrep(
            matchPattern: matchPattern,
            originalPattern: pattern,
            root: root,
            recursive: recursive,
            maxResults: maxResults,
            register: registerProcess,
            unregister: unregisterProcess
        ) {
            return rgResult
        }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: globToRegex(matchPattern))
        } catch {
            return OpResult(content: jsonError("invalid glob pattern: \(pattern)"))
        }

        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        struct Hit { let path: String; let mtime: Date }
        var hits: [Hit] = []
        var timedOut = false
        let deadline = Date().addingTimeInterval(30)
        while let item = enumerator?.nextObject() as? URL {
            if Task.isCancelled {
                return OpResult(content: jsonError("glob was cancelled"))
            }
            if Date() >= deadline { timedOut = true; break }
            let name = item.lastPathComponent
            if bakedInIgnores.contains(name) {
                enumerator?.skipDescendants()
                continue
            }
            if !recursive {
                // Skip anything deeper than the root.
                if item.deletingLastPathComponent().path != root {
                    continue
                }
            }
            let resource = try? item.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard resource?.isRegularFile == true else { continue }
            let relativePath: String
            if item.path.hasPrefix(rootPrefix) {
                relativePath = String(item.path.dropFirst(rootPrefix.count))
            } else {
                relativePath = name
            }
            let candidate = pathQualified ? relativePath : name
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            if regex.firstMatch(in: candidate, range: range) != nil {
                hits.append(Hit(path: item.path, mtime: resource?.contentModificationDate ?? .distantPast))
            }
        }
        hits.sort { $0.mtime > $1.mtime }
        let truncated = hits.count > maxResults || timedOut
        let capped = Array(hits.prefix(maxResults))

        var payload: [String: Any] = [
            "success": true,
            "backend": "native",
            "pattern": pattern,
            "path": root,
            "files": capped.map { $0.path },
            "count": capped.count,
            "truncated": truncated,
            "total_files": hits.count
        ]
        if timedOut {
            payload["total_is_lower_bound"] = true
            payload["warnings"] = ["search hit the 30s time budget — results are partial; narrow the path or pattern"]
        }
        return OpResult(content: jsonString(payload))
    }

    /// Glob via `rg --files --glob <pattern>`: parallel directory walk that
    /// also honors .gitignore (the native fallback only knows the baked-in
    /// ignore list). Returns nil when rg is unavailable or errors, so the
    /// caller can fall back to the native sweep.
    private static func globViaRipgrep(
        matchPattern: String,
        originalPattern: String,
        root: String,
        recursive: Bool,
        maxResults: Int,
        register: ((Process) -> Void)? = nil,
        unregister: ((Process) -> Void)? = nil
    ) async -> OpResult? {
        guard let rg = await locateExecutable("rg") else { return nil }
        var args: [String] = ["--files", "--color=never"]
        // Non-recursive basename patterns (e.g. "*.swift") match immediate
        // children only — mirror the native semantics with --max-depth 1,
        // since rg's gitignore-style globs would otherwise match at any depth.
        if !recursive {
            args.append("--max-depth")
            args.append("1")
        }
        for ignore in bakedInIgnores {
            args.append("--glob")
            args.append("!\(ignore)/")
        }
        args.append("--glob")
        args.append(matchPattern)
        args.append(root)

        let (out, _, status) = await runProcess(
            executable: rg, args: args, timeoutSeconds: 30,
            register: register, unregister: unregister
        )
        if status == -3 {
            return OpResult(content: jsonError("glob was cancelled"))
        }
        if status == -2 {
            // Do NOT fall back to the native sweep here — it is slower than rg
            // and untimed, so a walk that already blew 30s would hang the turn.
            return OpResult(content: jsonError("glob timed out after 30s — narrow the path or pattern"))
        }
        // rg exits 1 when nothing matched — that's a valid empty result.
        guard status == 0 || status == 1 else { return nil }

        var paths: [String] = []
        var totalExact = true
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            if paths.count >= parseBound { totalExact = false; break }
            paths.append(String(line))
        }
        let sorted = sortPathsByMtime(paths)
        let truncated = sorted.count > maxResults || !totalExact
        let capped = Array(sorted.prefix(maxResults))
        var payload: [String: Any] = [
            "success": true,
            "backend": "ripgrep",
            "pattern": originalPattern,
            "path": root,
            "files": capped,
            "count": capped.count,
            "truncated": truncated,
            "total_files": sorted.count
        ]
        if !totalExact { payload["total_is_lower_bound"] = true }
        return OpResult(content: jsonString(payload))
    }

    // MARK: - list_dir

    /// Flat listing of a directory's immediate contents (non-recursive).
    /// Collects all visible entries (bounded by parseBound and a 30s budget),
    /// sorts by name, then applies offset + cap — so pagination is deterministic
    /// and total_entries reflects the real visible count.
    static func listDir(
        path rawPath: String,
        ignore extraIgnores: [String]? = nil,
        includeHidden: Bool = false,
        includeIgnored: Bool = false,
        maxResults requestedMax: Int = DiscoveryTools.maxResults,
        offset: Int = 0
    ) async -> OpResult {
        let path = FilesystemTools.normalizePath(rawPath)
        guard FilesystemTools.isAbsolute(path) else {
            return OpResult(content: jsonError("path must be absolute: \(rawPath)"))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            var message = "path does not exist: \(path)"
            let suggestions = didYouMean(for: path)
            if !suggestions.isEmpty {
                message += ". Did you mean: \(suggestions.joined(separator: ", "))"
            }
            return OpResult(content: jsonError(message))
        }
        guard isDir.boolValue else {
            return OpResult(content: jsonError("path is a file, not a directory: \(path) — use read_file for file contents"))
        }

        var ignores = bakedInIgnores
        if let extraIgnores { ignores.formUnion(extraIgnores) }
        let maxEntries = min(max(1, requestedMax), maxResultsHardCap)
        let startIndex = max(0, offset)

        let rootURL = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }

        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: options,
            errorHandler: { _, error in enumerationError = error; return true }
        ) else {
            return OpResult(content: jsonError("failed to list \(path)"))
        }

        let deadline = Date().addingTimeInterval(30)
        var collected: [(name: String, sortKey: String, url: URL)] = []
        var ignoredNames: Set<String> = []
        var totalIsLowerBound = false
        var warnings: [String] = []
        var scanned = 0

        for case let url as URL in enumerator {
            scanned += 1
            if scanned % 256 == 0 {
                if Task.isCancelled {
                    return OpResult(content: jsonError("list_dir was cancelled"))
                }
                if Date() > deadline {
                    totalIsLowerBound = true
                    warnings.append("directory walk exceeded the 30s budget — listing is partial")
                    break
                }
            }
            let name = url.lastPathComponent
            if ignores.contains(name) {
                ignoredNames.insert(name)
                if !includeIgnored { continue }
            }
            if collected.count >= parseBound {
                totalIsLowerBound = true
                warnings.append("directory has more than \(parseBound) visible entries — totals are a lower bound")
                break
            }
            collected.append((name, name.lowercased(), url))
        }

        if collected.isEmpty, let error = enumerationError {
            return OpResult(content: jsonError("failed to list \(path): \(error.localizedDescription)"))
        }
        if let error = enumerationError {
            warnings.append("some entries could not be read: \(error.localizedDescription)")
        }

        collected.sort { $0.sortKey < $1.sortKey }
        let total = collected.count
        let slice = collected.dropFirst(startIndex).prefix(maxEntries)
        let truncated = totalIsLowerBound || startIndex + slice.count < total

        let iso = ISO8601DateFormatter()
        var entries: [[String: Any]] = []
        entries.reserveCapacity(slice.count)
        for item in slice {
            var entry: [String: Any] = ["name": item.name, "path": item.url.path]
            if let rv = try? item.url.resourceValues(forKeys: keys) {
                if rv.isSymbolicLink == true {
                    entry["type"] = "symlink"
                    if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: item.url.path) {
                        entry["target"] = target
                        var targetIsDir: ObjCBool = false
                        let resolved = item.url.resolvingSymlinksInPath().path
                        if FileManager.default.fileExists(atPath: resolved, isDirectory: &targetIsDir) {
                            entry["target_type"] = targetIsDir.boolValue ? "dir" : "file"
                        } else {
                            entry["target_type"] = "missing"
                        }
                    }
                } else if rv.isDirectory == true {
                    entry["type"] = "dir"
                } else if rv.isRegularFile == true {
                    entry["type"] = "file"
                    if let size = rv.fileSize { entry["size_bytes"] = size }
                } else {
                    entry["type"] = "other"
                }
                if let mtime = rv.contentModificationDate {
                    entry["mtime"] = iso.string(from: mtime)
                }
            } else {
                entry["type"] = "unknown"
                entry["stat_failed"] = true
            }
            entries.append(entry)
        }

        var payload: [String: Any] = [
            "success": true,
            "path": path,
            "entries": entries,
            "count": entries.count,
            "offset": startIndex,
            "total_entries": total,
            "truncated": truncated
        ]
        if totalIsLowerBound { payload["total_is_lower_bound"] = true }
        if !ignoredNames.isEmpty {
            payload[includeIgnored ? "ignored_included" : "ignored"] = ignoredNames.sorted()
        }
        if !includeHidden { payload["hidden_skipped"] = true }
        if !warnings.isEmpty { payload["warnings"] = warnings }
        return OpResult(content: jsonString(payload))
    }

    /// Up to 3 fuzzy name suggestions from the parent directory of a nonexistent path.
    /// Fuzzy "Did you mean" suggestions for a missing path: case-insensitive bidirectional
    /// substring match against the parent directory, up to 3 results. Shared with read_file.
    static func didYouMean(for path: String) -> [String] {
        let parent = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent.lowercased()
        guard !base.isEmpty,
              let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return [] }
        return names.filter {
            let n = $0.lowercased()
            return n.contains(base) || (n.count >= 3 && base.contains(n))
        }.sorted().prefix(3).map { (parent as NSString).appendingPathComponent($0) }
    }

    // MARK: - list_recent_files

    static func listRecentFiles(limit: Int = 20, offset: Int = 0, filterOrigin: String? = nil) async -> OpResult {
        let origin: FilesLedger.Origin? = filterOrigin.flatMap { FilesLedger.Origin(rawValue: $0) }
        if let filterOrigin, origin == nil {
            return OpResult(content: jsonError("invalid filter_origin '\(filterOrigin)'. Valid values: edited, generated, telegram, email, download"))
        }
        let entries = await FilesLedger.shared.recentFiles(limit: limit, offset: offset, filterOrigin: origin)
        let total = await FilesLedger.shared.totalCount(filterOrigin: origin)
        let iso = ISO8601DateFormatter()
        let payload: [[String: Any]] = entries.map { e in
            var d: [String: Any] = [
                "path": e.path,
                "last_touched": iso.string(from: e.last_touched),
                "origin": e.origin.rawValue,
                "touch_count": e.touch_count
            ]
            if let desc = e.description { d["description"] = desc }
            return d
        }
        return OpResult(content: jsonString([
            "success": true,
            "files": payload,
            "returned": entries.count,
            "offset": offset,
            "total": total
        ]))
    }

    // MARK: - Helpers

    private static func locateExecutable(_ name: String) async -> String? {
        let candidatePaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in candidatePaths {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // Fallback: ask the shell.
        let which = await runProcess(executable: "/usr/bin/which", args: [name], timeoutSeconds: 5)
        if which.status == 0 {
            let path = which.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Run a subprocess with a timeout and cooperative cancellation.
    /// Returns (stdout, stderr, exit code); status -2 = timed out, -3 = cancelled.
    /// Pipes are drained concurrently so output larger than the 64KB pipe buffer
    /// can't deadlock the child against our exit-poll loop, and timeout/cancel
    /// kills use ProcessTree so descendants don't survive. The optional
    /// register/unregister hooks put the child in ToolExecutor's running-process
    /// registry so turn-cancel and app-shutdown sweeps reach it.
    private static func runProcess(
        executable: String,
        args: [String],
        timeoutSeconds: Double,
        register: ((Process) -> Void)? = nil,
        unregister: ((Process) -> Void)? = nil
    ) async -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return ("", "failed to spawn \(executable): \(error.localizedDescription)", -1)
        }
        register?(process)
        defer { unregister?(process) }

        let outTask = Task.detached { (try? outPipe.fileHandleForReading.readToEnd()) ?? Data() }
        let errTask = Task.detached { (try? errPipe.fileHandleForReading.readToEnd()) ?? Data() }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            if Task.isCancelled {
                await ProcessTree.terminate(process, graceNanos: 100_000_000)
                _ = await outTask.value
                _ = await errTask.value
                return ("", "cancelled", -3)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if process.isRunning {
            await ProcessTree.terminate(process, graceNanos: 100_000_000)
            _ = await outTask.value
            _ = await errTask.value
            return ("", "process timed out after \(timeoutSeconds)s", -2)
        }
        let outData = await outTask.value
        let errData = await errTask.value
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }

    /// Convert a shell-style glob (supporting *, ?, **/, {a,b} alternation, and
    /// character classes) into a regex anchored to the full candidate.
    private static func globToRegex(_ glob: String) -> String {
        "^" + globToRegexBody(Array(glob)) + "$"
    }

    private static func globToRegexBody(_ chars: [Character]) -> String {
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    if i + 2 < chars.count, chars[i + 2] == "/" {
                        out += "(?:.*/)?"
                        i += 3
                    } else {
                        out += ".*"
                        i += 2
                    }
                    continue
                }
                out += "[^/]*"
            case "?": out += "[^/]"
            case "{":
                // Brace alternation: {ts,tsx} → (?:ts|tsx). Supports nesting.
                var depth = 1
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "{" { depth += 1 }
                    else if chars[j] == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    j += 1
                }
                if depth == 0 {
                    let inner = Array(chars[(i + 1)..<j])
                    var alternatives: [[Character]] = [[]]
                    var d = 0
                    for c in inner {
                        if c == "{" { d += 1 }
                        else if c == "}" { d -= 1 }
                        if c == ",", d == 0 {
                            alternatives.append([])
                        } else {
                            alternatives[alternatives.count - 1].append(c)
                        }
                    }
                    out += "(?:" + alternatives.map { globToRegexBody($0) }.joined(separator: "|") + ")"
                    i = j + 1
                    continue
                }
                // Unmatched brace — treat as a literal character.
                out += "\\{"
            case ".", "(", ")", "}", "^", "$", "+", "|", "\\":
                out += "\\\(ch)"
            case "[":
                out += "["   // passthrough — user wrote their own class
            case "]":
                out += "]"
            default:
                out += String(ch)
            }
            i += 1
        }
        return out
    }

    private static func jsonError(_ message: String) -> String {
        jsonString(["error": message])
    }

    private static func jsonString(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"failed to encode response\"}"
    }
}
