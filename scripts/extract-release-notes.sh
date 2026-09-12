#!/usr/bin/env bash
# extract-release-notes.sh - Extract one exact release section from a
# Keep a Changelog file.
#
#   scripts/extract-release-notes.sh VERSION CHANGELOG
set -eu

if [ "$#" -ne 2 ]; then
	printf 'usage: %s VERSION CHANGELOG\n' "$0" >&2
	exit 2
fi

VERSION=$1
CHANGELOG=$2
[ -n "$VERSION" ] || {
	printf 'extract-release-notes: version is empty\n' >&2
	exit 2
}
[ -f "$CHANGELOG" ] || {
	printf 'extract-release-notes: changelog is missing: %s\n' "$CHANGELOG" >&2
	exit 2
}

awk -v wanted="$VERSION" '
function heading_version(line, bracket, suffix) {
  if (substr(line, 1, 4) != "## [") return ""
  bracket = index(substr(line, 5), "]")
  if (bracket == 0) return ""
  suffix = substr(line, 5 + bracket)
  if (suffix != "" && suffix !~ /^[[:space:]]+-[[:space:]]+[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][[:space:]]*$/) return ""
  return substr(line, 5, bracket - 1)
}

{
  if (substr($0, 1, 4) == "## [") {
    if (found) {
      done = 1
      next
    }
    version = heading_version($0)
    if (version == wanted) {
      found = 1
      next
    }
  }
  if (found && !done) lines[++count] = $0
}

END {
  if (!found) exit 3
  first = 1
  while (first <= count && lines[first] ~ /^[[:space:]]*$/) first++
  last = count
  while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
  if (first > last) exit 4
  for (i = first; i <= last; i++) print lines[i]
}
' "$CHANGELOG" || {
	status=$?
	case "$status" in
	3) printf 'extract-release-notes: release section not found: %s\n' "$VERSION" >&2 ;;
	4) printf 'extract-release-notes: release section is empty: %s\n' "$VERSION" >&2 ;;
	*) printf 'extract-release-notes: failed to read release section: %s\n' "$VERSION" >&2 ;;
	esac
	exit "$status"
}
