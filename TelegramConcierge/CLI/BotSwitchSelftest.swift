import ArgumentParser
import Foundation

/// Hidden deterministic test of the `/switchbot` flow's pure core.
/// Pins (a) the decision matrix — nothing but an explicit `confirm` AFTER a
/// discovered chat may reach the cutover, (b) the token-shape gate that
/// keeps chat ids and typos from ever being probed as tokens, (c) the
/// one-time code format, (d) the tolerant getUpdates parse the discovery
/// poll relies on, and (e) the discovery filter: only a human in a PRIVATE
/// chat can claim the code (a group would hand Ada to everyone in it).
/// Pure static checks — no storage or network touched.
struct BotSwitchSelftest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__botswitch-selftest",
        abstract: "Internal: verify the /switchbot decision matrix, token gate and discovery parsing.",
        shouldDisplay: false
    )

    func run() throws {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        typealias Flow = BotSwitchFlow
        let goodToken = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw1"

        // 1. Decision matrix.
        check("bare + no pending → instructions",
              Flow.decide(argument: "", hasPending: false, hasDiscovered: false, cutoverInProgress: false) == .instructions)
        check("bare + pending → status",
              Flow.decide(argument: "  ", hasPending: true, hasDiscovered: false, cutoverInProgress: false) == .status)
        check("cancel always → cancel (case-insensitive)",
              Flow.decide(argument: "CANCEL", hasPending: true, hasDiscovered: true, cutoverInProgress: false) == .cancel)
        check("confirm before discovery → confirmNotReady",
              Flow.decide(argument: "confirm", hasPending: true, hasDiscovered: false, cutoverInProgress: false) == .confirmNotReady)
        check("confirm with no pending at all → confirmNotReady",
              Flow.decide(argument: "Confirm", hasPending: false, hasDiscovered: false, cutoverInProgress: false) == .confirmNotReady)
        check("confirm after discovery → cutover (the ONLY path to cutover)",
              Flow.decide(argument: "confirm", hasPending: true, hasDiscovered: true, cutoverInProgress: false) == .cutover)
        check("valid token → beginSwitch with trimmed token",
              Flow.decide(argument: " \(goodToken) ", hasPending: false, hasDiscovered: false, cutoverInProgress: false)
                  == .beginSwitch(token: goodToken, discardBacklog: false))
        check("token + discard → explicit backlog go-ahead",
              Flow.decide(argument: "\(goodToken) DISCARD", hasPending: false, hasDiscovered: false, cutoverInProgress: false)
                  == .beginSwitch(token: goodToken, discardBacklog: true))
        check("token + unknown suffix → invalidToken",
              Flow.decide(argument: "\(goodToken) please", hasPending: false, hasDiscovered: false, cutoverInProgress: false) == .invalidToken)
        check("garbage argument → invalidToken",
              Flow.decide(argument: "please switch", hasPending: false, hasDiscovered: false, cutoverInProgress: false) == .invalidToken)
        check("a bare chat id is NOT a token",
              Flow.decide(argument: "5551234567", hasPending: false, hasDiscovered: false, cutoverInProgress: false) == .invalidToken)

        // An executing cutover freezes the state machine: the reentrant
        // MainActor lets other-surface commands interleave with the
        // cutover's post-commit awaits, and an accepted cancel there would
        // report "unchanged" while the switch completes anyway
        // (Codex, 2026-08-22). EVERY variant must answer "finalizing".
        for frozen in ["", "cancel", "confirm", goodToken, "\(goodToken) discard", "junk"] {
            check("cutover in progress freezes «\(frozen.isEmpty ? "bare" : String(frozen.prefix(12)))…» → finalizing",
                  Flow.decide(argument: frozen, hasPending: true, hasDiscovered: true, cutoverInProgress: true) == .finalizing)
        }

        // 2. Token-shape gate.
        check("realistic token accepted", Flow.validTokenFormat(goodToken) != nil)
        check("missing colon rejected", Flow.validTokenFormat("123456789AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw1") == nil)
        check("short secret rejected", Flow.validTokenFormat("123456789:short") == nil)
        check("interior whitespace rejected", Flow.validTokenFormat("123456789:AAH dqTcvCH1vGWJxfSeofSAs0K5PALDsaw1") == nil)
        check("empty rejected", Flow.validTokenFormat("") == nil)

        // 3. One-time code: 6 digits, deterministic under an injected RNG,
        // leading zeros preserved.
        var rng = SeededRNG(seed: 42)
        let code1 = Flow.generateCode(using: &rng)
        check("code is 6 digits", code1.count == 6 && code1.allSatisfy(\.isNumber), code1)
        var rngA = SeededRNG(seed: 7), rngB = SeededRNG(seed: 7)
        check("code is deterministic under a seeded RNG",
              Flow.generateCode(using: &rngA) == Flow.generateCode(using: &rngB))
        var zeroRng = ConstantRNG(value: 0)
        check("leading zeros preserved", Flow.generateCode(using: &zeroRng) == "000000")

        // 4. getUpdates parsing (tolerant, JSONSerialization-based).
        let batch = """
        {"ok":true,"result":[
          {"update_id":10,"message":{"chat":{"id":555,"type":"private"},
           "from":{"first_name":"Anna","last_name":"Rossi","username":"annar","is_bot":false},
           "text":"hello 424242"}},
          {"update_id":11,"message":{"chat":{"id":-100777,"type":"group"},
           "from":{"first_name":"Mallory","is_bot":false},"text":"424242"}},
          {"update_id":12,"message":{"chat":{"id":556,"type":"private"},
           "from":{"first_name":"RoboSpam","is_bot":true},"text":"424242"}},
          {"update_id":13,"edited_message":{"chat":{"id":557,"type":"private"}}},
          {"update_id":14,"message":{"chat":{"id":558,"type":"private"},"text":"no sender"}}
        ]}
        """.data(using: .utf8)!
        let parsed = Flow.parseGetUpdates(batch)
        check("parses all messages with a chat id", parsed.messages.count == 4,
              "\(parsed.messages.count)")
        check("maxUpdateId spans non-message updates too", parsed.maxUpdateId == 14,
              "\(String(describing: parsed.maxUpdateId))")
        check("sender display joins name and username",
              parsed.messages.first?.senderDisplay == "Anna Rossi (@annar)",
              parsed.messages.first?.senderDisplay ?? "nil")
        check("senderless message falls back to chat id display",
              parsed.messages.last?.senderDisplay == "chat 558",
              parsed.messages.last?.senderDisplay ?? "nil")

        check("malformed JSON → empty parse, no crash",
              Flow.parseGetUpdates(Data("not json".utf8)) == Flow.ParsedUpdates(messages: [], maxUpdateId: nil))
        check("ok:false → empty parse",
              Flow.parseGetUpdates(Data(#"{"ok":false,"result":[]}"#.utf8))
                  == Flow.ParsedUpdates(messages: [], maxUpdateId: nil))

        // 5. Discovery filter: the code only counts from a HUMAN in a
        // PRIVATE chat — the group echo and the bot sender above must lose.
        let found = Flow.findCode("424242", in: parsed.messages)
        check("code found in the private human chat", found?.chatId == 555,
              "\(String(describing: found))")
        check("wrong code finds nothing", Flow.findCode("999999", in: parsed.messages) == nil)
        let groupOnly = parsed.messages.filter { !$0.isPrivateChat }
        check("group-chat code is refused", Flow.findCode("424242", in: groupOnly) == nil)
        let botOnly = parsed.messages.filter(\.fromIsBot)
        check("bot-sent code is refused", Flow.findCode("424242", in: botOnly) == nil)

        // 6. Error classification: the discovery loop must tell "empty
        // batch" from "error" — a webhook conflict or revoked token would
        // otherwise tight-loop for ten minutes (Codex, 2026-08-22).
        check("ok:true classifies as updates",
              Flow.classifyGetUpdates(httpStatus: 200, data: batch)
                  == .updates(Flow.parseGetUpdates(batch)))
        check("409 webhook conflict is permanent",
              Flow.classifyGetUpdates(httpStatus: 409,
                  data: Data(#"{"ok":false,"error_code":409,"description":"Conflict: webhook is active"}"#.utf8))
                  == .permanentError("Conflict: webhook is active"))
        check("401 revoked token is permanent",
              Flow.classifyGetUpdates(httpStatus: 401,
                  data: Data(#"{"ok":false,"error_code":401,"description":"Unauthorized"}"#.utf8))
                  == .permanentError("Unauthorized"))
        check("429 rate limit is transient",
              Flow.classifyGetUpdates(httpStatus: 429,
                  data: Data(#"{"ok":false,"error_code":429,"description":"Too Many Requests"}"#.utf8))
                  == .transientError("Too Many Requests"))
        check("undecodable body is transient with the HTTP status",
              Flow.classifyGetUpdates(httpStatus: 502, data: Data("<html>bad gateway".utf8))
                  == .transientError("HTTP 502"))

        // 7. getWebhookInfo parsing (the beginSwitch preflight against
        // taking over a bot that another service owns / has a backlog).
        let webhookData = Data(#"{"ok":true,"result":{"url":"https://x.example/hook","pending_update_count":7}}"#.utf8)
        check("webhook info parses url + pending count",
              Flow.parseWebhookInfo(webhookData) == Flow.WebhookInfo(url: "https://x.example/hook", pendingUpdateCount: 7))
        check("fresh bot parses as empty webhook, zero pending",
              Flow.parseWebhookInfo(Data(#"{"ok":true,"result":{"url":"","pending_update_count":0}}"#.utf8))
                  == Flow.WebhookInfo(url: "", pendingUpdateCount: 0))
        check("failed webhook check parses as nil (caller skips preflight)",
              Flow.parseWebhookInfo(Data(#"{"ok":false}"#.utf8)) == nil)

        // 8. Registry visibility (owner, 2026-08-22): /switchbot is listed
        // behind /commands but NOT one tap away in the Telegram menu.
        check("/commands lists /switchbot",
              ChatCommandRegistry.commandsListText().contains("/switchbot — "))
        check("switchbot is NOT in the Telegram menu",
              !ChatCommandRegistry.menuCommands.map(\.command).contains("switchbot"))

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        if failures > 0 { throw ExitCode(1) }
    }
}

/// Minimal deterministic RNG (splitmix64) for pinning code generation.
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private struct ConstantRNG: RandomNumberGenerator {
    let value: UInt64
    mutating func next() -> UInt64 { value }
}
