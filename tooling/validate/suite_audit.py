#!/usr/bin/env python3

"""Structural suite audit for b-agentic's Pi integration."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MAX_KERNEL_LINES = 120
MAX_KERNEL_BYTES = 7_000


def run_cmd(cmd: list[str], label: str) -> bool:
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        print(f"{label} failed:", file=sys.stderr)
        print(result.stdout, file=sys.stderr, end="")
        print(result.stderr, file=sys.stderr, end="")
        return False
    print(f"{label} passed")
    return True


def skill_names() -> list[str]:
    try:
        registry = json.loads((ROOT / "skills" / "registry.yaml").read_text())
    except (OSError, json.JSONDecodeError):
        return []
    return sorted(skill["name"] for skill in registry.get("skills", []) if isinstance(skill, dict) and isinstance(skill.get("name"), str))


def audit_slimness(errors: list[str]) -> None:
    kernel = ROOT / "references" / "kernel.template.md"
    text = kernel.read_text()
    lines = len(text.splitlines())
    size = len(text.encode())
    if lines > MAX_KERNEL_LINES or size > MAX_KERNEL_BYTES:
        errors.append(f"{kernel.relative_to(ROOT)}: kernel exceeds slimness limit ({lines} lines/{size} bytes; max {MAX_KERNEL_LINES} lines/{MAX_KERNEL_BYTES} bytes)")


def audit_unresolved_tokens(errors: list[str]) -> None:
    paths = [ROOT / "README.md", ROOT / "references" / "kernel.template.md", *(ROOT / "skills" / name / "SKILL.md" for name in skill_names())]
    for path in paths:
        if path.exists() and "{{" in path.read_text():
            errors.append(f"{path.relative_to(ROOT)}: unresolved template token")


def main() -> int:
    all_ok = run_cmd([sys.executable, "tooling/generate/registry_sync.py", "--check"], "Generated asset sync")
    all_ok &= run_cmd(["bash", "scripts/validate-skills.sh"], "Validation suite")
    errors: list[str] = []
    audit_slimness(errors)
    audit_unresolved_tokens(errors)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    if not all_ok:
        return 1
    print("b-agentic structural suite audit (automated checks) passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
