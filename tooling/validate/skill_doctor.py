#!/usr/bin/env python3
"""Check locally installed Claude Code b-agentic skill discovery readiness."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KERNEL_BLOCK_START = "<!-- b-agentic:start -->"
KERNEL_BLOCK_END = "<!-- b-agentic:end -->"


def claude_dir(config_dir: str | None, home: Path) -> Path:
    explicit = config_dir or os.environ.get("B_AGENTIC_CLAUDE_DIR") or os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(explicit).expanduser() if explicit else home / ".claude"


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


def kernel_block(text: str) -> str | None:
    """Return the managed kernel text between the markers; None unless exactly one well-formed pair exists."""
    if text.count(KERNEL_BLOCK_START) != 1 or text.count(KERNEL_BLOCK_END) != 1:
        return None
    start = text.index(KERNEL_BLOCK_START)
    end = text.index(KERNEL_BLOCK_END)
    if end < start:
        return None
    return text[start + len(KERNEL_BLOCK_START) : end].strip("\n")


def missing_payload(claude_root: Path) -> list[str]:
    """Managed specialists, hooks, CLIs, and references that the installed tree lacks."""
    missing = []
    for source in sorted((ROOT / "claude" / "agents").glob("b-*.md")):
        if not (claude_root / "agents" / source.name).is_file():
            missing.append(f"agents/{source.name}")
    for folder in ("bin", "hooks"):
        for source in sorted((ROOT / "claude" / folder).glob("*.mjs")):
            if not (claude_root / "b-agentic" / folder / source.name).is_file():
                missing.append(f"b-agentic/{folder}/{source.name}")
    for name in ("capabilities.yaml", "mcp_operations.yaml", "kernel.template.md"):
        if not (claude_root / "b-agentic" / "references" / name).is_file():
            missing.append(f"b-agentic/references/{name}")
    return missing


def stale_assets(claude_root: Path, skills: list[str]) -> list[str]:
    stale = []
    for name in skills:
        source = ROOT / "skills" / name / "SKILL.md"
        installed = claude_root / "skills" / name / "SKILL.md"
        if source.exists() and installed.exists() and source.read_bytes() != installed.read_bytes():
            stale.append(f"skill {name}")
    for source in sorted((ROOT / "claude" / "agents").glob("b-*.md")):
        installed = claude_root / "agents" / source.name
        if installed.exists() and source.read_bytes() != installed.read_bytes():
            stale.append(f"agent {source.stem}")
    source_kernel = ROOT / "references" / "kernel.template.md"
    installed_kernel = claude_root / "CLAUDE.md"
    if source_kernel.exists() and installed_kernel.exists():
        block = kernel_block(installed_kernel.read_text())
        if block is not None and block != source_kernel.read_text().strip("\n"):
            stale.append("kernel")
    return stale


def main() -> int:
    parser = argparse.ArgumentParser(description="Check installed b-agentic Claude Code skill discovery readiness.")
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    parser.add_argument("--config-dir", help="Inspect this explicit Claude Code configuration directory.")
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    claude_root = claude_dir(args.config_dir, home)
    skills_root = claude_root / "skills"
    kernel = claude_root / "CLAUDE.md"
    kernel_present = kernel.exists() and kernel_block(kernel.read_text()) is not None
    expected = registry_skill_names()
    installed = installed_skill_names(skills_root)
    skills = payload_status(installed, expected)
    stale = stale_assets(claude_root, expected)
    missing = missing_payload(claude_root)
    ready = kernel_present and skills.startswith("ready") and not stale and not missing

    print("agent: Claude Code")
    print(f"expected-skills: {len(expected)}")
    print(f"kernel-path: {kernel}")
    print(f"skill-path: {skills_root / 'b-plan' / 'SKILL.md'}")
    print(f"manifest-path: {claude_root / 'b-agentic' / 'install.json'}")
    print(f"kernel: {'ready' if kernel_present else 'missing'}")
    print(f"skills: {skills}")
    print(f"payload: {'ready' if not missing else 'missing: ' + ','.join(missing)}")
    print(f"content: {'ready' if not stale else 'stale: ' + ','.join(stale)}")
    print(
        f"discovery: {'ready: skills path populated and current' if ready else 'blocked: install complete current skill payload'}"
    )
    return 0 if ready else 1


if __name__ == "__main__":
    raise SystemExit(main())
