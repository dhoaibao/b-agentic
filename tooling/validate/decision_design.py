#!/usr/bin/env python3

"""Narrow structure and traceability checks for the decision record."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

from citations import path_citations, tracked_paths


ROOT = Path(__file__).resolve().parents[2]
DECISION_PATH = ROOT / "docs" / "decision_design.md"
REQUIRED_SECTIONS = (
    "Scope and evidence",
    "Product boundary and architecture",
    "Workflow and skill design",
    "Safety and approval design",
    "MCP and external-evidence design",
    "Installation, configuration, and lifecycle",
    "Verification and change discipline",
    "Intentional non-goals",
)
H2_RE = re.compile(r"^##(?:[ \t]+(?P<name>.*?))?[ \t]*$", re.MULTILINE)


def source_references(text: str, tracked: set[str] | None = None) -> list[str]:
    return [
        reference
        for reference in path_citations(text, tracked, include_plain=False, include_prefix=False)
        if "*" not in reference
    ]


def section_bodies(text: str) -> list[tuple[str, str]]:
    headings = list(H2_RE.finditer(text))
    sections: list[tuple[str, str]] = []
    for index, heading in enumerate(headings):
        end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
        name = (heading.group("name") or "").strip()
        sections.append((name, text[heading.end() : end]))
    return sections


def candidate_paths() -> set[str]:
    """Return tracked plus non-ignored candidate files without trusting ignored paths."""
    result = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], cwd=ROOT, capture_output=True, text=True)
    return set(result.stdout.splitlines()) if result.returncode == 0 else set()


def validate(text: str, tracked: set[str], label: str = "docs/decision_design.md") -> list[str]:
    # Generated Pi delivery assets can be untracked during candidate
    # validation, but ignored on-disk files never qualify as traceable evidence.
    tracked = set(tracked) | candidate_paths()
    errors: list[str] = []
    sections = section_bodies(text)
    section_names = [name for name, _ in sections]
    expected = list(REQUIRED_SECTIONS)
    if section_names != expected:
        errors.append(f"{label}: top-level sections must be exactly {expected!r} in order; found {section_names!r}")

    for name, body in sections:
        if name not in REQUIRED_SECTIONS:
            continue
        if not re.search(r"\bEvidence:", body):
            errors.append(f"{label}: decision section {name!r} has no Evidence marker")
        if not any(reference in tracked for reference in source_references(body, tracked)):
            errors.append(f"{label}: decision section {name!r} has no tracked repository source reference")

    references = source_references(text)
    for reference in sorted(set(references)):
        if reference not in tracked:
            errors.append(f"{label}: referenced repository source is not currently tracked: {reference}")
    if not references:
        errors.append(f"{label}: no repository source references found")
    return errors


def fixture(section_names: list[str]) -> str:
    return "\n\n".join(f"## {name}\nEvidence: `README.md`." for name in section_names) + "\n"


def self_test() -> int:
    tracked = {"README.md"}
    expected = list(REQUIRED_SECTIONS)
    good = fixture(expected)
    if validate(good, tracked, "fixture"):
        print("decision-design self-test failed: complete fixture was rejected", file=sys.stderr)
        return 1

    wrong_order = expected.copy()
    wrong_order[0], wrong_order[1] = wrong_order[1], wrong_order[0]
    extra_section = expected[:1] + ["Extra section"] + expected[1:]
    cases = [
        (fixture(wrong_order), "top-level sections must be exactly"),
        (fixture(extra_section), "top-level sections must be exactly"),
        (good.replace("README.md", "tooling/missing.py", 1), "not currently tracked"),
        (good.replace("Evidence:", "Support:", 1), "no Evidence marker"),
    ]
    for text, expected_error in cases:
        errors = validate(text, tracked, "fixture")
        if not any(expected_error in error for error in errors):
            print(
                f"decision-design self-test failed: expected {expected_error!r}",
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
