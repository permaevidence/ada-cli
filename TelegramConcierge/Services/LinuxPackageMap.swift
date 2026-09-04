import Foundation

/// The ONLY place Linux package names live (plan §4.7): the quick setup's
/// toolchain row and the regular wizard's Linux step both read it. Pure so
/// the selftest pins every cell on macOS too.
enum LinuxPackageMap {
    static let managers = ["apt-get", "dnf", "pacman"]

    /// Argument shape per manager, before the package names.
    static func installArgs(for manager: String) -> [String] {
        switch manager {
        case "apt-get": return ["install", "-y"]
        case "dnf": return ["install", "-y"]
        case "pacman": return ["-S", "--noconfirm", "--needed"]
        default: return ["install", "-y"]
        }
    }

    /// Logical name → distribution package.
    static func package(_ logical: String, manager: String) -> String {
        switch (logical, manager) {
        case ("poppler", "pacman"): return "poppler"
        case ("poppler", _): return "poppler-utils"
        case ("imagemagick", "dnf"): return "ImageMagick"
        case ("imagemagick", _): return "imagemagick"
        case ("ffmpeg", "dnf"): return "ffmpeg-free"
        case ("ffmpeg", _): return "ffmpeg"
        case ("pandoc", _): return "pandoc"
        case ("libreoffice", "pacman"): return "libreoffice-fresh"
        case ("libreoffice", _): return "libreoffice"
        case ("pip", "pacman"): return "python-pip"
        case ("pip", _): return "python3-pip"
        default: return logical
        }
    }

    /// The quick setup's full mandatory install for one manager, in order.
    static let mandatoryLogical = ["poppler", "imagemagick", "ffmpeg", "pandoc", "libreoffice"]

    static func mandatoryPackages(manager: String) -> [String] {
        mandatoryLogical.map { package($0, manager: manager) }
    }

    /// `sudo <manager> <args> <packages>` argument vector (after `sudo`).
    static func installCommand(manager: String, managerPath: String, packages: [String]) -> [String] {
        [managerPath] + installArgs(for: manager) + packages
    }
}
