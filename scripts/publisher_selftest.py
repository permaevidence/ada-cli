#!/usr/bin/env python3
"""Publisher fault-injection tests (docs/RELEASE_SIGNING_PLAN.md §11.3).

Runs the REAL release scripts — check-supersession.sh, publish-release.sh,
verify-public-release.sh — against one in-process fake that plays the
GitHub Releases API, the uploads host and the public releases/download
host, with switchable faults:

  * no live signed state is refused (bootstrap retired); invalid live envelope
    never unlocks it; older/equal sequence cannot replace newer live state;
  * publishing over an existing immutable release fails honestly, stale
    drafts are cleaned, uploads go envelope-LAST, publication is one PATCH
    with explicit make_latest, an ambiguous PATCH is confirmed by re-read,
    a failed publication leaves the old release latest;
  * public verification AUTHENTICATES FIRST with the committed key and
    never executes a downloaded binary before the bytes proved identical to
    the verified candidate (the forged-binary regression);
  * the workflow carries no transitional Blob publication any more (the
    §6.3 window closed 2026-08-31) and nothing references the retired
    publish-cdn.sh;
  * tokens never appear in script output.

Needs: bash, python3, curl, tar, an Ed25519-capable openssl. Exit 0 = all
checks passed.
"""

import base64
import hashlib
import http.server
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import urllib.parse
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = REPO_ROOT / ".github" / "scripts"
REPO = "permaevidence/ada-cli-fake"
GH_TOKEN = "ghs_FAKEtokenSECRET1234567890abcdef"
PLATFORMS = ["macos-arm64", "linux-x64", "linux-arm64"]

PASSED = 0
FAILED = 0


def check(label, ok, detail=""):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print(f"  ✔ {label}")
    else:
        FAILED += 1
        print(f"  ✖ {label}" + (f" — {detail[-1200:]}" if detail else ""))


# ---------------------------------------------------------------------------
# The fake: one server, four roles.

class State:
    def __init__(self):
        self.reset({})

    def reset(self, cfg):
        self.releases = {}          # id -> dict(tag_name, draft, name, assets: {name: bytes})
        self.next_id = 100
        self.latest_id = None       # published release served at /releases/latest
        self.latest_queue = []      # per-request overrides for /latest (ids), consumed in order
        self.faults = cfg.get("faults", {})
        self.download_overrides = {}  # asset name -> bytes served instead (public host)
        self.log = []               # (method, path)


STATE = State()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def _send(self, code, body=b"", ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _release_json(self, rid):
        r = STATE.releases[rid]
        return {"id": rid, "tag_name": r["tag_name"], "draft": r["draft"], "name": r["name"],
                "assets": [{"name": n} for n in r["assets"]]}

    def _auth_ok(self):
        return self.headers.get("Authorization") == f"Bearer {GH_TOKEN}"

    # -- routing ---------------------------------------------------------
    def do_GET(self):
        STATE.log.append(("GET", self.path))
        u = urllib.parse.urlparse(self.path)
        p = u.path
        if p == "/__control/state":
            return self._send(200, {
                "releases": {str(i): self._release_json(i) | {"asset_order": list(r["assets"].keys())}
                             for i, r in STATE.releases.items()},
                "latest_id": STATE.latest_id, "log": STATE.log})
        # public release download host
        m = re.fullmatch(r"/releases/latest/download/([^/]+)", p)
        if m:
            rid = STATE.latest_queue.pop(0) if STATE.latest_queue else STATE.latest_id
            return self._serve_asset(rid, m.group(1))
        m = re.fullmatch(r"/releases/download/v([0-9.]+)/([^/]+)", p)
        if m:
            rid = next((i for i, r in STATE.releases.items()
                        if not r["draft"] and r["tag_name"] == "v" + m.group(1)), None)
            return self._serve_asset(rid, m.group(2))
        # GitHub API
        if not self._auth_ok():
            return self._send(401, {"message": "bad credentials"})
        m = re.fullmatch(rf"/repos/{REPO}/releases/tags/([^/]+)", p)
        if m:
            rid = next((i for i, r in STATE.releases.items()
                        if not r["draft"] and r["tag_name"] == m.group(1)), None)
            return self._send(200, self._release_json(rid)) if rid else self._send(404, {"message": "Not Found"})
        if p == f"/repos/{REPO}/releases":
            q = urllib.parse.parse_qs(u.query)
            page = int(q.get("page", ["1"])[0])
            items = [self._release_json(i) for i in sorted(STATE.releases)] if page == 1 else []
            return self._send(200, items)
        m = re.fullmatch(rf"/repos/{REPO}/releases/(\d+)", p)
        if m:
            rid = int(m.group(1))
            return self._send(200, self._release_json(rid)) if rid in STATE.releases else self._send(404, {})
        self._send(404, {"message": f"no route {p}"})

    def _serve_asset(self, rid, name):
        if name in STATE.download_overrides:
            return self._send(200, STATE.download_overrides[name], "application/octet-stream")
        if rid is None or name not in STATE.releases[rid]["assets"]:
            return self._send(404, b"Not Found", "text/plain")
        return self._send(200, STATE.releases[rid]["assets"][name], "application/octet-stream")

    def do_POST(self):
        STATE.log.append(("POST", self.path))
        u = urllib.parse.urlparse(self.path)
        p = u.path
        body = self._body()
        if p == "/__control/reset":
            STATE.reset(json.loads(body or b"{}"))
            return self._send(200, {"ok": True})
        if p == "/__control/seed":
            cfg = json.loads(body)
            rid = STATE.next_id; STATE.next_id += 1
            STATE.releases[rid] = {"tag_name": cfg["tag_name"], "draft": cfg.get("draft", False),
                                   "name": cfg.get("name", ""),
                                   "assets": {k: base64.b64decode(v) for k, v in cfg.get("assets", {}).items()}}
            if cfg.get("latest"):
                STATE.latest_id = rid
            return self._send(200, {"id": rid})
        if p == "/__control/override":
            cfg = json.loads(body)
            for k, v in cfg.get("download_overrides", {}).items():
                STATE.download_overrides[k] = base64.b64decode(v)
            STATE.latest_queue = cfg.get("latest_queue", STATE.latest_queue)
            return self._send(200, {"ok": True})
        if not self._auth_ok():
            return self._send(401, {"message": "bad credentials"})
        if p == f"/repos/{REPO}/releases":
            if STATE.faults.get("create") == "500":
                return self._send(500, {"message": "boom"})
            req = json.loads(body)
            rid = STATE.next_id; STATE.next_id += 1
            STATE.releases[rid] = {"tag_name": req["tag_name"], "draft": bool(req.get("draft")),
                                   "name": req.get("name", ""), "assets": {}}
            return self._send(201, self._release_json(rid))
        m = re.fullmatch(rf"/repos/{REPO}/releases/(\d+)/assets", p)
        if m:
            rid = int(m.group(1))
            name = urllib.parse.parse_qs(u.query)["name"][0]
            if rid not in STATE.releases:
                return self._send(404, {})
            if STATE.faults.get("upload_fail") == name:
                return self._send(500, {"message": "upload boom"})
            STATE.releases[rid]["assets"][name] = body
            return self._send(201, {"name": name})
        self._send(404, {"message": f"no route {p}"})

    def do_PATCH(self):
        STATE.log.append(("PATCH", self.path))
        body = self._body()
        if not self._auth_ok():
            return self._send(401, {"message": "bad credentials"})
        m = re.fullmatch(rf"/repos/{REPO}/releases/(\d+)", self.path)
        if not m or int(m.group(1)) not in STATE.releases:
            return self._send(404, {})
        rid = int(m.group(1))
        req = json.loads(body)
        STATE.log.append(("PATCH-BODY", json.dumps(req, sort_keys=True)))
        fault = STATE.faults.get("patch")
        if fault == "500_noapply":
            return self._send(500, {"message": "patch boom"})
        r = STATE.releases[rid]
        if "draft" in req:
            r["draft"] = bool(req["draft"])
        if str(req.get("make_latest")) == "true" and not r["draft"]:
            STATE.latest_id = rid
        if fault == "502_apply":
            return self._send(502, b"<html>bad gateway</html>", "text/html")
        return self._send(200, self._release_json(rid))

    def do_DELETE(self):
        STATE.log.append(("DELETE", self.path))
        if not self._auth_ok():
            return self._send(401, {"message": "bad credentials"})
        m = re.fullmatch(rf"/repos/{REPO}/releases/(\d+)", self.path)
        if not m or int(m.group(1)) not in STATE.releases:
            return self._send(404, {})
        del STATE.releases[int(m.group(1))]
        self._send(204)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # curl closes early on --max-filesize / -f failures; that is expected.
        pass


def control(base, path, payload=None):
    import urllib.request
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(base + path, data=data, method="POST" if data is not None else "GET",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


# ---------------------------------------------------------------------------
# Fixtures

def run(script, env, args=(), cwd=None, timeout=120):
    e = {k: v for k, v in os.environ.items() if k != "GH_TOKEN"}
    e.update(env)
    r = subprocess.run(["bash", str(script), *args], env=e, cwd=cwd or REPO_ROOT,
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout + r.stderr


def fake_ada(version):
    return f"""#!/bin/sh
# fake ada binary for the publisher tests: it FORGES a verification verdict.
case "$1" in
  --version) echo "{version}" ;;
  __verify-envelope) [ -n "${{FAKE_ADA_MARKER:-}}" ] && : > "$FAKE_ADA_MARKER"; echo "forged: verified"; exit 0 ;;
  *) exit 0 ;;
esac
""".encode()


def make_tarball(path, version, platform, salt=b""):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        data = fake_ada(version)
        ti = tarfile.TarInfo("ada"); ti.size = len(data); ti.mode = 0o755; ti.mtime = 0
        tf.addfile(ti, io.BytesIO(data))
        pad = f"platform={platform} version={version}\n".encode() + salt
        ti = tarfile.TarInfo(f"pad-{platform}"); ti.size = len(pad); ti.mtime = 0
        tf.addfile(ti, io.BytesIO(pad))
    Path(path).write_bytes(buf.getvalue())


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def make_dist(dist, version, sequence, base_url, key, published="2026-08-31T00:00:00Z", salt=b""):
    """A production-shaped dist/: three tarballs, sidecars, manifest.json, manifest.sig.json."""
    dist = Path(dist); dist.mkdir(parents=True, exist_ok=True)
    platforms = {}
    for platform in PLATFORMS:
        name = f"ada-{platform}.tar.gz"
        make_tarball(dist / name, version, platform, salt)
        digest = sha256(dist / name)
        (dist / f"{name}.sha256").write_text(f"{digest}  {name}\n")
        platforms[platform] = {"url": f"{base_url}/releases/download/v{version}/{name}",
                               "sha256": digest, "size": (dist / name).stat().st_size}
    manifest = {"schema": 1, "channel": "ada-cli", "sequence": sequence, "version": version,
                "published": published, "expires": "2027-08-31T00:00:00Z", "platforms": platforms}
    (dist / "manifest.json").write_bytes(json.dumps(manifest, separators=(",", ":"), sort_keys=True).encode())
    rc, out = run(SCRIPTS / "sign-envelope.sh",
                  {"EXPECTED_PUBKEY_PEM": str(key["pub"])},
                  [str(key["priv"]), "ada-cli", str(dist / "manifest.json"), str(dist / "manifest.sig.json")])
    assert rc == 0, out
    return dist


def seed_release(base, dist, version, latest=True, draft=False):
    assets = {p.name: base64.b64encode(p.read_bytes()).decode()
              for p in Path(dist).iterdir() if p.is_file()}
    assets["install.sh"] = base64.b64encode((REPO_ROOT / "scripts/get-ada.sh").read_bytes()).decode()
    return control(base, "/__control/seed", {"tag_name": f"v{version}", "draft": draft,
                                               "latest": latest, "assets": assets})["id"]


def tampered_envelope(path):
    env = json.loads(Path(path).read_bytes())
    sig = bytearray(base64.b64decode(env["signature"])); sig[0] ^= 1
    env["signature"] = base64.b64encode(bytes(sig)).decode()
    return json.dumps(env, separators=(",", ":")).encode()


# ---------------------------------------------------------------------------

def main():
    for tool in ("bash", "curl", "tar", "python3"):
        if shutil.which(tool) is None:
            print(f"✖ required tool missing: {tool}")
            return 1
    work = Path(tempfile.mkdtemp(prefix="ada-publisher-"))
    server = Server(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    base = f"http://127.0.0.1:{port}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        return body(work, base)
    finally:
        server.shutdown()
        shutil.rmtree(work, ignore_errors=True)


def body(work, base):
    # Key material through the real ceremony helper.
    rc, out = run(REPO_ROOT / "scripts/release-keygen.sh", {}, ["ada-cli", str(work / "keys")])
    check("release-keygen.sh produced a test key", rc == 0, out)
    if rc != 0:
        return 1
    priv = next((work / "keys").glob("*.priv.pem"))
    key = {"priv": priv, "pub": Path(str(priv)[:-len(".priv.pem")] + ".pub.pem")}
    live_url = f"{base}/releases/latest/download/manifest.sig.json"
    common = {"EXPECTED_PUBKEY": str(key["pub"]), "LIVE_ENVELOPE_URL": live_url}

    dist58 = make_dist(work / "dist58", "0.1.58", 58, base, key)
    dist59 = make_dist(work / "dist59", "0.1.59", 59, base, key)

    # ------------------------------------------------------------------
    print("— check-supersession.sh —")
    control(base, "/__control/reset", {})
    # The one-time bootstrap is gone: without an authenticated live envelope
    # NOTHING publishes — not the historical bootstrap tag, not a marker file.
    for seq, ref in (("58", "v0.1.58"), ("59", "v0.1.59")):
        rc, out = run(SCRIPTS / "check-supersession.sh", common | {"SEQUENCE": seq, "REF_NAME": ref})
        check(f"no live signed state: {ref}/{seq} is refused (bootstrap retired)",
              rc != 0 and "bootstrap retired" in out, out)
    rc, out = run(SCRIPTS / "check-supersession.sh", common | {"SEQUENCE": "58", "REF_NAME": "v0.1.58",
                                                               "BOOTSTRAP_FILE": str(work / "marker")})
    (work / "marker").write_text("v0.1.58 58\n")
    rc, out = run(SCRIPTS / "check-supersession.sh", common | {"SEQUENCE": "58", "REF_NAME": "v0.1.58",
                                                               "BOOTSTRAP_FILE": str(work / "marker")})
    check("a marker file is inert: BOOTSTRAP_FILE no longer unlocks anything", rc != 0 and "bootstrap retired" in out, out)
    check("repository carries no bootstrap marker", not (REPO_ROOT / ".github/BOOTSTRAP_RELEASE").exists())
    check("check-supersession.sh has no marker-reading code",
          "BOOTSTRAP_FILE" not in (SCRIPTS / "check-supersession.sh").read_text())

    seed_release(base, dist58, "0.1.58")
    rc, out = run(SCRIPTS / "check-supersession.sh", common | {"SEQUENCE": "59", "REF_NAME": "v0.1.59"})
    check("live 58: sequence 59 supersedes", rc == 0 and "supersedes live 58" in out, out)
    rc, out = run(SCRIPTS / "check-supersession.sh", common | {"SEQUENCE": "58", "REF_NAME": "v0.1.58"})
    check("live 58: equal sequence cannot replace live state", rc != 0 and "superseded" in out, out)
    rc, out = run(SCRIPTS / "check-supersession.sh", common | {"SEQUENCE": "57", "REF_NAME": "v0.1.57"})
    check("live 58: older run cannot replace newer state", rc != 0 and "superseded" in out, out)
    control(base, "/__control/override", {"download_overrides": {
        "manifest.sig.json": base64.b64encode(tampered_envelope(dist58 / "manifest.sig.json")).decode()}})
    rc, out = run(SCRIPTS / "check-supersession.sh", common | {"SEQUENCE": "58", "REF_NAME": "v0.1.58"})
    check("invalid live envelope is a hard stop (never treated as absent)",
          rc != 0 and "does not authenticate" in out and "bootstrap retired" not in out, out)

    # ------------------------------------------------------------------
    print("— publish-release.sh —")
    pub_env = {"GH_TOKEN": GH_TOKEN, "REPO": REPO, "GH_API_URL": base, "GH_UPLOADS_URL": base,
               "INSTALLER": str(REPO_ROOT / "scripts/get-ada.sh")}

    control(base, "/__control/reset", {})
    old_id = seed_release(base, dist58, "0.1.58")
    rc, out = run(SCRIPTS / "publish-release.sh", pub_env | {"REF_NAME": "v0.1.59", "VERSION": "0.1.59", "DIST": str(dist59)})
    st = control(base, "/__control/state")
    new = [r for i, r in st["releases"].items() if r["tag_name"] == "v0.1.59"]
    check("happy path: exit 0 and confirmed published", rc == 0 and "✔ published immutable release v0.1.59" in out, out)
    check("happy path: release exists, is not a draft, and is latest",
          len(new) == 1 and not new[0]["draft"] and st["latest_id"] == new[0]["id"], json.dumps(st["releases"]))
    order = new[0]["asset_order"] if new else []
    check("happy path: signed envelope uploaded LAST, after every asset",
          order and order[-1] == "manifest.sig.json"
          and set(order[:-1]) == {f"ada-{p}.tar.gz" for p in PLATFORMS} | {f"ada-{p}.tar.gz.sha256" for p in PLATFORMS}
          | {"manifest.json", "install.sh"}, str(order))
    patch_bodies = [b for m, b in st["log"] if m == "PATCH-BODY"]
    check("happy path: exactly one publish PATCH with draft=false and explicit make_latest",
          patch_bodies == ['{"draft": false, "make_latest": "true"}'], str(patch_bodies))
    check("happy path: installer asset is byte-identical to scripts/get-ada.sh",
          rc == 0 and requests_asset(base, new[0]["id"], "install.sh") == (REPO_ROOT / "scripts/get-ada.sh").read_bytes())
    check("token never appears in publisher output", GH_TOKEN not in out)
    check("old release survives (immutable): still present, no longer latest",
          str(old_id) in st["releases"] and st["latest_id"] != old_id)

    # publish over an existing immutable release
    log_before = len(st["log"])
    rc, out = run(SCRIPTS / "publish-release.sh", pub_env | {"REF_NAME": "v0.1.59", "VERSION": "0.1.59", "DIST": str(dist59)})
    st = control(base, "/__control/state")
    later = st["log"][log_before:]
    check("existing published release: refused honestly, no retry loop",
          rc != 0 and "immutability forbids republish" in out, out)
    check("existing published release: no draft created, nothing PATCHed",
          not any(m == "POST" and p.endswith("/releases") for m, p in later)
          and not any(m == "PATCH" for m, p in later), str(later))

    # stale draft cleanup
    control(base, "/__control/reset", {})
    seed_release(base, dist58, "0.1.58")
    stale_id = seed_release(base, dist59, "0.1.59", latest=False, draft=True)
    rc, out = run(SCRIPTS / "publish-release.sh", pub_env | {"REF_NAME": "v0.1.59", "VERSION": "0.1.59", "DIST": str(dist59)})
    st = control(base, "/__control/state")
    check("stale draft from a failed run is deleted, then publication succeeds",
          rc == 0 and ("DELETE", f"/repos/{REPO}/releases/{stale_id}") in [tuple(x) for x in st["log"]]
          and str(stale_id) not in st["releases"]
          and any(r["tag_name"] == "v0.1.59" and not r["draft"] for r in st["releases"].values()), out)

    # upload failure mid-way
    control(base, "/__control/reset", {"faults": {"upload_fail": "ada-linux-x64.tar.gz"}})
    old_id = seed_release(base, dist58, "0.1.58")
    rc, out = run(SCRIPTS / "publish-release.sh", pub_env | {"REF_NAME": "v0.1.59", "VERSION": "0.1.59", "DIST": str(dist59)})
    st = control(base, "/__control/state")
    drafts = [r for r in st["releases"].values() if r["tag_name"] == "v0.1.59"]
    check("upload failure: reported, exit nonzero", rc != 0 and "uploading ada-linux-x64.tar.gz failed" in out, out)
    check("upload failure: draft never published, old release stays latest",
          drafts and drafts[0]["draft"] and st["latest_id"] == old_id
          and not any(m == "PATCH" for m, p in st["log"]), json.dumps(st["releases"]))
    check("upload failure: envelope was NOT uploaded to the abandoned draft",
          drafts and "manifest.sig.json" not in drafts[0]["asset_order"])

    # ambiguous publish: PATCH applied server-side but answered 502
    control(base, "/__control/reset", {"faults": {"patch": "502_apply"}})
    seed_release(base, dist58, "0.1.58")
    rc, out = run(SCRIPTS / "publish-release.sh", pub_env | {"REF_NAME": "v0.1.59", "VERSION": "0.1.59", "DIST": str(dist59)})
    st = control(base, "/__control/state")
    new = [r for r in st["releases"].values() if r["tag_name"] == "v0.1.59"]
    check("ambiguous PATCH (applied, HTTP 502): confirmed by re-read, reported, exit 0",
          rc == 0 and "answered HTTP 502 but the release IS published" in out and new and not new[0]["draft"], out)

    # draft-publication failure: PATCH fails, nothing applied
    control(base, "/__control/reset", {"faults": {"patch": "500_noapply"}})
    old_id = seed_release(base, dist58, "0.1.58")
    rc, out = run(SCRIPTS / "publish-release.sh", pub_env | {"REF_NAME": "v0.1.59", "VERSION": "0.1.59", "DIST": str(dist59)})
    st = control(base, "/__control/state")
    new = [r for r in st["releases"].values() if r["tag_name"] == "v0.1.59"]
    check("draft-publication failure: reported, release remains a draft, old stays latest",
          rc != 0 and "remains a draft" in out and new and new[0]["draft"] and st["latest_id"] == old_id, out)

    control(base, "/__control/reset", {"faults": {"create": "500"}})
    rc, out = run(SCRIPTS / "publish-release.sh", pub_env | {"REF_NAME": "v0.1.59", "VERSION": "0.1.59", "DIST": str(dist59)})
    check("draft creation failure: reported before any upload", rc != 0 and "creating the draft release failed" in out, out)

    # ------------------------------------------------------------------
    print("— verify-public-release.sh (authenticate first) —")
    ver_env = {"VERSION": "0.1.59", "SEQUENCE": "59", "PLATFORM": "linux-x64",
               "EXPECTED_PUBKEY": str(key["pub"]), "RELEASE_BASE_URL": base,
               "CANDIDATE_TARBALL": str(dist59 / "ada-linux-x64.tar.gz"),
               "CANDIDATE_ENVELOPE": str(dist59 / "manifest.sig.json"),
               "ATTEMPTS": "3", "RETRY_SLEEP": "0"}

    def verify(extra=None):
        marker = work / f"marker-{os.urandom(4).hex()}"
        rc, out = run(SCRIPTS / "verify-public-release.sh", ver_env | (extra or {}) | {"FAKE_ADA_MARKER": str(marker)})
        return rc, out, marker.exists()

    control(base, "/__control/reset", {})
    seed_release(base, dist58, "0.1.58", latest=False)
    seed_release(base, dist59, "0.1.59")
    log_mark = len(control(base, "/__control/state")["log"])
    rc, out, ran = verify()
    check("happy path: authenticates, byte-identical, functional check runs AFTER", rc == 0 and ran
          and out.index("public envelope authenticates") < out.index("byte-identical to the signed candidate")
          < out.index("byte-identical to the verified candidate") < out.index("end-to-end public verification passed"), out)

    # forged binary + tampered envelope: the blocker regression
    control(base, "/__control/override", {"download_overrides": {
        "manifest.sig.json": base64.b64encode(tampered_envelope(dist59 / "manifest.sig.json")).decode()}})
    log_mark = len(control(base, "/__control/state")["log"])
    rc, out, ran = verify()
    later = control(base, "/__control/state")["log"][log_mark:]
    check("tampered public envelope: refused BEFORE any asset download, binary never executed",
          rc != 0 and "does not authenticate" in out and not ran
          and not any("ada-linux-x64.tar.gz" in p for m, p in later), out)

    # public asset differs from what the manifest authenticates
    control(base, "/__control/reset", {})
    seed_release(base, dist59, "0.1.59")
    bad = bytearray((dist59 / "ada-linux-x64.tar.gz").read_bytes()); bad[-1] ^= 0xFF
    control(base, "/__control/override", {"download_overrides": {"ada-linux-x64.tar.gz": base64.b64encode(bytes(bad)).decode()}})
    rc, out, ran = verify()
    check("public asset with wrong sha256: refused, binary never executed",
          rc != 0 and "sha256 does not match" in out and not ran, out)

    # public bytes authenticate but are not this run's candidate (a different build)
    control(base, "/__control/reset", {})
    other = make_dist(work / "dist59-other", "0.1.59", 59, base, key, salt=b"other-build")
    seed_release(base, other, "0.1.59")
    rc, out, ran = verify()
    check("valid-but-foreign public release: envelope not byte-identical to this run's, refused",
          rc != 0 and "NOT byte-identical to the one this run signed" in out and not ran, out)
    control(base, "/__control/reset", {})
    seed_release(base, dist59, "0.1.59")
    rc, out, ran = verify({"CANDIDATE_TARBALL": str(other / "ada-linux-x64.tar.gz")})
    check("public asset hashes correctly but differs from the verified candidate: refused",
          rc != 0 and "NOT byte-identical to the verified candidate" in out and not ran, out)

    # latest not propagated yet: authenticated OLDER version retries, then succeeds
    control(base, "/__control/reset", {})
    old_id = seed_release(base, dist58, "0.1.58", latest=False)
    seed_release(base, dist59, "0.1.59")
    control(base, "/__control/override", {"latest_queue": [old_id, old_id]})
    rc, out, ran = verify()
    check("latest propagation delay: authenticated older version retries, then passes",
          rc == 0 and ran and "attempt 1, authenticated v0.1.58" in out and "attempt 2" in out, out)
    control(base, "/__control/reset", {})
    seed_release(base, dist58, "0.1.58")
    rc, out, ran = verify({"ATTEMPTS": "2"})
    check("latest never serves the new version: reported, exit nonzero, binary never executed",
          rc != 0 and "never served an authenticated v0.1.59" in out and not ran, out)
    rc, out, ran = verify({"SEQUENCE": "60"})
    check("authenticated sequence mismatch is refused", rc != 0 and not ran, out)

    # ------------------------------------------------------------------
    print("— workflow structure —")
    wf = (REPO_ROOT / ".github/workflows/release-signed.yml").read_text()
    jobs = re.split(r"\n(?=  [a-z][a-z0-9-]*:\n)", wf)
    def job(name):
        return next((j for j in jobs if j.startswith(f"  {name}:\n")), "")
    publish = job("publish"); verify_prod = job("verify-production")
    check("the transitional Blob dual-publish job is gone and nothing references publish-cdn.sh or a Blob token",
          publish and not job("legacy-blob-dual-publish") and "publish-cdn.sh" not in wf
          and "BLOB" not in wf and not (SCRIPTS / "publish-cdn.sh").exists())
    check("verify-production depends on publish only",
          "needs: [authorize, publish]" in verify_prod and "legacy-blob" not in verify_prod)
    check("verify-production authenticates via the committed key before touching public assets",
          "actions/checkout@" in verify_prod and "download-artifact@" in verify_prod
          and "verify-public-release.sh" in verify_prod and "CANDIDATE_TARBALL" in verify_prod)
    check("authorize and publish share the tested supersession script",
          wf.count("check-supersession.sh") == 2 and "publish-release.sh" in publish)
    uses = re.findall(r"uses: ([^\s@]+)@([0-9a-f]+)", wf)
    check("every action is pinned to a full commit SHA", uses and all(len(sha) == 40 for _, sha in uses), str(uses))
    check("no script depends on xxd", not any("xxd" in (SCRIPTS / f).read_text().replace("# Also provides hex helpers so no script depends on xxd", "").replace("No xxd anywhere", "")
                                              for f in os.listdir(SCRIPTS) if f.endswith(".sh")))

    print()
    if FAILED:
        print(f"{FAILED} FAILED, {PASSED} passed")
        return 1
    print(f"ALL {PASSED} PUBLISHER CHECKS PASSED")
    return 0


def requests_asset(base, rid, name):
    import urllib.request
    with urllib.request.urlopen(f"{base}/releases/latest/download/{name}") as r:
        return r.read()


if __name__ == "__main__":
    sys.exit(main())
