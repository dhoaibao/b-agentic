#!/usr/bin/env python3
"""Install, sync, or remove b-agentic's Claude Code assets.

The installer owns only what it records in `~/.claude/b-agentic/install.json`:
copied skills, agents, hooks, and CLIs (by sha256), the kernel block in
CLAUDE.md (by sha256), the permission rules and hook entries it adds to
settings.json (exact values), and the MCP servers it adds to ~/.claude.json.
Everything else in those files is user-owned and preserved, and byte equality
with a managed value is never treated as ownership.

Every operation first plans in memory: it parses and validates every user file
and every destination (symlinks, non-directory ancestors, the Pi runtime) and
refuses on a problem before the first write. It then records its intent in the
manifest as a `pending` section that sits beside the last committed ownership,
applies the plan, and finally commits. An interruption leaves a manifest from
which a retry or an uninstall still recognizes both the old and the new state.
Nothing is ever written under ~/.pi, and only the default ~/.claude directory is
supported because the managed hooks, agents, and instructions refer to it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
KERNEL_BLOCK_START = "<!-- b-agentic:start -->"
KERNEL_BLOCK_END = "<!-- b-agentic:end -->"
MANIFEST_SCHEMA = 1
MANAGED_ROOTS = ("skills", "agents", "b-agentic")
SKILL_NAME = re.compile(r"^b-[a-z0-9-]+$")
CODEX_PLUGIN_COMMANDS = (
    "/plugin marketplace add openai/codex-plugin-cc",
    "/plugin install codex@openai-codex",
    "/codex:setup",
)
PREREQUISITES = ("node", "git", "rtk", "codegraph", "bunx", "claude", "codex")


class InstallError(Exception):
    """A refusal the user can act on."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def home_dir() -> Path:
    return Path.home()


def resolve_claude_dir() -> Path:
    """The default ~/.claude directory; any other configured directory is refused."""
    default = home_dir() / ".claude"
    for name in ("CLAUDE_CONFIG_DIR", "B_AGENTIC_CLAUDE_DIR"):
        value = os.environ.get(name)
        if value and os.path.realpath(os.path.expanduser(value)) != os.path.realpath(default):
            raise InstallError(
                f"{name}={value} is not supported: the managed hooks, agents, and instructions refer to "
                f"{default}. Unset it to install into {default}."
            )
    return default


def guard_destination(path: Path) -> None:
    """Refuse to touch the frozen Pi runtime, the home directory itself, or the filesystem root."""
    resolved = Path(os.path.realpath(path))
    home = home_dir()
    if resolved in (Path("/"), Path(os.path.realpath(home))):
        raise InstallError(f"refusing to manage {path}")
    for pi_root in {home / ".pi", Path(os.path.realpath(home / ".pi"))}:
        if resolved == pi_root or pi_root in resolved.parents:
            raise InstallError(f"refusing to write under the Pi runtime directory: {path}")


def check_directory_chain(path: Path, base: Path) -> None:
    """Every existing component from `base` down to `path` must be a real directory."""
    current = base
    for part in path.relative_to(base).parts:
        current = current / part
        if current.is_symlink():
            raise InstallError(f"{current} is a symlink; remove or replace it")
        if current.exists() and not current.is_dir():
            raise InstallError(f"{current} exists but is not a directory")
    guard_destination(path)


def destination_identity(path: Path) -> tuple[Any, ...]:
    """What a destination really is: its inode when it exists (catches hard links and symlink
    aliases), else its resolved path (catches two names that would create the same file)."""
    try:
        status = os.stat(path)
    except FileNotFoundError:
        return ("path", os.path.realpath(path))
    return ("inode", status.st_dev, status.st_ino)


def check_disjoint(destinations: list[tuple[str, Path]]) -> None:
    """No two destinations may be the same file: each is planned and written independently,
    so an alias would let one write silently undo another."""
    seen: dict[tuple[Any, ...], tuple[str, Path]] = {}
    for label, path in destinations:
        key = destination_identity(path)
        if key in seen:
            other_label, other_path = seen[key]
            raise InstallError(
                f"{label} ({path}) and {other_label} ({other_path}) resolve to the same file; "
                "give each its own file before installing or uninstalling"
            )
        seen[key] = (label, path)


def safe_relative(relative: str) -> str:
    parts = Path(relative).parts
    if Path(relative).is_absolute() or not parts or ".." in parts or parts[0] not in MANAGED_ROOTS:
        raise InstallError(f"unsafe managed path: {relative!r}")
    return relative


def read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise InstallError(f"{path} is not valid JSON ({exc}); fix or move it, then retry") from exc
    if not isinstance(value, dict):
        raise InstallError(f"{path} must contain a JSON object")
    return value


def json_text(value: dict[str, Any]) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def find_block(text: str, label: str) -> tuple[int, int] | None:
    """Span of the one managed kernel block, None when absent; malformed markers refuse."""
    starts = [m.start() for m in re.finditer(re.escape(KERNEL_BLOCK_START), text)]
    ends = [m.start() for m in re.finditer(re.escape(KERNEL_BLOCK_END), text)]
    if not starts and not ends:
        return None
    if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
        raise InstallError(
            f"{label} has duplicate, orphaned, or reversed b-agentic markers; repair or remove them manually, then retry"
        )
    return starts[0], ends[0] + len(KERNEL_BLOCK_END)


def validate_settings_shape(settings: dict[str, Any], label: str) -> None:
    permissions = settings.get("permissions", {})
    if not isinstance(permissions, dict):
        raise InstallError(f"{label}: permissions must be an object")
    for kind in ("allow", "ask", "deny"):
        if not isinstance(permissions.get(kind, []), list):
            raise InstallError(f"{label}: permissions.{kind} must be an array")
    hooks = settings.get("hooks", {})
    if not isinstance(hooks, dict):
        raise InstallError(f"{label}: hooks must be an object")
    for event, entries in hooks.items():
        if not isinstance(entries, list):
            raise InstallError(f"{label}: hooks.{event} must be an array")
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("hooks", []), list):
                raise InstallError(f"{label}: every hooks.{event} entry must be an object with a hooks array")
            if not all(isinstance(hook, dict) for hook in entry.get("hooks", [])):
                raise InstallError(f"{label}: every hook in hooks.{event} must be an object")


def validate_mcp_shape(config: dict[str, Any], label: str) -> None:
    if not isinstance(config.get("mcpServers", {}), dict):
        raise InstallError(f"{label}: mcpServers must be an object")


def merge_unique(*groups: list[Any]) -> list[Any]:
    merged: list[Any] = []
    for group in groups:
        for item in group:
            if item not in merged:
                merged.append(item)
    return merged


class Installer:
    def __init__(self, source: Path, dry_run: bool, force: bool, clickup: bool | None) -> None:
        self.source = source
        self.claude_dir = resolve_claude_dir()
        self.assets_dir = self.claude_dir / "b-agentic"
        self.manifest_path = self.assets_dir / "install.json"
        self.mcp_path = home_dir() / ".claude.json"
        self.dry_run = dry_run
        self.force = force
        self.clickup_choice = clickup
        self.stamp = f"{time.strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:6]}"
        self.messages: list[str] = []
        self.warnings: list[str] = []
        self.counts = {"written": 0, "unchanged": 0, "kept": 0, "removed": 0}
        self.backed_up: set[Path] = set()
        guard_destination(self.claude_dir)
        guard_destination(self.mcp_path)

    # -- output ---------------------------------------------------------------
    def say(self, text: str) -> None:
        self.messages.append(("[dry-run] " if self.dry_run else "") + text)

    def warn(self, text: str) -> None:
        self.warnings.append(text)

    # -- destinations -------------------------------------------------------------
    def managed_path(self, relative: str) -> Path:
        """A payload destination: only real directories may sit between ~/.claude and the file."""
        path = self.claude_dir / safe_relative(relative)
        check_directory_chain(path.parent, self.claude_dir)
        if path.is_dir() and not path.is_symlink():
            raise InstallError(f"{path} is a directory; expected a file")
        guard_destination(path)
        return path

    def config_target(self, path: Path) -> Path:
        """A user-owned config file; a symlinked file is written through, never replaced."""
        target = Path(os.path.realpath(path)) if path.is_symlink() else path
        guard_destination(target)
        if target.exists() and not target.is_file():
            raise InstallError(f"{target} exists but is not a regular file")
        # The nearest existing ancestor must be a directory, so a symlink that resolves
        # beneath a regular file is refused now rather than after the payload is written.
        for ancestor in target.parents:
            if ancestor.exists():
                if not ancestor.is_dir():
                    raise InstallError(f"{ancestor} exists but is not a directory (needed for {target})")
                break
        return target

    def check_aliases(self, relatives: list[str]) -> None:
        """Config files, the manifest, and every payload destination must be pairwise distinct."""
        destinations: list[tuple[str, Path]] = [
            ("CLAUDE.md", self.config_target(self.claude_dir / "CLAUDE.md")),
            ("settings.json", self.config_target(self.claude_dir / "settings.json")),
            (".claude.json", self.config_target(self.mcp_path)),
            ("the install manifest", self.manifest_path),
        ]
        for relative in relatives:
            path = self.claude_dir / safe_relative(relative)
            if not path.is_symlink():  # a user-owned symlinked payload file is left alone
                destinations.append((relative, path))
        check_disjoint(destinations)

    def preflight(self) -> None:
        """Validate every directory the run may create or write into, before the first write."""
        if self.claude_dir.exists() and not self.claude_dir.is_dir():
            raise InstallError(f"{self.claude_dir} exists but is not a directory")
        check_directory_chain(self.assets_dir, self.claude_dir)
        manifest = self.manifest_path
        if manifest.is_symlink() or (manifest.exists() and not manifest.is_file()):
            raise InstallError(f"{manifest} must be a regular file")
        guard_destination(manifest)
        backups = self.assets_dir / "backups"
        check_directory_chain(backups, self.claude_dir)
        for path in (self.claude_dir / "CLAUDE.md", self.claude_dir / "settings.json", self.mcp_path):
            self.config_target(path)
        self.check_aliases([])

    # -- writes (only called after planning) ----------------------------------------
    def write_bytes(self, path: Path, data: bytes) -> None:
        guard_destination(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
        try:
            with os.fdopen(handle, "wb") as stream:
                stream.write(data)
            if path.exists():
                os.chmod(temporary, path.stat().st_mode & 0o777)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def backup(self, path: Path) -> None:
        if path in self.backed_up or not path.is_file():
            return
        self.backed_up.add(path)
        relative = str(path).lstrip("/").replace("/", "__")
        target = self.assets_dir / "backups" / self.stamp / relative
        guard_destination(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)

    def remove_file(self, path: Path) -> None:
        guard_destination(path)
        path.unlink(missing_ok=True)
        directory = path.parent
        while directory != self.claude_dir and directory.is_dir() and not any(directory.iterdir()):
            guard_destination(directory)
            directory.rmdir()
            directory = directory.parent

    # -- payload --------------------------------------------------------------
    def payload(self) -> dict[str, bytes]:
        files: dict[str, bytes] = {}
        registry = json.loads((self.source / "skills" / "registry.yaml").read_text())
        for skill in registry["skills"]:
            name = skill["name"]
            if not isinstance(name, str) or not SKILL_NAME.fullmatch(name):
                raise InstallError(f"registry skill name is not a safe b-* name: {name!r}")
            files[f"skills/{name}/SKILL.md"] = (self.source / "skills" / name / "SKILL.md").read_bytes()
        for path in sorted((self.source / "claude" / "agents").glob("b-*.md")):
            files[f"agents/{path.name}"] = path.read_bytes()
        for folder in ("bin", "hooks"):
            for path in sorted((self.source / "claude" / folder).glob("*.mjs")):
                files[f"b-agentic/{folder}/{path.name}"] = path.read_bytes()
        for name in ("capabilities.yaml", "mcp_operations.yaml", "kernel.template.md"):
            files[f"b-agentic/references/{name}"] = (self.source / "references" / name).read_bytes()
        return files

    def kernel_block(self) -> str:
        kernel = (self.source / "references" / "kernel.template.md").read_text().strip("\n")
        return f"{KERNEL_BLOCK_START}\n{kernel}\n{KERNEL_BLOCK_END}"

    # -- manifest -------------------------------------------------------------
    def read_manifest(self) -> dict[str, Any]:
        manifest = read_json(self.manifest_path)
        if manifest and manifest.get("schema") != MANIFEST_SCHEMA:
            raise InstallError(f"{self.manifest_path} has an unsupported schema; uninstall with the matching version")
        for relative in [*manifest.get("files", {}), *manifest.get("pending", {}).get("files", {})]:
            safe_relative(relative)
        return manifest

    def write_manifest(self, manifest: dict[str, Any]) -> None:
        if self.dry_run:
            return
        text = json_text(manifest)
        if not self.manifest_path.exists() or self.manifest_path.read_text() != text:
            self.write_bytes(self.manifest_path, text.encode())

    # Ownership lookups: the last committed value and every value a run may have
    # written before it was interrupted.
    @staticmethod
    def file_owners(manifest: dict[str, Any], relative: str) -> set[str]:
        committed = manifest.get("files", {}).get(relative)
        return {d for d in [committed, *manifest.get("pending", {}).get("files", {}).get(relative, [])] if d}

    @staticmethod
    def kernel_owners(manifest: dict[str, Any]) -> set[str]:
        committed = manifest.get("kernel_sha256")
        return {d for d in [committed, *manifest.get("pending", {}).get("kernel", [])] if d}

    @staticmethod
    def mcp_candidates(manifest: dict[str, Any], name: str) -> list[Any]:
        committed = manifest.get("mcp", {}).get("servers", {}).get(name)
        pending = manifest.get("pending", {}).get("mcp_servers", {}).get(name, [])
        return [entry for entry in [committed, *pending] if entry is not None]

    @staticmethod
    def mcp_names(manifest: dict[str, Any]) -> list[str]:
        return merge_unique(
            list(manifest.get("mcp", {}).get("servers", {})),
            list(manifest.get("pending", {}).get("mcp_servers", {})),
        )

    # -- planning -----------------------------------------------------------------
    def plan_files(self, manifest: dict[str, Any]) -> dict[str, Any]:
        recorded: dict[str, str] = {}
        writes: list[tuple[Path, bytes, bool]] = []
        removals: list[Path] = []
        committed = manifest.get("files", {})
        desired = self.payload()
        for relative, data in desired.items():
            path = self.managed_path(relative)
            digest = sha256(data)
            owners = self.file_owners(manifest, relative)
            if path.is_symlink():
                self.warn(f"left user-owned symlink: {path}")
                self.counts["kept"] += 1
                if relative in committed:
                    recorded[relative] = committed[relative]
            elif not path.exists():
                writes.append((path, data, False))
                recorded[relative] = digest
            else:
                current = sha256(path.read_bytes())
                if current == digest:
                    self.counts["unchanged"] += 1
                    # Byte equality is not ownership: only a file a previous run recorded is ours.
                    if owners:
                        recorded[relative] = digest
                elif current in owners or self.force:
                    writes.append((path, data, True))
                    recorded[relative] = digest
                else:
                    reason = "modified since install" if owners else "not installed by b-agentic"
                    self.warn(f"kept {path} ({reason}); pass --force to replace it after a backup")
                    self.counts["kept"] += 1
                    if relative in committed:
                        recorded[relative] = committed[relative]
        for relative in merge_unique(list(committed), list(manifest.get("pending", {}).get("files", {}))):
            if relative in desired:
                continue
            path = self.managed_path(relative)
            if path.is_symlink() or not path.exists():
                continue
            owners = self.file_owners(manifest, relative)
            if sha256(path.read_bytes()) in owners:
                removals.append(path)
            else:
                self.warn(f"kept retired file {path} (modified since install)")
                if relative in committed:
                    recorded[relative] = committed[relative]
        return {"recorded": recorded, "writes": writes, "removals": removals}

    def plan_kernel(self, manifest: dict[str, Any]) -> dict[str, Any]:
        path = self.claude_dir / "CLAUDE.md"
        target = self.config_target(path)
        existed = target.exists()
        text = target.read_text() if existed else ""
        span = find_block(text, str(path))
        block = self.kernel_block()
        digest = sha256(block.encode())
        owners = self.kernel_owners(manifest)
        committed = manifest.get("kernel_sha256")
        created = bool(manifest.get("claude_md_created", False)) or not existed
        new_text: str | None
        if span is None:
            new_text = text.rstrip("\n") + "\n\n" + block + "\n" if text.strip() else block + "\n"
            owned: str | None = digest
        else:
            current_digest = sha256(text[span[0] : span[1]].encode())
            if current_digest == digest:
                # Identical content is not ownership: only a block a previous run recorded is ours.
                new_text, owned = None, digest if digest in owners else None
            elif current_digest in owners or self.force:
                new_text, owned = text[: span[0]] + block + text[span[1] :], digest
            else:
                reason = "modified since install" if owners else "not installed by b-agentic"
                self.warn(f"kept the kernel block in {path} ({reason}); pass --force to replace it after a backup")
                self.counts["kept"] += 1
                new_text, owned = None, committed
        return {"target": target, "text": new_text, "existed": existed, "sha256": owned, "created": created}

    def plan_settings(self, previous: dict[str, Any]) -> dict[str, Any]:
        path = self.claude_dir / "settings.json"
        target = self.config_target(path)
        settings = read_json(target)
        validate_settings_shape(settings, str(path))
        template = json.loads((self.source / "claude" / "configs" / "settings.template.json").read_text())
        record: dict[str, Any] = {"permissions": {}, "hooks": []}
        permissions = settings.setdefault("permissions", {})
        for kind in ("allow", "ask", "deny"):
            existing = permissions.setdefault(kind, [])
            wanted = template["permissions"][kind]
            recorded = previous.get("permissions", {}).get(kind, [])
            # A rule an earlier version added and this version no longer ships is retired,
            # but only if the manifest says it was ours.
            for rule in (rule for rule in recorded if rule not in wanted):
                while rule in existing:
                    existing.remove(rule)
            added = [rule for rule in recorded if rule in wanted]
            for rule in wanted:
                if rule not in existing:
                    existing.append(rule)
                    added.append(rule)
            record["permissions"][kind] = [rule for rule in dict.fromkeys(added) if rule in existing]
        hooks = settings.setdefault("hooks", {})
        recorded_hooks = previous.get("hooks", [])
        for event, entries in template["hooks"].items():
            event_entries = hooks.setdefault(event, [])
            for entry in entries:
                matcher = entry.get("matcher")
                for hook in entry["hooks"]:
                    item = {"event": event, "matcher": matcher, "hook": hook}
                    matching = [e for e in event_entries if e.get("matcher") == matcher]
                    if any(hook in e.get("hooks", []) for e in matching):
                        # An identical hook is ours only if a prior run inserted it.
                        if item in recorded_hooks:
                            record["hooks"].append(item)
                    elif any(h.get("command") == hook["command"] for e in event_entries for h in e.get("hooks", [])):
                        self.warn(
                            f"the managed hook {hook['command']} already exists in {path} with a different matcher or "
                            "fields; left as is, so its safety coverage may be incomplete"
                        )
                    else:
                        if matcher is not None and matching:
                            matching[0].setdefault("hooks", []).append(dict(hook))
                        else:
                            event_entries.append(
                                {**({"matcher": matcher} if matcher is not None else {}), "hooks": [dict(hook)]}
                            )
                        record["hooks"].append(item)
        for event in [name for name, value in hooks.items() if value == []]:
            del hooks[event]
        if not hooks:
            del settings["hooks"]
        text = json_text(settings)
        return {
            "target": target,
            "text": text if not target.exists() or target.read_text() != text else None,
            "record": record,
        }

    def plan_mcp(self, clickup: bool, manifest: dict[str, Any]) -> dict[str, Any]:
        target = self.config_target(self.mcp_path)
        config = read_json(target)
        validate_mcp_shape(config, str(self.mcp_path))
        servers = config.setdefault("mcpServers", {})
        desired = dict(json.loads((self.source / "claude" / "configs" / "mcp.base.json").read_text())["mcpServers"])
        if clickup:
            desired.update(
                json.loads((self.source / "claude" / "configs" / "mcp.clickup.json").read_text())["mcpServers"]
            )
        recorded: dict[str, Any] = {}
        for name, entry in desired.items():
            candidates = self.mcp_candidates(manifest, name)
            if name not in servers:
                servers[name] = entry
                recorded[name] = entry
            elif servers[name] == entry:
                if candidates:
                    recorded[name] = entry
            elif servers[name] in candidates:
                servers[name] = entry
                recorded[name] = entry
            else:
                self.warn(f"kept your existing MCP server '{name}' (differs from the managed entry)")
        for name in self.mcp_names(manifest):
            if name not in recorded and servers.get(name) in self.mcp_candidates(manifest, name):
                del servers[name]
        text = json_text(config)
        return {
            "target": target,
            "text": text if not target.exists() or target.read_text() != text else None,
            "recorded": recorded,
        }

    # -- operations -----------------------------------------------------------
    def install(self) -> None:
        self.preflight()
        previous = self.read_manifest()
        self.check_aliases(
            merge_unique(
                list(self.payload()),
                list(previous.get("files", {})),
                list(previous.get("pending", {}).get("files", {})),
            )
        )
        clickup = self.clickup_choice if self.clickup_choice is not None else bool(previous.get("clickup", False))
        # Plan everything first: any structural refusal happens before the first write.
        files = self.plan_files(previous)
        kernel = self.plan_kernel(previous)
        settings = self.plan_settings(previous.get("settings", {}))
        mcp = self.plan_mcp(clickup, previous)
        final = {
            "schema": MANIFEST_SCHEMA,
            "target": "claude",
            "clickup": clickup,
            "claude_md_created": kernel["created"],
            "kernel_sha256": kernel["sha256"],
            "files": dict(sorted(files["recorded"].items())),
            "settings": settings["record"],
            "mcp": {"file": str(self.mcp_path), "servers": mcp["recorded"]},
        }
        # Intent: keep the last committed ownership and list what this run may write as `pending`,
        # so an interruption leaves a manifest that recognizes both the old and the new state.
        old_pending = previous.get("pending", {})
        intent = json.loads(json.dumps(previous)) if previous else {"schema": MANIFEST_SCHEMA, "target": "claude"}
        intent.update({"clickup": clickup, "claude_md_created": kernel["created"]})
        intent.setdefault("kernel_sha256", None)
        intent.setdefault("files", {})
        intent.setdefault("mcp", {"file": str(self.mcp_path), "servers": {}})
        old_settings = intent.setdefault("settings", {"permissions": {}, "hooks": []})
        old_settings["permissions"] = {
            kind: merge_unique(old_settings.get("permissions", {}).get(kind, []), rules)
            for kind, rules in settings["record"]["permissions"].items()
        }
        old_settings["hooks"] = merge_unique(old_settings.get("hooks", []), settings["record"]["hooks"])
        # Keep every older pending key (a retired file or a dropped server may still be scheduled
        # for cleanup) and add this run's planned values, so a second interruption loses nothing.
        pending_files = {relative: list(digests) for relative, digests in old_pending.get("files", {}).items()}
        for relative, digest in files["recorded"].items():
            pending_files[relative] = merge_unique(pending_files.get(relative, []), [digest])
        pending_servers = {name: list(entries) for name, entries in old_pending.get("mcp_servers", {}).items()}
        for name, entry in mcp["recorded"].items():
            pending_servers[name] = merge_unique(pending_servers.get(name, []), [entry])
        intent["pending"] = {
            "files": pending_files,
            "kernel": merge_unique(old_pending.get("kernel", []), [kernel["sha256"]] if kernel["sha256"] else []),
            "mcp_servers": pending_servers,
        }
        self.write_manifest(intent)
        for path, data, replace in files["writes"]:
            if not self.dry_run:
                if replace:
                    self.backup(path)
                self.write_bytes(path, data)
            self.counts["written"] += 1
        for path in files["removals"]:
            if not self.dry_run:
                self.remove_file(path)
            self.counts["removed"] += 1
        if kernel["text"] is not None:
            if not self.dry_run:
                self.backup(kernel["target"])
                self.write_bytes(kernel["target"], kernel["text"].encode())
            self.say(f"kernel block {'updated' if kernel['existed'] else 'written'} in {self.claude_dir / 'CLAUDE.md'}")
        if settings["text"] is not None:
            if not self.dry_run:
                self.backup(settings["target"])
                self.write_bytes(settings["target"], settings["text"].encode())
            self.say(f"settings merged in {self.claude_dir / 'settings.json'}")
        if mcp["text"] is not None:
            if not self.dry_run:
                self.backup(mcp["target"])
                self.write_bytes(mcp["target"], mcp["text"].encode())
            self.say(f"MCP servers merged in {self.mcp_path}; restart Claude Code to load them")
        self.write_manifest(final)

    def uninstall(self) -> None:
        self.preflight()
        manifest = self.read_manifest()
        if not manifest:
            self.say("nothing to uninstall: no b-agentic manifest found")
            return
        # Plan: parse every user file first so a malformed one refuses before any removal.
        removals: list[Path] = []
        keys = merge_unique(list(manifest.get("files", {})), list(manifest.get("pending", {}).get("files", {})))
        self.check_aliases(keys)
        for relative in keys:
            path = self.managed_path(relative)
            if path.is_symlink() or not path.exists():
                continue
            if sha256(path.read_bytes()) in self.file_owners(manifest, relative):
                removals.append(path)
            else:
                self.warn(f"kept {path} (modified since install)")
        kernel_plan = self.plan_kernel_removal(manifest)
        settings_plan = self.plan_settings_removal(manifest.get("settings", {}))
        mcp_plan = self.plan_mcp_removal(manifest)
        for path in removals:
            if not self.dry_run:
                self.remove_file(path)
            self.counts["removed"] += 1
        for plan, message in (
            (kernel_plan, f"kernel block removed from {self.claude_dir / 'CLAUDE.md'}"),
            (settings_plan, f"settings entries removed from {self.claude_dir / 'settings.json'}"),
            (mcp_plan, f"MCP servers removed from {self.mcp_path}"),
        ):
            if plan is None:
                continue
            if not self.dry_run:
                self.backup(plan["target"])
                if plan.get("delete"):
                    self.remove_file(plan["target"])
                else:
                    self.write_bytes(plan["target"], plan["text"].encode())
            self.say(message)
        if not self.dry_run:
            guard_destination(self.manifest_path)
            self.manifest_path.unlink(missing_ok=True)
            for folder in ("bin", "hooks", "references"):
                directory = self.assets_dir / folder
                if directory.is_dir() and not any(directory.iterdir()):
                    guard_destination(directory)
                    directory.rmdir()
            if self.assets_dir.is_dir() and not any(self.assets_dir.iterdir()):
                guard_destination(self.assets_dir)
                self.assets_dir.rmdir()
            elif (self.assets_dir / "backups").is_dir():
                self.say(f"backups kept in {self.assets_dir / 'backups'}")

    def plan_kernel_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        owners = self.kernel_owners(manifest)
        if not owners:
            return None  # the block was never ours
        path = self.claude_dir / "CLAUDE.md"
        target = self.config_target(path)
        if not target.exists():
            return None
        text = target.read_text()
        span = find_block(text, str(path))
        if span is None:
            return None
        if sha256(text[span[0] : span[1]].encode()) not in owners:
            self.warn(f"kept the modified kernel block in {path}")
            return None
        remaining = (text[: span[0]].rstrip("\n") + "\n\n" + text[span[1] :].lstrip("\n")).strip("\n")
        if manifest.get("claude_md_created") and not remaining:
            return {"target": target, "delete": True}
        return {"target": target, "text": remaining + "\n" if remaining else ""}

    def plan_settings_removal(self, record: dict[str, Any]) -> dict[str, Any] | None:
        path = self.claude_dir / "settings.json"
        target = self.config_target(path)
        if not target.exists():
            return None
        settings = read_json(target)
        validate_settings_shape(settings, str(path))
        changed = False
        permissions = settings.get("permissions", {})
        for kind, rules in record.get("permissions", {}).items():
            existing = permissions.get(kind)
            if isinstance(existing, list):
                kept = [rule for rule in existing if rule not in rules]
                if kept != existing:
                    changed = True
                    permissions[kind] = kept
                    if kept == []:
                        del permissions[kind]
        if permissions == {} and "permissions" in settings and changed:
            del settings["permissions"]
        hooks = settings.get("hooks", {})
        for item in record.get("hooks", []):
            entries = hooks.get(item["event"], [])
            emptied = []
            for entry in entries:
                if entry.get("matcher") == item["matcher"] and item["hook"] in entry.get("hooks", []):
                    entry["hooks"].remove(item["hook"])
                    changed = True
                    if entry["hooks"] == []:
                        emptied.append(entry)
            if emptied:
                hooks[item["event"]] = [entry for entry in entries if not any(entry is gone for gone in emptied)]
                if hooks[item["event"]] == []:
                    del hooks[item["event"]]
        if hooks == {} and "hooks" in settings and changed:
            del settings["hooks"]
        return {"target": target, "text": json_text(settings)} if changed else None

    def plan_mcp_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        names = self.mcp_names(manifest)
        target = self.config_target(self.mcp_path)
        if not target.exists() or not names:
            return None
        config = read_json(target)
        validate_mcp_shape(config, str(self.mcp_path))
        servers = config.get("mcpServers", {})
        removed = [name for name in names if servers.get(name) in self.mcp_candidates(manifest, name)]
        for name in removed:
            del servers[name]
        if not removed:
            return None
        if servers == {}:
            del config["mcpServers"]
        return {"target": target, "text": json_text(config)}

    def next_steps(self) -> list[str]:
        missing = [tool for tool in PREREQUISITES if shutil.which(tool) is None]
        lines = [
            "Next steps:",
            "  1. Restart Claude Code so skills, agents, hooks, settings, and MCP servers load.",
            "  2. For the independent review gate, run these in Claude Code (installer never runs them):",
            *[f"       {command}" for command in CODEX_PLUGIN_COMMANDS],
            "     then sign in to Codex and keep the plugin's review gate disabled (b-review is the gate).",
            "  3. Approve each repository once for Codex review when b-review asks.",
        ]
        if missing:
            lines.append(
                f"  Tools not found on PATH (install them to enable the affected workflows): {', '.join(missing)}"
            )
        return lines

    def report(self, operation: str) -> None:
        for message in self.messages:
            print(message)
        for warning in self.warnings:
            print(f"warning: {warning}", file=sys.stderr)
        summary = ", ".join(f"{count} {name}" for name, count in self.counts.items() if count)
        label = "[dry-run] " if self.dry_run else ""
        print(f"{label}b-agentic {operation} for Claude Code ({self.claude_dir}): {summary or 'no changes'}")
        if operation != "uninstall" and not self.dry_run:
            print("\n".join(self.next_steps()))


def source_revision(source: Path) -> str | None:
    try:
        return subprocess.run(
            ["git", "-C", str(source), "rev-parse", "--short", "HEAD"], capture_output=True, text=True, check=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uninstall", action="store_true", help="remove what the manifest recorded")
    parser.add_argument("--dry-run", action="store_true", help="print the plan and change nothing")
    parser.add_argument("--force", action="store_true", help="replace modified or unmanaged files after a backup")
    parser.add_argument("--source", default=str(ROOT), help="b-agentic source checkout (default: this repository)")
    clickup = parser.add_mutually_exclusive_group()
    clickup.add_argument("--with-clickup", action="store_true", help="add the optional ClickUp MCP server")
    clickup.add_argument("--without-clickup", action="store_true", help="drop the optional ClickUp MCP server")
    args = parser.parse_args(argv)
    try:
        source = Path(args.source).resolve()
        if not (source / "skills" / "registry.yaml").is_file() or not (source / "claude" / "agents").is_dir():
            raise InstallError(f"{source} is not a b-agentic Claude Code source checkout")
        choice = True if args.with_clickup else False if args.without_clickup else None
        if choice is None and os.environ.get("B_AGENTIC_CLICKUP_MCP", "").lower() in {"y", "yes", "true", "1"}:
            choice = True
        installer = Installer(source, args.dry_run, args.force, choice)
        if args.uninstall:
            installer.uninstall()
            installer.report("uninstall")
        else:
            installer.install()
            installer.report(f"install ({source_revision(source) or 'unversioned source'})")
    except InstallError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(
            f"error: {exc}; the manifest records the interrupted run, so fix the cause and rerun the same command "
            "(or --uninstall)",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
