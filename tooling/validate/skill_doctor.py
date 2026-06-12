#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


SUPPORTED_RUNTIMES = {"claude-code", "codex-cli", "opencode"}
ROOT = Path(__file__).resolve().parents[2]


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
            "manifest": home / ".claude" / "b-agentic" / "install.json",
        }
    if runtime == "codex-cli":
        return {
            "kernel": home / ".codex" / "AGENTS.md",
            "skill": home / ".codex" / "skills" / "b-plan" / "SKILL.md",
            "config": home / ".codex" / "config.toml",
            "manifest": home / ".codex" / "b-agentic" / "install.json",
        }
    if runtime == "opencode":
        return {
            "kernel": home / ".config" / "opencode" / "AGENTS.md",
            "skill": home / ".config" / "opencode" / "skills" / "b-plan" / "SKILL.md",
            "command": home / ".config" / "opencode" / "commands" / "b-plan.md",
            "manifest": home / ".config" / "opencode" / "b-agentic" / "install.json",
        }
    raise ValueError(runtime)


def registry_skill_names() -> list[str]:
    registry_path = ROOT / "skills" / "registry.yaml"
    if not registry_path.exists():
        return []
    data = json.loads(registry_path.read_text())
    return sorted(
        skill["name"]
        for skill in data.get("skills", [])
        if isinstance(skill, dict) and isinstance(skill.get("name"), str)
    )


def manifest_skill_names(path: Path) -> list[str]:
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text())
    except Exception:
        return []
    return sorted(name for name in data.get("skills", []) if isinstance(name, str))


def expected_skill_names(paths: dict[str, Path]) -> list[str]:
    return registry_skill_names() or manifest_skill_names(paths["manifest"])


def payload_status(installed: list[str], expected: list[str], label: str) -> str:
    if not expected:
        return "missing expected skill list"
    if installed == expected:
        return f"ready: {len(installed)} {label} installed"
    missing = sorted(set(expected) - set(installed))
    extra = sorted(set(installed) - set(expected))
    details = []
    if missing:
        details.append(f"missing {','.join(missing)}")
    if extra:
        details.append(f"extra {','.join(extra)}")
    return "missing or mismatched: " + "; ".join(details)


def installed_skill_names(skill_root: Path) -> list[str]:
    if not skill_root.exists():
        return []
    return sorted(
        path.parent.name
        for path in skill_root.glob("b-*/SKILL.md")
        if path.parent.is_dir()
    )


def status_for_claude(paths: dict[str, Path], expected: list[str]) -> dict[str, str]:
    skills = installed_skill_names(paths["skill"].parents[1])
    skills_ready = skills == expected and bool(expected)
    return {
        "kernel": "ready" if paths["kernel"].exists() else "missing",
        "skills": payload_status(skills, expected, "skills"),
        "discovery": "ready: native skills path populated" if skills_ready else "blocked: install complete skill payload",
    }


def status_for_opencode(paths: dict[str, Path], expected: list[str]) -> dict[str, str]:
    skill_root = paths["skill"].parents[1]
    command_root = paths["command"].parent
    skills = installed_skill_names(skill_root)
    commands = sorted(path.stem for path in command_root.glob("b-*.md")) if command_root.exists() else []
    skills_ready = skills == expected and bool(expected)
    wrapper_ready = commands == expected and bool(expected)
    return {
        "kernel": "ready" if paths["kernel"].exists() else "missing",
        "skills": payload_status(skills, expected, "skills"),
        "wrappers": payload_status(commands, expected, "wrappers"),
        "discovery": "ready: native skills and /b-* wrappers installed" if skills_ready and wrapper_ready else "blocked: install complete skill and wrapper payloads",
    }


def status_for_codex(paths: dict[str, Path], expected: list[str]) -> dict[str, str]:
    skill_root = paths["skill"].parents[1]
    skills = installed_skill_names(skill_root)
    expected_paths = {str(skill_root / name) for name in expected}
    enabled_paths: set[str] = set()
    config_ready = False
    if paths["config"].exists():
        data = load_toml(paths["config"])
        entries = data.get("skills", {}).get("config", [])
        if isinstance(entries, list):
            for entry in entries:
                if isinstance(entry, dict) and entry.get("enabled") is True and isinstance(entry.get("path"), str):
                    enabled_paths.add(entry["path"])
    skills_ready = skills == expected and bool(expected)
    config_ready = bool(expected_paths) and expected_paths.issubset(enabled_paths)
    return {
        "kernel": "ready" if paths["kernel"].exists() else "missing",
        "skills": payload_status(skills, expected, "skills"),
        "config": "ready" if config_ready else "missing",
        "discovery": "ready: skills.config points at installed skill paths" if skills_ready and config_ready else "blocked: install complete skill payload and Codex skill config",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Check installed b-agentic skill discovery readiness for a runtime.")
    parser.add_argument("--runtime", required=True, choices=sorted(SUPPORTED_RUNTIMES))
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    paths = resolve_runtime_paths(args.runtime, home)
    expected = expected_skill_names(paths)

    if args.runtime == "claude-code":
        status = status_for_claude(paths, expected)
    elif args.runtime == "codex-cli":
        status = status_for_codex(paths, expected)
    elif args.runtime == "opencode":
        status = status_for_opencode(paths, expected)
    else:
        raise ValueError(args.runtime)

    print(f"runtime: {args.runtime}")
    print(f"expected-skills: {len(expected)}")
    for name, path in paths.items():
        print(f"{name}-path: {path}")
    for key, value in status.items():
        print(f"{key}: {value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
