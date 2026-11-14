#!/usr/bin/env python3
"""Install, sync, or remove b-agentic's Pi assets.

The installer owns only what it records in `~/.pi/agent/b-agentic/install.json`:
copied skills, prompts, agents, the guard extension, hooks, and CLIs (by sha256), the
kernel block in AGENTS.md (by sha256), the package pins it adds to settings.json, the MCP
servers it adds to mcp.json, and the permission system's config (by sha256, only when it is
absent or was written by b-agentic; a config with the user's own rules is never edited). Everything else in those files is user-owned and preserved, and byte
equality with a managed value is never treated as ownership.

It plans in memory, refuses before the first write when a user file is malformed or a
destination is unsafe, records its intent as a `pending` manifest section, applies the
plan, and commits, exactly like the Claude Code installer. It never runs `pi install`,
npm, or any vendor installer (Pi installs the pinned packages on its next start), never
touches ~/.claude or ~/.claude.json, and supports only the default ~/.pi/agent directory
because the managed extension, hooks, and instructions refer to it.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any

import optional_components
from claude_install import (
    KERNEL_BLOCK_END,
    KERNEL_BLOCK_START,
    SKILL_NAME,
    InstallError,
    add_optional_arguments,
    check_directory_chain,
    check_disjoint,
    find_block,
    guard_destination,
    home_dir,
    json_text,
    merge_unique,
    parse_optional_arguments,
    read_json,
    sha256,
    source_revision,
)
from claude_install_ui import Ui

ROOT = Path(__file__).resolve().parents[2]
MANIFEST_SCHEMA = 1
MANAGED_ROOTS = ("skills", "prompts", "agents", "extensions", "b-agentic")
# What a Pi install never touches: Claude Code's directory and configuration file.
PI_PROTECTED = ((".claude", "the Claude Code directory"), (".claude.json", "the Claude Code configuration"))
PI_HOOKS = ("b-path-guard.mjs", "b-verify-gate.mjs", "b-spec-context.mjs", "b-run-context.mjs")
PI_BINS = (
    "b-candidate-snapshot.mjs",
    "b-state.mjs",
    "b-state-commands.mjs",
    "b-state-core.mjs",
    "b-state-gates.mjs",
    "b-state-git.mjs",
    "b-state-next.mjs",
    "b-state-record.mjs",
    "b-state-store.mjs",
    "b-state-worktree.mjs",
    "b_run.py",
)
PI_REFERENCES = ("capabilities.yaml", "mcp_operations.yaml", "artifacts.yaml")
EXTENSION_FILES = ("index.ts", "guard.mjs")
# A copy of the generated permission config always ships here, so a user with their own rules can merge it by hand.
PERMISSION_COPY = "b-agentic/permission.json"
PREREQUISITES = ("node", "git", "rtk", "codegraph", "bunx", "pi")
# Names Pi loads from the agent directory as instruction files, in precedence order.
INSTRUCTION_FILES = ("AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD")


def resolve_pi_dir() -> Path:
    """The default ~/.pi/agent directory; any other configured directory is refused."""
    default = home_dir() / ".pi" / "agent"
    value = os.environ.get("PI_CODING_AGENT_DIR")
    if value and os.path.realpath(os.path.expanduser(value)) != os.path.realpath(default):
        raise InstallError(
            f"PI_CODING_AGENT_DIR={value} is not supported: the managed extension, hooks, and instructions refer to "
            f"{default}. Unset it to install into {default}."
        )
    return default


def safe_relative(relative: str) -> str:
    parts = Path(relative).parts
    if Path(relative).is_absolute() or not parts or ".." in parts or parts[0] not in MANAGED_ROOTS:
        raise InstallError(f"unsafe managed path: {relative!r}")
    return relative


def package_name(entry: Any) -> str | None:
    """The npm package a `packages` entry names: `npm:@scope/name@1.2.3` or an object with a `source`."""
    source = entry if isinstance(entry, str) else entry.get("source") if isinstance(entry, dict) else None
    match = re.match(r"^npm:(@?[^@]+)", source) if isinstance(source, str) else None
    return match.group(1) if match else None


def validate_settings_shape(settings: dict[str, Any], label: str) -> None:
    packages = settings.get("packages", [])
    if not isinstance(packages, list):
        raise InstallError(f"{label}: packages must be an array")
    if not all(isinstance(entry, (str, dict)) for entry in packages):
        raise InstallError(f"{label}: every packages entry must be a string or an object")


def validate_mcp_shape(config: dict[str, Any], label: str) -> None:
    if not isinstance(config.get("mcpServers", {}), dict):
        raise InstallError(f"{label}: mcpServers must be an object")


class PiInstaller:
    def __init__(
        self,
        source: Path,
        dry_run: bool,
        force: bool,
        ui: Ui | None = None,
        with_ids: list[str] | None = None,
        without_ids: list[str] | None = None,
    ) -> None:
        self.source = source
        self.components = self.load_components()
        self.with_ids = with_ids or []
        self.without_ids = without_ids or []
        self.selection: dict[str, bool] = {key: False for key in self.components}
        self.ui = ui if ui is not None else Ui(enabled=False)
        self.pi_dir = resolve_pi_dir()
        self.assets_dir = self.pi_dir / "b-agentic"
        self.manifest_path = self.assets_dir / "install.json"
        self.dry_run = dry_run
        self.force = force
        self.stamp = f"{time.strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:6]}"
        self.messages: list[str] = []
        self.warnings: list[str] = []
        self.counts = {"written": 0, "unchanged": 0, "kept": 0, "removed": 0}
        self.backed_up: set[Path] = set()
        guard_destination(self.pi_dir, PI_PROTECTED)

    # -- optional components --------------------------------------------------
    def load_components(self) -> dict[str, dict[str, Any]]:
        try:
            return optional_components.load(self.source)
        except ValueError as exc:
            raise InstallError(str(exc)) from exc

    def select_components(self, manifest: dict[str, Any]) -> None:
        try:
            self.selection = optional_components.resolve(self.components, manifest, self.with_ids, self.without_ids)
        except ValueError as exc:
            raise InstallError(str(exc)) from exc
        if self.components and not (self.with_ids or self.without_ids) and self.ui.interactive:
            options = [(key, component["label"]) for key, component in self.components.items()]
            picked = self.ui.checklist(
                "Optional components (unchecked ones are not installed; installed ones that are unchecked are removed)",
                options,
                {key for key, on in self.selection.items() if on},
            )
            self.selection = {key: key in picked for key in self.components}

    def excluded_skills(self) -> set[str]:
        return optional_components.excluded_skills(self.components, self.selection)

    def excluded_servers(self) -> set[str]:
        return optional_components.excluded_servers(self.components, self.selection)

    # -- output ---------------------------------------------------------------
    def say(self, text: str) -> None:
        self.messages.append(("[dry-run] " if self.dry_run else "") + text)

    def warn(self, text: str) -> None:
        self.warnings.append(text)

    @staticmethod
    def display_text(text: str) -> str:
        return text.replace(str(home_dir()), "~")

    def display(self, path: Path | str) -> str:
        text = str(path)
        home = str(home_dir())
        return "~" + text[len(home) :] if text == home or text.startswith(home + os.sep) else text

    def plan_summary(
        self,
        files: dict[str, Any],
        kernel: dict[str, Any],
        settings: dict[str, Any],
        mcp: dict[str, Any],
        permission: dict[str, Any],
    ) -> list[str]:
        def verb(text: Any, changed: str) -> str:
            return changed if text is not None else "unchanged"

        file_parts = [f"{len(files['writes'])} to write", f"{self.counts['unchanged']} unchanged"]
        if files["removals"]:
            file_parts.append(f"{len(files['removals'])} to remove")
        if self.counts["kept"]:
            file_parts.append(f"{self.counts['kept']} kept")
        return [
            self.ui.style(self.display(self.pi_dir), "cyan"),
            f"  {self.ui.style('files', 'green')}: {', '.join(file_parts)}",
            f"  {self.ui.style('kernel', 'green')}: AGENTS.md block "
            f"{verb(kernel['text'], 'updated' if kernel['existed'] else 'written')}",
            f"  {self.ui.style('settings', 'green')}: settings.json packages {verb(settings['text'], 'merged')}",
            f"  {self.ui.style('mcp', 'green')}: mcp.json {verb(mcp['text'], 'merged')}",
            f"  {self.ui.style('permission', 'green')}: permission config {verb(permission['text'], 'written')}",
            f"  {self.ui.style('optional', 'green')}: {optional_components.summary(self.components, self.selection)}",
        ]

    # -- destinations -------------------------------------------------------------
    def managed_path(self, relative: str) -> Path:
        path = self.pi_dir / safe_relative(relative)
        check_directory_chain(path.parent, self.pi_dir, PI_PROTECTED)
        if path.is_dir() and not path.is_symlink():
            raise InstallError(f"{path} is a directory; expected a file")
        guard_destination(path, PI_PROTECTED)
        return path

    def config_target(self, path: Path) -> Path:
        """A user-owned config file; a symlinked file is written through, never replaced."""
        target = Path(os.path.realpath(path)) if path.is_symlink() else path
        guard_destination(target, PI_PROTECTED)
        if target.exists() and not target.is_file():
            raise InstallError(f"{target} exists but is not a regular file")
        for ancestor in target.parents:
            if ancestor.exists():
                if not ancestor.is_dir():
                    raise InstallError(f"{ancestor} exists but is not a directory (needed for {target})")
                break
        return target

    @property
    def agents_md(self) -> Path:
        return self.pi_dir / "AGENTS.md"

    @property
    def settings_path(self) -> Path:
        return self.pi_dir / "settings.json"

    @property
    def mcp_path(self) -> Path:
        return self.pi_dir / "mcp.json"

    @property
    def permission_path(self) -> Path:
        return self.pi_dir / "extensions" / "pi-permission-system" / "config.json"

    def config_files(self) -> list[tuple[str, Path]]:
        return [
            ("AGENTS.md", self.agents_md),
            ("settings.json", self.settings_path),
            ("mcp.json", self.mcp_path),
            ("the permission config", self.permission_path),
        ]

    def check_aliases(self, relatives: list[str]) -> None:
        destinations: list[tuple[str, Path]] = [
            (label, self.config_target(path)) for label, path in self.config_files()
        ]
        destinations.append(("the install manifest", self.manifest_path))
        for relative in relatives:
            path = self.pi_dir / safe_relative(relative)
            if not path.is_symlink():
                destinations.append((relative, path))
        check_disjoint(destinations)

    def preflight(self) -> None:
        if self.pi_dir.exists() and not self.pi_dir.is_dir():
            raise InstallError(f"{self.pi_dir} exists but is not a directory")
        check_directory_chain(self.assets_dir, self.pi_dir, PI_PROTECTED)
        manifest = self.manifest_path
        if manifest.is_symlink() or (manifest.exists() and not manifest.is_file()):
            raise InstallError(f"{manifest} must be a regular file")
        guard_destination(manifest, PI_PROTECTED)
        check_directory_chain(self.assets_dir / "backups", self.pi_dir, PI_PROTECTED)
        for _, path in self.config_files():
            self.config_target(path)
        self.check_aliases([])

    # -- writes (only called after planning) ----------------------------------------
    def write_bytes(self, path: Path, data: bytes) -> None:
        guard_destination(path, PI_PROTECTED)
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
        guard_destination(target, PI_PROTECTED)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)

    def remove_file(self, path: Path) -> None:
        guard_destination(path, PI_PROTECTED)
        path.unlink(missing_ok=True)
        directory = path.parent
        while directory != self.pi_dir and directory.is_dir() and not any(directory.iterdir()):
            guard_destination(directory, PI_PROTECTED)
            directory.rmdir()
            directory = directory.parent

    # -- payload --------------------------------------------------------------
    def payload(self) -> dict[str, bytes]:
        files: dict[str, bytes] = {}
        registry = json.loads((self.source / "skills" / "registry.yaml").read_text())
        excluded = self.excluded_skills()
        for skill in registry["skills"]:
            name = skill["name"]
            if not isinstance(name, str) or not SKILL_NAME.fullmatch(name):
                raise InstallError(f"registry skill name is not a safe b-* name: {name!r}")
            if name in excluded:
                continue
            try:
                body = optional_components.filter_skill(
                    (self.source / "pi" / "skills" / name / "SKILL.md").read_bytes().decode(),
                    excluded,
                    optional_components.optional_skills(self.components),
                )
            except ValueError as exc:
                raise InstallError(f"pi/skills/{name}/SKILL.md: {exc}") from exc
            files[f"skills/{name}/SKILL.md"] = body.encode()
            files[f"prompts/{name}.md"] = (self.source / "pi" / "prompts" / f"{name}.md").read_bytes()
        for path in sorted((self.source / "pi" / "agents").glob("b-*.md")):
            files[f"agents/{path.name}"] = path.read_bytes()
        for name in EXTENSION_FILES:
            files[f"extensions/b-agentic/{name}"] = (
                self.source / "pi" / "extensions" / "b-agentic" / name
            ).read_bytes()
        for name in PI_HOOKS:
            files[f"b-agentic/hooks/{name}"] = (self.source / "claude" / "hooks" / name).read_bytes()
        for name in PI_BINS:
            files[f"b-agentic/bin/{name}"] = (self.source / "claude" / "bin" / name).read_bytes()
        for name in PI_REFERENCES:
            files[f"b-agentic/references/{name}"] = (self.source / "references" / name).read_bytes()
        files[PERMISSION_COPY] = self.permission_text().encode()
        return files

    def kernel_block(self) -> str:
        kernel = (self.source / "pi" / "kernel.md").read_text().strip("\n")
        try:
            kernel = optional_components.filter_kernel(kernel, self.excluded_skills())
        except ValueError as exc:
            raise InstallError(str(exc)) from exc
        return f"{KERNEL_BLOCK_START}\n{kernel}\n{KERNEL_BLOCK_END}"

    # -- manifest -------------------------------------------------------------
    def read_manifest(self) -> dict[str, Any]:
        manifest = read_json(self.manifest_path)
        if manifest and (manifest.get("schema") != MANIFEST_SCHEMA or manifest.get("target") != "pi"):
            raise InstallError(f"{self.manifest_path} is not a Pi install manifest of a supported schema")
        for relative in [*manifest.get("files", {}), *manifest.get("pending", {}).get("files", {})]:
            safe_relative(relative)
        return manifest

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
    def recorded_packages(manifest: dict[str, Any]) -> list[str]:
        return merge_unique(
            list(manifest.get("settings", {}).get("packages", [])),
            list(manifest.get("pending", {}).get("packages", [])),
        )

    # -- planning -----------------------------------------------------------------
    def plan_all(self, previous: dict[str, Any]) -> tuple[dict[str, Any], ...]:
        self.counts = {name: 0 for name in self.counts}
        self.warnings.clear()
        files = self.plan_files(previous)
        kernel = self.plan_kernel(previous)
        settings = self.plan_settings(previous)
        mcp = self.plan_mcp(previous)
        permission = self.plan_permission(previous)
        self.warn_foreign_skills()
        return files, kernel, settings, mcp, permission

    def warn_foreign_skills(self) -> None:
        """Pi also discovers ~/.agents/skills; an older b-* skill there is not ours and may shadow ours."""
        shared = home_dir() / ".agents" / "skills"
        if not shared.is_dir():
            return
        found = sorted(entry.name for entry in shared.iterdir() if SKILL_NAME.fullmatch(entry.name))
        if found:
            self.warn(
                f"{shared} holds b-* skills ({', '.join(found)}) that Pi also loads and that b-agentic does not own; "
                "when a name matches an installed skill Pi keeps only one, so remove the old copies by hand"
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
        target = self.config_target(self.agents_md)
        existed = target.exists()
        text = target.read_text() if existed else ""
        span = find_block(text, str(self.agents_md))
        block = self.kernel_block()
        digest = sha256(block.encode())
        owners = self.kernel_owners(manifest)
        committed = manifest.get("kernel_sha256")
        created = bool(manifest.get("agents_md_created", False)) or not existed
        if not existed:
            # Pi loads only the first instruction file of a directory, so a new AGENTS.md would hide another.
            hidden = [name for name in INSTRUCTION_FILES[2:] if (self.pi_dir / name).exists()]
            if hidden:
                raise InstallError(
                    f"{self.pi_dir / hidden[0]} exists and Pi would stop loading it once AGENTS.md exists "
                    "(Pi reads only the first of AGENTS.override.md, AGENTS.md, AGENTS.MD, CLAUDE.md, CLAUDE.MD); "
                    "move its content into AGENTS.md, then install again"
                )
        if (self.pi_dir / INSTRUCTION_FILES[0]).exists():
            self.warn(
                f"{self.pi_dir / INSTRUCTION_FILES[0]} exists, and Pi loads it instead of AGENTS.md, "
                "so the b-agentic kernel will not load until you remove or merge it"
            )
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
                self.warn(
                    f"kept the kernel block in {self.agents_md} ({reason}); pass --force to replace it after a backup"
                )
                self.counts["kept"] += 1
                new_text, owned = None, committed
        return {"target": target, "text": new_text, "existed": existed, "sha256": owned, "created": created}

    def plan_settings(self, manifest: dict[str, Any]) -> dict[str, Any]:
        """Add the pinned packages to settings.json `packages`; never run an install."""
        target = self.config_target(self.settings_path)
        settings = read_json(target)
        validate_settings_shape(settings, str(self.settings_path))
        wanted = json.loads((self.source / "pi" / "configs" / "settings.packages.json").read_text())["packages"]
        recorded_before = self.recorded_packages(manifest)
        packages = settings.setdefault("packages", [])
        owned: list[str] = []
        wanted_names = {package_name(pin) for pin in wanted}
        # A pin an earlier version added and this version no longer ships is retired when still exactly ours.
        for pin in recorded_before:
            if package_name(pin) not in wanted_names and pin in packages:
                packages.remove(pin)
        for pin in wanted:
            name = package_name(pin)
            same_package = [entry for entry in packages if package_name(entry) == name]
            if pin in packages:
                if pin in recorded_before:
                    owned.append(pin)
            elif not same_package:
                packages.append(pin)
                owned.append(pin)
            elif all(entry in recorded_before for entry in same_package):
                for entry in same_package:
                    packages.remove(entry)
                packages.append(pin)
                owned.append(pin)
            else:
                self.warn(
                    f"kept your settings.json entry for {name} (it differs from the pinned {pin}); "
                    "the tested version may not match"
                )
        if not packages:
            del settings["packages"]
        text = json_text(settings)
        return {
            "target": target,
            "text": text if not target.exists() or target.read_text() != text else None,
            "record": {"packages": owned},
            "created": not target.exists(),
        }

    def plan_mcp(self, manifest: dict[str, Any]) -> dict[str, Any]:
        target = self.config_target(self.mcp_path)
        config = read_json(target)
        validate_mcp_shape(config, str(self.mcp_path))
        servers = config.setdefault("mcpServers", {})
        excluded = self.excluded_servers()
        desired = {
            name: entry
            for name, entry in json.loads((self.source / "pi" / "configs" / "mcp.base.json").read_text())[
                "mcpServers"
            ].items()
            if name not in excluded
        }
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
            if name in recorded or name not in servers:
                continue
            if servers[name] in self.mcp_candidates(manifest, name):
                del servers[name]
            elif name in excluded:
                self.warn(f"kept your edited MCP server '{name}' although its optional component is not selected")
        if not servers:
            del config["mcpServers"]
        text = json_text(config)
        return {
            "target": target,
            "text": text if not target.exists() or target.read_text() != text else None,
            "recorded": recorded,
            "created": not target.exists(),
        }

    def permission_text(self) -> str:
        """The generated permission config, without the rules of any deselected optional server."""
        template = json.loads((self.source / "pi" / "configs" / "permission.json").read_text())
        prefixes = tuple(f"mcp__{re.sub(r'[^A-Za-z0-9_]', '_', server)}__" for server in self.excluded_servers())
        permission = dict(template["permission"])
        permission["mcp"] = {
            key: value
            for key, value in template["permission"]["mcp"].items()
            if not (prefixes and key.startswith(prefixes))
        }
        return json_text({"yoloMode": template["yoloMode"], "permission": permission})

    @staticmethod
    def permission_owners(manifest: dict[str, Any]) -> set[str]:
        committed = manifest.get("permission_sha256")
        return {d for d in [committed, *manifest.get("pending", {}).get("permission", [])] if d}

    def plan_permission(self, manifest: dict[str, Any]) -> dict[str, Any]:
        """Write the generated permission config only when none exists or the file is one b-agentic wrote.

        The permission system resolves a config by its own rules (a universal `*` is only a fallback, `mcp`
        is its own surface), so merging managed rules into a user's rules could weaken what the user
        restricted. A config that holds the user's own rules is left untouched; the generated copy under
        b-agentic/ is for merging by hand.
        """
        target = self.config_target(self.permission_path)
        text = self.permission_text()
        digest = sha256(text.encode())
        owners = self.permission_owners(manifest)
        committed = manifest.get("permission_sha256")
        new_text: str | None
        if not target.exists():
            new_text, owned = text, digest
        else:
            current = sha256(target.read_bytes())
            if current == digest:
                new_text, owned = None, digest if digest in owners else None
            elif current in owners or self.force:
                new_text, owned = text, digest
            else:
                reason = "modified since install" if owners else "your own rules"
                self.warn(
                    f"left {self.permission_path} untouched ({reason}), so Pi runs without b-agentic's generated "
                    f"permission rules and its safety coverage is incomplete; merge {self.assets_dir / 'permission.json'} "
                    "into it by hand (a universal * rule and the mcp section interact with it), or pass --force to "
                    "replace it after a backup"
                )
                self.counts["kept"] += 1
                new_text, owned = None, committed
        return {"target": target, "text": new_text, "sha256": owned}

    # -- operations -----------------------------------------------------------
    def validate_destinations(self) -> tuple[dict[str, Any], list[str]]:
        self.preflight()
        previous = self.read_manifest()
        payload = list(self.payload())
        self.check_aliases(
            merge_unique(payload, list(previous.get("files", {})), list(previous.get("pending", {}).get("files", {})))
        )
        return previous, payload

    def install(self) -> None:
        self.preflight()
        manifest = self.read_manifest()
        for note in [line for line in os.environ.get("B_AGENTIC_NOTES", "").splitlines() if line]:
            if self.ui.fancy:
                self.ui.step(self.display_text(note))
            else:
                print(note)
        self.ui.step(f"Source: {self.display(self.source)}")
        self.select_components(manifest)
        previous, payload = self.validate_destinations()
        skill_count = len({relative.split("/")[1] for relative in payload if relative.startswith("skills/")})
        agent_count = sum(1 for relative in payload if relative.startswith("agents/"))
        self.ui.step(f"Found {skill_count} skills, {agent_count} agents, {len(payload)} managed files")
        files, kernel, settings, mcp, permission = self.plan_all(previous)
        if self.ui.fancy:
            self.ui.box("Installation Summary", self.plan_summary(files, kernel, settings, mcp, permission))
            if self.ui.interactive:
                if not self.ui.confirm("Proceed with installation?", default=True):
                    raise InstallError(f"installation cancelled; nothing under {self.pi_dir} was changed")
                previous, _ = self.validate_destinations()
                files, kernel, settings, mcp, permission = self.plan_all(previous)
        final = {
            "schema": MANIFEST_SCHEMA,
            "target": "pi",
            "agents_md_created": kernel["created"],
            "kernel_sha256": kernel["sha256"],
            "files": dict(sorted(files["recorded"].items())),
            "settings": settings["record"],
            "mcp": {"file": str(self.mcp_path), "servers": mcp["recorded"]},
            "permission_sha256": permission["sha256"],
            "settings_created": bool(previous.get("settings_created")) or settings["created"],
            "mcp_created": bool(previous.get("mcp_created")) or mcp["created"],
            "optional_components": dict(self.selection),
        }
        old_pending = previous.get("pending", {})
        intent = json.loads(json.dumps(previous)) if previous else {"schema": MANIFEST_SCHEMA, "target": "pi"}
        intent.update(
            {
                "agents_md_created": kernel["created"],
                "optional_components": dict(self.selection),
                "settings_created": final["settings_created"],
                "mcp_created": final["mcp_created"],
            }
        )
        intent.setdefault("kernel_sha256", None)
        intent.setdefault("files", {})
        intent.setdefault("mcp", {"file": str(self.mcp_path), "servers": {}})
        intent.setdefault("settings", {"packages": []})
        intent.setdefault("permission_sha256", None)
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
            "packages": merge_unique(old_pending.get("packages", []), settings["record"]["packages"]),
            "permission": merge_unique(
                old_pending.get("permission", []), [permission["sha256"]] if permission["sha256"] else []
            ),
        }
        self.write_manifest(intent)
        for path, data, replace in files["writes"]:
            if not self.dry_run:
                if replace:
                    self.backup(path)
                self.write_bytes(path, data)
            self.counts["written"] += 1
        for plan, message in (
            (kernel, f"kernel block {'updated' if kernel['existed'] else 'written'} in {self.agents_md}"),
            (settings, f"package pins merged in {self.settings_path}"),
            (mcp, f"MCP servers merged in {self.mcp_path}"),
            (permission, f"permission config written to {self.permission_path}"),
        ):
            if plan["text"] is None:
                continue
            if not self.dry_run:
                self.backup(plan["target"])
                self.write_bytes(plan["target"], plan["text"].encode())
            self.say(message)
        for path in files["removals"]:
            if not self.dry_run:
                self.remove_file(path)
            self.counts["removed"] += 1
        self.write_manifest(final)

    def uninstall(self) -> None:
        self.preflight()
        manifest = self.read_manifest()
        if not manifest:
            self.say("nothing to uninstall: no b-agentic Pi manifest found")
            return
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
        plans = (
            (self.plan_kernel_removal(manifest), f"kernel block removed from {self.agents_md}"),
            (self.plan_settings_removal(manifest), f"package pins removed from {self.settings_path}"),
            (self.plan_mcp_removal(manifest), f"MCP servers removed from {self.mcp_path}"),
            (self.plan_permission_removal(manifest), f"permission config removed: {self.permission_path}"),
        )
        for plan, message in plans:
            if plan is None:
                continue
            if not self.dry_run:
                self.backup(plan["target"])
                if plan.get("delete"):
                    self.remove_file(plan["target"])
                else:
                    self.write_bytes(plan["target"], plan["text"].encode())
            self.say(message)
        for path in removals:
            if not self.dry_run:
                self.remove_file(path)
            self.counts["removed"] += 1
        if not self.dry_run:
            guard_destination(self.manifest_path, PI_PROTECTED)
            self.manifest_path.unlink(missing_ok=True)
            for folder in ("bin", "hooks", "references"):
                directory = self.assets_dir / folder
                if directory.is_dir() and not any(directory.iterdir()):
                    guard_destination(directory, PI_PROTECTED)
                    directory.rmdir()
            if self.assets_dir.is_dir() and not any(self.assets_dir.iterdir()):
                guard_destination(self.assets_dir, PI_PROTECTED)
                self.assets_dir.rmdir()
            elif (self.assets_dir / "backups").is_dir():
                self.say(f"backups kept in {self.assets_dir / 'backups'}")

    def plan_kernel_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        owners = self.kernel_owners(manifest)
        if not owners:
            return None
        target = self.config_target(self.agents_md)
        if not target.exists():
            return None
        text = target.read_text()
        span = find_block(text, str(self.agents_md))
        if span is None:
            return None
        if sha256(text[span[0] : span[1]].encode()) not in owners:
            self.warn(f"kept the modified kernel block in {self.agents_md}")
            return None
        remaining = (text[: span[0]].rstrip("\n") + "\n\n" + text[span[1] :].lstrip("\n")).strip("\n")
        if manifest.get("agents_md_created") and not remaining:
            return {"target": target, "delete": True}
        return {"target": target, "text": remaining + "\n" if remaining else ""}

    def plan_settings_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        target = self.config_target(self.settings_path)
        pins = self.recorded_packages(manifest)
        if not target.exists() or not pins:
            return None
        settings = read_json(target)
        validate_settings_shape(settings, str(self.settings_path))
        packages = settings.get("packages", [])
        kept = [entry for entry in packages if entry not in pins]
        if kept == packages:
            return None
        if kept:
            settings["packages"] = kept
        else:
            del settings["packages"]
        if settings == {} and manifest.get("settings_created"):
            return {"target": target, "delete": True}
        return {"target": target, "text": json_text(settings)}

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
        if config == {} and manifest.get("mcp_created"):
            return {"target": target, "delete": True}
        return {"target": target, "text": json_text(config)}

    def plan_permission_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        owners = self.permission_owners(manifest)
        if not owners:
            return None  # the config was never ours
        target = self.config_target(self.permission_path)
        if not target.exists():
            return None
        if sha256(target.read_bytes()) in owners:
            return {"target": target, "delete": True}
        self.warn(f"kept {self.permission_path} (modified since install)")
        return None

    def next_steps(self) -> list[str]:
        missing = [tool for tool in PREREQUISITES if shutil.which(tool) is None]
        lines = [
            "Next steps:",
            "  1. Start Pi (online) so it installs the pinned packages from settings.json: pi-subagents, "
            "pi-permission-system, and rpiv-ask-user-question. The installer never runs pi install or npm.",
            "  2. Run /login in Pi, or set a provider API key, then try /b-plan.",
            "  3. npm may report the tree-sitter-bash install script as not yet approved; if Pi's bash rules do not "
            "load, run `npm approve-scripts` in the agent directory's npm folder.",
            "  The review gate on Pi is the read-only b-reviewer subagent; no Codex plugin is used.",
        ]
        if self.components:
            lines.append(
                "  Optional components ("
                + optional_components.summary(self.components, self.selection)
                + "): re-run with --with=<id> or --without=<id>, or use the checkbox, to change them."
            )
        if missing:
            lines.append(
                f"  Tools not found on PATH (install them to enable the affected workflows): {', '.join(missing)}"
            )
        return lines

    def report_fancy(self, operation: str) -> None:
        verb = "Uninstalled" if operation == "uninstall" else "Installed"
        summary = ", ".join(f"{count} {name}" for name, count in self.counts.items() if count)
        label = "[dry-run] " if self.dry_run else ""
        ok = self.ui.glyph["ok"]
        self.ui.step(f"{label}{'Uninstall' if operation == 'uninstall' else 'Installation'} complete", done=True)
        lines = [f"{self.ui.style(ok, 'green')} {self.display(self.pi_dir)}", f"  {summary or 'no changes'}"]
        lines += [f"  {self.display_text(message)}" for message in self.messages]
        self.ui.box(f"{label}{verb}", lines, tone="green")
        if self.warnings:
            self.ui.box(
                "Warnings", [f"{self.ui.style('!', 'yellow')} {warning}" for warning in self.warnings], tone="yellow"
            )
        if operation != "uninstall" and not self.dry_run:
            self.ui.box("Next steps", [line[2:] if line.startswith("  ") else line for line in self.next_steps()[1:]])
        self.ui.emit()

    def report(self, operation: str) -> None:
        if self.ui.fancy:
            self.report_fancy(operation)
            return
        for message in self.messages:
            print(message)
        for warning in self.warnings:
            print(f"warning: {warning}", file=sys.stderr)
        summary = ", ".join(f"{count} {name}" for name, count in self.counts.items() if count)
        label = "[dry-run] " if self.dry_run else ""
        print(f"{label}b-agentic {operation} for Pi ({self.pi_dir}): {summary or 'no changes'}")
        if operation != "uninstall" and not self.dry_run:
            print("\n".join(self.next_steps()))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uninstall", action="store_true", help="remove what the manifest recorded")
    parser.add_argument("--dry-run", action="store_true", help="print the plan and change nothing")
    parser.add_argument("--force", action="store_true", help="replace modified or unmanaged files after a backup")
    parser.add_argument("-y", "--yes", action="store_true", help="skip interactive questions and use defaults")
    parser.add_argument("--source", default=str(ROOT), help="b-agentic source checkout (default: this repository)")
    add_optional_arguments(parser)
    args = parser.parse_args(argv)
    try:
        if args.uninstall and (args.with_ids or args.without_ids):
            raise InstallError("--with and --without cannot be combined with --uninstall")
        source = Path(args.source).resolve()
        if not (source / "skills" / "registry.yaml").is_file() or not (source / "pi" / "kernel.md").is_file():
            raise InstallError(f"{source} is not a b-agentic source checkout with a pi/ tree")
        ui = Ui(enabled=not (args.yes or args.dry_run or args.uninstall))
        ui.header()
        installer = PiInstaller(source, args.dry_run, args.force, ui, *parse_optional_arguments(source, args))
        try:
            if args.uninstall:
                installer.uninstall()
                installer.report("uninstall")
            else:
                installer.install()
                installer.report(f"install ({source_revision(source) or 'unversioned source'})")
        finally:
            ui.close()
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
