import ArgumentParser
import Foundation

/// Self-update from the public release CDN — the same artifacts the curl
/// installer uses. Downloads the tarball for this platform, verifies its
/// SHA-256 against the manifest, and swaps the installed binary + resource
/// bundle in place (with sudo when the install directory needs it).
/// The download/verify/swap core lives in UpgradeService, shared with the
/// `/upgrade` chat command.
struct Upgrade: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Update Ada CLI to the latest published release.",
        aliases: ["update"]
    )

    @Flag(name: [.customShort("y"), .long], help: "Do not ask for confirmation.")
    var yes = false

    func run() async throws {
        print("Checking for updates…")
        let update: UpgradeService.Update
        switch await UpgradeService.check() {
        case .unsupportedPlatform:
            print("✖ No prebuilt releases exist for this platform.")
            throw ExitCode(1)
        case .failed(let reason):
            print("✖ Could not fetch the release manifest: \(reason)")
            throw ExitCode(1)
        case .upToDate(let version):
            print("✔ Already up to date (\(version)).")
            return
        case .noBuildForPlatform(let version, let platform):
            print("✖ Release \(version) has no build for \(platform) (yet).")
            throw ExitCode(1)
        case .manifestOlder(let current, let manifest):
            print("⚠ The release feed serves \(manifest), older than the installed \(current) — a release is probably still publishing. Not downgrading; try again in a few minutes.")
            return
        case .available(let available):
            update = available
        }

        if adaCLIVersion.hasSuffix("-dev") {
            print("⚠ This is a source build (\(adaCLIVersion)) — upgrading replaces it with the prebuilt release \(update.version).")
        } else {
            print("Update available: \(adaCLIVersion) → \(update.version)")
        }
        if !yes {
            print("Install? [y/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Cancelled.")
                return
            }
        }

        do {
            try await UpgradeService.downloadAndInstall(update, allowSudo: true) { print($0) }
        } catch {
            print("✖ \(error.localizedDescription)")
            throw ExitCode(1)
        }
        print("✔ Ada CLI updated to \(update.version).")
    }
}
