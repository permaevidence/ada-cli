import Foundation

/// MCP stdio transport: newline-delimited JSON-RPC 2.0.
///
/// Each message is a single JSON object terminated by a single `\n`. This
/// differs from LSP's `Content-Length: N\r\n\r\n<body>` framing — MCP chose
/// the simpler wire format since JSON-RPC messages can't legitimately contain
/// unescaped newlines inside their top-level object.
enum MCPFraming {

    /// Encode a JSON-RPC message (dictionary) as a fully-framed MCP payload.
    /// The encoder passes `.withoutEscapingSlashes` so forward slashes in URIs
    /// and file paths come through clean, and we append a trailing newline.
    static func encode(_ json: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(
            withJSONObject: json,
            options: [.withoutEscapingSlashes]
        )
        var result = body
        result.append(0x0a) // '\n'
        return result
    }

    /// Attempt to decode the next complete newline-delimited JSON message from
    /// `buffer`. Removes the consumed bytes on success. Returns `nil` if the
    /// buffer does not yet contain a full line.
    ///
    /// Malformed lines (not valid JSON, or not a JSON object) are consumed and
    /// skipped — some servers emit log spew on stdout during startup, and
    /// we'd rather tolerate it than jam the decoder.
    static func decodeNext(buffer: inout Data) throws -> [String: Any]? {
        while let newlineIdx = buffer.firstIndex(of: 0x0a) {
            let lineData = buffer.subdata(in: 0..<newlineIdx)
            // Consume up to and including the newline.
            buffer.removeSubrange(0...newlineIdx)

            // Empty lines (keepalive) are skipped silently.
            let trimmed = lineData.trimmingNewlinesAndSpaces()
            guard !trimmed.isEmpty else { continue }

            // Non-JSON stdout noise is skipped silently.
            guard let first = trimmed.first, first == 0x7b /* '{' */ else {
                continue
            }

            do {
                if let obj = try JSONSerialization.jsonObject(with: trimmed) as? [String: Any] {
                    return obj
                }
                // Arrays or primitives at top level aren't JSON-RPC; skip.
                continue
            } catch {
                // Skip malformed line and try the next one.
                continue
            }
        }
        return nil
    }
}

private extension Data {
    func trimmingNewlinesAndSpaces() -> Data {
        var start = startIndex
        var end = endIndex
        while start < end, Self.isWhitespace(self[start]) { start = index(after: start) }
        while end > start, Self.isWhitespace(self[index(before: end)]) { end = index(before: end) }
        return subdata(in: start..<end)
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
    }
}
