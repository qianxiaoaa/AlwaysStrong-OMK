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
