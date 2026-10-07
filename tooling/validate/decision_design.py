#!/usr/bin/env python3

"""Narrow structure and traceability checks for the ADR-001 design record."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

from citations import path_citations, tracked_paths


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LABEL = "docs/decisions/ADR-001-b-agentic-design-record.md"
DECISION_PATH = ROOT / DEFAULT_LABEL
REQUIRED_SECTIONS = ("Context", "Decision", "Consequences")
REQUIRED_DECISION_AREAS = (
    "Product boundary and architecture",
    "Workflow and skill design",
    "Safety and approval design",
    "MCP and external-evidence design",
    "Installation, configuration, and lifecycle",
    "Verification and change discipline",
)
H2_RE = re.compile(r"^##(?:[ \t]+(?P<name>.*?))?[ \t]*$", re.MULTILINE)
H3_RE = re.compile(r"^###(?:[ \t]+(?P<name>.*?))?[ \t]*$", re.MULTILINE)
HEADER_RULES = (
    (
        r"^- Status: (Proposed|Accepted|Superseded|Deprecated)[ \t]*$",
        "a '- Status:' line (Proposed, Accepted, Superseded, or Deprecated)",
    ),
    (r"^- Date: \d{4}-\d{2}-\d{2}[ \t]*$", "a '- Date: YYYY-MM-DD' line"),
    (r"^- Supersedes: \S.*$", "a '- Supersedes:' line"),
)


def source_references(text: str, tracked: set[str] | None = None) -> list[str]:
    return [
        reference
        for reference in path_citations(text, tracked, include_plain=False, include_prefix=False)
        if "*" not in reference
    ]


def split_bodies(text: str, heading_re: re.Pattern[str]) -> list[tuple[str, str]]:
    headings = list(heading_re.finditer(text))
    sections: list[tuple[str, str]] = []
    for index, heading in enumerate(headings):
        end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
        name = (heading.group("name") or "").strip()
        sections.append((name, text[heading.end() : end]))
    return sections


def section_bodies(text: str) -> list[tuple[str, str]]:
    return split_bodies(text, H2_RE)


def decision_areas(body: str) -> list[tuple[str, str]]:
    """Split a Decision body into its level-3 areas; text before the first area is intro."""
    return split_bodies(body, H3_RE)


def candidate_paths() -> set[str]:
    """Return tracked plus non-ignored candidate files without trusting ignored paths."""
    result = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], cwd=ROOT, capture_output=True, text=True)
    return set(result.stdout.splitlines()) if result.returncode == 0 else set()


def check_evidence(label: str, name: str, body: str, tracked: set[str]) -> list[str]:
    errors: list[str] = []
    if not re.search(r"\bEvidence:", body):
        errors.append(f"{label}: decision section {name!r} has no Evidence marker")
    if not any(reference in tracked for reference in source_references(body, tracked)):
        errors.append(f"{label}: decision section {name!r} has no tracked repository source reference")
    return errors


def validate(text: str, tracked: set[str], label: str = DEFAULT_LABEL) -> list[str]:
    # Generated delivery assets can be untracked during candidate
    # validation, but ignored on-disk files never qualify as traceable evidence.
    tracked = set(tracked) | candidate_paths()
    errors: list[str] = []
    sections = section_bodies(text)
    section_names = [name for name, _ in sections]
    expected = list(REQUIRED_SECTIONS)
    if section_names != expected:
        errors.append(f"{label}: top-level sections must be exactly {expected!r} in order; found {section_names!r}")

    first_heading = H2_RE.search(text)
    header = text[: first_heading.start()] if first_heading else text
    for pattern, description in HEADER_RULES:
        if not re.search(pattern, header, re.MULTILINE):
            errors.append(f"{label}: header must contain {description}")

    for name, body in sections:
        if name == "Decision":
            areas = decision_areas(body)
            area_names = [area_name for area_name, _ in areas]
            expected_areas = list(REQUIRED_DECISION_AREAS)
            if area_names != expected_areas:
                errors.append(
                    f"{label}: Decision areas must be exactly {expected_areas!r} in order; found {area_names!r}"
                )
            for area_name, area_body in areas:
                if area_name in REQUIRED_DECISION_AREAS:
                    errors.extend(check_evidence(label, area_name, area_body, tracked))
        elif name in REQUIRED_SECTIONS:
            errors.extend(check_evidence(label, name, body, tracked))

    references = source_references(text)
    for reference in sorted(set(references)):
        if reference not in tracked:
            errors.append(f"{label}: referenced repository source is not currently tracked: {reference}")
    if not references:
        errors.append(f"{label}: no repository source references found")
    return errors


VALID_HEADER = "# ADR-001: fixture\n\n- Status: Accepted\n- Date: 2026-01-01\n- Supersedes: none\n\n"


def fixture(
    section_names: list[str] | None = None,
    area_names: list[str] | None = None,
    header: str = VALID_HEADER,
) -> str:
    section_names = list(REQUIRED_SECTIONS) if section_names is None else section_names
    area_names = list(REQUIRED_DECISION_AREAS) if area_names is None else area_names
    blocks = []
    for name in section_names:
        block = f"## {name}\n"
        if name == "Decision":
            block += "\nIntro without evidence.\n\n"
            block += "\n\n".join(f"### {area}\nEvidence: `README.md`." for area in area_names) + "\n"
        else:
            block += "Evidence: `README.md`.\n"
        blocks.append(block)
    return header + "\n".join(blocks)


def self_test() -> int:
    tracked = {"README.md"}
    expected = list(REQUIRED_SECTIONS)
    areas = list(REQUIRED_DECISION_AREAS)
    good = fixture()
    if validate(good, tracked, "fixture"):
        print("ADR-001 self-test failed: complete fixture was rejected", file=sys.stderr)
        return 1

    wrong_order = expected.copy()
    wrong_order[0], wrong_order[1] = wrong_order[1], wrong_order[0]
    extra_section = expected[:1] + ["Extra section"] + expected[1:]
    reordered_areas = areas.copy()
    reordered_areas[0], reordered_areas[1] = reordered_areas[1], reordered_areas[0]
    consequences_no_evidence = good.replace("## Consequences\nEvidence:", "## Consequences\nSupport:")
    cases = [
        (fixture(wrong_order), "top-level sections must be exactly"),
        (fixture(extra_section), "top-level sections must be exactly"),
        (fixture(area_names=areas[1:]), "Decision areas must be exactly"),
        (fixture(area_names=reordered_areas), "Decision areas must be exactly"),
        (good.replace("README.md", "tooling/missing.py", 1), "not currently tracked"),
        (good.replace("Evidence:", "Support:", 1), "no Evidence marker"),
        (consequences_no_evidence, "decision section 'Consequences' has no Evidence marker"),
        (fixture(header="# ADR-001: fixture\n\n- Date: 2026-01-01\n- Supersedes: none\n\n"), "'- Status:' line"),
        (fixture(header=VALID_HEADER.replace("2026-01-01", "soon")), "'- Date: YYYY-MM-DD' line"),
    ]
    for text, expected_error in cases:
        errors = validate(text, tracked, "fixture")
        if not any(expected_error in error for error in errors):
            print(
                f"ADR-001 self-test failed: expected {expected_error!r}",
                file=sys.stderr,
            )
            return 1
    print("Decision-design structure and traceability self-test passed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Check decision-record structure and traceability.")
    parser.add_argument("--self-test", action="store_true", help="run focused parser checks")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not DECISION_PATH.exists():
        print(f"{DECISION_PATH.relative_to(ROOT)}: missing", file=sys.stderr)
        return 1
    decision_text = DECISION_PATH.read_text()
    tracked = tracked_paths()
    errors = validate(decision_text, tracked)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    references = sorted(set(source_references(decision_text, tracked)))
    print(f"Decision-design structure and traceability check passed ({len(references)} tracked source references).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
