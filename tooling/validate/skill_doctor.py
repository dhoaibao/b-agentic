#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def runtime_records() -> dict[str, dict]:
    data = json.loads((ROOT / "runtimes" / "registry.yaml").read_text())
    return {
        runtime["name"]: runtime
        for runtime in data.get("runtimes", [])
        if isinstance(runtime, dict) and isinstance(runtime.get("name"), str)
    }


def expand_home(path: str, home: Path) -> Path:
    if path.startswith("~/"):
        return home / path[2:]
    return Path(path).expanduser()


def resolve_runtime_paths(runtime: dict, home: Path) -> dict[str, Path]:
    skills_root = expand_home(runtime["skills_install_root"], home)
    metadata_root = expand_home(runtime["metadata_root"], home)
    kernel = expand_home(runtime["memory_install_path"], home)
    paths = {
        "kernel": kernel,
        "skill": skills_root / "b-plan" / "SKILL.md",
        "manifest": metadata_root / "install.json",
    }
    wrappers = runtime.get("command_wrappers", {})
    if isinstance(wrappers, dict) and wrappers.get("supported") and isinstance(wrappers.get("install_root"), str):
        paths["command"] = expand_home(wrappers["install_root"], home) / "b-plan.md"
    return paths


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


def status_for_native_skills(paths: dict[str, Path], expected: list[str]) -> dict[str, str]:
    skills = installed_skill_names(paths["skill"].parents[1])
    skills_ready = skills == expected and bool(expected)
    return {
        "kernel": "ready" if paths["kernel"].exists() else "missing",
        "skills": payload_status(skills, expected, "skills"),
        "discovery": "ready: native skills path populated" if skills_ready else "blocked: install complete skill payload",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Check installed b-agentic skill discovery readiness for a runtime.")
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    args = parser.parse_args()

    runtimes = runtime_records()
    runtime = runtimes.get(args.runtime)
    if runtime is None:
        print(f"unsupported runtime: {args.runtime}", file=sys.stderr)
        return 2

    home = Path(args.home).expanduser()
    paths = resolve_runtime_paths(runtime, home)
    expected = expected_skill_names(paths)

    status = status_for_native_skills(paths, expected)

    print(f"runtime: {args.runtime}")
    print(f"expected-skills: {len(expected)}")
    for name, path in paths.items():
        print(f"{name}-path: {path}")
    for key, value in status.items():
        print(f"{key}: {value}")
    return 0 if all(value.startswith("ready") for value in status.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
