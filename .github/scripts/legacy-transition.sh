#!/bin/bash
# Compiled legacy-transition descriptor (docs/RENAME_PLAN.md §3.2), shared by
# check-supersession.sh and verify-public-release.sh.
#
# After the repository rename the channel's "latest" is still the previous
# identity's envelope — channel `ada-cli`, keyId `ada-cli-release-v1-…` over
# the SAME key material, artifacts under the old repository path — until the
# first Briglia release publishes AND GitHub's latest pointer catches up with
# it (the Stage-7 rehearsal measured that lag at about two minutes). This
# helper answers exactly one question: does a served envelope authenticate,
# with the COMMITTED expected key, as THAT legacy state — field for field,
# never as a wildcard. There is no environment override and no bypass flag.
# The whole file is deleted in the follow-up commit after the first Briglia
# release (§7.2 step 10), together with both call sites.
#
# Sourced. legacy_live_authenticates <envelope> <expected-pub.pem> <payload-out>
#   returns 0  = authenticates as the exact legacy state (payload written)
#   returns 1  = does not (reason printed for the descriptor mismatches)
LEGACY_CHANNEL="ada-cli"
LEGACY_ARTIFACT_PREFIX="https://github.com/permaevidence/ada-cli/releases/download/v"

legacy_live_authenticates() {
    local envelope="$1" pub="$2" payload_out="$3" here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    "$here/verify-envelope.sh" "$envelope" "$pub" "$LEGACY_CHANNEL" "$payload_out" >/dev/null 2>&1 || return 1
    # The authenticated legacy payload must be the genuine old channel's
    # manifest: its own channel field and every artifact URL pin the
    # previous identity. Anything else signed under the old domain is
    # refused — the descriptor is exact, not a wildcard.
    python3 - "$payload_out" "$LEGACY_CHANNEL" "$LEGACY_ARTIFACT_PREFIX" <<'PYEOF'
import json, sys
path, channel, prefix = sys.argv[1:4]
try:
    m = json.load(open(path))
except Exception:
    sys.exit("✖ legacy envelope authenticates but its payload is not JSON — refusing")
if not isinstance(m, dict) or m.get("schema") != 1 or m.get("channel") != channel:
    sys.exit(f"✖ legacy envelope authenticates but its payload is not a {channel} schema-1 manifest")
version = m.get("version")
platforms = m.get("platforms")
if not isinstance(version, str) or not isinstance(platforms, dict) or not platforms:
    sys.exit("✖ legacy manifest is malformed")
for name, entry in platforms.items():
    url = entry.get("url") if isinstance(entry, dict) else None
    if not isinstance(url, str) or not url.startswith(prefix + version + "/"):
        sys.exit(f"✖ legacy manifest artifact for {name} is not under {prefix}{version}/ — refusing")
PYEOF
}
