#!/usr/bin/env python3
"""Remove a native Pi b-agentic install from its self-contained manifest.

This helper is copied into the managed metadata directory, so uninstall remains
possible when the source checkout is no longer present. It deliberately removes
only unmodified b-agentic assets under the invoking user's home directory.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
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


def remove_profiles(names: object, root: Path, snapshots: Path, label: str, dry_run: bool) -> bool:
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
            if not dry_run:
                target.unlink()
        elif target.exists():
            warn(f"preserving modified {label}: {target}")
            preserved = True
    return preserved


def remove_owned_packages(
    config_dir: Path, settings: Path, template: Path, original: Path | None, dry_run: bool
) -> bool:
    """Remove only package declarations absent from the pre-install settings."""
    if not settings.is_file() or settings.is_symlink() or not template.is_file():
        return False
    if original is not None and not original.is_file():
        return True
    try:
        current = load_jsonc(settings.read_text()).get("packages", [])
        managed = json.loads(template.read_text())["packages"]
        previous = load_jsonc(original.read_text()).get("packages", []) if original else []
        if not all(isinstance(items, list) for items in (current, managed, previous)):
            raise ValueError("package declarations must be lists")
        owned = [item for item in managed if item in current and item not in previous]
    except (OSError, ValueError, TypeError, AttributeError, KeyError) as exc:
        warn(f"preserving package cache: cannot establish ownership ({exc})")
        return True
    if not owned:
        return False
    if dry_run:
        print(f"[dry-run] remove {len(owned)} managed Pi packages")
        return False
    pi = shutil.which("pi")
    if pi is None:
        warn("preserving package cache: Pi CLI unavailable")
        return True
    env = dict(os.environ, PI_CODING_AGENT_DIR=str(config_dir))
    failed = False
    for package in owned:
        if not isinstance(package, str) or not package.startswith("npm:"):
            warn(f"preserving invalid package declaration: {package!r}")
            failed = True
            continue
        result = subprocess.run([pi, "remove", package, "--no-approve"], cwd=config_dir, env=env, check=False)
        if result.returncode:
            warn(f"could not remove managed package: {package}")
            failed = True
    return failed


def main() -> int:
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--dry-run"):
        print("usage: manifest_uninstall.py <manifest-path> [--dry-run]", file=sys.stderr)
        return 2
    dry_run = len(sys.argv) == 3
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
    if data.get("runtime") != "pi":
        print(f"error: unsupported manifest runtime: {data.get('runtime')!r}", file=sys.stderr)
        return 1

    metadata = manifest.parent
    paths = data.get("paths", {}) if isinstance(data.get("paths"), dict) else {}
    config_dir = manifest_path(paths, "piConfigDir", home / ".pi" / "agent", home)
    skills = manifest_path(paths, "skills", config_dir / "skills", home)
    agents = manifest_path(paths, "agents", config_dir / "agents", home)
    commands = manifest_path(paths, "commands", config_dir / "prompts", home)
    kernel = manifest_path(paths, "kernel", config_dir / "AGENTS.md", home)
    snapshots = {"skills": metadata / "skills", "agents": metadata / "agents", "commands": metadata / "prompts"}
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
            if not dry_run:
                shutil.rmtree(target)
        elif target.exists():
            warn(f"preserving modified skill: {target}")
            preserved = True

    if kernel.exists() or kernel.is_symlink():
        snapshot = metadata / "AGENTS.md"
        if kernel.is_symlink() or not equal(kernel, snapshot):
            warn(f"preserving modified managed kernel: {kernel}")
            preserved = True
        else:
            kernel_backup = data.get("backups", {}).get("kernel", "none")
            if kernel_backup not in (None, "none", ""):
                original_kernel = Path(kernel_backup).expanduser() if isinstance(kernel_backup, str) else None
                if (
                    original_kernel is None
                    or not original_kernel.is_file()
                    or original_kernel.is_symlink()
                    or not confined(original_kernel, home)
                ):
                    warn("preserving managed kernel: original backup is missing or unsafe")
                    preserved = True
                elif not dry_run:
                    shutil.copy2(original_kernel, kernel)
                    if data.get("kernelPriorBackups"):
                        warn(f"preserving earlier user kernel backups in {metadata / 'backups'}")
                        preserved = True
            elif not dry_run:
                kernel.unlink()

    preserved |= remove_profiles(data.get("agents"), agents, snapshots["agents"], "Pi specialist", dry_run)
    preserved |= remove_profiles(data.get("commands"), commands, snapshots["commands"], "Pi prompt", dry_run)

    if data.get("themeAction") in {"write", "replace"}:
        license_file = metadata / "themes" / "LICENSE"
        license_snapshot = metadata / "themes" / "LICENSE.snapshot"
        if (
            license_file.is_symlink()
            or license_snapshot.is_symlink()
            or (license_file.exists() and not equal(license_file, license_snapshot))
        ):
            warn(f"preserving modified Pi theme license: {license_file}")
            preserved = True
        theme = config_dir / "themes" / "dracula.json"
        snapshot = metadata / "themes" / "dracula.json"
        if theme.parent.is_symlink() or theme.is_symlink() or not confined(theme, home):
            warn(f"preserving symlinked or unsafe Pi theme: {theme}")
            preserved = True
        elif theme.exists() and equal(theme, snapshot):
            if not dry_run:
                theme.unlink()
        elif theme.exists():
            warn(f"preserving modified Pi theme: {theme}")
            preserved = True

    configs = (
        ("settings", config_dir / "settings.json", "settings.base.json"),
        ("mcp", config_dir / "mcp.json", "mcp.base.json"),
        (
            "permission",
            config_dir / "extensions" / "pi-permission-system" / "config.json",
            "permission.user.template.json",
        ),
    )
    if data.get("magicContextAction"):
        configs += (
            ("magicContext", home / ".config" / "cortexkit" / "magic-context.jsonc", "magic-context.base.json"),
        )
    backups = data.get("backups", {}) if isinstance(data.get("backups"), dict) else {}
    for key, default, template_name in configs:
        if key == "magicContext":
            declared = paths.get(key)
            if (
                not isinstance(declared, str)
                or not Path(declared).is_absolute()
                or not confined(Path(declared), home)
                or any(parent.is_symlink() for parent in Path(declared).parents if parent != home)
            ):
                warn("preserving Magic Context config: unsafe manifest path")
                preserved = True
                continue
        config = manifest_path(paths, key, default, home)
        template = metadata / "templates" / template_name
        backup = backups.get(key)
        original = Path(backup).expanduser() if isinstance(backup, str) and backup not in {"", "none"} else None
        if config.is_symlink():
            warn(f"preserving symlinked {key}: {config}")
            preserved = True
        elif config.exists():
            if not template.exists() or (
                original is not None and (not confined(original, home) or not original.is_file())
            ):
                warn(f"preserving {key}: missing managed template or backup")
                preserved = True
                continue
            try:
                if key == "settings":
                    if remove_owned_packages(config_dir, config, template, original, dry_run):
                        preserved = True
                        continue
                cleaned = remove_managed_json_config(config, template, original, key)
                if cleaned == {}:
                    if not dry_run and data.get(f"{key}Action") == "write":
                        config.unlink()
                    elif not dry_run:
                        config.write_text("{}\n")
                elif cleaned != load_jsonc(config.read_text()):
                    if not dry_run:
                        config.write_text(json.dumps(cleaned, indent=2) + "\n")
                else:
                    warn(f"preserving modified {key}: {config}")
                    preserved = True
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                warn(f"preserving {key}: {config} ({exc})")
                preserved = True

    if preserved:
        warn(f"preserving managed metadata due to modified assets: {metadata}")
    elif confined(metadata, home) and not dry_run:
        shutil.rmtree(metadata)
    print("Manifest-only uninstall preview for Pi." if dry_run else "Manifest-only uninstall complete for Pi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
