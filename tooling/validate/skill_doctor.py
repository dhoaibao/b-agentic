#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


SUPPORTED_RUNTIMES = {"claude-code", "codex-cli", "opencode", "kilo-code"}


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def load_toml(path: Path) -> dict:
    try:
        import tomllib
    except ModuleNotFoundError as exc:  # pragma: no cover
        raise SystemExit("Codex CLI skill doctor requires Python 3.11+ (stdlib tomllib).") from exc
    return tomllib.loads(path.read_text())


def resolve_runtime_paths(runtime: str, home: Path) -> dict[str, Path]:
    if runtime == "claude-code":
        return {
            "kernel": home / ".claude" / "CLAUDE.md",
            "skill": home / ".claude" / "skills" / "b-plan" / "SKILL.md",
        }
    if runtime == "codex-cli":
        return {
            "kernel": home / ".codex" / "AGENTS.md",
            "skill": home / ".codex" / "skills" / "b-plan" / "SKILL.md",
            "config": home / ".codex" / "config.toml",
        }
    if runtime == "opencode":
        return {
            "kernel": home / ".config" / "opencode" / "AGENTS.md",
            "skill": home / ".config" / "opencode" / "skills" / "b-plan" / "SKILL.md",
            "command": home / ".config" / "opencode" / "commands" / "b-plan.md",
        }
    if runtime == "kilo-code":
        return {
            "kernel": home / ".config" / "kilo" / "AGENTS.md",
            "skill": home / ".config" / "kilo" / "skills" / "b-plan" / "SKILL.md",
            "config": home / ".config" / "kilo" / "kilo.jsonc",
        }
    raise ValueError(runtime)


def status_for_claude(paths: dict[str, Path]) -> dict[str, str]:
    return {
        "kernel": "ready" if paths["kernel"].exists() else "missing",
        "skill": "ready" if paths["skill"].exists() else "missing",
        "discovery": "ready: native skills path populated" if paths["skill"].exists() else "blocked: install skill payload",
    }


def status_for_opencode(paths: dict[str, Path]) -> dict[str, str]:
    skill_ready = paths["skill"].exists()
    command_ready = paths["command"].exists()
    return {
        "kernel": "ready" if paths["kernel"].exists() else "missing",
        "skill": "ready" if skill_ready else "missing",
        "wrapper": "ready" if command_ready else "missing",
        "discovery": "ready: native skill and /b-plan wrapper installed" if skill_ready and command_ready else "blocked: install skill and wrapper payloads",
    }


def status_for_codex(paths: dict[str, Path]) -> dict[str, str]:
    skill_ready = paths["skill"].exists()
    config_ready = False
    if paths["config"].exists():
        data = load_toml(paths["config"])
        entries = data.get("skills", {}).get("config", [])
        if isinstance(entries, list):
            expected = str(paths["skill"].parent)
            for entry in entries:
                if isinstance(entry, dict) and entry.get("path") == expected and entry.get("enabled") is True:
                    config_ready = True
                    break
    return {
        "kernel": "ready" if paths["kernel"].exists() else "missing",
        "skill": "ready" if skill_ready else "missing",
        "config": "ready" if config_ready else "missing",
        "discovery": "ready: skills.config points at installed skill path" if skill_ready and config_ready else "blocked: install skill payload and Codex skill config",
    }


def status_for_kilo(paths: dict[str, Path], home: Path) -> dict[str, str]:
    skill_ready = paths["skill"].exists()
    config_ready = False
    if paths["config"].exists():
        data = load_json(paths["config"])
        entries = data.get("skills", {}).get("paths", [])
        if isinstance(entries, list):
            expected = str(home / ".config" / "kilo" / "skills")
            for entry in entries:
                if isinstance(entry, str) and (entry == "~/.config/kilo/skills" or entry == expected):
                    config_ready = True
                    break
    return {
        "kernel": "ready" if paths["kernel"].exists() else "missing",
        "skill": "ready" if skill_ready else "missing",
        "config": "ready" if config_ready else "missing",
        "discovery": "ready: skills.paths includes installed skill root" if skill_ready and config_ready else "blocked: install skill payload and Kilo skills.paths config",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Check installed b-agentic skill discovery readiness for a runtime.")
    parser.add_argument("--runtime", required=True, choices=sorted(SUPPORTED_RUNTIMES))
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    paths = resolve_runtime_paths(args.runtime, home)

    if args.runtime == "claude-code":
        status = status_for_claude(paths)
    elif args.runtime == "codex-cli":
        status = status_for_codex(paths)
    elif args.runtime == "opencode":
        status = status_for_opencode(paths)
    else:
        status = status_for_kilo(paths, home)

    print(f"runtime: {args.runtime}")
    for name, path in paths.items():
        print(f"{name}-path: {path}")
    for key, value in status.items():
        print(f"{key}: {value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
