# Release procedure

Maintainer procedure for cutting a `vYYYY.MM.DD` release. The release workflow
(`.github/workflows/release.yml`) runs on every `v*` tag push, re-runs the
quality gates, builds the checksum-verified bundle, and publishes the release
with `b-agentic.tar.gz` and `b-agentic.tar.gz.sha256` assets.

## Version contract

- `VERSION` at the repository root holds exactly `vYYYY.MM.DD` and equals the newest `## [vYYYY.MM.DD] - YYYY-MM-DD` heading in `CHANGELOG.md` (enforced by `tooling/validate/changelog.py`).
- The git tag pushed for a release must equal `$(cat VERSION)` (enforced by the release workflow).
- One changelog section per calendar date; same-day changes aggregate into that section.

## Before tagging

Run the same gates the release workflow runs:

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

## Tag and publish

```bash
git tag "$(cat VERSION)"
git push origin "$(cat VERSION)"
```

The workflow then verifies the tag equals `VERSION`, runs the validation suite,
installer smoke suite, and structural audit, rebuilds the bundle, extracts the
release notes for the tagged section with `scripts/extract-release-notes.sh`,
and creates the GitHub release with both assets. Do not edit the release by
hand; fix, retag, and rerun.

## First release and installer bootstrap

The piped `main` installer downloads `releases/latest/download/b-agentic.tar.gz`
and fails with an actionable error until the first `vYYYY.MM.DD` release exists.
Cut the first tag in the same change window that lands the tarball transport so
the public install command never points at a releaseless repository.

`--ref` pins a specific release (`releases/download/<ref>/...`); it accepts only
`vYYYY.MM.DD` tags. The standalone preview-markdown installer
(`adapters/pi/scripts/install-preview-markdown.sh`) keeps its own SemVer
(`vX.Y.Z`) tag line and is unaffected by CalVer releases.
