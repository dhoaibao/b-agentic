#!/usr/bin/env python3

"""Check the mechanical structure of the human-facing CHANGELOG."""

from __future__ import annotations

from datetime import date
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CHANGELOG_PATH = ROOT / "CHANGELOG.md"
VERSION_PATH = ROOT / "VERSION"
CATEGORY_NAMES = ("Added", "Changed", "Deprecated", "Removed", "Fixed", "Security")
CATEGORY_SET = set(CATEGORY_NAMES)
H2_RE = re.compile(r"^##(?:[ \t]+(?P<name>.*?))?[ \t]*$", re.MULTILINE)
H3_RE = re.compile(r"^###[ \t]+(?P<name>.+?)[ \t]*$", re.MULTILINE)
RELEASE_HEADING_RE = re.compile(
    r"^\[(?P<version>v(?P<year>\d{4})\.(?P<month>\d{2})\.(?P<day>\d{2}))"
    r"\] - (?P<date>\d{4}-\d{2}-\d{2})$"
)


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def validate(text: str) -> list[str]:
    errors: list[str] = []
    headings = list(H2_RE.finditer(text))
    releases = []
    release_versions: set[str] = set()
    release_dates: set[date] = set()
    sortable_releases: list[tuple[date, str, int]] = []

    for heading in headings:
        raw_name = heading.group("name")
        name = raw_name.strip() if raw_name is not None else ""
        line = line_number(text, heading.start())
        if not name:
            errors.append(f"CHANGELOG.md:{line}: empty level-2 heading; expected a release section")
            continue

        match = RELEASE_HEADING_RE.fullmatch(name)
        if match is None:
            errors.append(f"CHANGELOG.md:{line}: invalid release heading {name!r}; expected [vYYYY.MM.DD] - YYYY-MM-DD")
            continue

        version = match.group("version")
        if version in release_versions:
            errors.append(f"CHANGELOG.md:{line}: duplicate release version {version!r}")
        else:
            release_versions.add(version)

        version_date_text = f"{match.group('year')}-{match.group('month')}-{match.group('day')}"
        try:
            version_date = date.fromisoformat(version_date_text)
        except ValueError:
            errors.append(
                f"CHANGELOG.md:{line}: release heading {name!r} has invalid calendar version date {version_date_text!r}"
            )
            version_date = None

        release_date_text = match.group("date")
        try:
            release_date = date.fromisoformat(release_date_text)
        except ValueError:
            errors.append(f"CHANGELOG.md:{line}: release heading {name!r} has invalid ISO date {release_date_text!r}")
            release_date = None

        if version_date is not None and release_date is not None and version_date != release_date:
            errors.append(
                f"CHANGELOG.md:{line}: release heading {name!r} must use a date matching "
                f"its calendar version ({version_date.isoformat()})"
            )
        releases.append((heading, line))
        if version_date is not None and release_date is not None:
            if version_date in release_dates:
                errors.append(
                    f"CHANGELOG.md:{line}: duplicate release date {version_date.isoformat()!r}; "
                    "combine same-day changes in one release section"
                )
            else:
                release_dates.add(version_date)
            sortable_releases.append((version_date, version, line))

    previous_date: date | None = None
    previous_version: str | None = None
    for release_date, version, line in sortable_releases:
        if previous_date is not None and release_date >= previous_date:
            errors.append(
                f"CHANGELOG.md:{line}: release {version!r} is not older than preceding "
                f"release {previous_version!r}; releases must be newest first"
            )
        previous_date = release_date
        previous_version = version

    sections = releases
    for heading, line in sections:
        next_heading = next(
            (candidate for candidate in headings if candidate.start() > heading.start()),
            None,
        )
        body_end = next_heading.start() if next_heading is not None else len(text)
        body = text[heading.end() : body_end]
        seen: set[str] = set()
        for category_heading in H3_RE.finditer(body):
            category = category_heading.group("name").strip()
            category_line = line_number(text, heading.end() + category_heading.start())
            if category not in CATEGORY_SET:
                errors.append(
                    f"CHANGELOG.md:{category_line}: unsupported category {category!r}; "
                    f"expected one of {', '.join(CATEGORY_NAMES)}"
                )
            elif category in seen:
                errors.append(
                    f"CHANGELOG.md:{category_line}: duplicate {category!r} category "
                    f"in section {heading.group('name').strip()!r}"
                )
            else:
                seen.add(category)

    return errors


def newest_release_version(text: str) -> str | None:
    for heading in H2_RE.finditer(text):
        name = heading.group("name")
        if name is None:
            continue
        match = RELEASE_HEADING_RE.fullmatch(name.strip())
        if match is not None:
            return match.group("version")
    return None


def validate_version_file(text: str) -> list[str]:
    errors: list[str] = []
    if not VERSION_PATH.exists():
        return ["VERSION: missing; expected the newest `## [vYYYY.MM.DD]` version"]
    version = VERSION_PATH.read_text().strip()
    if not version:
        return ["VERSION: empty; expected the newest `## [vYYYY.MM.DD]` version"]
    if version != version.strip("\n") and "\n" in version:
        errors.append("VERSION: multi-line content; expected exactly one version token")
    newest = newest_release_version(text)
    if newest is None:
        errors.append("VERSION: CHANGELOG.md has no release heading to compare against")
    elif version != newest:
        errors.append(f"VERSION: {version!r} does not match the newest CHANGELOG.md release heading {newest!r}")
    return errors


def main() -> int:
    if not CHANGELOG_PATH.exists():
        print("CHANGELOG.md: missing", file=sys.stderr)
        return 1
    text = CHANGELOG_PATH.read_text()
    errors = validate(text)
    errors.extend(validate_version_file(text))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    release_count = sum(
        RELEASE_HEADING_RE.fullmatch(heading.group("name").strip()) is not None for heading in H2_RE.finditer(text)
    )
    print(f"CHANGELOG format/structure validation passed ({release_count} release sections)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
