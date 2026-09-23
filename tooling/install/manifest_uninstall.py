#!/usr/bin/env python3
"""Remove a native OpenCode b-agentic install from its self-contained manifest.

This helper is copied into the managed metadata directory, so uninstall remains
possible when the source checkout is no longer present. It deliberately removes
only unmodified b-agentic assets under the invoking user's home directory.
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

from jsonc import loads as load_jsonc
from json_cleanup import remove_managed_json_config


def warn(message: str) -> None:
    print(f"warning: {message}", file=sys.stderr)


def confined(path: Path, home: Path) -> bool:
    try:
        return path.expanduser().resolve().is_relative_to(home)
    except OSError:
        return False


def safe_name(name: object) -> bool:
    return (
        isinstance(name, str)
        and name.startswith("b-")
        and all(("a" <= char <= "z") or ("0" <= char <= "9") or char == "-" for char in name)
        and not name.endswith("-")
    )


def equal(left: Path, right: Path) -> bool:
    try:
        if left.is_symlink() or right.is_symlink():
            return False
        if left.is_dir() and right.is_dir():
            left_children = {item.name: item for item in left.iterdir()}
            right_children = {item.name: item for item in right.iterdir()}
            return left_children.keys() == right_children.keys() and all(
                equal(left_children[name], right_children[name]) for name in left_children
            )
        return left.is_file() and right.is_file() and left.read_bytes() == right.read_bytes()
    except OSError:
        return False


def manifest_path(paths: dict, key: str, fallback: Path, home: Path) -> Path:
    candidate = paths.get(key)
    path = Path(candidate).expanduser() if isinstance(candidate, str) else fallback
    if not confined(path, home):
        warn(f"ignoring manifest {key} path outside home: {path}")
        return fallback
    return path


def remove_profiles(names: object, root: Path, snapshots: Path, label: str) -> bool:
    preserved = False
    for name in names if isinstance(names, list) else []:
        if not safe_name(name):
            warn(f"preserving {label} with unsafe manifest name")
            preserved = True
            continue
        target = root / f"{name}.md"
        snapshot = snapshots / f"{name}.md"
        if target.is_symlink():
            warn(f"preserving symlinked {label}: {target}")
            preserved = True
        elif target.exists() and equal(target, snapshot):
            target.unlink()
        elif target.exists():
            warn(f"preserving modified {label}: {target}")
            preserved = True
    return preserved


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: manifest_uninstall.py <manifest-path>", file=sys.stderr)
        return 2
    home = Path.home().resolve()
    manifest = Path(sys.argv[1]).expanduser()
    if not confined(manifest, home) or not manifest.is_file() or manifest.is_symlink():
        print(f"error: manifest is missing, symlinked, or outside home: {manifest}", file=sys.stderr)
        return 1
    try:
        data = json.loads(manifest.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: unreadable manifest: {exc}", file=sys.stderr)
        return 1
    if data.get("runtime") != "opencode":
        print(f"error: unsupported manifest runtime: {data.get('runtime')!r}", file=sys.stderr)
        return 1

    metadata = manifest.parent
    paths = data.get("paths", {}) if isinstance(data.get("paths"), dict) else {}
    config_dir = manifest_path(paths, "opencodeConfigDir", home / ".config" / "opencode", home)
    skills = manifest_path(paths, "skills", config_dir / "skills", home)
    agents = manifest_path(paths, "agents", config_dir / "agents", home)
    commands = manifest_path(paths, "commands", config_dir / "commands", home)
    kernel = manifest_path(paths, "kernel", config_dir / "AGENTS.md", home)
    config = manifest_path(paths, "opencodeConfig", config_dir / "opencode.json", home)
    snapshots = {"skills": metadata / "skills", "agents": metadata / "agents", "commands": metadata / "commands"}
    preserved = False

    for name in data.get("skills", []):
        if not safe_name(name):
            warn("preserving skill with unsafe manifest name")
            preserved = True
            continue
        target, snapshot = skills / name, snapshots["skills"] / name
        if target.is_symlink():
            warn(f"preserving symlinked skill: {target}")
            preserved = True
        elif target.exists() and equal(target, snapshot):
            shutil.rmtree(target)
        elif target.exists():
            warn(f"preserving modified skill: {target}")
            preserved = True

    if kernel.exists():
        snapshot = metadata / "AGENTS.md"
        if kernel.is_symlink() or not equal(kernel, snapshot):
            warn(f"preserving modified managed kernel: {kernel}")
            preserved = True
        else:
            kernel.unlink()

    preserved |= remove_profiles(data.get("agents"), agents, snapshots["agents"], "OpenCode subagent")
    preserved |= remove_profiles(data.get("commands"), commands, snapshots["commands"], "OpenCode command")

    template = metadata / "templates" / "opencode.user.template.json"
    backup = data.get("backups", {}).get("opencodeConfig") if isinstance(data.get("backups"), dict) else None
    original = Path(backup).expanduser() if isinstance(backup, str) and backup not in {"", "none"} else None
    if config.is_symlink():
        warn(f"preserving symlinked opencode.json: {config}")
        preserved = True
    elif config.exists():
        if not template.exists():
            warn(f"preserving opencode.json: missing managed template: {template}")
            preserved = True
        elif original is not None and not original.is_file():
            warn(f"preserving opencode.json: recorded backup is missing: {original}")
            preserved = True
        else:
            try:
                cleaned = remove_managed_json_config(config, template, original, "opencode.json")
                if cleaned == {}:
                    config.unlink()
                elif cleaned != load_jsonc(config.read_text()):
                    config.write_text(json.dumps(cleaned, indent=2) + "\n")
                else:
                    warn(f"preserving modified opencode.json: {config}")
                    preserved = True
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                warn(f"preserving opencode.json: {config} ({exc})")
                preserved = True

    if preserved:
        warn(f"preserving managed metadata due to modified assets: {metadata}")
    elif confined(metadata, home):
        shutil.rmtree(metadata)
    print("Manifest-only uninstall complete for OpenCode.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
