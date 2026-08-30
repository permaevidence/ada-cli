import Foundation

/// LSP wire framing: `Content-Length: N\r\n\r\n<json>` with optional
/// additional headers (ignored). Encoding and incremental decoding helpers.
enum LSPFraming {

    /// Encode a JSON-RPC message (dictionary) as a fully-framed LSP payload.
    static func encode(_ json: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json, options: [])
        let header = "Content-Length: \(body.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else {
            throw LSPFrameError.invalidHeader
        }
        var result = headerData
        result.append(body)
        return result
    }

    /// Attempt to decode the next complete LSP message from `buffer`.
    /// Removes the consumed bytes on success. Returns `nil` if the buffer
    /// does not yet contain a full frame.
    static func decodeNext(buffer: inout Data) throws -> [String: Any]? {
        let separator = Data([0x0d, 0x0a, 0x0d, 0x0a]) // \r\n\r\n
        guard let sepRange = buffer.firstRange(of: separator) else {
            return nil
        }
        let headerData = buffer.subdata(in: 0..<sepRange.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            throw LSPFrameError.invalidHeader
        }
        var contentLength: Int?
        for line in headerStr.components(separatedBy: "\r\n") {
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "content-length" {
                contentLength = Int(value)
            }
        }
        guard let length = contentLength else {
            throw LSPFrameError.missingContentLength
        }
        let bodyStart = sepRange.upperBound
        let bodyEnd = bodyStart + length
        guard buffer.count >= bodyEnd else { return nil }
        let bodyData = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(0..<bodyEnd)
        guard let obj = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            throw LSPFrameError.invalidBody
        }
        return obj
    }
}
