#!/usr/bin/env python3
"""Generate the signed AlwaysStrong update manifest.

The device trusts a bundled Ed25519 public key (module/pubkey.b64), not a
server. This script produces `manifest.json`, whose `module` entry carries the
update zip's sha256, size and a base64 detached signature. The release workflow
signs the zip with the ALWAYSSTRONG_SIGNING_KEY secret (openssl) and feeds the
signature in here; the device verifies it with the bundled verify_tool before
installing anything.

Usage:
  gen-manifest.py --zip PATH --sig-file PATH --out PATH \
                  --repo OWNER/REPO --tag TAG [--keybox PATH] [--published-at ISO8601]

The version and versionCode are read from the zip's own module.prop, so the
manifest can never disagree with the artifact. Exit codes: 0 ok, 2 bad input.
"""
import argparse
import hashlib
import json
import os
import sys
import zipfile


def read_prop(zip_path):
    with zipfile.ZipFile(zip_path) as z:
        with z.open("module.prop") as fh:
            text = fh.read().decode("utf-8", "replace")
    props = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        props[k.strip()] = v.strip()
    return props


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", required=True)
    ap.add_argument("--sig-file", required=True,
                    help="file holding the base64 detached signature of --zip")
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo", required=True, help="OWNER/REPO")
    ap.add_argument("--tag", required=True, help="release tag, e.g. v1.0.5-omk-r4")
    ap.add_argument("--keybox", default="", help="optional keybox.xml to pin")
    ap.add_argument("--published-at", default="")
    args = ap.parse_args()

    if not os.path.isfile(args.zip):
        sys.stderr.write("zip not found: %s\n" % args.zip)
        return 2
    if not os.path.isfile(args.sig_file):
        sys.stderr.write("signature not found: %s\n" % args.sig_file)
        return 2

    props = read_prop(args.zip)
    version = props.get("version", "")
    vc_raw = props.get("versionCode", "")
    if not version or not vc_raw.isdigit():
        sys.stderr.write("module.prop missing version/versionCode\n")
        return 2
    version_code = int(vc_raw)

    with open(args.zip, "rb") as fh:
        blob = fh.read()
    with open(args.sig_file) as fh:
        signature = fh.read().strip()

    zip_name = os.path.basename(args.zip)
    module_entry = {
        "url": "https://github.com/%s/releases/download/%s/%s" % (args.repo, args.tag, zip_name),
        "sha256": hashlib.sha256(blob).hexdigest(),
        "size": len(blob),
        "signature": signature,
        "version": version,
        "version_code": version_code,
    }

    manifest = {
        "version": version,
        "version_code": version_code,
        "repo": args.repo,
        "generated_at": args.published_at or "",
        "module": module_entry,
    }

    if args.keybox:
        if not os.path.isfile(args.keybox):
            sys.stderr.write("keybox not found: %s\n" % args.keybox)
            return 2
        with open(args.keybox, "rb") as fh:
            kb = fh.read()
        manifest["keybox"] = {
            "sha256": hashlib.sha256(kb).hexdigest(),
            "size": len(kb),
        }

    with open(args.out, "w") as fh:
        json.dump(manifest, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    print("manifest: %s -> %s (vc=%d, sha256=%s)" %
          (zip_name, args.out, version_code, module_entry["sha256"][:16]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
