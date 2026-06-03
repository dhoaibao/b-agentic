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


def managed_kimi_mcp_server(current_server: object, template_server: object, server_name: str) -> bool:
    if not isinstance(current_server, dict) or not isinstance(template_server, dict):
        return False
    normalized = json.loads(json.dumps(current_server))

    if server_name == "context7":
        headers = normalized.get("headers")
        template_headers = template_server.get("headers", {})
        if isinstance(headers, dict) and isinstance(template_headers, dict) and "CONTEXT7_API_KEY" in headers:
            headers["CONTEXT7_API_KEY"] = template_headers.get("CONTEXT7_API_KEY")
    elif server_name in {"brave-search", "firecrawl"}:
        key_name = "BRAVE_API_KEY" if server_name == "brave-search" else "FIRECRAWL_API_KEY"
        env = normalized.get("env")
        template_env = template_server.get("env", {})
        if isinstance(env, dict) and isinstance(template_env, dict) and key_name in env:
            env[key_name] = template_env.get(key_name)

    return normalized == template_server


def remove_kimi_mcp_config(path_value: str | None, template: Path) -> None:
    if not isinstance(path_value, str):
        return
    path = Path(path_value).expanduser()
    if not path.exists():
        return
    if not template.exists():
        warn(f"preserving modified mcp.json: {path}")
        return
    if files_equal(path, template):
        remove_file(path)
        return

    try:
        current = json.loads(path.read_text())
        incoming = json.loads(template.read_text())
    except Exception:
        warn(f"preserving modified mcp.json: {path}")
        return

    if not isinstance(current, dict) or not isinstance(incoming, dict):
        warn(f"preserving modified mcp.json: {path}")
        return

    cleaned = json.loads(json.dumps(current))
    servers = cleaned.get("mcpServers")
    incoming_servers = incoming.get("mcpServers")
    if not isinstance(servers, dict) or not isinstance(incoming_servers, dict):
        warn(f"preserving modified mcp.json: {path}")
        return

    changed = False
    for server_name, template_server in incoming_servers.items():
        if server_name not in servers:
            continue
        if managed_kimi_mcp_server(servers[server_name], template_server, server_name):
            servers.pop(server_name)
            changed = True

    if not servers:
        cleaned.pop("mcpServers", None)

    if not changed or cleaned == current:
        warn(f"preserving modified mcp.json: {path}")
        return
    if cleaned == {}:
        remove_file(path)
        return

    path.write_text(json.dumps(cleaned, indent=2, sort_keys=True) + "\n")


def remove_codex_managed_block(path_value: str | None) -> None:
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
        warn(f"preserving modified Codex config: {path}")
        return
    prefix, remainder = text.split(begin, 1)
    _managed, suffix = remainder.split(end, 1)
    cleaned = (prefix + suffix).strip()
    if cleaned:
        path.write_text(cleaned + "\n")
    else:
        remove_file(path)


def remove_kimi_managed_block(path_value: str | None) -> None:
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
        warn(f"preserving modified Kimi config: {path}")
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
        "kimi-code-cli": {
            "metadata": home / ".kimi-code" / "b-agentic",
            "skills": home / ".kimi-code" / "skills",
            "kernel": home / ".kimi-code" / "b-agentic-kernel.md",
            "kimiConfig": home / ".kimi-code" / "config.toml",
            "kimiMcpJson": home / ".kimi-code" / "mcp.json",
        },
    }

    defaults = runtime_defaults.get(runtime)
    if defaults is None:
        raise SystemExit(f"unsupported manifest runtime: {runtime!r}")
    if metadata.resolve() != defaults["metadata"].resolve():
        raise SystemExit(f"manifest path does not match runtime metadata root: {manifest_path}")

    def managed_skill_dir(path: Path) -> bool:
        skill_file = path / "SKILL.md"
        if not skill_file.exists():
            return False
        try:
            text = skill_file.read_text()
        except Exception:
            return False
        return "Generated from skills/registry.yaml" in text

    skills_root = defaults["skills"]
    for name in data.get("skills", []):
        if not safe_name(name):
            warn("preserving skill with unsafe manifest name")
            continue
        skill_dir = skills_root / name
        if managed_skill_dir(skill_dir):
            remove_tree(skill_dir)
        elif skill_dir.exists():
            warn(f"preserving skill without managed marker: {skill_dir}")

    kernel_path = defaults["kernel"]
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
        remove_snapshot_profiles(data.get("agents", []), defaults["agents"], metadata / "agents", "md", "Claude Code agent")
        remove_config_if_template(str(defaults["settings"]), metadata / "templates" / "settings.template.json", "settings.json")
        remove_config_if_template(str(defaults["claudeJson"]), metadata / "templates" / "mcp.user.template.json", ".claude.json")
    elif runtime == "opencode":
        remove_snapshot_profiles(data.get("agents", []), defaults["agents"], metadata / "agents", "md", "OpenCode agent")
        remove_snapshot_profiles(data.get("commands", []), defaults["commands"], metadata / "commands", "md", "OpenCode command")
        remove_config_if_template(str(defaults["opencodeJson"]), metadata / "templates" / "mcp.user.template.json", "opencode.json")
    elif runtime == "codex-cli":
        remove_snapshot_profiles(data.get("agents", []), defaults["agents"], metadata / "agents", "toml", "Codex agent")
        remove_snapshot_profiles(data.get("rules", []), defaults["rules"], metadata / "rules", "rules", "Codex rule")
        remove_codex_managed_block(str(defaults["codexConfig"]))
    elif runtime == "kimi-code-cli":
        remove_kimi_managed_block(str(defaults["kimiConfig"]))
        remove_kimi_mcp_config(str(defaults["kimiMcpJson"]), metadata / "templates" / "mcp.user.template.json")

    remove_tree(metadata)
    print(f"Manifest-only uninstall complete for {runtime}. Source cache was not required.")


if __name__ == "__main__":
    main()
