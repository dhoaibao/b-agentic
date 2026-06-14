#!/usr/bin/env python3
"""Manifest-only uninstall script for b-agentic.

Reads a b-agentic install manifest and removes managed files without
requiring the source repository. Called by install.sh during uninstall.

Usage:
    python3 manifest_uninstall.py <manifest-path>
"""

import json
import shutil
import sys
from pathlib import Path


def warn(message: str) -> None:
    print(f"warning: {message}", file=sys.stderr)


def under_home(path: Path) -> bool:
    try:
        path.resolve().relative_to(home)
        return True
    except Exception:
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


def manifest_managed_path(paths: dict, key: str, fallback: Path) -> Path:
    value = paths.get(key)
    if not isinstance(value, str) or not value:
        return fallback
    path = Path(value).expanduser()
    if under_home(path):
        return path
    warn(f"ignoring manifest path outside home for {key}: {path}")
    return fallback


def files_equal(left: Path, right: Path) -> bool:
    try:
        return left.read_bytes() == right.read_bytes()
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


def remove_config_if_template(path_value: str | None, template: Path, label: str) -> None:
    if not isinstance(path_value, str):
        return
    path = Path(path_value).expanduser()
    if path.exists() and template.exists() and files_equal(path, template):
        remove_file(path)
    elif path.exists():
        warn(f"preserving modified {label}: {path}")


def remove_toml_managed_block(path_value: str | None, label: str) -> None:
    if not isinstance(path_value, str):
        return
    path = Path(path_value).expanduser()
    if not path.exists():
        return
    begin = "# BEGIN b-agentic managed config"
    end = "# END b-agentic managed config"
    text = path.read_text()
    if begin not in text:
        return
    if end not in text:
        warn(f"preserving modified {label}: {path}")
        return
    prefix, remainder = text.split(begin, 1)
    _managed, suffix = remainder.split(end, 1)
    cleaned = (prefix + suffix).strip()
    if cleaned:
        path.write_text(cleaned + "\n")
    else:
        remove_file(path)


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: manifest_uninstall.py <manifest-path>", file=sys.stderr)
        sys.exit(1)

    manifest_path = Path(sys.argv[1]).expanduser()
    if not manifest_path.exists():
        print(f"error: manifest not found: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    global home
    home = Path.home().resolve()

    data = json.loads(manifest_path.read_text())
    runtime = data.get("runtime")
    paths = data.get("paths", {})
    metadata = manifest_path.parent

    runtime_defaults = {
        "claude-code": {
            "metadata": home / ".claude" / "b-agentic",
            "skills": home / ".claude" / "skills",
            "kernel": home / ".claude" / "CLAUDE.md",
            "agents": home / ".claude" / "agents",
            "settings": home / ".claude" / "settings.json",
            "claudeJson": home / ".claude.json",
        },
        "opencode": {
            "metadata": home / ".config" / "opencode" / "b-agentic",
            "skills": home / ".config" / "opencode" / "skills",
            "kernel": home / ".config" / "opencode" / "AGENTS.md",
            "agents": home / ".config" / "opencode" / "agents",
            "commands": home / ".config" / "opencode" / "commands",
            "opencodeJson": home / ".config" / "opencode" / "opencode.json",
        },
        "codex-cli": {
            "metadata": home / ".codex" / "b-agentic",
            "skills": home / ".codex" / "skills",
            "kernel": home / ".codex" / "AGENTS.md",
            "agents": home / ".codex" / "agents",
            "rules": home / ".codex" / "rules",
            "codexConfig": home / ".codex" / "config.toml",
        },
        "droid": {
            "metadata": home / ".factory" / "b-agentic",
            "skills": home / ".factory" / "skills",
            "kernel": home / ".factory" / "AGENTS.md",
            "settings": home / ".factory" / "settings.json",
            "mcpJson": home / ".factory" / "mcp.json",
        },
    }

    defaults = runtime_defaults.get(runtime)
    if defaults is None:
        raise SystemExit(f"unsupported manifest runtime: {runtime!r}")
    if not under_home(metadata):
        raise SystemExit(f"manifest path is outside home: {manifest_path}")

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
    for name in data.get("skills", []):
        if not safe_name(name):
            warn("preserving skill with unsafe manifest name")
            continue
        skill_dir = skills_root / name
        if managed_skill_dir(skill_dir):
            remove_tree(skill_dir)
        elif skill_dir.exists():
            warn(f"preserving skill without managed marker: {skill_dir}")

    kernel_path = manifest_managed_path(paths, "kernel", defaults["kernel"])
    kernel_snapshot = metadata / kernel_path.name
    if kernel_path.exists():
        try:
            kernel_text = kernel_path.read_text()
        except Exception:
            kernel_text = ""
        if "<!-- b-agentic-managed -->" in kernel_text and kernel_snapshot.exists() and files_equal(kernel_path, kernel_snapshot):
            remove_file(kernel_path)
        else:
            warn(f"preserving modified managed kernel: {kernel_path}")

    if runtime == "claude-code":
        remove_snapshot_profiles(data.get("agents", []), manifest_managed_path(paths, "agents", defaults["agents"]), metadata / "agents", "md", "Claude Code agent")
        remove_config_if_template(str(manifest_managed_path(paths, "settings", defaults["settings"])), metadata / "templates" / "settings.template.json", "settings.json")
        remove_config_if_template(str(manifest_managed_path(paths, "claudeJson", defaults["claudeJson"])), metadata / "templates" / "mcp.user.template.json", ".claude.json")
    elif runtime == "opencode":
        remove_snapshot_profiles(data.get("agents", []), manifest_managed_path(paths, "agents", defaults["agents"]), metadata / "agents", "md", "OpenCode agent")
        remove_snapshot_profiles(data.get("commands", []), manifest_managed_path(paths, "commands", defaults["commands"]), metadata / "commands", "md", "OpenCode command")
        remove_config_if_template(str(manifest_managed_path(paths, "opencodeJson", defaults["opencodeJson"])), metadata / "templates" / "mcp.user.template.json", "opencode.json")
    elif runtime == "codex-cli":
        remove_snapshot_profiles(data.get("agents", []), manifest_managed_path(paths, "agents", defaults["agents"]), metadata / "agents", "toml", "Codex agent")
        remove_snapshot_profiles(data.get("rules", []), manifest_managed_path(paths, "rules", defaults["rules"]), metadata / "rules", "rules", "Codex rule")
        remove_toml_managed_block(str(manifest_managed_path(paths, "codexConfig", defaults["codexConfig"])), "Codex config")
    elif runtime == "droid":
        remove_config_if_template(str(manifest_managed_path(paths, "settings", defaults["settings"])), metadata / "templates" / "settings.template.json", "settings.json")
        remove_config_if_template(str(manifest_managed_path(paths, "mcpJson", defaults["mcpJson"])), metadata / "templates" / "mcp.user.template.json", "mcp.json")
    remove_tree(metadata)
    print(f"Manifest-only uninstall complete for {runtime}. Source cache was not required.")


if __name__ == "__main__":
    main()
