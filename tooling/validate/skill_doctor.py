#!/usr/bin/env python3
"""Check locally installed native Pi b-agentic skill discovery readiness."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def registry_skill_names() -> list[str]:
    try:
        data = json.loads((ROOT / "skills" / "registry.yaml").read_text())
    except (OSError, json.JSONDecodeError):
        return []
    return sorted(
        skill["name"]
        for skill in data.get("skills", [])
        if isinstance(skill, dict) and isinstance(skill.get("name"), str)
    )


def installed_skill_names(root: Path) -> list[str]:
    return sorted(path.parent.name for path in root.glob("b-*/SKILL.md") if path.parent.is_dir())


def payload_status(installed: list[str], expected: list[str]) -> str:
    if installed == expected and expected:
        return f"ready: {len(installed)} skills installed"
    missing = sorted(set(expected) - set(installed))
    extra = sorted(set(installed) - set(expected))
    details = []
    if missing:
        details.append(f"missing {','.join(missing)}")
    if extra:
        details.append(f"extra {','.join(extra)}")
    return "missing or mismatched: " + "; ".join(details or ["no skills installed"])


def stale_assets(pi_root: Path, skills: list[str]) -> list[str]:
    stale = []
    for name in skills:
        source = ROOT / "skills" / name / "SKILL.md"
        installed = pi_root / "skills" / name / "SKILL.md"
        if source.exists() and installed.exists() and source.read_bytes() != installed.read_bytes():
            stale.append(f"skill {name}")
    source_kernel = ROOT / "references" / "kernel.template.md"
    installed_kernel = pi_root / "AGENTS.md"
    if (
        source_kernel.exists()
        and installed_kernel.exists()
        and source_kernel.read_bytes() != installed_kernel.read_bytes()
    ):
        stale.append("kernel")
    return stale


def main() -> int:
    parser = argparse.ArgumentParser(description="Check installed b-agentic Pi skill discovery readiness.")
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    parser.add_argument("--config-dir", help="Inspect this explicit Pi agent directory.")
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    configured_dir = args.config_dir or os.environ.get("B_AGENTIC_PI_DIR") or os.environ.get("PI_CODING_AGENT_DIR")
    pi_root = Path(configured_dir).expanduser() if configured_dir else home / ".pi" / "agent"
    skills_root = pi_root / "skills"
    metadata_root = pi_root / "b-agentic"
    kernel = pi_root / "AGENTS.md"
    expected = registry_skill_names()
    installed = installed_skill_names(skills_root)
    skills = payload_status(installed, expected)
    stale = stale_assets(pi_root, expected)
    ready = kernel.exists() and skills.startswith("ready") and not stale

    print("agent: Pi")
    print(f"expected-skills: {len(expected)}")
    print(f"kernel-path: {kernel}")
    print(f"skill-path: {skills_root / 'b-plan' / 'SKILL.md'}")
    print(f"manifest-path: {metadata_root / 'install.json'}")
    print(f"kernel: {'ready' if kernel.exists() else 'missing'}")
    print(f"skills: {skills}")
    print(f"content: {'ready' if not stale else 'stale: ' + ','.join(stale)}")
    print(
        f"discovery: {'ready: native skills path populated and current' if ready else 'blocked: install complete current skill payload'}"
    )
    return 0 if ready else 1


if __name__ == "__main__":
    raise SystemExit(main())
