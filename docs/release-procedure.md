# Release procedure

Maintainer reference for the automated release flow. A push to `main` (or a
manual dispatch on `main`) can publish a release: the `release` job in the CI
workflow (`.github/workflows/validate.yml`) runs only after the `validate` job
passes on both matrix legs, then builds and publishes the checksum-verified
bundle without re-running the gates. There is no manual tagging, personal
access token, or stored secret (the built-in `GITHUB_TOKEN` with
`contents: write` is the only credential).

## Version contract

- `VERSION` at the repository root holds exactly `vYYYY.MM.DD` and equals the newest `## [vYYYY.MM.DD] - YYYY-MM-DD` heading in `CHANGELOG.md` (enforced by `tooling/validate/changelog.py`).
- The published release tag is `$(cat VERSION).N` (for example `v2026.09.12.2`), where `N` is one plus the number of existing tags matching `$(cat VERSION).*` on the remote. The ordinal lives only in the tag and the shipped payload.
- One changelog section per calendar date; same-day changes aggregate into that section. Same-day pushes reuse the section and increment the ordinal instead of creating a new dated section.
- The date base comes from the committed `VERSION` file, never the runner clock, so the extracted notes always have a matching changelog section.
- `CHANGELOG.md` headings, `tooling/validate/changelog.py`, and the one-section-per-day rule are unchanged by the ordinal scheme.

## What the workflow does, in order

1. The `validate` job runs its quality, validation, and structural-audit gates on
   both Ubuntu and macOS matrix legs. The release job cannot start unless both
   legs pass; the gates run on the pristine tree before the release stamp, so
   changelog validation sees the committed `VERSION`.
2. The `release` job checks out the source and resolves the release version:
   read `VERSION`, assert it matches `vYYYY.MM.DD`, count existing remote
   `VERSION.*` tags with `git ls-remote`, and take `RELEASE_VERSION = VERSION.N`
   (the first push of a day yields `.1`). The run fails loudly if the tag
   already exists.
3. Check shell syntax with `bash -n` on the release scripts.
4. Stamp the runner copy of `VERSION` with the full `RELEASE_VERSION` so the
   shipped payload self-identifies with the exact release. The workflow never
   commits or pushes to `main`; the repository's `VERSION` stays
   `vYYYY.MM.DD`.
5. Build the bundle with `scripts/build-release.sh` and extract notes with
   `bash scripts/extract-release-notes.sh "$BASE_VERSION" CHANGELOG.md` — the
   bare date resolved in step 2, not the ordinal.
6. Publish with `gh release create "$RELEASE_VERSION" --target "$GITHUB_SHA"`,
   which creates the tag itself, so no `git push` is needed and a
   workflow-created tag cannot suppress another workflow.

## Before pushing

Run the validation-job gates and release packaging checks locally; a failed
gate blocks the release but not the push, so `main` can sit ahead of the latest
release until the next green push:

```bash
bash -n install.sh scripts/build-release.sh scripts/extract-release-notes.sh
bash scripts/validate-skills.sh --release
bash scripts/b-agentic-audit.sh --skip-preflight
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
