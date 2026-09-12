# Release procedure

Maintainer reference for the automated release flow. Every push to `main`
publishes a release: the release workflow (`.github/workflows/release.yml`)
re-runs the quality gates on the pushed commit, builds the checksum-verified
bundle, and publishes a release whose tag is derived from `VERSION` — no
manual tagging, no personal access token, and no stored secrets (the built-in
`GITHUB_TOKEN` with `contents: write` is the only credential).

## Version contract

- `VERSION` at the repository root holds exactly `vYYYY.MM.DD` and equals the newest `## [vYYYY.MM.DD] - YYYY-MM-DD` heading in `CHANGELOG.md` (enforced by `tooling/validate/changelog.py`).
- The published release tag is `$(cat VERSION).N` (for example `v2026.09.12.2`), where `N` is one plus the number of existing tags matching `$(cat VERSION).*` on the remote. The ordinal lives only in the tag and the shipped payload.
- One changelog section per calendar date; same-day changes aggregate into that section. Same-day pushes reuse the section and increment the ordinal instead of creating a new dated section.
- The date base comes from the committed `VERSION` file, never the runner clock, so the extracted notes always have a matching changelog section.
- `CHANGELOG.md` headings, `tooling/validate/changelog.py`, and the one-section-per-day rule are unchanged by the ordinal scheme.

## What the workflow does, in order

1. Checkout and Python 3.12 setup.
2. Resolve the release version: read `VERSION`, assert it matches `vYYYY.MM.DD`, count existing remote `VERSION.*` tags with `git ls-remote`, and take `RELEASE_VERSION = VERSION.N` (first push of a day yields `.1`). The run fails loudly if the tag already exists.
3. Full gates on the pristine tree: `bash -n` on the release scripts, `bash scripts/validate-skills.sh --release`, `bash scripts/smoke-install.sh`, and `bash scripts/b-agentic-audit.sh --skip-preflight`. Because the gates run before the stamp, changelog validation still sees the committed `VERSION`.
4. Stamp the runner copy of `VERSION` with the full `RELEASE_VERSION` so the shipped payload self-identifies with the exact release. The workflow never commits or pushes to `main`; the repository's `VERSION` stays `vYYYY.MM.DD`.
5. Build the bundle with `scripts/build-release.sh` and extract notes with `bash scripts/extract-release-notes.sh "$BASE_VERSION" CHANGELOG.md` — the bare date resolved in step 2, not the ordinal.
6. Publish with `gh release create "$RELEASE_VERSION" --target "$GITHUB_SHA"`, which creates the tag itself, so no `git push` is needed and a workflow-created tag cannot suppress another workflow.

## Before pushing

Run the same gates the workflow runs; a failed gate blocks the release but not
the push, so `main` can sit ahead of the latest release until the next green
push:

```bash
bash -n install.sh scripts/build-release.sh scripts/extract-release-notes.sh
bash scripts/validate-skills.sh --release
bash scripts/b-agentic-audit.sh --skip-preflight
bash scripts/smoke-install.sh
bash scripts/build-release.sh dist
(cd dist && sha256sum -c b-agentic.tar.gz.sha256)
bash scripts/extract-release-notes.sh "$(cat VERSION)" CHANGELOG.md
```

`scripts/build-release.sh` stages the release payload allowlist (`install.sh`,
`VERSION`, `skills/`, `references/`, `adapters/pi/{manifest.yaml,configs,extensions,packages,scripts}`,
`tooling/install/{common.sh,json_cleanup.py,jsonc.py,manifest_uninstall.py}`),
rejects symlinks and dependency trees, and emits `dist/b-agentic.tar.gz` plus
its checksum. Docs, tests, generators, validators, and CI configuration never
ship.

## First release

No manual first tag exists or is needed: the first push to `main` after this
workflow lands publishes the day's `.1` release automatically (for
`VERSION=v2026.09.12`, that is `v2026.09.12.1`). Until that first release
exists, the piped `main` installer downloads
`releases/latest/download/b-agentic.tar.gz` and fails with an actionable
error.

`--ref` pins a specific release (`releases/download/<ref>/...`); it accepts
only `vYYYY.MM.DD.N` tags — bare dates, commit SHAs, and SemVer tags are
rejected. The standalone preview-markdown installer
(`adapters/pi/scripts/install-preview-markdown.sh`) keeps its own SemVer
(`vX.Y.Z`) tag line and is unaffected by CalVer releases.
