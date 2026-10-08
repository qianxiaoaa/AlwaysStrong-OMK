# User Instruction Memory

This file records user instructions, preferences, and teachings for reference in future interactions.

## Format

### User Instruction Entry
[User Instruction Summary]
- Date: [YYYY-MM-DD]
- Context: [Mentioned scenario or time]
- Instructions:
  - [Content of user teaching or instruction, described line by line]

### Project Knowledge Entry
[Project Knowledge Summary]
- Date: [YYYY-MM-DD]
- Context: Discovered by Agent while performing [specific task description]
- Category: [Operations & Deployment|Build Methods|Testing Methods|Troubleshooting & Debugging|Workflow & Collaboration|Environment Configuration]
- Instructions:
  - [Specific knowledge points, described line by line]

## Deduplication Strategy
- Before adding a new entry, check for similar or identical instructions.
- If a duplicate is found, skip the new entry or merge it with the existing one.
- When merging, update the context or date information.
- This helps avoid redundant entries and keeps the memory file tidy.

## Entries

[Project Knowledge Summary]
- Date: 2026-10-08
- Context: Discovered by Agent while pushing the AlwaysStrong-OMK v1.0.5-omk-r2/r3 releases
- Category: Workflow & Collaboration
- Instructions:
  - Remotes: `origin` = https://github.com/UtMostUR/AlwaysStrong-OMK (read-only upstream, token account has pull only); `fork` = https://github.com/qianxiaoaa/AlwaysStrong-OMK (writable, admin). Release/push always targets `fork`.
  - The configured git credential helper (`/app/agent/bin/agent git-credential-helper`) returns HTTP 500 in this environment, so `git credential fill` and a plain `git push` fail with "could not read Username". `/root/.git-credentials` is absent and `gh` is not logged in.
  - Workaround that works: pass an explicit token via an auth header, never embed it in the remote URL or echo it:
    `git -c credential.helper= -c http.extraHeader="Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)" push fork <ref>`
  - The GitHub Releases API works with the same token; create the release via `POST /repos/<owner>/<repo>/releases`, then upload the asset to its `upload_url`.

[Project Knowledge Summary]
- Date: 2026-10-08
- Context: Discovered by Agent while building and releasing AlwaysStrong-OMK
- Category: Build Methods
- Instructions:
  - Build: `bash build.sh --omk-file /tmp/opencode/omk135.zip` (the local OhMyKeymint payload avoids re-downloading). Output: `out/AlwaysStrong-<version>.zip`. Run builds through the background-terminal tool per the resource rules.
  - Revision bump: `bash scripts/bump-r.sh` increments the `-omk-rN` suffix, updates `module/module.prop` (`version` + `versionCode`) and prepends a `CHANGELOG.md` section, taking notes from `.upstream-changes.txt` (or `UPSTREAM_SUMMARY`). Prints the new tag.
  - The release workflow `.github/workflows/upstream-release.yml` runs daily 02:00 Beijing (cron `0 18 * * *`) to re-pin OhMyKeymint/PlayIntegrityFork and bump `-omk-rN` automatically.
  - Every new `module/*.sh` must be named in `module/customize.sh`'s extraction list, or `build.sh`'s install-coverage check ("every staged script has an installer") fails the build.
  - `out/`, `build/`, `*.zip`, `*.bak` are gitignored; `.upstream-changes.txt` is a transient input to `bump-r.sh`, not committed.

[Project Knowledge Summary]
- Date: 2026-10-08
- Context: Discovered by Agent while implementing the signed self-update (Phase 2)
- Category: Operations & Deployment
- Instructions:
  - Update trust root: Ed25519. Public key bundled at `module/pubkey.b64` (+ `module/pubkey.fp` = sha256 of that file, first 16 hex). Private key lives ONLY in the Actions secret `ALWAYSSTRONG_SIGNING_KEY` (base64 of a PKCS8 PEM). If that secret is lost the update chain must be re-cut and devices re-flashed.
  - Sign locally: `openssl pkeyutl -sign -inkey key.pem -rawin -in <zip> -out sig`; the manifest's `signature` is base64 of those 64 raw bytes.
  - Distribution channel: `mirror-data` branch holds `mirror/manifest.json`; devices fetch it from raw.githubusercontent + jsDelivr edges, and the zip from the GitHub release. Releases also carry `manifest.json` as an asset.
  - Publish a manifest for a release: `ALWAYSSTRONG_SIGNING_KEY=... GH_TOKEN=... MIRROR_REMOTE=<remote> bash scripts/publish-manifest.sh <tag> <owner/repo>` (downloads the release zip, signs, attaches, pushes `mirror-data`). The `mirror-data` branch must already exist (created once via the Git Data API).
  - The scheduled release workflow calls `publish-manifest.sh` inline after `gh release create`, because releases made with `GITHUB_TOKEN` do NOT trigger other workflows (`release: published` fires only for human/other-token releases).
  - Set/refresh Actions secrets with `GH_TOKEN=<pat> gh secret set NAME --repo OWNER/REPO --body <value>` (the `gh` CLI handles libsodium encryption; plain API PUT would require sealed-box).
  - Rebuild the verifier binaries: `bash scripts/build-verifier.sh` (pure-Go cross-compile to GOOS=linux for the 4 ABIs; no NDK).
  - Component index (P3): `packages/sources.json` lists components; `scripts/gen-packages.py` resolves upstream releases and emits `packages.json` + `packages.json.sig` (detached Ed25519 over the exact index bytes, same key/secret as the module manifest). Publish with `ALWAYSSTRONG_SIGNING_KEY=... GH_TOKEN=... MIRROR_REMOTE=<remote> bash scripts/publish-packages.sh <owner/repo>`; the scheduled `.github/workflows/packages.yml` does it automatically. Device client is `module/components.sh` (verify index -> per-package sha256+signature -> ksud/magisk or pm install -r).
  - Component auto-install is OFF by default: enable with `touch $CONFIG_DIR/components_auto` (modules flagged `x-auto`) and `touch $CONFIG_DIR/components_allow_apk` for APKs; `no_components` disables the whole feature.
  - NOTE (r7): the yypm backend (`module/common.sh` + `module/webui.sh` + `module/yypm_service.sh`) is now the single automatic owner of keybox fetch, component distribution and module self-update; `module/service.sh` no longer fetches them on its timer. The `auto_install` key in `/data/adb/tricky_store/yypm/config.prop` (WebUI "附属模块更新" switch, `webui.sh auto-install on|off`) gates *automatic* installs of `x-auto=1` entries; the manual "一键安装" (`webui.sh install-all`) is not gated. Component installs still verify the packages index + per-package sha256/Ed25519.
