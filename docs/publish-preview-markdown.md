# Publish the standalone preview package

Maintainer-only procedure for preparing and publishing the dedicated Pi package.
This does not replace the consumer installation guidance in the package README.

## Package location

The package root is:

```text
adapters/pi/packages/preview-markdown
```

It contains the package manifest, package-facing README, and the one canonical
extension source under `extensions/`. Do not create a second copy of the
extension or publish from the repository root.

## Validate the source package

From the repository root, run the canonical repository-local validator:

```bash
bash adapters/pi/scripts/validate-preview-markdown-package.sh
```

The validator reads the package manifest, checks the Pi manifest and peer
dependencies, runs an offline `npm pack`, verifies the exact package entries,
and confirms that the packed manifest discovers the extension. It does not
publish, authenticate, or change npm state.

## Inspect the tarball without publishing

Review npm's dry-run file report first:

```bash
cd adapters/pi/packages/preview-markdown
npm pack --dry-run --ignore-scripts
```

For an exact archive listing, create a temporary destination and inspect the
archive that npm produced:

```bash
package_dir="$PWD"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/preview-markdown-pack.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
pack_json="$(npm pack --ignore-scripts --json --pack-destination "$work_dir")"
tarball="$(node -e 'process.stdout.write(JSON.parse(process.argv[1])[0].filename)' "$pack_json")"
tar -tzf "$work_dir/$tarball" | LC_ALL=C sort
```

The intended archive contains only:

```text
package/README.md
package/extensions/b-agentic-preview-markdown.ts
package/package.json
```

Do not use `npm publish --dry-run` as a substitute for the repository
validator; run both the validator and the tarball inspection when reviewing a
release candidate.

## Verify npm identity and scope safely

Before publishing, verify the registry and authenticated identity without
printing credentials:

```bash
npm whoami --registry=https://registry.npmjs.org/
npm config get registry
npm config get @dhoaibao:registry
```

Confirm that the account reported by `npm whoami` is authorized to publish the
`@dhoaibao` scope. A successful login does not by itself prove scope access.
Use npm's account or organization settings for that confirmation; never print,
copy, or commit an `.npmrc` containing an access token.

## Version and publish

Read the package identity and version from the manifest rather than copying a
release number into this procedure:

```bash
cd adapters/pi/packages/preview-markdown
package_name="$(node -p "require('./package.json').name")"
package_version="$(node -p "require('./package.json').version")"
printf '%s@%s\n' "$package_name" "$package_version"
```

npm package versions are immutable. If npm reports that this exact
`$package_name@$package_version` already exists, update only the package
manifest to the next valid release version, then rerun validation and tarball
inspection before retrying. Never retry a rejected publish with the same
version.

After the checks pass and scope access is confirmed, publish from the dedicated
package directory:

```bash
cd adapters/pi/packages/preview-markdown
npm publish --access public
```

The manifest's `publishConfig.access` is `public`, and the explicit flag keeps
the intended public-access behavior visible at the publishing command.

## Verify after publishing

Use the manifest-derived name and version to verify npm made the expected
release visible:

```bash
cd adapters/pi/packages/preview-markdown
package_name="$(node -p "require('./package.json').name")"
package_version="$(node -p "require('./package.json').version")"
npm view "$package_name@$package_version" version dist.tarball
```

From a disposable or reviewed Pi profile, install the package through Pi and
start or reload Pi. Confirm that the `preview_markdown` tool and the
`/preview-markdown:render`, `/preview-markdown:theme`, and
`/preview-markdown:list` commands are discoverable, then render a preview and
exercise theme switching and source copying.

## Boundaries

- `npm publish` uploads the package only. It does not create a Git commit, tag,
  push, or release in GitHub.
- The raw GitHub installer is a separate release path. Its version-pinned
  bootstrap URL and downloaded source require a corresponding public GitHub
  tag; publishing the npm package does not create that tag.
- The raw installer remains separate from the full b-agentic installer and does
  not install the broader b-agentic bundle.
