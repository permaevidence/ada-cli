import ArgumentParser
import Foundation

/// Hidden deterministic test of the userdata toolchain installer
/// (UserdataToolchain.swift): missing-tool detection, redirected-apt
/// invocation shape, SYNTHETIC base-status closure resolution (full
/// dependency bundling), base-package extraction refusal, extraction,
/// alternatives-aware wrapper generation with the ImageMagick env exports,
/// LibreOffice relocation (rc rewriting, registry layer, program-dir lib
/// path, nogui fallback), version-probe enforcement, v1-wrapper prefix
/// rebuild, broken-wrapper self-repair, empty-closure honesty, cleanup,
/// idempotence, and marker-scoped removal. Everything runs against fake
/// apt-get/dpkg shell scripts in a temp root — no network, no real
/// packages, any platform.
struct ToolchainPrefixSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__toolchain-selftest",
        abstract: "Internal: verify the userdata toolchain installer against fakes.",
        shouldDisplay: false
    )

    func run() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("ada-toolchain-selftest-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        /// True when the pid no longer runs. An unreaped ZOMBIE counts as
        /// gone: in CI containers nobody reaps orphans, so kill(pid, 0)
        /// keeps succeeding on a corpse — that false "alive" broke the
        /// tree-kill check on Linux CI (run 33254829140).
        func processGone(_ pid: Int32) -> Bool {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            #if os(Linux)
            if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat",
                                      encoding: .utf8),
               let paren = stat.range(of: ") "),
               stat[paren.upperBound...].hasPrefix("Z") {
                return true
            }
            #endif
            return false
        }
        func waitGone(_ pid: Int32, seconds: TimeInterval = 3) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if processGone(pid) { return true }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return processGone(pid)
        }

        func writeScript(_ url: URL, _ body: String) throws {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func fakeBinary(_ url: URL, exit code: Int = 0) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try writeScript(url, "#!/bin/sh\necho fake-tool 1.0\nexit \(code)\n")
        }

        // Shared fakes -------------------------------------------------
        let fakeDir = tempRoot.appendingPathComponent("fakes")
        try fm.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        let aptLog = tempRoot.appendingPathComponent("apt.log")
        let dpkgLog = tempRoot.appendingPathComponent("dpkg.log")
        let payload = tempRoot.appendingPathComponent("payload")
        let loPayload = tempRoot.appendingPathComponent("lo-payload")

        let fakeApt = fakeDir.appendingPathComponent("apt-get")
        try writeScript(fakeApt, """
        #!/bin/sh
        echo "$@" >> "\(aptLog.path)"
        cache=""
        for a in "$@"; do case "$a" in Dir::Cache=*) cache="${a#Dir::Cache=}";; esac; done
        cmd=""; last=""; targets=""; sim=0
        for a in "$@"; do
            case "$a" in update|install|download) if [ -z "$cmd" ]; then cmd="$a"; fi;; esac
            case "$a" in --simulate|-s) sim=1;; esac
            case "$a" in poppler-utils|imagemagick|ffmpeg|pandoc|libreoffice*) targets="$targets $a";; esac
            last="$a"
        done
        if [ "$sim" = 1 ]; then
            case "$targets" in *-nogui*)
                if [ "${FAKE_APT_NOGUI_MISSING:-0}" = "1" ]; then exit 100; fi;;
            esac
            exit 0
        fi
        v="${FAKE_REPO_VERSION:-1.0}"
        if [ "$cmd" = "install" ] && [ "${FAKE_APT_EMPTY:-0}" != "1" ]; then
            mkdir -p "$cache/archives"
            touch "$cache/archives/fake_${v}_all.deb"
            case "$targets" in *libreoffice*)
                touch "$cache/archives/libreoffice-writer_${v}_all.deb";;
            esac
            if [ "${FAKE_APT_ADD_LIBC:-0}" = "1" ]; then
                touch "$cache/archives/libc6_2.39-0ubuntu8_arm64.deb"
            fi
        fi
        uris=0
        for a in "$@"; do if [ "$a" = "--print-uris" ]; then uris=1; fi; done
        if [ "$cmd" = "download" ] && [ "$uris" = 1 ]; then
            for a in "$@"; do
                case "$a" in -*|*::*|download) continue;; esac
                echo "'http://repo/pool/${a}_${v}_all.deb' ${a}_${v}_all.deb 100 SHA256:abc"
            done
            exit 0
        fi
        if [ "$cmd" = "download" ]; then
            if [ "${FAKE_APT_NO_DOWNLOAD:-0}" = "1" ]; then exit 100; fi
            # only the conventional soname-derived name "libblas3" exists
            if [ "$last" = "libblas3" ]; then
                touch "./${last}_1.0_all.deb"
            else
                exit 100
            fi
        fi
        exit "${FAKE_APT_EXIT:-0}"
        """)
        let fakeDpkg = fakeDir.appendingPathComponent("dpkg")
        try writeScript(fakeDpkg, """
        #!/bin/sh
        echo "$@" >> "\(dpkgLog.path)"
        if [ "$1" = "--compare-versions" ]; then
            # lexicographic is enough for the fixtures (1.0 vs 2.0)
            awk -v a="$2" -v b="$4" 'BEGIN { exit (a < b) ? 0 : 1 }'
            exit $?
        fi
        prefix="$3"
        mkdir -p "$prefix"
        case "$2" in
        *libblas3*)
            # library package: provides the alternatives-style subdir
            mkdir -p "$prefix/usr/lib/x86_64-linux-gnu/blas"
            : > "$prefix/usr/lib/x86_64-linux-gnu/blas/libblas.so.3"
            ;;
        *libreoffice*)
            cp -R "\(loPayload.path)/." "$prefix/"
            ;;
        *)
            cp -R "\(payload.path)/." "$prefix/"
            ;;
        esac
        exit 0
        """)

        // A real-ish dpkg status: essential + required stanzas, the libc
        // family reachable only through the dependency closure, an ordinary
        // installed package that must NOT survive into the synthetic
        // status, and a ghost-essential (deinstall) that must be dropped.
        let statusFixture = """
        Package: dash
        Essential: yes
        Status: install ok installed
        Priority: required
        Version: 0.5.12

        Package: libc6
        Status: install ok installed
        Priority: optional
        Version: 2.39
        Depends: libgcc-s1

        Package: libgcc-s1
        Status: install ok installed
        Priority: optional
        Version: 14.2
        Depends: gcc-14-base (>= 14)

        Package: gcc-14-base
        Status: install ok installed
        Priority: optional
        Version: 14.2

        Package: poppler-utils
        Status: install ok installed
        Priority: optional
        Version: 24.02

        Package: ghost-essential
        Status: deinstall ok config-files
        Essential: yes
        Version: 1.0
        """
        let statusFile = tempRoot.appendingPathComponent("dpkg-status")
        try statusFixture.write(to: statusFile, atomically: true, encoding: .utf8)

        // Payload: what "extraction" produces — poppler five, ImageMagick
        // im6-suffixed trio (the alternatives wrinkle), ffmpeg pair, plus
        // the IM module/config dirs the wrappers must export.
        for tool in ["pdftotext", "pdftoppm", "pdfinfo", "pdfseparate", "pdfunite",
                     "ffprobe"] {
            try fakeBinary(payload.appendingPathComponent("usr/bin/\(tool)"))
        }
        // ffmpeg simulates the field bug on demand: with
        // FAKE_FFMPEG_NEEDS_BLAS=1 it dies exactly like a binary missing
        // libblas.so.3 until the blas provider subdir exists in the prefix.
        let ffmpegURL = payload.appendingPathComponent("usr/bin/ffmpeg")
        try fm.createDirectory(at: ffmpegURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try writeScript(ffmpegURL, """
        #!/bin/sh
        if [ "${FAKE_FFMPEG_NEEDS_BLAS:-0}" = "1" ] \\
           && [ ! -f "$(dirname "$0")/../lib/x86_64-linux-gnu/blas/libblas.so.3" ]; then
            echo "ffmpeg: error while loading shared libraries: libblas.so.3: cannot open shared object file: No such file or directory" >&2
            exit 127
        fi
        echo fake-tool 1.0
        exit 0
        """)
        for tool in ["convert", "identify", "mogrify"] {
            try fakeBinary(payload.appendingPathComponent("usr/bin/\(tool)-im6.q16"))
        }
        let codersRel = "usr/lib/x86_64-linux-gnu/ImageMagick-6.9.12/modules-Q16/coders"
        try fm.createDirectory(at: payload.appendingPathComponent(codersRel),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: payload.appendingPathComponent("etc/ImageMagick-6"),
                               withIntermediateDirectories: true)

        // LibreOffice payload: soffice script (answers --version AND the
        // real conversion probe — a txt→PDF into --outdir), rc files with
        // the hardcoded paths the relocation must rewrite, and the shipped
        // registry that the postinst (never run under dpkg -x) would have
        // copied to /etc.
        let sofficeURL = loPayload.appendingPathComponent("usr/lib/libreoffice/program/soffice")
        try fm.createDirectory(at: sofficeURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try writeScript(sofficeURL, """
        #!/bin/sh
        outdir=""; src=""; prev=""
        for a in "$@"; do
            if [ "$prev" = "--outdir" ]; then outdir="$a"; fi
            prev="$a"; src="$a"
        done
        if [ -n "$outdir" ] && [ "${FAKE_SOFFICE_NO_PDF:-0}" != "1" ]; then
            base=$(basename "$src")
            echo fakepdf > "$outdir/${base%.*}.pdf"
        fi
        echo "LibreOffice 24.2 fake"
        exit 0
        """)
        try """
        [Bootstrap]
        BRAND_BASE_DIR=file:///usr/lib/libreoffice
        CONFIGURATION_LAYERS=xcsxcu:${BRAND_BASE_DIR}/share/registry res:${BRAND_BASE_DIR}/share/registry xcsxcu:/etc/libreoffice/registry
        URE_MORE_SERVICES=file:///usr/lib/libreoffice/program/services
        """.write(to: loPayload.appendingPathComponent("usr/lib/libreoffice/program/fundamentalrc"),
                  atomically: true, encoding: .utf8)
        try """
        [Bootstrap]
        UserInstallation=$SYSUSERCONFIG/libreoffice/4
        """.write(to: loPayload.appendingPathComponent("usr/lib/libreoffice/program/bootstraprc"),
                  atomically: true, encoding: .utf8)
        let registryDir = loPayload.appendingPathComponent("usr/lib/libreoffice/share/.registry")
        try fm.createDirectory(at: registryDir, withIntermediateDirectories: true)
        try "reg".write(to: registryDir.appendingPathComponent("main.xcd"),
                        atomically: true, encoding: .utf8)
        // The deb also ships /etc/libreoffice/registry — but with ONLY
        // *.sample files (the real .xcd copies are a postinst job). The
        // field bug was preferring this decoy; relocation must skip it.
        let etcRegistry = loPayload.appendingPathComponent("etc/libreoffice/registry")
        try fm.createDirectory(at: etcRegistry, withIntermediateDirectories: true)
        try "sample".write(to: etcRegistry.appendingPathComponent("oo-ldap.xcd.sample"),
                           atomically: true, encoding: .utf8)

        func scenario(_ name: String) throws -> (root: URL, bin: URL, sys: URL) {
            let base = tempRoot.appendingPathComponent(name)
            let root = base.appendingPathComponent("toolchain")
            let bin = base.appendingPathComponent("wrapperbin")
            let sys = base.appendingPathComponent("sysbin")
            for dir in [root, bin, sys] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            setenv("BRIGLIA_TOOLCHAIN_ROOT", root.path, 1)
            setenv("BRIGLIA_TOOLCHAIN_BIN", bin.path, 1)
            setenv("BRIGLIA_TOOLCHAIN_PATH", "\(bin.path):\(sys.path)", 1)
            setenv("BRIGLIA_TOOLCHAIN_APT", fakeApt.path, 1)
            setenv("BRIGLIA_TOOLCHAIN_DPKG", fakeDpkg.path, 1)
            setenv("BRIGLIA_TOOLCHAIN_DPKG_STATUS", statusFile.path, 1)
            for knob in ["FAKE_APT_EMPTY", "FAKE_APT_EXIT", "FAKE_APT_NOGUI_MISSING",
                         "FAKE_APT_ADD_LIBC", "FAKE_APT_NO_DOWNLOAD",
                         "FAKE_FFMPEG_NEEDS_BLAS", "FAKE_SOFFICE_NO_PDF",
                         "FAKE_REPO_VERSION", "BRIGLIA_TOOLCHAIN_FAULT"] {
                unsetenv(knob)
            }
            try? fm.removeItem(at: aptLog)
            try? fm.removeItem(at: dpkgLog)
            return (root, bin, sys)
        }

        let coreTools = ["pdftotext", "pdftoppm", "pdfinfo", "pdfseparate", "pdfunite",
                         "convert", "identify", "mogrify", "ffmpeg", "ffprobe"]

        // 0. Pure functions: synthetic status, base-package rules ---------
        do {
            let synthetic = UserdataToolchain.makeSyntheticStatus(realStatusText: statusFixture)
            check("synthetic status keeps essential + required stanzas",
                  synthetic.contains("Package: dash"))
            check("synthetic status keeps the libc family via hardcode + dep closure",
                  synthetic.contains("Package: libc6")
                  && synthetic.contains("Package: libgcc-s1")
                  && synthetic.contains("Package: gcc-14-base"))
            check("synthetic status DROPS ordinary installed packages (full-closure core)",
                  !synthetic.contains("Package: poppler-utils"))
            check("synthetic status drops deinstalled stanzas even if essential",
                  !synthetic.contains("Package: ghost-essential"))
            check("base-package rules cover the loader-coupled set only",
                  UserdataToolchain.isAlwaysSystemPackage("libc6")
                  && UserdataToolchain.isAlwaysSystemPackage("libc-bin")
                  && UserdataToolchain.isAlwaysSystemPackage("libgcc-s1")
                  && UserdataToolchain.isAlwaysSystemPackage("libcrypt1")
                  && UserdataToolchain.isAlwaysSystemPackage("libc6-dev")
                  && UserdataToolchain.isAlwaysSystemPackage("gcc-14-base")
                  && !UserdataToolchain.isAlwaysSystemPackage("libpoppler134")
                  && !UserdataToolchain.isAlwaysSystemPackage("libstdc++6"))
        }

        // 1. Full install on a bare system -----------------------------
        do {
            let (root, bin, _) = try scenario("full")
            let before = UserdataToolchain.status()
            check("bare system: all core tools missing",
                  before.filter { !$0.optional }.allSatisfy { !$0.present })
            check("status marks optional components",
                  before.contains { $0.name == "soffice" && $0.optional }
                  && before.contains { $0.name == "pandoc" && $0.optional })

            let report = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("full install reports ok", report.ok, report.failures.joined(separator: "; "))
            check("full install wraps every tool",
                  Set(report.wrappers) == Set(coreTools),
                  report.wrappers.joined(separator: ","))

            let convert = try String(contentsOf: bin.appendingPathComponent("convert"),
                                     encoding: .utf8)
            check("convert wrapper targets the im6-suffixed binary",
                  convert.contains("convert-im6.q16"))
            check("convert wrapper exports ImageMagick module + config paths",
                  convert.contains("MAGICK_CODER_MODULE_PATH=")
                  && convert.contains(codersRel)
                  && convert.contains("MAGICK_CONFIGURE_PATH=")
                  && convert.contains("etc/ImageMagick-6"))
            do {
                // Rename plan §4.5.9: wrappers written by the previous identity
                // (and rebased, not rewritten, by `briglia migrate`) keep the
                // legacy marker and must stay OURS forever.
                let legacy = root.appendingPathComponent("legacy-marker-wrapper").path
                try "#!/bin/sh\n\(UserdataToolchain.legacyWrapperMarker)\nexec /x \"$@\"\n"
                    .write(toFile: legacy, atomically: true, encoding: .utf8)
                let foreign = root.appendingPathComponent("foreign-wrapper").path
                try "#!/bin/sh\n# someone else's wrapper\nexec /x \"$@\"\n"
                    .write(toFile: foreign, atomically: true, encoding: .utf8)
                check("legacy-marker wrapper is recognized as ours",
                      UserdataToolchain.isOurWrapper(legacy))
                check("unmarked wrapper is not ours", !UserdataToolchain.isOurWrapper(foreign))
                check("current marker differs from the legacy one and both are accepted",
                      UserdataToolchain.wrapperMarker != UserdataToolchain.legacyWrapperMarker
                      && UserdataToolchain.acceptedWrapperMarkers.count == 2)
            }
            check("wrapper carries markers and the arch lib dir",
                  convert.contains(UserdataToolchain.wrapperMarker)
                  && convert.contains(UserdataToolchain.closureMarker)
                  && convert.contains("x86_64-linux-gnu"))

            let aptCalls = (try? String(contentsOf: aptLog, encoding: .utf8)) ?? ""
            let baseStatusPath = root.appendingPathComponent("apt/state/base-status").path
            check("apt state fully redirected + resolves against the synthetic base status",
                  aptCalls.contains("Dir::State=\(root.path)")
                  && aptCalls.contains("Dir::State::lists=\(root.path)")
                  && aptCalls.contains("Dir::Cache=\(root.path)")
                  && aptCalls.contains("Dir::State::status=\(baseStatusPath)")
                  && aptCalls.contains("Debug::NoLocking=1"))
            let writtenSynthetic = (try? String(contentsOfFile: baseStatusPath,
                                                encoding: .utf8)) ?? ""
            check("synthetic base status written for apt (real status never used)",
                  writtenSynthetic.contains("Package: dash")
                  && !writtenSynthetic.contains("Package: poppler-utils"))
            check("download used install --download-only with all targets",
                  aptCalls.contains("--download-only")
                  && aptCalls.contains("poppler-utils")
                  && aptCalls.contains("imagemagick")
                  && aptCalls.contains("ffmpeg")
                  && !aptCalls.contains("pandoc")
                  && !aptCalls.contains("libreoffice"))

            check("lists and archives cleaned after success",
                  !fm.fileExists(atPath: root.appendingPathComponent("apt/lists").path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("apt/cache").path))

            let after = UserdataToolchain.status()
            check("status after install: all core tools present from prefix",
                  after.filter { !$0.optional }
                       .allSatisfy { $0.present && $0.source == "prefix" })

            // Idempotence: second run probes the wrappers and downloads nothing.
            try? fm.removeItem(at: aptLog)
            let again = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("second run is a clean no-op",
                  again.ok && again.wrappers.isEmpty
                  && again.notes.contains(where: { $0.contains("nothing to install") })
                  && !fm.fileExists(atPath: aptLog.path))

            // Marker-scoped removal: foreign files survive. The lock file
            // lives BESIDE the root, so removal cannot unlink a held lock
            // out from under a concurrent operation (Codex round 3 #3).
            let foreign = bin.appendingPathComponent("pandoc")
            try writeScript(foreign, "#!/bin/sh\nexit 0\n")
            let removal = UserdataToolchain.removeAll()
            check("removeAll removes wrappers + prefix, keeps foreign files + sibling lock",
                  removal.ok
                  && removal.removed.contains("convert")
                  && removal.removed.contains("(prefix)")
                  && fm.fileExists(atPath: foreign.path)
                  && !fm.fileExists(atPath: bin.appendingPathComponent("convert").path)
                  && !fm.fileExists(atPath: root.path)
                  && fm.fileExists(atPath: root.path + ".lock"),
                  removal.failure ?? "")
        }

        // 2. Partially equipped system: only the missing package downloads
        do {
            let (_, _, sys) = try scenario("partial")
            for tool in ["pdftotext", "pdftoppm", "pdfinfo", "pdfseparate",
                         "pdfunite", "ffmpeg", "ffprobe"] {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            let report = UserdataToolchain.installSync(includePandoc: false) { _ in }
            let aptCalls = (try? String(contentsOf: aptLog, encoding: .utf8)) ?? ""
            check("partial system targets only imagemagick",
                  report.ok
                  && report.alreadyPresent.contains("poppler-utils")
                  && report.alreadyPresent.contains("ffmpeg")
                  && report.installedPackages == ["imagemagick"]
                  && aptCalls.contains("imagemagick")
                  && !aptCalls.contains("poppler-utils"), report.failures.joined(separator: ";"))
            check("partial status: mixed sources",
                  UserdataToolchain.status().contains {
                      $0.name == "pdftotext" && $0.source == "system" }
                  && UserdataToolchain.status().contains {
                      $0.name == "convert" && $0.source == "prefix" })
        }

        // 3. Everything present: apt never runs ------------------------
        do {
            let (_, _, sys) = try scenario("complete")
            for tool in coreTools {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            let report = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("complete system: no-op without touching apt",
                  report.ok && report.installedPackages.isEmpty
                  && !fm.fileExists(atPath: aptLog.path)
                  && report.notes.contains(where: { $0.contains("nothing to install") }))
        }

        // 4. Version-probe failure removes the broken wrapper ----------
        do {
            let (_, bin, sys) = try scenario("probe")
            for tool in ["pdftotext", "pdftoppm", "pdfinfo", "pdfseparate",
                         "pdfunite", "ffmpeg", "ffprobe", "convert", "mogrify"] {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            // only identify missing; its payload binary is broken
            try fakeBinary(payload.appendingPathComponent("usr/bin/identify-im6.q16"),
                           exit: 1)
            defer { try? fakeBinary(payload.appendingPathComponent("usr/bin/identify-im6.q16")) }
            let report = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("failed probe reported and wrapper removed",
                  !report.ok
                  && report.failures.contains(where: { $0.contains("identify") })
                  && !fm.fileExists(atPath: bin.appendingPathComponent("identify").path))
        }

        // 5. Empty closure while tools are missing: honest failure -----
        do {
            _ = try scenario("empty")
            setenv("FAKE_APT_EMPTY", "1", 1)
            let report = UserdataToolchain.installSync(includePandoc: false) { _ in }
            unsetenv("FAKE_APT_EMPTY")
            check("empty download with missing tools fails honestly",
                  !report.ok
                  && report.failures.contains(where: { $0.contains("downloaded nothing") }))
        }

        // 6. pandoc: only on request -----------------------------------
        do {
            let (_, _, sys) = try scenario("pandoc")
            for tool in coreTools {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            try fakeBinary(payload.appendingPathComponent("usr/bin/pandoc"))
            let report = UserdataToolchain.installSync(includePandoc: true) { _ in }
            let aptCalls = (try? String(contentsOf: aptLog, encoding: .utf8)) ?? ""
            check("pandoc installs only with the flag, alone",
                  report.ok && report.installedPackages == ["pandoc"]
                  && report.wrappers == ["pandoc"]
                  && aptCalls.contains("pandoc")
                  && !aptCalls.contains("imagemagick"))
        }

        // 7. soname parsing + package-name candidates (pure functions) ---
        check("missingSoname parses the loader error",
              UserdataToolchain.missingSoname(
                  in: "ffmpeg: error while loading shared libraries: "
                      + "libblas.so.3: cannot open shared object file")
              == "libblas.so.3"
              && UserdataToolchain.missingSoname(in: "segmentation fault") == nil)
        check("soname → Debian package-name candidates incl. noble t64 renames",
              UserdataToolchain.sonamePackageCandidates("libblas.so.3")
              == ["libblas3", "libblas3t64", "libblas-3", "libblas"]
              && UserdataToolchain.sonamePackageCandidates("libclucene-core.so.1")
                  .contains("libclucene-core1t64"))

        // 8. runtime-library recovery: apt's closure omitted a virtual-
        //    provided library (the Pixel libblas field bug) — the probe
        //    failure must trigger fetch → extract → wrapper refresh → pass.
        do {
            let (_, bin, sys) = try scenario("recover")
            for tool in ["pdftotext", "pdftoppm", "pdfinfo", "pdfseparate",
                         "pdfunite", "convert", "identify", "mogrify", "ffprobe"] {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            setenv("FAKE_FFMPEG_NEEDS_BLAS", "1", 1)
            let report = UserdataToolchain.installSync(includePandoc: false) { _ in }
            unsetenv("FAKE_FFMPEG_NEEDS_BLAS")
            let aptCalls = (try? String(contentsOf: aptLog, encoding: .utf8)) ?? ""
            let wrapperText = (try? String(
                contentsOf: bin.appendingPathComponent("ffmpeg"),
                encoding: .utf8)) ?? ""
            check("probe failure recovers by fetching the soname's package",
                  report.ok
                  && report.notes.contains(where: {
                      $0.contains("libblas3") && $0.contains("libblas.so.3") })
                  && aptCalls.contains("download libblas3")
                  && fm.fileExists(atPath: bin.appendingPathComponent("ffmpeg").path),
                  report.failures.joined(separator: "; "))
            check("refreshed wrapper reaches the alternatives lib subdir",
                  wrapperText.contains("x86_64-linux-gnu/blas"))
        }

        // 9. recovery impossible: honest failure naming the soname --------
        do {
            let (_, bin, sys) = try scenario("norecover")
            for tool in ["pdftotext", "pdftoppm", "pdfinfo", "pdfseparate",
                         "pdfunite", "convert", "identify", "mogrify", "ffprobe"] {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            setenv("FAKE_FFMPEG_NEEDS_BLAS", "1", 1)
            setenv("FAKE_APT_NO_DOWNLOAD", "1", 1)
            let report = UserdataToolchain.installSync(includePandoc: false) { _ in }
            unsetenv("FAKE_FFMPEG_NEEDS_BLAS")
            unsetenv("FAKE_APT_NO_DOWNLOAD")
            check("unfetchable library fails honestly, wrapper removed",
                  !report.ok
                  && report.failures.contains(where: {
                      $0.contains("libblas.so.3") })
                  && !fm.fileExists(atPath: bin.appendingPathComponent("ffmpeg").path))
        }

        // 10. LibreOffice: nogui packages, relocation, special wrapper ----
        do {
            let (root, bin, sys) = try scenario("libreoffice")
            for tool in coreTools {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            let report = UserdataToolchain.installSync(includePandoc: false,
                                                       includeLibreOffice: true) { _ in }
            let aptCalls = (try? String(contentsOf: aptLog, encoding: .utf8)) ?? ""
            check("libreoffice installs the nogui trio after a simulate check",
                  report.ok
                  && report.installedPackages == ["libreoffice"]
                  && aptCalls.contains("--simulate")
                  && aptCalls.contains("libreoffice-writer-nogui")
                  && aptCalls.contains("libreoffice-impress-nogui"),
                  report.failures.joined(separator: "; "))
            let loDownload = aptCalls.split(separator: "\n").first {
                $0.contains("--download-only") && $0.contains("libreoffice-writer-nogui")
            }.map(String.init) ?? ""
            check("libreoffice downloads WITH recommends (conversion needs them)",
                  loDownload.contains("APT::Install-Recommends=true")
                  && !loDownload.contains("--no-install-recommends"),
                  loDownload)
            check("libreoffice wraps soffice + libreoffice",
                  Set(report.wrappers) == Set(["soffice", "libreoffice"]))

            let prefixLO = root.appendingPathComponent("prefix/usr/lib/libreoffice")
            let wrapper = (try? String(contentsOf: bin.appendingPathComponent("soffice"),
                                       encoding: .utf8)) ?? ""
            check("soffice wrapper: headless plugin, program-dir lib path, private profile",
                  wrapper.contains("SAL_USE_VCLPLUGIN=svp")
                  && wrapper.contains("\(prefixLO.path)/program")
                  && wrapper.contains("-env:UserInstallation=file://\(root.path)/louser")
                  && wrapper.contains(UserdataToolchain.closureMarker))

            let fund = (try? String(
                contentsOf: prefixLO.appendingPathComponent("program/fundamentalrc"),
                encoding: .utf8)) ?? ""
            check("fundamentalrc relocated to the prefix",
                  fund.contains("BRAND_BASE_DIR=file://\(prefixLO.path)")
                  && !fund.contains("file:///usr/lib/libreoffice")
                  && !fund.contains("\u{1}"))
            check("configuration layers point at the shipped share/.registry, not the sample-only /etc decoy",
                  fund.contains("\(prefixLO.path)/share/.registry")
                  && !fund.contains("/etc/libreoffice/registry")
                  && !fund.contains(root.path + "/prefix" + root.path))
        }

        // 10b. LO probe is a REAL conversion: exit-0 soffice that produces
        //      no PDF must fail verification (the libclucene field mode —
        //      --version worked while conversions were broken)
        do {
            let (_, bin, sys) = try scenario("loprobe")
            for tool in coreTools {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            setenv("FAKE_SOFFICE_NO_PDF", "1", 1)
            let report = UserdataToolchain.installSync(includePandoc: false,
                                                       includeLibreOffice: true) { _ in }
            unsetenv("FAKE_SOFFICE_NO_PDF")
            check("conversion-less soffice fails its probe, wrappers removed",
                  !report.ok
                  && report.failures.contains(where: { $0.contains("no PDF") })
                  && !fm.fileExists(atPath: bin.appendingPathComponent("soffice").path)
                  && !fm.fileExists(atPath: bin.appendingPathComponent("libreoffice").path))
        }

        // 11. LibreOffice nogui fallback on images without the split ------
        do {
            let (_, _, sys) = try scenario("lofallback")
            for tool in coreTools {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            setenv("FAKE_APT_NOGUI_MISSING", "1", 1)
            let report = UserdataToolchain.installSync(includePandoc: false,
                                                       includeLibreOffice: true) { _ in }
            unsetenv("FAKE_APT_NOGUI_MISSING")
            let aptCalls = (try? String(contentsOf: aptLog, encoding: .utf8)) ?? ""
            check("nogui unavailable → falls back to the full packages, noted",
                  report.ok
                  && report.notes.contains(where: { $0.contains("nogui LibreOffice packages unavailable") })
                  && aptCalls.contains("libreoffice-calc libreoffice-impress"),
                  report.failures.joined(separator: "; "))
        }

        // 12. base packages are never extracted into the prefix -----------
        do {
            let (_, _, sys) = try scenario("baseskip")
            for tool in ["pdftotext", "pdftoppm", "pdfinfo", "pdfseparate",
                         "pdfunite", "ffmpeg", "ffprobe"] {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            setenv("FAKE_APT_ADD_LIBC", "1", 1)
            let report = UserdataToolchain.installSync(includePandoc: false) { _ in }
            unsetenv("FAKE_APT_ADD_LIBC")
            let dpkgCalls = (try? String(contentsOf: dpkgLog, encoding: .utf8)) ?? ""
            check("a libc6 deb in the closure is skipped, disclosed, never extracted",
                  report.ok
                  && !dpkgCalls.contains("libc6")
                  && report.notes.contains(where: {
                      $0.contains("never bundled") && $0.contains("libc6") }),
                  report.failures.joined(separator: "; "))
        }

        // 13. v1 wrapper (pre self-contained closures) → prefix rebuild ---
        do {
            let (root, bin, sys) = try scenario("v1migrate")
            for tool in coreTools where tool != "pdftotext" {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            // a working v1 wrapper + a prefix with old system-leaning content
            try writeScript(bin.appendingPathComponent("pdftotext"), """
            #!/bin/sh
            \(UserdataToolchain.wrapperMarker)
            echo fake-tool 1.0
            exit 0
            """)
            let junk = root.appendingPathComponent("prefix/usr/bin/old-junk")
            try fm.createDirectory(at: junk.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try "old".write(to: junk, atomically: true, encoding: .utf8)

            let report = UserdataToolchain.installSync(includePandoc: false) { _ in }
            let aptCalls = (try? String(contentsOf: aptLog, encoding: .utf8)) ?? ""
            let wrapper = (try? String(contentsOf: bin.appendingPathComponent("pdftotext"),
                                       encoding: .utf8)) ?? ""
            check("v1 wrapper triggers a rebuild: prefix wiped, closure re-downloaded",
                  report.ok
                  && report.installedPackages == ["poppler-utils"]
                  && aptCalls.contains("poppler-utils")
                  && !fm.fileExists(atPath: junk.path),
                  report.failures.joined(separator: "; "))
            check("rebuilt wrapper is marked self-contained",
                  wrapper.contains(UserdataToolchain.closureMarker))
        }

        // 13b. rebuild with LibreOffice: the staging build bakes prefix.new
        //      paths into the rc files; the commit swap must rebase them to
        //      the final prefix path (and the staging probe bin must never
        //      leak into the live prefix)
        do {
            let (root, bin, sys) = try scenario("lorebase")
            for tool in coreTools {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            let install = UserdataToolchain.installSync(includePandoc: false,
                                                        includeLibreOffice: true) { _ in }
            check("lo-rebase setup: initial install ok", install.ok,
                  install.failures.joined(separator: "; "))
            // v1 soffice wrapper forces a full prefix rebuild
            try writeScript(bin.appendingPathComponent("soffice"), """
            #!/bin/sh
            \(UserdataToolchain.wrapperMarker)
            exit 0
            """)
            let rebuilt = UserdataToolchain.installSync(includePandoc: false) { _ in }
            let fund = (try? String(
                contentsOf: root.appendingPathComponent(
                    "prefix/usr/lib/libreoffice/program/fundamentalrc"),
                encoding: .utf8)) ?? ""
            check("rebuild rebases LibreOffice rc files onto the final prefix",
                  rebuilt.ok
                  && fund.contains("\(root.path)/prefix/usr/lib/libreoffice")
                  && !fund.contains("prefix.new")
                  && !fm.fileExists(atPath: root.appendingPathComponent("prefix/.ada-probe-bin").path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("prefix.new").path),
                  rebuilt.failures.joined(separator: "; ") + " fund=" + fund.prefix(200))
        }

        // 14. broken self-contained wrapper self-repairs on install -------
        do {
            let (_, bin, sys) = try scenario("repair")
            for tool in coreTools where tool != "ffmpeg" {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            // our wrapper, current generation, but its library vanished
            // (the post-purge Pixel poppler failure mode)
            try writeScript(bin.appendingPathComponent("ffmpeg"), """
            #!/bin/sh
            \(UserdataToolchain.wrapperMarker)
            \(UserdataToolchain.closureMarker)
            echo "ffmpeg: error while loading shared libraries: libwhatever.so.9: cannot open shared object file" >&2
            exit 127
            """)
            let report = UserdataToolchain.installSync(includePandoc: false) { _ in }
            let aptCalls = (try? String(contentsOf: aptLog, encoding: .utf8)) ?? ""
            let wrapper = (try? String(contentsOf: bin.appendingPathComponent("ffmpeg"),
                                       encoding: .utf8)) ?? ""
            check("broken wrapper is detected by its probe and reinstalled",
                  report.ok
                  && report.installedPackages == ["ffmpeg"]
                  && aptCalls.contains("ffmpeg")
                  && wrapper.contains("LD_LIBRARY_PATH"),
                  report.failures.joined(separator: "; "))
        }

        // 15. upgrade: manifest recording, staleness check, full rebuild ---
        check("deb filename parsing incl. URL-encoded epochs",
              UserdataToolchain.parseDebFilename("libpoppler134_24.02.0-1ubuntu9.9_arm64.deb")
                  .map { $0.name == "libpoppler134" && $0.version == "24.02.0-1ubuntu9.9" } == true
              && UserdataToolchain.parseDebFilename("libfoo_1%3a2.0_all.deb")?.version == "1:2.0"
              && UserdataToolchain.parseDebFilename("not-a-deb.txt") == nil)
        do {
            let (_, bin, _) = try scenario("upgrade")
            let install = UserdataToolchain.installSync(includePandoc: false) { _ in }
            let manifest = UserdataToolchain.loadManifest()
            check("install records extracted package versions in the manifest",
                  install.ok && manifest["fake"] == "1.0",
                  String(describing: manifest))

            try? fm.removeItem(at: aptLog)
            let current = UserdataToolchain.upgradeSync { _ in }
            let aptCurrent = (try? String(contentsOf: aptLog, encoding: .utf8)) ?? ""
            check("upgrade against a current repo is a no-op",
                  current.ok && current.wrappers.isEmpty
                  && current.notes.contains(where: { $0.contains("everything up to date") })
                  && !aptCurrent.contains("--download-only"),
                  current.failures.joined(separator: "; "))

            setenv("FAKE_REPO_VERSION", "2.0", 1)
            try? fm.removeItem(at: aptLog)
            let upgraded = UserdataToolchain.upgradeSync { _ in }
            unsetenv("FAKE_REPO_VERSION")
            let aptUpgraded = (try? String(contentsOf: aptLog, encoding: .utf8)) ?? ""
            check("stale repo triggers a self-contained rebuild and advances the manifest",
                  upgraded.ok
                  && !upgraded.wrappers.isEmpty
                  && upgraded.notes.contains(where: {
                      $0.contains("upgraded:") && $0.contains("fake 1.0 → 2.0") })
                  && aptUpgraded.contains("--download-only")
                  && UserdataToolchain.loadManifest()["fake"] == "2.0"
                  && fm.fileExists(atPath: bin.appendingPathComponent("pdftotext").path),
                  upgraded.failures.joined(separator: "; "))
        }

        // 16. transactional rebuild: an early failure (repo unreachable)
        //     must roll back — the working prefix, wrappers and manifest
        //     survive exactly as they were (Codex regression audit: the old
        //     code deleted the prefix FIRST, so any later failure destroyed
        //     a working toolchain)
        do {
            let (root, bin, _) = try scenario("txrollback")
            let install = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("tx setup: initial install ok", install.ok,
                  install.failures.joined(separator: "; "))
            let marker = root.appendingPathComponent("prefix/tx-old-marker")
            try "old".write(to: marker, atomically: true, encoding: .utf8)
            // force a rebuild whose apt update fails
            let v1Text = """
            #!/bin/sh
            \(UserdataToolchain.wrapperMarker)
            echo fake-tool 1.0
            exit 0

            """
            try writeScript(bin.appendingPathComponent("pdftotext"), v1Text)
            setenv("FAKE_APT_EXIT", "100", 1)
            let failed = UserdataToolchain.installSync(includePandoc: false) { _ in }
            unsetenv("FAKE_APT_EXIT")
            let restoredWrapper = (try? String(
                contentsOf: bin.appendingPathComponent("pdftotext"),
                encoding: .utf8)) ?? ""
            // With staging builds, an early failure never touches the
            // working toolchain at all — nothing to restore, and neither
            // staging nor the snapshot may linger.
            check("failed rebuild leaves the working toolchain untouched",
                  !failed.ok
                  && fm.fileExists(atPath: marker.path)
                  && restoredWrapper == v1Text
                  && UserdataToolchain.loadManifest()["fake"] == "1.0"
                  && !fm.fileExists(atPath: root.appendingPathComponent("prefix.previous").path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("prefix.new").path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("tx").path)
                  && failed.notes.contains(where: {
                      $0.contains("nothing was changed") }),
                  failed.failures.joined(separator: "; "))
        }

        // 16b. transactional rebuild: a LATE failure (probe after extraction)
        //      also rolls back — including wrappers the probe loop removed
        do {
            let (root, bin, _) = try scenario("txprobe")
            let install = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("tx-probe setup: initial install ok", install.ok,
                  install.failures.joined(separator: "; "))
            let marker = root.appendingPathComponent("prefix/tx-old-marker")
            try "old".write(to: marker, atomically: true, encoding: .utf8)
            try writeScript(bin.appendingPathComponent("pdftotext"), """
            #!/bin/sh
            \(UserdataToolchain.wrapperMarker)
            echo fake-tool 1.0
            exit 0
            """)
            // the rebuild extracts a broken identify → its probe fails late
            try fakeBinary(payload.appendingPathComponent("usr/bin/identify-im6.q16"),
                           exit: 1)
            defer { try? fakeBinary(payload.appendingPathComponent("usr/bin/identify-im6.q16")) }
            setenv("FAKE_REPO_VERSION", "2.0", 1)
            let failed = UserdataToolchain.installSync(includePandoc: false) { _ in }
            unsetenv("FAKE_REPO_VERSION")
            check("late probe failure aborts the rebuild with the toolchain untouched",
                  !failed.ok
                  && fm.fileExists(atPath: marker.path)
                  && fm.fileExists(atPath: bin.appendingPathComponent("identify").path)
                  && UserdataToolchain.loadManifest()["fake"] == "1.0"
                  && !fm.fileExists(atPath: root.appendingPathComponent("prefix.previous").path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("prefix.new").path),
                  failed.failures.joined(separator: "; "))
        }

        // 16c. crash mid-rebuild: leftover backup is authoritative — the
        //      next run discards the staging prefix and restores it
        do {
            let (root, _, _) = try scenario("txrecover")
            let install = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("tx-recover setup: initial install ok", install.ok,
                  install.failures.joined(separator: "; "))
            let prefix = root.appendingPathComponent("prefix")
            let backup = root.appendingPathComponent("prefix.previous")
            try fm.moveItem(at: prefix, to: backup)
            let staging = prefix.appendingPathComponent("staging-junk")
            try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
            try "junk".write(to: staging, atomically: true, encoding: .utf8)
            let second = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("interrupted rebuild recovered from the backup on the next run",
                  second.ok
                  && second.notes.contains(where: { $0.contains("interrupted rebuild") })
                  && !fm.fileExists(atPath: backup.path)
                  && !fm.fileExists(atPath: staging.path)
                  && fm.fileExists(atPath: prefix.appendingPathComponent("usr/bin/pdftotext").path),
                  second.failures.joined(separator: "; "))
        }

        // 16d. crash AFTER the interrupted run already wrote new wrappers +
        //      manifest: recovery must restore all three pieces from the tx
        //      snapshot — prefix alone would leave a manifest claiming
        //      versions the restored binaries don't have (Codex round 2 #1)
        do {
            let (root, bin, _) = try scenario("txcrashlate")
            let install = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("tx-crash-late setup: initial install ok", install.ok,
                  install.failures.joined(separator: "; "))
            let originalWrapper = (try? String(
                contentsOf: bin.appendingPathComponent("pdftotext"),
                encoding: .utf8)) ?? ""

            // Reproduce the exact on-disk state of a rebuild that died right
            // before committing: tx snapshot written, prefix set aside,
            // staging prefix + NEW wrappers + NEW manifest already in place.
            let txWrappers = root.appendingPathComponent("tx/wrappers")
            try fm.createDirectory(at: txWrappers, withIntermediateDirectories: true)
            for entry in (try? fm.contentsOfDirectory(atPath: bin.path)) ?? [] {
                let source = bin.appendingPathComponent(entry)
                if UserdataToolchain.isOurWrapper(source.path) {
                    try fm.copyItem(at: source, to: txWrappers.appendingPathComponent(entry))
                }
            }
            try #"{"fake":"1.0"}"#.write(
                to: root.appendingPathComponent("tx/manifest.json"),
                atomically: true, encoding: .utf8)
            try fm.moveItem(at: root.appendingPathComponent("prefix"),
                            to: root.appendingPathComponent("prefix.previous"))
            try fm.createDirectory(at: root.appendingPathComponent("prefix"),
                                   withIntermediateDirectories: true)
            try writeScript(bin.appendingPathComponent("pdftotext"), """
            #!/bin/sh
            \(UserdataToolchain.wrapperMarker)
            \(UserdataToolchain.closureMarker)
            # WRITTEN BY THE INTERRUPTED RUN
            exit 1
            """)
            try writeScript(bin.appendingPathComponent("pandoc"), """
            #!/bin/sh
            \(UserdataToolchain.wrapperMarker)
            \(UserdataToolchain.closureMarker)
            exit 1
            """)
            try #"{"fake":"9.9"}"#.write(to: UserdataToolchain.manifestURL,
                                         atomically: true, encoding: .utf8)

            let second = UserdataToolchain.installSync(includePandoc: false) { _ in }
            let restoredWrapper = (try? String(
                contentsOf: bin.appendingPathComponent("pdftotext"),
                encoding: .utf8)) ?? ""
            check("late-crash recovery restores prefix + wrappers + manifest together",
                  second.ok
                  && second.notes.contains(where: { $0.contains("interrupted rebuild") })
                  && restoredWrapper == originalWrapper
                  && !fm.fileExists(atPath: bin.appendingPathComponent("pandoc").path)
                  && UserdataToolchain.loadManifest()["fake"] == "1.0"
                  && !fm.fileExists(atPath: root.appendingPathComponent("prefix.previous").path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("tx").path),
                  second.failures.joined(separator: "; ")
                  + " manifest=\(UserdataToolchain.loadManifest())")
        }

        // 16e. the COMMIT POINT is the durable tx/state marker, not the
        //      backup deletion: an undeletable backup no longer flips a
        //      successful install back to the old state on the next run
        //      (Codex round 3 #1 — the old commit point was the recursive
        //      deletion itself, so a crash or failure mid-deletion left a
        //      "partial backup as authority" trap). The NEW state must stay
        //      live throughout, and cleanup retries until it succeeds.
        //      Permission-based injection is void under root (containers).
        if geteuid() != 0 {
            let (root, bin, _) = try scenario("txcommitfail")
            let install = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("tx-commit-fail setup: initial install ok", install.ok,
                  install.failures.joined(separator: "; "))
            // a directory cleanup cannot clear from under the OLD prefix
            // (which becomes the backup during the commit swap)
            let locked = root.appendingPathComponent("prefix/locked")
            try fm.createDirectory(at: locked, withIntermediateDirectories: true)
            try "held".write(to: locked.appendingPathComponent("held"),
                             atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            try writeScript(bin.appendingPathComponent("pdftotext"), """
            #!/bin/sh
            \(UserdataToolchain.wrapperMarker)
            echo fake-tool 1.0
            exit 0
            """)
            setenv("FAKE_REPO_VERSION", "2.0", 1)
            let rebuilt = UserdataToolchain.installSync(includePandoc: false) { _ in }
            unsetenv("FAKE_REPO_VERSION")
            let backup = root.appendingPathComponent("prefix.previous")
            let newWrapper = (try? String(
                contentsOf: bin.appendingPathComponent("pdftotext"),
                encoding: .utf8)) ?? ""
            check("undeletable backup: install still COMMITS — new state live, cleanup deferred",
                  rebuilt.ok
                  && rebuilt.notes.contains(where: { $0.contains("could not be cleaned up yet") })
                  && newWrapper.contains(UserdataToolchain.closureMarker)
                  && UserdataToolchain.loadManifest()["fake"] == "2.0"
                  && fm.fileExists(atPath: backup.path)
                  && UserdataToolchain.txState() == "committed",
                  rebuilt.failures.joined(separator: "; ")
                  + " notes=" + rebuilt.notes.joined(separator: " | "))
            // while the backup stays stuck, the next run reports it honestly
            // and never touches the committed new state
            let stuck = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("stuck committed cleanup reported honestly, new state untouched",
                  !stuck.ok
                  && stuck.failures.contains(where: { $0.contains("cannot be cleaned up") })
                  && UserdataToolchain.loadManifest()["fake"] == "2.0",
                  stuck.failures.joined(separator: "; "))
            // unblock: cleanup completes and the NEW toolchain is retained —
            // the old code would have restored the stale backup right here
            try fm.setAttributes([.posixPermissions: 0o755],
                                 ofItemAtPath: backup.appendingPathComponent("locked").path)
            let after = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("after unblocking, cleanup completes and the NEW toolchain is retained",
                  after.ok
                  && after.notes.contains(where: { $0.contains("had already committed") })
                  && !fm.fileExists(atPath: backup.path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("tx").path)
                  && UserdataToolchain.loadManifest()["fake"] == "2.0",
                  after.failures.joined(separator: "; "))
        } else {
            print("· commit-failure injection skipped (running as root — permissions don't bind)")
        }

        // 16g. crash DURING the post-commit recursive backup deletion: the
        //      leftover PARTIAL backup must never be restored over the
        //      committed new prefix, and the stale tx snapshot must not be
        //      replayed (Codex round 3 #1, the exact reported scenario)
        do {
            let (root, bin, _) = try scenario("txcommitted")
            setenv("FAKE_REPO_VERSION", "3.0", 1)
            let install = UserdataToolchain.installSync(includePandoc: false) { _ in }
            unsetenv("FAKE_REPO_VERSION")
            check("tx-committed setup: initial install ok", install.ok,
                  install.failures.joined(separator: "; "))
            let newMarker = root.appendingPathComponent("prefix/new-marker")
            try "new".write(to: newMarker, atomically: true, encoding: .utf8)
            let goodWrapper = (try? String(
                contentsOf: bin.appendingPathComponent("pdftotext"),
                encoding: .utf8)) ?? ""
            // Simulate the crash state: durable committed marker, partially
            // deleted backup, tx snapshot still holding STALE wrappers and
            // a stale manifest.
            let backup = root.appendingPathComponent("prefix.previous")
            try fm.createDirectory(at: backup.appendingPathComponent("partial-old"),
                                   withIntermediateDirectories: true)
            let txWrappers = root.appendingPathComponent("tx/wrappers")
            try fm.createDirectory(at: txWrappers, withIntermediateDirectories: true)
            try "#!/bin/sh\n\(UserdataToolchain.wrapperMarker)\n# STALE SNAPSHOT\nexit 1\n"
                .write(to: txWrappers.appendingPathComponent("pdftotext"),
                       atomically: true, encoding: .utf8)
            try #"{"fake":"0.1"}"#.write(
                to: root.appendingPathComponent("tx/manifest.json"),
                atomically: true, encoding: .utf8)
            try "committed".write(to: root.appendingPathComponent("tx/state"),
                                  atomically: true, encoding: .utf8)
            let second = UserdataToolchain.installSync(includePandoc: false) { _ in }
            let wrapperAfter = (try? String(
                contentsOf: bin.appendingPathComponent("pdftotext"),
                encoding: .utf8)) ?? ""
            check("committed marker wins: new prefix/wrappers/manifest retained, leftovers cleaned",
                  second.ok
                  && fm.fileExists(atPath: newMarker.path)
                  && wrapperAfter == goodWrapper
                  && UserdataToolchain.loadManifest()["fake"] == "3.0"
                  && !fm.fileExists(atPath: backup.path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("tx").path),
                  second.failures.joined(separator: "; "))
        }

        // 16h. a failed RECOVERY write must preserve the snapshot instead of
        //      deleting its only good copy while reporting success (Codex
        //      round 3 #1); the retry then converges from that snapshot.
        //      Permission-based injection is void under root (containers).
        if geteuid() != 0 {
            let (root, bin, _) = try scenario("txrecoverfail")
            let install = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("tx-recover-fail setup: initial install ok", install.ok,
                  install.failures.joined(separator: "; "))
            let goodWrapper = (try? String(
                contentsOf: bin.appendingPathComponent("pdftotext"),
                encoding: .utf8)) ?? ""
            // Reproduce a mid-swap crash: tx snapshot (prepared) + backup,
            // unverified staging output sitting at prefixDir.
            let txWrappers = root.appendingPathComponent("tx/wrappers")
            try fm.createDirectory(at: txWrappers, withIntermediateDirectories: true)
            for entry in (try? fm.contentsOfDirectory(atPath: bin.path)) ?? [] {
                let source = bin.appendingPathComponent(entry)
                if UserdataToolchain.isOurWrapper(source.path) {
                    try fm.copyItem(at: source,
                                    to: txWrappers.appendingPathComponent(entry))
                }
            }
            try #"{"fake":"1.0"}"#.write(
                to: root.appendingPathComponent("tx/manifest.json"),
                atomically: true, encoding: .utf8)
            try "prepared".write(to: root.appendingPathComponent("tx/state"),
                                 atomically: true, encoding: .utf8)
            try fm.moveItem(at: root.appendingPathComponent("prefix"),
                            to: root.appendingPathComponent("prefix.previous"))
            try fm.createDirectory(at: root.appendingPathComponent("prefix"),
                                   withIntermediateDirectories: true)
            try writeScript(bin.appendingPathComponent("pdftotext"), """
            #!/bin/sh
            \(UserdataToolchain.wrapperMarker)
            \(UserdataToolchain.closureMarker)
            # WRITTEN BY THE INTERRUPTED RUN
            exit 1
            """)
            // Injection: the wrapper bin dir refuses writes, so restoring
            // the snapshot wrappers fails mid-recovery.
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)
            let failed = UserdataToolchain.installSync(includePandoc: false) { _ in }
            let txKept = fm.fileExists(atPath: root.appendingPathComponent("tx").path)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            check("failed recovery write: honest failure, snapshot preserved",
                  !failed.ok
                  && failed.failures.contains(where: { $0.contains("snapshot") })
                  && txKept,
                  failed.failures.joined(separator: "; ") + " txKept=\(txKept)")
            let retried = UserdataToolchain.installSync(includePandoc: false) { _ in }
            let wrapperAfter = (try? String(
                contentsOf: bin.appendingPathComponent("pdftotext"),
                encoding: .utf8)) ?? ""
            check("retry converges from the preserved snapshot",
                  retried.ok
                  && retried.notes.contains(where: { $0.contains("interrupted rebuild") })
                  && wrapperAfter == goodWrapper
                  && UserdataToolchain.loadManifest()["fake"] == "1.0"
                  && !fm.fileExists(atPath: root.appendingPathComponent("tx").path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("prefix.previous").path),
                  retried.failures.joined(separator: "; "))
        } else {
            print("· recovery-failure injection skipped (running as root — permissions don't bind)")
        }

        // 16f. cross-process lock: a live transaction must never be
        //      "recovered" by a concurrent operation (Codex round 2 #3)
        do {
            let (root, _, sys) = try scenario("txlock")
            for tool in coreTools {
                try fakeBinary(sys.appendingPathComponent(tool))
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            // the lock is a SIBLING of the root (survives removeAll)
            let lockFD = open(root.path + ".lock", O_WRONLY | O_CREAT, 0o600)
            flock(lockFD, LOCK_EX)
            let busyInstall = UserdataToolchain.installSync(includePandoc: false) { _ in }
            let busyUpgrade = UserdataToolchain.upgradeSync { _ in }
            let busyRemove = UserdataToolchain.removeAll()
            flock(lockFD, LOCK_UN)
            close(lockFD)
            let after = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("install/upgrade/remove refuse while the lock is held, work after release",
                  !busyInstall.ok
                  && busyInstall.failures.contains(where: { $0.contains("another toolchain operation") })
                  && !busyUpgrade.ok
                  && busyUpgrade.failures.contains(where: { $0.contains("another toolchain operation") })
                  && !busyRemove.ok
                  && busyRemove.failure?.contains("another toolchain operation") == true
                  && busyRemove.removed.isEmpty
                  && after.ok,
                  (busyInstall.failures + busyUpgrade.failures
                   + [busyRemove.failure ?? ""]
                   + after.failures).joined(separator: "; "))
        }

        // 16i. power-loss durability, snapshot side: a rollback snapshot
        //      that cannot be flushed to storage must abort the rebuild
        //      BEFORE anything visible changes (Codex round 4 — an
        //      unflushed tx/ could restore garbage after power loss)
        do {
            let (root, bin, _) = try scenario("txsnapflush")
            let install = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("snap-flush setup: initial install ok", install.ok,
                  install.failures.joined(separator: "; "))
            let marker = root.appendingPathComponent("prefix/flush-marker")
            try "old".write(to: marker, atomically: true, encoding: .utf8)
            try writeScript(bin.appendingPathComponent("pdftotext"), """
            #!/bin/sh
            \(UserdataToolchain.wrapperMarker)
            echo fake-tool 1.0
            exit 0
            """)
            let v1Text = (try? String(
                contentsOf: bin.appendingPathComponent("pdftotext"),
                encoding: .utf8)) ?? ""
            setenv("BRIGLIA_TOOLCHAIN_FAULT", "snapshot-flush", 1)
            let failed = UserdataToolchain.installSync(includePandoc: false) { _ in }
            unsetenv("BRIGLIA_TOOLCHAIN_FAULT")
            let wrapperAfter = (try? String(
                contentsOf: bin.appendingPathComponent("pdftotext"),
                encoding: .utf8)) ?? ""
            check("unflushable snapshot aborts before touching anything",
                  !failed.ok
                  && failed.failures.contains(where: { $0.contains("snapshot") })
                  && fm.fileExists(atPath: marker.path)
                  && wrapperAfter == v1Text
                  && !fm.fileExists(atPath: root.appendingPathComponent("tx").path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("prefix.new").path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("prefix.previous").path),
                  failed.failures.joined(separator: "; "))
        }

        // 16j. power-loss durability, commit side: the committed marker may
        //      only be written after a CHECKED storage barrier over every
        //      filesystem involved — a failed flush rolls the swap back
        //      instead of certifying state still in volatile caches
        //      (Codex round 4)
        do {
            let (root, bin, _) = try scenario("txcommitflush")
            let install = UserdataToolchain.installSync(includePandoc: false) { _ in }
            check("commit-flush setup: initial install ok", install.ok,
                  install.failures.joined(separator: "; "))
            let marker = root.appendingPathComponent("prefix/flush-marker")
            try "old".write(to: marker, atomically: true, encoding: .utf8)
            let v1Text = """
            #!/bin/sh
            \(UserdataToolchain.wrapperMarker)
            echo fake-tool 1.0
            exit 0

            """
            try writeScript(bin.appendingPathComponent("pdftotext"), v1Text)
            setenv("FAKE_REPO_VERSION", "2.0", 1)
            setenv("BRIGLIA_TOOLCHAIN_FAULT", "commit-flush", 1)
            let failed = UserdataToolchain.installSync(includePandoc: false) { _ in }
            unsetenv("BRIGLIA_TOOLCHAIN_FAULT")
            let wrapperAfter = (try? String(
                contentsOf: bin.appendingPathComponent("pdftotext"),
                encoding: .utf8)) ?? ""
            check("failed commit barrier rolls the swap back completely",
                  !failed.ok
                  && failed.failures.contains(where: { $0.contains("stable storage") })
                  && failed.notes.contains(where: {
                      $0.contains("previous working toolchain was restored") })
                  && fm.fileExists(atPath: marker.path)
                  && wrapperAfter == v1Text
                  && UserdataToolchain.loadManifest()["fake"] == "1.0"
                  && UserdataToolchain.txState() == nil
                  && !fm.fileExists(atPath: root.appendingPathComponent("prefix.previous").path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("prefix.new").path),
                  failed.failures.joined(separator: "; ")
                  + " manifest=\(UserdataToolchain.loadManifest())")
            // fault cleared → the same rebuild goes through and commits
            let retried = UserdataToolchain.installSync(includePandoc: false) { _ in }
            unsetenv("FAKE_REPO_VERSION")
            check("with the barrier passing, the rebuild commits normally",
                  retried.ok
                  && UserdataToolchain.loadManifest()["fake"] == "2.0"
                  && !fm.fileExists(atPath: root.appendingPathComponent("tx").path)
                  && !fm.fileExists(atPath: root.appendingPathComponent("prefix.previous").path),
                  retried.failures.joined(separator: "; "))
        }

        // 17. a timed-out toolchain command must not leave descendants
        //     running (they could keep mutating the prefix after the
        //     reported timeout) — the whole process TREE dies
        do {
            let pidFile = tempRoot.appendingPathComponent("straggler.pid")
            let hang = tempRoot.appendingPathComponent("hang")
            try writeScript(hang, """
            #!/bin/sh
            sleep 600 &
            echo $! > "\(pidFile.path)"
            wait
            """)
            let result = UserdataToolchain.run(hang.path, [], timeout: 1)
            let straggler = Int32((try? String(contentsOf: pidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            let stragglerDead = straggler > 0 && waitGone(straggler)
            check("timeout kills the whole process tree, no straggler survives",
                  result.exitCode == 124 && straggler > 0 && stragglerDead,
                  "exit=\(result.exitCode) straggler=\(straggler) dead=\(stragglerDead)")
        }

        // 17b. leader exits FIRST, a detached child keeps the pipe open —
        //      the old code waited on the reader forever (the timeout branch
        //      never fires once the tracked process is gone). run() must
        //      come back by the deadline, kill the leader's group, and say so.
        do {
            let pidFile = tempRoot.appendingPathComponent("orphan.pid")
            let daemonish = tempRoot.appendingPathComponent("daemonish")
            try writeScript(daemonish, """
            #!/bin/sh
            sleep 600 &
            echo $! > "\(pidFile.path)"
            exit 0
            """)
            let started = Date()
            let result = UserdataToolchain.run(daemonish.path, [], timeout: 2)
            let elapsed = Date().timeIntervalSince(started)
            let orphan = Int32((try? String(contentsOf: pidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            let orphanDead = orphan > 0 && waitGone(orphan)
            // Whatever the platform shape (macOS sees the leader's exit and
            // kills the straggler; on Linux the orphan holds corelibs'
            // exit-detection descriptor so the ordinary timeout branch
            // fires — reference_corelibs_process_pipes_linux), the result
            // must be NONZERO: Briglia forcibly killed part of the process
            // tree, and callers must never mistake that for a clean
            // apt/dpkg run (Codex round 3 #2 — the old macOS shape returned
            // the leader's exit 0 with only an ignorable note).
            let honest = result.exitCode == 124
                && (result.output.contains("outlived the command")
                    || result.output.contains("timed out"))
            check("leader-exits-first: bounded return, NONZERO exit, orphan killed",
                  elapsed < 30 && honest && orphan > 0 && orphanDead,
                  "elapsed=\(Int(elapsed))s exit=\(result.exitCode) orphan=\(orphan) dead=\(orphanDead) output=\(result.output.prefix(120))")
        }

        // cleanup env so nothing leaks into other selftests
        for key in ["BRIGLIA_TOOLCHAIN_ROOT", "BRIGLIA_TOOLCHAIN_BIN", "BRIGLIA_TOOLCHAIN_PATH",
                    "BRIGLIA_TOOLCHAIN_APT", "BRIGLIA_TOOLCHAIN_DPKG",
                    "BRIGLIA_TOOLCHAIN_DPKG_STATUS"] {
            unsetenv(key)
        }

        print(failures == 0
              ? "toolchain selftest: all checks passed"
              : "toolchain selftest: \(failures) FAILURE(S)")
        if failures > 0 { throw ExitCode(1) }
    }
}
