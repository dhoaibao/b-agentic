#!/usr/bin/env python3
"""Install, sync, or remove b-agentic's OpenCode assets.

The installer owns only what it records in `~/.config/opencode/b-agentic/install.json`:
copied skills, agents, the safety plugin, hooks, and CLIs (by sha256), the kernel
block in AGENTS.md (by sha256), the permission rules it appends to opencode.json
(exact values), and the MCP servers it adds under `mcp.servers`. Everything else in
those files is user-owned and preserved, and byte equality with a managed value is
never treated as ownership.

It follows the Claude Code installer's safety model: every operation first plans in
memory, validates every user file and destination, and refuses before the first write;
it then records its intent as a `pending` manifest section, applies the plan, and
commits. Nothing is written under ~/.pi or ~/.claude, and only the default
~/.config/opencode directory is supported because the managed plugin, skills, and
instructions refer to it.

OpenCode applies the last matching permission rule, so the managed rules are always the
final block of `permissions`. An `opencode.jsonc` file cannot be merged without losing
its comments, so it is refused. A manifest from the retired OpenCode runtime is refused
unless --migrate-legacy is passed, which removes only the paths that manifest names.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any

import claude_install
from claude_install import (
    KERNEL_BLOCK_END,
    KERNEL_BLOCK_START,
    SKILL_NAME,
    InstallError,
    check_directory_chain,
    check_disjoint,
    find_block,
    guard_destination,
    home_dir,
    json_text,
    merge_unique,
    read_json,
    sha256,
    source_revision,
)

# Claude Code's locations: no resolved OpenCode destination may enter them (see guard_destination).
claude_install.FOREIGN_RUNTIME_ROOTS = (".claude",)
claude_install.FOREIGN_RUNTIME_FILES = (".claude.json",)

ROOT = Path(__file__).resolve().parents[2]
MANIFEST_SCHEMA = 1
MANAGED_ROOTS = ("skills", "agents", "plugins", "b-agentic")
LEGACY_KERNEL_MARKER = "<!-- b-agentic-managed -->"
PREREQUISITES = ("node", "git", "rtk", "codegraph", "bunx", "opencode", "codex")
ENV_DIR_OVERRIDES = ("XDG_CONFIG_HOME", "OPENCODE_CONFIG_DIR", "B_AGENTIC_OPENCODE_DIR")


def resolve_opencode_dir() -> Path:
    """The default ~/.config/opencode directory; any other configured directory is refused."""
    default = home_dir() / ".config" / "opencode"
    for name in ENV_DIR_OVERRIDES:
        value = os.environ.get(name)
        if not value:
            continue
        candidate = Path(os.path.expanduser(value))
        if name == "XDG_CONFIG_HOME":
            candidate = candidate / "opencode"
        if os.path.realpath(candidate) != os.path.realpath(default):
            raise InstallError(
                f"{name}={value} is not supported: the managed plugin, skills, and instructions refer to "
                f"{default}. Unset it to install into {default}."
            )
    return default


def safe_relative(relative: str) -> str:
    parts = Path(relative).parts
    if Path(relative).is_absolute() or not parts or ".." in parts or parts[0] not in MANAGED_ROOTS:
        raise InstallError(f"unsafe managed path: {relative!r}")
    return relative


def validate_permissions_shape(config: dict[str, Any], label: str) -> None:
    if "permission" in config:
        raise InstallError(
            f"{label}: the v1 'permission' map is not merged (its rules would silently stop applying next to the "
            "managed ones); convert it to the v2 'permissions' array, then retry"
        )
    rules = config.get("permissions", [])
    if not isinstance(rules, list):
        raise InstallError(
            f"{label}: permissions must be an array of rules (OpenCode v2); the v1 'permission' map is not merged"
        )
    for rule in rules:
        if not isinstance(rule, dict) or not all(
            isinstance(rule.get(key), str) for key in ("action", "resource", "effect")
        ):
            raise InstallError(f"{label}: every permissions entry must be an object with action, resource, and effect")


def validate_mcp_shape(config: dict[str, Any], label: str) -> None:
    mcp = config.get("mcp", {})
    if not isinstance(mcp, dict) or not isinstance(mcp.get("servers", {}), dict):
        raise InstallError(f"{label}: mcp.servers must be an object")


def remove_last(rules: list[Any], rule: Any) -> None:
    for index in range(len(rules) - 1, -1, -1):
        if rules[index] == rule:
            del rules[index]
            return


class Installer:
    def __init__(self, source: Path, dry_run: bool, force: bool, clickup: bool | None, migrate_legacy: bool) -> None:
        self.source = source
        self.opencode_dir = resolve_opencode_dir()
        self.assets_dir = self.opencode_dir / "b-agentic"
        self.manifest_path = self.assets_dir / "install.json"
        self.config_path = self.opencode_dir / "opencode.json"
        self.kernel_path = self.opencode_dir / "AGENTS.md"
        self.dry_run = dry_run
        self.force = force
        self.clickup_choice = clickup
        self.migrate_legacy = migrate_legacy
        self.stamp = f"{time.strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:6]}"
        self.messages: list[str] = []
        self.warnings: list[str] = []
        self.counts = {"written": 0, "unchanged": 0, "kept": 0, "removed": 0}
        self.backed_up: set[Path] = set()
        guard_destination(self.opencode_dir)

    # -- output ---------------------------------------------------------------
    def say(self, text: str) -> None:
        self.messages.append(("[dry-run] " if self.dry_run else "") + text)

    def warn(self, text: str) -> None:
        self.warnings.append(text)

    # -- destinations -----------------------------------------------------------
    def managed_path(self, relative: str) -> Path:
        path = self.opencode_dir / safe_relative(relative)
        check_directory_chain(path.parent, self.opencode_dir)
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
        for ancestor in target.parents:
            if ancestor.exists():
                if not ancestor.is_dir():
                    raise InstallError(f"{ancestor} exists but is not a directory (needed for {target})")
                break
        return target

    def check_aliases(self, relatives: list[str]) -> None:
        destinations: list[tuple[str, Path]] = [
            ("AGENTS.md", self.config_target(self.kernel_path)),
            ("opencode.json", self.config_target(self.config_path)),
            ("the install manifest", self.manifest_path),
        ]
        for relative in relatives:
            path = self.opencode_dir / safe_relative(relative)
            if not path.is_symlink():
                destinations.append((relative, path))
        check_disjoint(destinations)

    def preflight(self) -> None:
        if self.opencode_dir.exists() and not self.opencode_dir.is_dir():
            raise InstallError(f"{self.opencode_dir} exists but is not a directory")
        check_directory_chain(self.assets_dir, self.opencode_dir)
        manifest = self.manifest_path
        if manifest.is_symlink() or (manifest.exists() and not manifest.is_file()):
            raise InstallError(f"{manifest} must be a regular file")
        guard_destination(manifest)
        check_directory_chain(self.assets_dir / "backups", self.opencode_dir)
        for path in (self.kernel_path, self.config_path):
            self.config_target(path)
        jsonc = self.opencode_dir / "opencode.jsonc"
        if jsonc.exists():
            raise InstallError(
                f"{jsonc} exists; its comments cannot be preserved by a merge. Move its settings into "
                f"{self.config_path} (JSON) or remove it, then retry."
            )
        self.check_aliases([])

    # -- writes (only called after planning) ---------------------------------------
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
        while directory != self.opencode_dir and directory.is_dir() and not any(directory.iterdir()):
            guard_destination(directory)
            directory.rmdir()
            directory = directory.parent

    # -- payload ------------------------------------------------------------------
    def payload(self) -> dict[str, bytes]:
        files: dict[str, bytes] = {}
        registry = json.loads((self.source / "skills" / "registry.yaml").read_text())
        for skill in registry["skills"]:
            name = skill["name"]
            if not isinstance(name, str) or not SKILL_NAME.fullmatch(name):
                raise InstallError(f"registry skill name is not a safe b-* name: {name!r}")
            files[f"skills/{name}/SKILL.md"] = (self.source / "opencode" / "skills" / name / "SKILL.md").read_bytes()
        for path in sorted((self.source / "opencode" / "agents").glob("b-*.md")):
            files[f"agents/{path.name}"] = path.read_bytes()
        files["plugins/b-agentic.js"] = (self.source / "opencode" / "plugins" / "b-agentic.js").read_bytes()
        # The hooks and CLIs are runtime-neutral Node scripts shared with the Claude Code install.
        for folder in ("bin", "hooks"):
            for path in sorted((self.source / "claude" / folder).glob("*.mjs")):
                files[f"b-agentic/{folder}/{path.name}"] = path.read_bytes()
        for name in ("capabilities.yaml", "mcp_operations.yaml"):
            files[f"b-agentic/references/{name}"] = (self.source / "opencode" / "references" / name).read_bytes()
        files["b-agentic/references/kernel.md"] = (self.source / "opencode" / "configs" / "kernel.md").read_bytes()
        return files

    def check_migration_targets(self) -> None:
        """The migration deletes whole legacy trees, so the files it must not lose may not be symlinks.

        A symlink chain can pass through a tree the migration deletes before it resolves elsewhere, and
        replanning would then read the dangling link as an empty config. Requiring regular files closes
        that whole class instead of tracing each chain.
        """
        for label, path in (("opencode.json", self.config_path), ("AGENTS.md", self.kernel_path)):
            if path.is_symlink():
                raise InstallError(
                    f"{path} is a symlink; --migrate-legacy deletes the retired install's trees and needs {label} to be "
                    "a regular file. Replace the link with the file it points to, then retry."
                )

    def payload_destinations(self) -> None:
        for relative in self.payload():
            self.managed_path(relative)

    def kernel_block(self) -> str:
        kernel = (self.source / "opencode" / "configs" / "kernel.md").read_text().strip("\n")
        return f"{KERNEL_BLOCK_START}\n{kernel}\n{KERNEL_BLOCK_END}"

    def template(self) -> dict[str, Any]:
        return json.loads((self.source / "opencode" / "configs" / "opencode.template.json").read_text())

    def clickup_servers(self) -> dict[str, Any]:
        path = self.source / "opencode" / "configs" / "opencode.clickup.json"
        return dict(json.loads(path.read_text())["mcp"]["servers"])

    # -- manifest -----------------------------------------------------------------
    def read_manifest(self) -> dict[str, Any]:
        manifest = read_json(self.manifest_path)
        if manifest and "schema" not in manifest and manifest.get("suite") == "b-agentic":
            return manifest  # retired OpenCode runtime; handled by the legacy path
        if manifest and manifest.get("schema") != MANIFEST_SCHEMA:
            raise InstallError(f"{self.manifest_path} has an unsupported schema; uninstall with the matching version")
        if manifest and manifest.get("target") != "opencode":
            raise InstallError(f"{self.manifest_path} was not written by the OpenCode installer")
        for relative in [*manifest.get("files", {}), *manifest.get("pending", {}).get("files", {})]:
            safe_relative(relative)
        return manifest

    @staticmethod
    def is_legacy(manifest: dict[str, Any]) -> bool:
        return bool(manifest) and "schema" not in manifest and manifest.get("suite") == "b-agentic"

    def write_manifest(self, manifest: dict[str, Any]) -> None:
        if self.dry_run:
            return
        text = json_text(manifest)
        if not self.manifest_path.exists() or self.manifest_path.read_text() != text:
            self.write_bytes(self.manifest_path, text.encode())

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

    @staticmethod
    def permission_records(manifest: dict[str, Any]) -> list[dict[str, str]]:
        return merge_unique(manifest.get("permissions", []), *manifest.get("pending", {}).get("permissions", []))

    # -- legacy migration ---------------------------------------------------------------
    def legacy_removals(self, manifest: dict[str, Any]) -> list[Path]:
        """Paths the retired OpenCode install created, from its own manifest; nothing else."""
        paths: list[Path] = []
        for key, folder, suffix in (
            ("skills", "skills", ""),
            ("agents", "agents", ".md"),
            ("commands", "commands", ".md"),
        ):
            for name in manifest.get(key, []):
                if isinstance(name, str) and SKILL_NAME.fullmatch(name):
                    paths.append(self.opencode_dir / folder / f"{name}{suffix}")
        for folder in ("agents", "commands", "references", "skills", "templates", "tooling"):
            paths.append(self.assets_dir / folder)
        paths.append(self.assets_dir / "AGENTS.md")
        for path in paths:
            # Every ancestor down to the leaf's parent must be a real directory inside the OpenCode
            # directory, so a symlinked parent cannot redirect a deletion elsewhere.
            check_directory_chain(path.parent, self.opencode_dir)
            guard_destination(path)
        return paths

    def backup_tree(self, path: Path) -> None:
        relative = str(path).lstrip("/").replace("/", "__")
        target = self.assets_dir / "backups" / self.stamp / relative
        guard_destination(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(path, target, symlinks=True)

    def migrate_legacy_install(self, manifest: dict[str, Any]) -> None:
        for path in self.legacy_removals(manifest):
            guard_destination(path)
            if path.is_symlink() or not path.exists():
                continue
            if not self.dry_run:
                if path.is_dir():
                    self.backup_tree(path)
                    shutil.rmtree(path)
                else:
                    self.backup(path)
                    path.unlink()
            self.counts["removed"] += 1
        if (
            self.kernel_path.is_file()
            and not self.kernel_path.is_symlink()
            and self.kernel_path.read_text().startswith(LEGACY_KERNEL_MARKER)
        ):
            if not self.dry_run:
                self.backup(self.kernel_path)
                self.kernel_path.unlink()
            self.counts["removed"] += 1
        self.say("retired OpenCode install removed (backups kept under b-agentic/backups)")

    # -- planning -----------------------------------------------------------------------
    def plan_all(self, previous: dict[str, Any], clickup: bool) -> tuple[dict[str, Any], ...]:
        self.counts = {name: 0 for name in self.counts}
        self.warnings.clear()
        return (
            self.plan_files(previous),
            self.plan_kernel(previous),
            self.plan_config(previous, clickup),
        )

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
            if sha256(path.read_bytes()) in self.file_owners(manifest, relative):
                removals.append(path)
            else:
                self.warn(f"kept retired file {path} (modified since install)")
                if relative in committed:
                    recorded[relative] = committed[relative]
        return {"recorded": recorded, "writes": writes, "removals": removals}

    def plan_kernel(self, manifest: dict[str, Any]) -> dict[str, Any]:
        target = self.config_target(self.kernel_path)
        existed = target.exists()
        text = target.read_text() if existed else ""
        span = find_block(text, str(self.kernel_path))
        block = self.kernel_block()
        digest = sha256(block.encode())
        owners = self.kernel_owners(manifest)
        committed = manifest.get("kernel_sha256")
        created = bool(manifest.get("agents_md_created", False)) or not existed
        new_text: str | None
        if span is None:
            new_text = text.rstrip("\n") + "\n\n" + block + "\n" if text.strip() else block + "\n"
            owned: str | None = digest
        else:
            current_digest = sha256(text[span[0] : span[1]].encode())
            if current_digest == digest:
                new_text, owned = None, digest if digest in owners else None
            elif current_digest in owners or self.force:
                new_text, owned = text[: span[0]] + block + text[span[1] :], digest
            else:
                reason = "modified since install" if owners else "not installed by b-agentic"
                self.warn(f"kept the kernel block in {self.kernel_path} ({reason}); pass --force to replace it")
                self.counts["kept"] += 1
                new_text, owned = None, committed
        return {"target": target, "text": new_text, "existed": existed, "sha256": owned, "created": created}

    def plan_config(self, manifest: dict[str, Any], clickup: bool) -> dict[str, Any]:
        """opencode.json: the managed permission block goes last, and missing MCP servers are added."""
        target = self.config_target(self.config_path)
        config = read_json(target)
        label = str(self.config_path)
        validate_permissions_shape(config, label)
        validate_mcp_shape(config, label)
        template = self.template()
        wanted = template["permissions"]
        rules = list(config.get("permissions", []))
        for rule in reversed(self.permission_records(manifest)):
            remove_last(rules, rule)
        rules.extend(dict(rule) for rule in wanted)
        config["permissions"] = rules
        servers = config.setdefault("mcp", {}).setdefault("servers", {})
        desired = dict(template["mcp"]["servers"])
        if clickup:
            desired.update(self.clickup_servers())
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
            "permissions": [dict(rule) for rule in wanted],
            "mcp": recorded,
        }

    # -- operations ---------------------------------------------------------------------
    def validate_destinations(self) -> tuple[dict[str, Any], list[str]]:
        self.preflight()
        previous = self.read_manifest()
        if self.is_legacy(previous):
            if not self.migrate_legacy:
                raise InstallError(
                    f"{self.manifest_path} belongs to the retired OpenCode install. Re-run with --migrate-legacy to "
                    "remove its skills, agents, commands, and kernel (backed up) before installing."
                )
            previous = {}
        payload = list(self.payload())
        self.check_aliases(
            merge_unique(payload, list(previous.get("files", {})), list(previous.get("pending", {}).get("files", {})))
        )
        return previous, payload

    def install(self) -> None:
        self.preflight()
        raw = self.read_manifest()
        if self.is_legacy(raw) and self.migrate_legacy:
            # Validate the whole replacement install, and every path the migration would delete, before
            # removing anything; the legacy manifest stays until the new intent manifest replaces it, so
            # an interruption leaves a retryable --migrate-legacy state.
            self.legacy_removals(raw)
            self.check_migration_targets()
            self.payload_destinations()
            self.check_aliases(list(self.payload()))
            self.plan_all({}, bool(self.clickup_choice))
            self.warnings.clear()
            self.migrate_legacy_install(raw)
        previous, _ = self.validate_destinations()
        clickup = self.clickup_choice if self.clickup_choice is not None else bool(previous.get("clickup", False))
        files, kernel, config = self.plan_all(previous, clickup)
        final = {
            "schema": MANIFEST_SCHEMA,
            "target": "opencode",
            "clickup": clickup,
            "agents_md_created": kernel["created"],
            "kernel_sha256": kernel["sha256"],
            "files": dict(sorted(files["recorded"].items())),
            "permissions": config["permissions"],
            "mcp": {"file": str(self.config_path), "servers": config["mcp"]},
        }
        old_pending = previous.get("pending", {})
        intent = json.loads(json.dumps(previous)) if previous else {"schema": MANIFEST_SCHEMA, "target": "opencode"}
        intent.update({"clickup": clickup, "agents_md_created": kernel["created"]})
        intent.setdefault("kernel_sha256", None)
        intent.setdefault("files", {})
        intent.setdefault("permissions", [])
        intent.setdefault("mcp", {"file": str(self.config_path), "servers": {}})
        pending_files = {relative: list(digests) for relative, digests in old_pending.get("files", {}).items()}
        for relative, digest in files["recorded"].items():
            pending_files[relative] = merge_unique(pending_files.get(relative, []), [digest])
        pending_servers = {name: list(entries) for name, entries in old_pending.get("mcp_servers", {}).items()}
        for name, entry in config["mcp"].items():
            pending_servers[name] = merge_unique(pending_servers.get(name, []), [entry])
        intent["pending"] = {
            "files": pending_files,
            "kernel": merge_unique(old_pending.get("kernel", []), [kernel["sha256"]] if kernel["sha256"] else []),
            "mcp_servers": pending_servers,
            "permissions": [*old_pending.get("permissions", []), config["permissions"]],
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
            self.say(f"kernel block {'updated' if kernel['existed'] else 'written'} in {self.kernel_path}")
        if config["text"] is not None:
            if not self.dry_run:
                self.backup(config["target"])
                self.write_bytes(config["target"], config["text"].encode())
            self.say(f"permissions and MCP servers merged in {self.config_path}; restart OpenCode to load them")
        self.write_manifest(final)

    def uninstall(self) -> None:
        self.preflight()
        manifest = self.read_manifest()
        if not manifest:
            self.say("nothing to uninstall: no b-agentic manifest found")
            return
        if self.is_legacy(manifest):
            raise InstallError(
                f"{self.manifest_path} belongs to the retired OpenCode install; run install.sh --runtime=opencode "
                "--migrate-legacy to remove it"
            )
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
        config_plan = self.plan_config_removal(manifest)
        for path in removals:
            if not self.dry_run:
                self.remove_file(path)
            self.counts["removed"] += 1
        for plan, message in (
            (kernel_plan, f"kernel block removed from {self.kernel_path}"),
            (config_plan, f"permissions and MCP servers removed from {self.config_path}"),
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
            return None
        target = self.config_target(self.kernel_path)
        if not target.exists():
            return None
        text = target.read_text()
        span = find_block(text, str(self.kernel_path))
        if span is None:
            return None
        if sha256(text[span[0] : span[1]].encode()) not in owners:
            self.warn(f"kept the modified kernel block in {self.kernel_path}")
            return None
        remaining = (text[: span[0]].rstrip("\n") + "\n\n" + text[span[1] :].lstrip("\n")).strip("\n")
        if manifest.get("agents_md_created") and not remaining:
            return {"target": target, "delete": True}
        return {"target": target, "text": remaining + "\n" if remaining else ""}

    def plan_config_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        target = self.config_target(self.config_path)
        if not target.exists():
            return None
        config = read_json(target)
        label = str(self.config_path)
        validate_permissions_shape(config, label)
        validate_mcp_shape(config, label)
        changed = False
        rules = config.get("permissions", [])
        for rule in reversed(self.permission_records(manifest)):
            before = len(rules)
            remove_last(rules, rule)
            changed = changed or len(rules) != before
        if changed and rules == []:
            del config["permissions"]
        servers = config.get("mcp", {}).get("servers", {})
        removed = [
            name for name in self.mcp_names(manifest) if servers.get(name) in self.mcp_candidates(manifest, name)
        ]
        for name in removed:
            del servers[name]
            changed = True
        if removed and servers == {}:
            del config["mcp"]["servers"]
            if config["mcp"] == {}:
                del config["mcp"]
        return {"target": target, "text": json_text(config)} if changed else None

    def next_steps(self) -> list[str]:
        missing = [tool for tool in PREREQUISITES if shutil.which(tool) is None]
        lines = [
            "Next steps:",
            "  1. Restart OpenCode so skills, agents, the safety plugin, permissions, and MCP servers load.",
            "  2. The independent review gate reuses the Claude Code codex plugin (~/.claude/plugins); without it,",
            "     b-review reports the gate unavailable and asks. Install it from Claude Code:",
            "       /plugin marketplace add openai/codex-plugin-cc",
            "       /plugin install codex@openai-codex",
            "       /codex:setup",
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
        print(f"{label}b-agentic {operation} for OpenCode ({self.opencode_dir}): {summary or 'no changes'}")
        if operation != "uninstall" and not self.dry_run:
            print("\n".join(self.next_steps()))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uninstall", action="store_true", help="remove what the manifest recorded")
    parser.add_argument("--dry-run", action="store_true", help="print the plan and change nothing")
    parser.add_argument("--force", action="store_true", help="replace modified or unmanaged files after a backup")
    parser.add_argument("-y", "--yes", action="store_true", help="accepted for parity with the Claude Code installer")
    parser.add_argument("--migrate-legacy", action="store_true", help="remove the retired OpenCode install first")
    parser.add_argument("--source", default=str(ROOT), help="b-agentic source checkout (default: this repository)")
    clickup = parser.add_mutually_exclusive_group()
    clickup.add_argument("--with-clickup", action="store_true", help="add the optional ClickUp MCP server")
    clickup.add_argument("--without-clickup", action="store_true", help="drop the optional ClickUp MCP server")
    args = parser.parse_args(argv)
    try:
        source = Path(args.source).resolve()
        if not (source / "skills" / "registry.yaml").is_file() or not (source / "opencode" / "agents").is_dir():
            raise InstallError(f"{source} is not a b-agentic source checkout with OpenCode assets")
        choice = True if args.with_clickup else False if args.without_clickup else None
        if choice is None and os.environ.get("B_AGENTIC_CLICKUP_MCP", "").lower() in {"y", "yes", "true", "1"}:
            choice = True
        installer = Installer(source, args.dry_run, args.force, choice, args.migrate_legacy)
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
