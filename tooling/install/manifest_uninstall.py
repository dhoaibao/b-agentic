#!/usr/bin/env python3
"""Manifest-only uninstall script for b-agentic.

Reads a b-agentic install manifest and removes managed files without
requiring the source repository. Called by install.sh during uninstall.

Usage:
    python3 manifest_uninstall.py <manifest-path>
"""

import json
import os
import shutil
import sys
from pathlib import Path

from jsonc import loads as load_jsonc


def warn(message: str) -> None:
    print(f"warning: {message}", file=sys.stderr)


def under_home(path: Path) -> bool:
    try:
        resolved = path.resolve()
    except Exception:
        return False
    return any(_is_relative_to(resolved, root) for root in allowed_roots)


def _is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def safe_name(name: object) -> bool:
    if not isinstance(name, str) or not name.startswith("b-"):
        return False
    return all(ch.islower() or ch.isdigit() or ch == "-" for ch in name) and not name.endswith("-")


def remove_tree(path: Path) -> None:
    if path.exists() and under_home(path):
        shutil.rmtree(path)


def remove_file(path: Path) -> None:
    if path.exists() and under_home(path):
        path.unlink()


def has_symlink_ancestor(path: Path) -> bool:
    candidate = path.expanduser()
    while True:
        # Stop at either HOME spelling before inspecting ancestors outside it
        # (for example macOS /tmp -> /private/tmp). A symlink below HOME must
        # still be rejected even if it resolves back to HOME.
        if candidate == home_spelling or candidate == home:
            return False
        if candidate.is_symlink():
            return True
        parent = candidate.parent
        if parent == candidate:
            return True
        candidate = parent


def confined_regular_path(path: Path, label: str) -> bool:
    if has_symlink_ancestor(path):
        warn(f"preserving symlinked {label}: {path}")
        return False
    if not under_home(path):
        warn(f"preserving {label} outside home: {path}")
        return False
    return True


def manifest_managed_path(paths: dict, key: str, fallback: Path, *, require_confined: bool = False) -> Path | None:
    path = fallback
    value = paths.get(key)
    if isinstance(value, str) and value:
        candidate = Path(value).expanduser()
        if under_home(candidate):
            path = candidate
        else:
            warn(f"ignoring manifest path outside home for {key}: {candidate}")
    if require_confined and not confined_regular_path(path, fallback.name):
        return None
    return path


def files_equal(left: Path, right: Path) -> bool:
    try:
        return left.read_bytes() == right.read_bytes()
    except Exception:
        return False


def trees_equal(left: Path, right: Path) -> bool:
    if left.is_symlink() or right.is_symlink():
        return False
    if left.is_dir() and right.is_dir():
        left_entries = {item.name: item for item in left.iterdir()}
        right_entries = {item.name: item for item in right.iterdir()}
        return left_entries.keys() == right_entries.keys() and all(
            trees_equal(left_entries[name], right_entries[name]) for name in left_entries
        )
    return left.is_file() and right.is_file() and files_equal(left, right)


def files_equal_or_json_equal(left: Path, right: Path) -> bool:
    if files_equal(left, right):
        return True
    try:
        return load_jsonc(left.read_text()) == load_jsonc(right.read_text())
    except Exception:
        return False


def remove_snapshot_profiles(names: list, dst_root: Path, snapshot_root: Path, extension: str, label: str) -> None:
    for name in names:
        if not safe_name(name):
            warn(f"preserving {label} with unsafe manifest name")
            continue
        dst = dst_root / f"{name}.{extension}"
        snapshot = snapshot_root / f"{name}.{extension}"
        if not dst.exists():
            continue
        if snapshot.exists() and files_equal(dst, snapshot):
            remove_file(dst)
        else:
            warn(f"preserving modified {label}: {dst}")


def remove_merged_json_config(
    path_value: str | None,
    template: Path,
    label: str,
    backup_key: str | None,
    action_key: str | None,
    data: dict,
) -> None:
    """Remove b-agentic managed entries from a merged JSON config file.

    Uses the original backup recorded in the manifest to avoid deleting
    user-owned entries that existed before installation.
    """
    if not isinstance(path_value, str):
        return
    path = Path(path_value).expanduser()
    if not confined_regular_path(path, label) or not confined_regular_path(template, f"{label} template"):
        return
    if not path.exists() or not template.exists():
        return

    backups = data.get("backups", {})
    backup = backups.get(backup_key) if backup_key else None
    action = data.get(action_key) if action_key else None
    if backup == "none":
        backup = None

    original_path = None
    if backup:
        original_path = Path(backup).expanduser()
        if not confined_regular_path(original_path, f"{label} backup") or not original_path.exists():
            warn(f"preserving modified {label}: {path}")
            return
    elif action != "write":
        warn(f"preserving modified {label}: {path}")
        return

    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from json_cleanup import remove_managed_json_config

        cleaned = remove_managed_json_config(path, template, original_path, path.name)
    except Exception as exc:
        warn(f"preserving modified {label}: {path} ({exc})")
        return

    current = load_jsonc(path.read_text())
    if cleaned == current:
        warn(f"preserving modified {label}: {path}")
        return
    if cleaned == {}:
        remove_file(path)
    else:
        path.write_text(json.dumps(cleaned, indent=2, sort_keys=True) + "\n")


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: manifest_uninstall.py <manifest-path>", file=sys.stderr)
        sys.exit(1)

    manifest_path = Path(sys.argv[1]).expanduser()

    global home_spelling
    home_spelling = Path.home()
    global home
    home = home_spelling.resolve()
    global allowed_roots
    allowed_roots = [home]
    if not confined_regular_path(manifest_path, "manifest") or not manifest_path.exists():
        print(f"error: manifest not found or not confined: {manifest_path}", file=sys.stderr)
        sys.exit(1)
    data = json.loads(manifest_path.read_text())
    runtime = data.get("runtime")
    paths = data.get("paths", {})
    metadata = manifest_path.parent

    runtime_defaults = {
        "pi": {
            "metadata": home / ".pi" / "agent" / "b-agentic",
            "skills": home / ".pi" / "agent" / "skills",
            "agents": home / ".pi" / "agent" / "agents" / "b-agentic",
            "settings": home / ".pi" / "agent" / "settings.json",
            "kernel": home / ".pi" / "agent" / "AGENTS.md",
            "permissionsExtension": home / ".pi" / "agent" / "extensions" / "b-agentic-permissions.ts",
            "extensions": home / ".pi" / "agent" / "extensions",
            "mcpConfig": home / ".pi" / "agent" / "mcp.json",
            "theme": home / ".pi" / "agent" / "themes" / "dracula.json",
            "cachedTheme": home / ".pi" / "agent" / "b-agentic" / "themes" / "dracula.json",
        },
    }

    defaults = runtime_defaults.get(runtime)
    if defaults is None:
        raise SystemExit(f"unsupported manifest runtime: {runtime!r}")
    if not confined_regular_path(metadata, "manifest metadata"):
        raise SystemExit(f"manifest path is outside home or symlinked: {manifest_path}")

    def managed_skill_dir(path: Path) -> bool:
        skill_file = path / "SKILL.md"
        if not skill_file.exists():
            return False
        try:
            text = skill_file.read_text()
        except Exception:
            return False
        return "Generated from skills/registry.yaml" in text

    skills_root = manifest_managed_path(paths, "skills", defaults["skills"])
    skills_snapshot_root = metadata / "skills"
    for name in data.get("skills", []):
        if skills_root is None:
            warn("preserving skills because managed path is not confined")
            break
        if not safe_name(name):
            warn("preserving skill with unsafe manifest name")
            continue
        skill_dir = skills_root / name
        skill_snapshot = skills_snapshot_root / name
        if skill_dir.is_symlink():
            warn(f"preserving symlinked skill: {skill_dir}")
        elif managed_skill_dir(skill_dir) and trees_equal(skill_dir, skill_snapshot):
            remove_tree(skill_dir)
        elif skill_dir.exists():
            warn(f"preserving modified or unsnapshotted skill: {skill_dir}")

    kernel_path = manifest_managed_path(paths, "kernel", defaults["kernel"])
    kernel_snapshot = metadata / kernel_path.name if kernel_path else None
    if kernel_path and kernel_snapshot and kernel_path.exists():
        try:
            kernel_text = kernel_path.read_text()
        except Exception:
            kernel_text = ""
        if (
            "<!-- b-agentic-managed -->" in kernel_text
            and kernel_snapshot.exists()
            and files_equal(kernel_path, kernel_snapshot)
        ):
            remove_file(kernel_path)
        else:
            warn(f"preserving modified managed kernel: {kernel_path}")

    preserve_metadata = False

    if runtime == "pi":
        settings_path = manifest_managed_path(paths, "settings", defaults["settings"], require_confined=True)
        if settings_path:
            remove_merged_json_config(
                str(settings_path),
                metadata / "templates" / "subagents.user.template.json",
                "settings.json",
                "subagentSettings",
                "subagentSettingsAction",
                data,
            )
        agents_root = manifest_managed_path(paths, "agents", defaults["agents"], require_confined=True)
        agents_snapshot_root = metadata / "agents"
        for name in data.get("agents", []):
            if agents_root is None:
                warn("preserving subagent profiles because managed path is not confined")
                break
            if not safe_name(name):
                warn("preserving subagent profile with unsafe manifest name")
                continue
            profile = agents_root / f"{name}.md"
            profile_snapshot = agents_snapshot_root / f"{name}.md"
            if profile.is_symlink():
                warn(f"preserving symlinked subagent profile: {profile}")
            elif profile.exists() and profile_snapshot.exists() and files_equal(profile, profile_snapshot):
                remove_file(profile)
            elif profile.exists():
                warn(f"preserving modified subagent profile: {profile}")

        guard_path = metadata / "subagent-read-only-guard.ts"
        guard_snapshot = metadata / "subagent-read-only-guard.snapshot.ts"
        if guard_path.is_symlink():
            warn(f"preserving symlinked subagent read-only guard: {guard_path}")
            preserve_metadata = True
        elif (
            guard_path.exists()
            and guard_snapshot.is_file()
            and not guard_snapshot.is_symlink()
            and files_equal(guard_path, guard_snapshot)
        ):
            remove_file(guard_path)
            remove_file(guard_snapshot)
        elif guard_path.exists():
            warn(f"preserving modified or unsnapshotted subagent read-only guard: {guard_path}")
            preserve_metadata = True

        mcp_config_path = manifest_managed_path(paths, "mcpConfig", defaults["mcpConfig"], require_confined=True)
        if mcp_config_path:
            remove_merged_json_config(
                str(mcp_config_path),
                metadata / "templates" / "mcp.user.template.json",
                "mcp.json",
                "mcpConfig",
                "mcpAction",
                data,
            )
        extensions = paths.get("extensions")
        if not isinstance(extensions, dict):
            extensions = {
                "b-agentic-permissions.ts": paths.get("permissionsExtension", str(defaults["permissionsExtension"]))
            }
        backup_map = data.get("backups", {}).get("extensions", {})
        if not isinstance(backup_map, dict):
            backup_map = {}
        legacy_backup = data.get("backups", {}).get("permissionsExtension")
        for name, configured_path in extensions.items():
            safe_extension = (
                isinstance(name, str)
                and name.startswith("b-agentic-")
                and "\\" not in name
                and ".." not in Path(name).parts
                and all(part and part not in {".", ".."} for part in Path(name).parts)
            )
            if not safe_extension:
                warn("preserving Pi extension with unsafe manifest name")
                continue
            fallback = defaults["extensions"] / name
            extension_path = manifest_managed_path({"extension": configured_path}, "extension", fallback)
            extension_snapshot = metadata / "extensions" / name
            if extension_path is None:
                warn("preserving Pi extension because its managed path is not confined")
                continue
            if extension_path.is_symlink():
                label = "Pi permission extension" if name == "b-agentic-permissions.ts" else "Pi extension"
                warn(f"preserving symlinked {label}: {extension_path}")
                continue
            if not extension_path.exists():
                continue
            if not extension_snapshot.exists() or not files_equal(extension_path, extension_snapshot):
                warn(f"preserving modified Pi extension: {extension_path}")
                continue
            backup = backup_map.get(name)
            if backup in (None, "none") and name == "b-agentic-permissions.ts":
                backup = legacy_backup
            if backup in (None, "none"):
                remove_file(extension_path)
                continue
            original = Path(backup).expanduser() if isinstance(backup, str) else None
            backups_root = metadata / "backups"
            if original and original.is_file() and _is_relative_to(original.resolve(), backups_root.resolve()):
                shutil.copy2(original, extension_path)
            else:
                warn(f"preserving Pi extension because its original backup is unavailable: {extension_path}")
        theme_path = manifest_managed_path(paths, "theme", defaults["theme"])
        cached_theme = manifest_managed_path(paths, "cachedTheme", defaults["cachedTheme"])
        if theme_path is None or cached_theme is None:
            warn("preserving Pi theme because its managed path is not confined")
        elif theme_path.is_symlink():
            try:
                target = Path(os.readlink(theme_path))
                if not target.is_absolute():
                    target = theme_path.parent / target
                if target.resolve() == cached_theme.resolve() or target == cached_theme:
                    remove_file(theme_path)
                else:
                    warn(f"preserving symlinked Pi theme: {theme_path}")
            except Exception:
                warn(f"preserving symlinked Pi theme: {theme_path}")
        elif theme_path.exists():
            warn(f"preserving modified Pi theme: {theme_path}")
    if preserve_metadata:
        warn(f"preserving managed metadata because it contains a user-modified asset: {metadata}")
    else:
        remove_tree(metadata)
    print(f"Manifest-only uninstall complete for {runtime}. Source cache was not required.")


if __name__ == "__main__":
    main()
