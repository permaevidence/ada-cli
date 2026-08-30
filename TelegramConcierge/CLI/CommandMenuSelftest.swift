import ArgumentParser
import Foundation

/// Hidden deterministic test pinning the chat command catalog contract
/// (owner, 2026-08-21): the Telegram "/" menu stays trimmed to the five
/// everyday commands, /commands lists every public command and NONE of the
/// power/owner commands, and the terminal /help block derives from the same
/// table. Pure static checks on ChatCommandRegistry — no storage touched.
struct CommandMenuSelftest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__command-menu-selftest",
        abstract: "Internal: verify the chat command registry, Telegram menu and /commands listing.",
        shouldDisplay: false
    )

    func run() throws {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        let commands = ChatCommandRegistry.commands
        let names = commands.map(\.name)

        // 1. The trimmed menu: exactly the five everyday commands, in order,
        // with /commands as the discoverable index to the rest.
        let menu = ChatCommandRegistry.menuCommands.map(\.command)
        check("menu is exactly stop, status, prune, upgrade, commands",
              menu == ["stop", "status", "prune", "upgrade", "commands"],
              menu.joined(separator: ", "))
        check("deleteuserdata is NOT one tap away in the menu",
              !menu.contains("deleteuserdata"))
        check("menu descriptions are non-empty",
              ChatCommandRegistry.menuCommands.allSatisfy { !$0.description.isEmpty })

        // 2. Registry hygiene: no duplicates, every category renders.
        check("no duplicate command names", Set(names).count == names.count)
        check("every command's category is in the rendered category list",
              commands.allSatisfy { ChatCommandRegistry.categories.contains($0.category) })
        check("every category has at least one member",
              ChatCommandRegistry.categories.allSatisfy { cat in
                  commands.contains { $0.category == cat }
              })

        // 3. /commands lists every public command exactly once.
        let listing = ChatCommandRegistry.commandsListText()
        for name in names {
            check("/commands lists /\(name)", listing.contains("/\(name) — "))
        }

        // 4. …and none of the power/owner commands (decided 2026-08-21:
        // they keep working but stay out of the regular-user listing).
        for hidden in ["/spend", "/more1", "/more5", "/more10", "/hide", "/show",
                       "/transcribe", "/riavvia", "/pulisci", "/llm", "/attach", "/quit"] {
            check("/commands does not reveal \(hidden)", !listing.contains(hidden))
        }

        // 5. Terminal /help derives one line per public command, carrying
        // both the invocation and the description.
        let helpLines = ChatCommandRegistry.terminalHelpLines()
        check("terminal help has one line per command", helpLines.count == commands.count)
        check("terminal help lines carry invocation + description",
              zip(helpLines, commands).allSatisfy { line, cmd in
                  line.contains("/\(cmd.name)") && line.contains(cmd.description)
              })

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        if failures > 0 { throw ExitCode(1) }
    }
}
