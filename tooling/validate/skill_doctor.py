#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PI_SKILLS_ROOT = ".pi/agent/skills"
PI_METADATA_ROOT = ".pi/agent/b-agentic"
PI_KERNEL = ".pi/agent/AGENTS.md"


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


def main() -> int:
    parser = argparse.ArgumentParser(description="Check installed b-agentic Pi skill discovery readiness.")
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    skills_root = home / PI_SKILLS_ROOT
    metadata_root = home / PI_METADATA_ROOT
    kernel = home / PI_KERNEL
    expected = registry_skill_names()
    installed = installed_skill_names(skills_root)
    skills = payload_status(installed, expected)
    ready = kernel.exists() and skills.startswith("ready")

    print("agent: Pi")
    print(f"expected-skills: {len(expected)}")
    print(f"kernel-path: {kernel}")
    print(f"skill-path: {skills_root / 'b-plan' / 'SKILL.md'}")
    print(f"manifest-path: {metadata_root / 'install.json'}")
    print(f"kernel: {'ready' if kernel.exists() else 'missing'}")
    print(f"skills: {skills}")
    print(f"discovery: {'ready: native skills path populated' if ready else 'blocked: install complete skill payload'}")
    return 0 if ready else 1


if __name__ == "__main__":
    raise SystemExit(main())
