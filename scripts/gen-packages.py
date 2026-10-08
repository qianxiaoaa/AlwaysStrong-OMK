#!/usr/bin/env python3
"""Build and sign the AlwaysStrong-OMK component (packages) index.

Reads packages/sources.json, resolves each component's latest upstream GitHub
release (or a pinned URL), downloads the asset, computes its sha256/size, parses
the module version out of a zip's module.prop, and signs the asset bytes with the
module's Ed25519 key. The result is written to mirror/packages.json (via
--out) together with a detached Ed25519 signature over the exact index bytes
(<out>.sig).

The device verifies <out>.sig against mirror/packages.json with the bundled
public key before trusting any entry, then re-verifies each downloaded
component against the per-entry signature. Trust root = the key, so the index
and the packages may be served from any mirror/CDN.

Key source (one of):
  --key-file PATH                 PEM Ed25519 private key
  ALWAYSSTRONG_SIGNING_KEY env    base64(PKCS8 PEM) — same secret as the release manifest

GitHub API token (optional but recommended, for rate limits):
  GITHUB_TOKEN / GH_TOKEN

Exit: 0 ok · 2 bad input/tooling · 3 nothing resolved · 1 other failure
"""

import argparse
import base64
import datetime
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

UA = "AlwaysStrong-OMK-packages/1.0"


def die(msg, code=1):
    print("gen-packages: " + msg, file=sys.stderr)
    sys.exit(code)


def load_private_key(key_file):
    try:
        from cryptography.hazmat.primitives.serialization import load_pem_private_key
    except Exception as e:  # noqa: BLE001
        die("python 'cryptography' is required: %s" % e, 2)
    pem = None
    if key_file:
        with open(key_file, "rb") as fh:
            pem = fh.read()
    else:
        b64 = os.environ.get("ALWAYSSTRONG_SIGNING_KEY", "").strip()
        if not b64:
            die("provide --key-file or ALWAYSSTRONG_SIGNING_KEY", 2)
        try:
            pem = base64.b64decode(b64)
        except Exception as e:  # noqa: BLE001
            die("ALWAYSSTRONG_SIGNING_KEY is not valid base64: %s" % e, 2)
    try:
        return load_pem_private_key(pem, password=None)
    except Exception as e:  # noqa: BLE001
        die("failed to load private key: %s" % e, 2)


def token():
    return os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""


def http_get(url, tok=None, api=False, timeout=60):
    headers = {"User-Agent": UA, "Accept": "application/vnd.github+json"}
    if tok and api:
        headers["Authorization"] = "token " + tok
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def github_latest(repo, tok, timeout=30):
    if not re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", repo or ""):
        return None
    try:
        raw = http_get("https://api.github.com/repos/%s/releases/latest" % repo, tok, api=True, timeout=timeout)
        j = json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as e:
        print("  ! github api %s -> HTTP %s" % (repo, e.code), file=sys.stderr)
        return None
    except Exception as e:  # noqa: BLE001
        print("  ! github api %s -> %s" % (repo, e), file=sys.stderr)
        return None
    tag = j.get("tag_name") or ""
    assets = [(a.get("name", ""), a.get("browser_download_url", ""), a.get("size", 0))
              for a in j.get("assets", [])]
    return {"tag": tag, "assets": assets}


def pick_asset(assets, pattern):
    rx = re.compile(pattern)
    for name, url, size in assets:
        if name and url and rx.search(name):
            return name, url, size
    return None


def download(url, tok, timeout=180):
    # release assets: try without the token first (a wrong-scope token can 401),
    # then with it (private/rate-limited cases).
    last = None
    for use_tok in (False, True):
        try:
            headers = {"User-Agent": UA}
            if use_tok and tok:
                headers["Authorization"] = "token " + tok
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            last = e
            if not tok:
                break
    raise RuntimeError("download failed: %s" % last)


def read_module_prop(zip_bytes):
    """Return dict from module.prop inside a zip, or None.

    zipfile cannot always decompress new methods (e.g. zstd); fall back to a
    system `unzip -p` for the same entry.
    """
    body = None
    try:
        with zipfile.ZipFile(io.BytesIO(zip_bytes)) as z:
            best = None
            for info in z.infolist():
                name = info.filename.replace("\\", "/")
                if name.rsplit("/", 1)[-1] == "module.prop":
                    if best is None or len(name) < len(best):
                        best = name
            if best is not None:
                try:
                    body = z.read(best)
                except Exception:  # noqa: BLE001
                    body = None
    except Exception:  # noqa: BLE001
        body = None
    if not body:
        with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as tf:
            tf.write(zip_bytes)
            path = tf.name
        try:
            body = subprocess.run(["unzip", "-p", path, "module.prop"],
                                  capture_output=True, timeout=60).stdout
        except Exception:  # noqa: BLE001
            body = b""
        finally:
            os.unlink(path)
    if not body:
        return None
    out = {}
    for line in body.decode("utf-8", "replace").splitlines():
        m = re.match(r"^(id|name|version|versionCode)=(.*)$", line.strip())
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out if out.get("id") else None


def sign(private_key, data):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: F401
    return base64.b64encode(private_key.sign(data)).decode("ascii")


def jstr(v):
    return json.dumps(v, ensure_ascii=False)


def build_index(entries):
    """Compact one-entry-per-line JSON (device parses it line-wise with awk)."""
    names = [k for k in entries.keys() if not k.startswith("__")]
    lines = ["{"]
    lines.append('  "schema": 1,')
    lines.append('  "generated_at": %s,' % jstr(entries["__ts__"]))
    lines.append('  "repo": %s,' % jstr(entries["__repo__"]))
    lines.append('  "count": %d,' % len(names))
    lines.append('  "modules": {')
    for i, name in enumerate(names):
        e = entries[name]
        parts = []
        for k, v in e.items():
            parts.append("%s:%s" % (jstr(k), str(v) if isinstance(v, int) else jstr(v)))
        sep = "," if i < len(names) - 1 else ""
        lines.append('    %s: {%s}%s' % (jstr(name), ",".join(parts), sep))
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--registry", default="packages/sources.json")
    ap.add_argument("--out", required=True, help="path to write packages.json")
    ap.add_argument("--repo", default="qianxiaoaa/AlwaysStrong-OMK")
    ap.add_argument("--key-file", default="")
    ap.add_argument("--only", default="", help="only build these names (comma-separated)")
    args = ap.parse_args()

    if not os.path.isfile(args.registry):
        die("registry not found: %s" % args.registry, 2)
    with open(args.registry, "r", encoding="utf-8") as fh:
        registry = json.load(fh)

    only = set(x.strip() for x in args.only.split(",") if x.strip())
    key = load_private_key(args.key_file)
    tok = token()

    entries = {
        "__ts__": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "__repo__": args.repo,
    }
    n_ok = 0
    for name, src in registry.items():
        if name.startswith("_") or not isinstance(src, dict):
            continue
        if only and name not in only:
            continue
        print("==> %s (%s)" % (name, src.get("github_release") or src.get("pin_url", "")))
        pin = src.get("pin_url", "")
        tag = "pinned"
        url = ""
        if pin:
            url = pin
        else:
            rel = github_latest(src.get("github_release", ""), tok)
            if not rel:
                print("  ! no release resolved; skipping", file=sys.stderr)
                continue
            picked = pick_asset(rel["assets"], src.get("asset_match", ""))
            if not picked:
                print("  ! no asset matched %r; skipping" % src.get("asset_match", ""), file=sys.stderr)
                continue
            _, url, _ = picked
            tag = rel["tag"]
        try:
            data = download(url, tok)
        except Exception as e:  # noqa: BLE001
            print("  ! %s; skipping" % e, file=sys.stderr)
            continue
        sha = hashlib.sha256(data).hexdigest()
        entry = {
            "sha256": sha,
            "size": len(data),
            "url": url,
            "signature": sign(key, data),
            "x-type": "apk" if src.get("type") == "apk" else "ksu-module",
            "x-auto": 1 if src.get("auto") else 0,
        }
        if src.get("package"):
            entry["x-package"] = src["package"]
        entry["source"] = src.get("github_release", "") or "pinned"
        entry["tag"] = tag
        if entry["x-type"] == "ksu-module":
            meta = read_module_prop(data)
            if meta:
                entry["x-id"] = meta["id"]
                if meta.get("name"):
                    entry["x-name"] = meta["name"]
                if meta.get("version"):
                    entry["x-version"] = meta["version"]
                if meta.get("versionCode", "").isdigit():
                    entry["x-versionCode"] = int(meta["versionCode"])
        elif src.get("package"):
            # APK carries no module.prop; keep the tag as a human version hint
            entry["x-version"] = tag
        entries[name] = entry
        n_ok += 1
        print("    %s  sha256=%s  %d bytes  tag=%s" % (name, sha[:16], len(data), tag))

    if n_ok == 0:
        die("no components resolved", 3)

    text = build_index(entries)
    out = args.out
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(text)
    sig = base64.b64encode(key.sign(text.encode("utf-8"))).decode("ascii")
    with open(out + ".sig", "w", encoding="ascii") as fh:
        fh.write(sig)
    print("==> wrote %s (%d components) + %s.sig" % (out, n_ok, out))


if __name__ == "__main__":
    main()
