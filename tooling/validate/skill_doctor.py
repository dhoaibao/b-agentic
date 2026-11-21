#!/usr/bin/env python3
"""Check locally installed b-agentic skill discovery readiness for Claude Code."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tooling" / "install"))
import optional_components  # noqa: E402

KERNEL_BLOCK_START = "<!-- b-agentic:start -->"
KERNEL_BLOCK_END = "<!-- b-agentic:end -->"


# Where the generated assets live in the source tree and the installed layout.
SPEC = {
    "label": "Claude Code",
    "kernel_file": "CLAUDE.md",
    "skills_source": ROOT / "skills",
    "agents_source": ROOT / "claude" / "agents",
    "kernel_source": ROOT / "references" / "kernel.template.md",
    "kernel_reference": "kernel.template.md",
}


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


def missing_payload(root: Path) -> list[str]:
    """Managed specialists, hooks, CLIs, and references that the installed tree lacks."""
    spec = SPEC
    missing = []
    for source in sorted(spec["agents_source"].glob("b-*.md")):
        if not (root / "agents" / source.name).is_file():
            missing.append(f"agents/{source.name}")
    for folder, patterns in (("bin", ("*.mjs", "*.py")), ("hooks", ("*.mjs",))):
        for pattern in patterns:
            for source in sorted((ROOT / "claude" / folder).glob(pattern)):
                if not (root / "b-agentic" / folder / source.name).is_file():
                    missing.append(f"b-agentic/{folder}/{source.name}")
    for source in sorted((ROOT / "claude" / "bin").iterdir()):
        if source.is_file() and not source.suffix:
            problem = wrapper_problem(source, root / "b-agentic" / "bin" / source.name)
            if problem:
                missing.append(f"b-agentic/bin/{source.name} ({problem})")
    for name in ("capabilities.yaml", "mcp_operations.yaml", "artifacts.yaml", spec["kernel_reference"]):
        if not (root / "b-agentic" / "references" / name).is_file():
            missing.append(f"b-agentic/references/{name}")
    return missing


def exec_command(path: Path) -> list[str]:
    """Words of the first `exec` line of a shell wrapper; empty when there is none or it cannot be read."""
    try:
        for line in path.read_text().splitlines():
            if line.startswith("exec "):
                return shlex.split(line)[1:]
    except (OSError, UnicodeDecodeError, ValueError):
        pass
    return []


def wrapper_problem(source: Path, installed: Path) -> str | None:
    """Why an installed wrapper cannot run: skills call it by path, so a gap is exit 126 or 127, not a usage error.

    The installer swaps the bare `bun` of a Bun wrapper for the absolute path it found (ADR-028); an interpreter
    the source names bare, such as python3, is resolved from PATH and left alone.
    """
    if not installed.is_file():
        return "wrapper missing"
    if not os.access(installed, os.X_OK):
        return "not executable"
    if exec_command(source)[:1] != ["bun"]:
        return None
    command = exec_command(installed)
    if not command or not command[0].startswith("/"):
        return "no absolute bun path"
    bun = Path(command[0])
    if not (bun.is_file() and os.access(bun, os.X_OK)):
        return "bun path not executable"
    return None


def deselected_skills(root: Path) -> set[str]:
    """Skills of optional components the install manifest records as not selected (none when unrecorded)."""
    try:
        manifest = json.loads((root / "b-agentic" / "install.json").read_text())
        components = optional_components.load(ROOT)
    except (OSError, json.JSONDecodeError, ValueError):
        return set()
    recorded = manifest.get("optional_components") if isinstance(manifest, dict) else None
    if not isinstance(recorded, dict):
        return set()
    return optional_components.excluded_skills(components, {key: bool(recorded.get(key)) for key in components})


def stale_assets(root: Path, skills: list[str], skipped_skills: set[str] | None = None) -> list[str]:
    spec = SPEC
    stale = []
    try:
        components = optional_components.load(ROOT)
    except (OSError, ValueError):
        components = {}
    for name in skills:
        source = spec["skills_source"] / name / "SKILL.md"
        installed = root / "skills" / name / "SKILL.md"
        if source.exists() and installed.exists():
            try:
                wanted_skill = optional_components.filter_skill(
                    source.read_bytes().decode(),
                    skipped_skills or set(),
                    optional_components.optional_skills(components),
                ).encode()
            except (ValueError, UnicodeDecodeError):
                wanted_skill = source.read_bytes()
            if wanted_skill != installed.read_bytes():
                stale.append(f"skill {name}")
    for source in sorted(spec["agents_source"].glob("b-*.md")):
        installed = root / "agents" / source.name
        if installed.exists() and source.read_bytes() != installed.read_bytes():
            stale.append(f"agent {source.stem}")
    source_kernel = spec["kernel_source"]
    installed_kernel = root / spec["kernel_file"]
    if source_kernel.exists() and installed_kernel.exists():
        block = kernel_block(installed_kernel.read_text())
        try:
            wanted = optional_components.filter_kernel(source_kernel.read_text().strip("\n"), skipped_skills or set())
        except ValueError:
            wanted = source_kernel.read_text().strip("\n")
        if block is not None and block != wanted:
            stale.append("kernel")
    return stale


def main() -> int:
    parser = argparse.ArgumentParser(description="Check installed b-agentic skill discovery readiness.")
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    parser.add_argument("--config-dir", help="Inspect this explicit Claude Code configuration directory.")
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    claude_root = claude_dir(args.config_dir, home)
    skills_root = claude_root / "skills"
    kernel = claude_root / SPEC["kernel_file"]
    kernel_present = kernel.exists() and kernel_block(kernel.read_text()) is not None
    skipped = deselected_skills(claude_root)
    expected = [name for name in registry_skill_names() if name not in skipped]
    installed = [name for name in installed_skill_names(skills_root) if name not in skipped]
    skills = payload_status(installed, expected)
    stale = stale_assets(claude_root, expected, skipped)
    missing = missing_payload(claude_root)
    ready = kernel_present and skills.startswith("ready") and not stale and not missing

    print(f"agent: {SPEC['label']}")
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
