#!/usr/bin/env python3

"""Suite audit for b-agentic self-review.

Runs the standard validation suite and adds audit-only checks for:
- source/generated asset synchronization
- kernel/template slimness
- no developer-marker comments in source
- runtime-template excluded from the registry
- no unresolved template tokens in generated assets
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def run_cmd(cmd: list[str], label: str) -> bool:
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"{label} failed:", file=sys.stderr)
        if result.stdout:
            print(result.stdout, file=sys.stderr)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        return False
    print(f"{label} passed")
    return True


def audit_slimness(errors: list[str]) -> None:
    kernels = sorted((ROOT / "runtimes").glob("*/kernel.md"))
    for kernel in kernels:
        if kernel.parent.name == "runtime-template":
            continue
        lines = len(kernel.read_text().splitlines())
        if lines > 120:
            errors.append(
                f"{kernel.relative_to(ROOT)}: kernel exceeds 120 lines ({lines}); "
                "consider moving runtime-specific guidance elsewhere"
            )

    template = ROOT / "references" / "contract" / "kernel.template.md"
    template_lines = len(template.read_text().splitlines())
    if template_lines > 120:
        errors.append(
            f"{template.relative_to(ROOT)}: kernel template exceeds 120 lines ({template_lines})"
        )


def audit_no_todos(errors: list[str]) -> None:
    markers = ("TODO", "FIXME", "XXX", "HACK")
    marker_pattern = re.compile(r"\b(" + "|".join(markers) + r")\b")
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix not in {".py", ".sh", ".md", ".yaml", ".json", ".jsonc", ".toml"}:
            continue
        if path.samefile(__file__):
            continue
        if any(part in path.parts for part in (".git", "node_modules", ".codegraph", "__pycache__")):
            continue
        try:
            text = path.read_text()
        except Exception:
            continue
        for marker in marker_pattern.findall(text):
            errors.append(f"{path.relative_to(ROOT)}: contains {marker}")


def audit_runtime_template_excluded(errors: list[str]) -> None:
    registry = json.loads((ROOT / "runtimes" / "registry.yaml").read_text())
    names = {r.get("name") for r in registry.get("runtimes", []) if isinstance(r, dict)}
    if "runtime-template" in names:
        errors.append("runtimes/registry.yaml: runtime-template must not be registered")


def audit_unresolved_tokens(errors: list[str]) -> None:
    generated_paths = [
        ROOT / "README.md",
        ROOT / "references" / "contract" / "runtime.md",
        *(ROOT / "skills" / name / "SKILL.md" for name in _skill_names()),
        *(ROOT / "runtimes" / name / "kernel.md" for name in _runtime_names()),
        *(ROOT / "runtimes" / "opencode" / "commands" / f"{name}.md" for name in _skill_names()),
    ]
    for path in generated_paths:
        if path.exists() and "{{" in path.read_text():
            errors.append(f"{path.relative_to(ROOT)}: unresolved template token")


def _skill_names() -> list[str]:
    registry = json.loads((ROOT / "skills" / "registry.yaml").read_text())
    return sorted(
        skill["name"] for skill in registry.get("skills", [])
        if isinstance(skill, dict) and isinstance(skill.get("name"), str)
    )


def _runtime_names() -> list[str]:
    registry = json.loads((ROOT / "runtimes" / "registry.yaml").read_text())
    return sorted(
        runtime["name"] for runtime in registry.get("runtimes", [])
        if isinstance(runtime, dict) and isinstance(runtime.get("name"), str)
    )


def main() -> int:
    all_ok = True

    all_ok &= run_cmd([sys.executable, "tooling/generate/registry_sync.py", "--check"], "Generated asset sync")
    all_ok &= run_cmd(["bash", "scripts/validate-skills.sh"], "Validation suite")

    errors: list[str] = []
    audit_slimness(errors)
    audit_no_todos(errors)
    audit_runtime_template_excluded(errors)
    audit_unresolved_tokens(errors)

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    if not all_ok:
        return 1

    print("b-agentic suite audit passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
