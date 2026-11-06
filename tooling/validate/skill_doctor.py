#!/usr/bin/env python3
"""Check locally installed b-agentic skill discovery readiness for Claude Code or Codex."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KERNEL_BLOCK_START = "<!-- b-agentic:start -->"
KERNEL_BLOCK_END = "<!-- b-agentic:end -->"


# Where each runtime's generated assets live in the source tree and its installed layout.
RUNTIMES = {
    "claude": {
        "label": "Claude Code",
        "kernel_file": "CLAUDE.md",
        "skills_source": ROOT / "skills",
        "agents_source": ROOT / "claude" / "agents",
        "agent_glob": "b-*.md",
        "kernel_source": ROOT / "references" / "kernel.template.md",
        "kernel_reference": "kernel.template.md",
        "reference_files": ("capabilities.yaml", "mcp_operations.yaml"),
        "hook_sources": sorted((ROOT / "claude" / "hooks").glob("*.mjs")),
        "bin_sources": sorted((ROOT / "claude" / "bin").glob("*.mjs")),
        "extra_files": {},
    },
    "codex": {
        "label": "Codex",
        "kernel_file": "AGENTS.md",
        "skills_source": ROOT / "codex" / "skills",
        "agents_source": ROOT / "codex" / "agents",
        "agent_glob": "b-*.toml",
        "kernel_source": ROOT / "codex" / "configs" / "kernel.md",
        "kernel_reference": "kernel.md",
        "reference_files": ("capabilities.yaml", "mcp_operations.yaml", "specialist-tools.json"),
        "hook_sources": [
            ROOT / "codex" / "hooks" / "b-codex-hooks.mjs",
            ROOT / "claude" / "hooks" / "b-verify-gate.mjs",
        ],
        "bin_sources": [ROOT / "claude" / "bin" / "b-candidate-snapshot.mjs"],
        "extra_files": {},
    },
}


def claude_dir(config_dir: str | None, home: Path) -> Path:
    explicit = config_dir or os.environ.get("B_AGENTIC_CLAUDE_DIR") or os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(explicit).expanduser() if explicit else home / ".claude"


def runtime_dir(runtime: str, config_dir: str | None, home: Path) -> Path:
    if runtime == "codex":
        return Path(config_dir).expanduser() if config_dir else home / ".codex"
    return claude_dir(config_dir, home)


def skills_dir(runtime: str, root: Path, home: Path) -> Path:
    """Codex reads user skills from ~/.agents/skills, outside its configuration directory."""
    return home / ".agents" / "skills" if runtime == "codex" else root / "skills"


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


def missing_payload(root: Path, runtime: str = "claude") -> list[str]:
    """Managed specialists, hooks, CLIs, and references that the installed tree lacks."""
    spec = RUNTIMES[runtime]
    missing = []
    for source in sorted(spec["agents_source"].glob(spec["agent_glob"])):
        if not (root / "agents" / source.name).is_file():
            missing.append(f"agents/{source.name}")
    for folder, sources in (("bin", spec["bin_sources"]), ("hooks", spec["hook_sources"])):
        for source in sources:
            if not (root / "b-agentic" / folder / source.name).is_file():
                missing.append(f"b-agentic/{folder}/{source.name}")
    for name in (*spec["reference_files"], spec["kernel_reference"]):
        if not (root / "b-agentic" / "references" / name).is_file():
            missing.append(f"b-agentic/references/{name}")
    for relative in spec["extra_files"]:
        if not (root / relative).is_file():
            missing.append(relative)
    return missing


def stale_assets(root: Path, skills: list[str], runtime: str = "claude", skills_root: Path | None = None) -> list[str]:
    spec = RUNTIMES[runtime]
    skills_root = skills_root if skills_root is not None else root / "skills"
    stale = []
    for name in skills:
        source = spec["skills_source"] / name / "SKILL.md"
        installed = skills_root / name / "SKILL.md"
        if source.exists() and installed.exists() and source.read_bytes() != installed.read_bytes():
            stale.append(f"skill {name}")
    for source in sorted(spec["agents_source"].glob(spec["agent_glob"])):
        installed = root / "agents" / source.name
        if installed.exists() and source.read_bytes() != installed.read_bytes():
            stale.append(f"agent {source.stem}")
    for relative, source in spec["extra_files"].items():
        installed = root / relative
        if source.exists() and installed.exists() and source.read_bytes() != installed.read_bytes():
            stale.append(relative)
    source_kernel = spec["kernel_source"]
    installed_kernel = root / spec["kernel_file"]
    if source_kernel.exists() and installed_kernel.exists():
        block = kernel_block(installed_kernel.read_text())
        if block is not None and block != source_kernel.read_text().strip("\n"):
            stale.append("kernel")
    return stale


def main() -> int:
    parser = argparse.ArgumentParser(description="Check installed b-agentic skill discovery readiness.")
    parser.add_argument("--runtime", choices=sorted(RUNTIMES), default="claude", help="Runtime to inspect.")
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    parser.add_argument("--config-dir", help="Inspect this explicit configuration directory for the runtime.")
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    claude_root = runtime_dir(args.runtime, args.config_dir, home)
    skills_root = skills_dir(args.runtime, claude_root, home)
    kernel = claude_root / RUNTIMES[args.runtime]["kernel_file"]
    kernel_present = kernel.exists() and kernel_block(kernel.read_text()) is not None
    expected = registry_skill_names()
    installed = installed_skill_names(skills_root)
    skills = payload_status(installed, expected)
    stale = stale_assets(claude_root, expected, args.runtime, skills_root)
    missing = missing_payload(claude_root, args.runtime)
    ready = kernel_present and skills.startswith("ready") and not stale and not missing

    print(f"agent: {RUNTIMES[args.runtime]['label']}")
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
