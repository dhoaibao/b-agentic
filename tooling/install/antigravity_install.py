#!/usr/bin/env python3
"""Install, sync, or remove b-agentic's Antigravity CLI (agy) assets.

The installer owns only what it records in `~/.gemini/config/b-agentic/install.json`: copied skills, agents,
the always-on kernel rule, hooks, and CLIs (by sha256), the `b-agentic` group it adds to config/hooks.json
(its exact value), the MCP servers it adds to config/mcp_config.json (exact values), and the permission rules
it adds to antigravity-cli/settings.json (exact values). Everything else in those files is user-owned and
preserved, and byte equality with a managed value is never treated as ownership.

It shares the Claude Code installer's helpers and its plan-first discipline: every operation parses and
validates every user file and destination before the first write, records its intent in the manifest as a
`pending` section beside the last committed ownership, applies the plan, and finally commits. The two
installers share nothing at run time; this one only ever writes under `~/.gemini` and refuses a symlinked
`~/.gemini`, `config`, `antigravity-cli`, or managed directory (docs/decisions/ADR-025-antigravity-second-runtime.md).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any

import optional_components
from claude_install import (
    BUN_FLAGS,
    CLAUDE_INSTALL_PROTECTED,
    SKILL_NAME,
    InstallError,
    Installer,
    add_optional_arguments,
    check_directory_chain,
    check_disjoint,
    find_bun,
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
MANAGED_ROOTS = ("skills", "agents", "rules", "b-agentic")
HOOK_GROUP = "b-agentic"
# agy's Auto mode needs a terminal sandbox that some hosts lack, so every shell command would ask. The rule
# lives here, not in the generated template, so it can be switched off per install; the template's `ask` and
# `deny` rules still win over it.
SHELL_ALLOW_RULE = "command(*)"
RULE_RELATIVE = "rules/b-agentic.md"
STATUSLINE_SCRIPT = "b-statusline.mjs"
PREREQUISITES = ("bun", "node", "git", "rtk", "codegraph", "bunx", "agy", "codex")
# The installed hook command is `bun <flags> "$HOME/<path>"` in the template; the installer writes absolute paths.
TEMPLATE_HOOK_COMMAND = re.compile(r"^bun " + re.escape(" ".join(BUN_FLAGS)) + r' "\$HOME(/[^"$]+)"$')
# Never touched, on top of the retired runtimes: Claude Code's own files (a different runtime owns them).
AGY_INSTALL_PROTECTED = (
    *CLAUDE_INSTALL_PROTECTED,
    (".claude", "Claude Code's directory"),
    (".claude.json", "Claude Code's MCP configuration"),
)


def safe_relative(relative: str) -> str:
    parts = Path(relative).parts
    if Path(relative).is_absolute() or not parts or ".." in parts or parts[0] not in MANAGED_ROOTS:
        raise InstallError(f"unsafe managed path: {relative!r}")
    return relative


def validate_settings_shape(settings: dict[str, Any], label: str) -> None:
    permissions = settings.get("permissions", {})
    if not isinstance(permissions, dict):
        raise InstallError(f"{label}: permissions must be an object")
    for kind in ("allow", "ask", "deny"):
        if not isinstance(permissions.get(kind, []), list):
            raise InstallError(f"{label}: permissions.{kind} must be an array")


def validate_mcp_shape(config: dict[str, Any], label: str) -> None:
    if not isinstance(config.get("mcpServers", {}), dict):
        raise InstallError(f"{label}: mcpServers must be an object")


def filter_agy_rules(rules: list[str], servers: set[str], kind: str) -> list[str]:
    """Drop only the `allow` rules of excluded servers; `ask` and `deny` rules stay, as on Claude Code."""
    if kind != "allow":
        return list(rules)
    prefixes = tuple(f"mcp({name}/" for name in servers)
    return [rule for rule in rules if not (isinstance(rule, str) and rule.startswith(prefixes))]


class AntigravityInstaller:
    def __init__(
        self,
        source: Path,
        dry_run: bool,
        force: bool,
        ui: Ui | None = None,
        with_ids: list[str] | None = None,
        without_ids: list[str] | None = None,
        shell_auto: bool | None = None,
    ) -> None:
        self.source = source
        self.components = self.load_components()
        self.with_ids = with_ids or []
        self.without_ids = without_ids or []
        self.shell_auto_flag = shell_auto
        self.shell_auto = True
        self.selection: dict[str, bool] = {key: False for key in self.components}
        self.ui = ui if ui is not None else Ui(enabled=False)
        self.home = home_dir()
        self.gemini_dir = self.home / ".gemini"
        self.config_dir = self.gemini_dir / "config"
        self.assets_dir = self.config_dir / "b-agentic"
        self.manifest_path = self.assets_dir / "install.json"
        self.hooks_path = self.config_dir / "hooks.json"
        self.mcp_path = self.config_dir / "mcp_config.json"
        self.settings_path = self.gemini_dir / "antigravity-cli" / "settings.json"
        self.dry_run = dry_run
        self.force = force
        self.stamp = f"{time.strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:6]}"
        self.messages: list[str] = []
        self.warnings: list[str] = []
        self.counts = {"written": 0, "unchanged": 0, "kept": 0, "removed": 0}
        self.backed_up: set[Path] = set()
        self.guard(self.gemini_dir)

    # -- optional components --------------------------------------------------
    def load_components(self) -> dict[str, dict[str, Any]]:
        try:
            return optional_components.load(self.source)
        except ValueError as exc:
            raise InstallError(str(exc)) from exc

    def select_components(self, manifest: dict[str, Any]) -> None:
        """Fix the optional-component selection before planning: flags, then a checkbox on a terminal."""
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

    def select_shell_auto(self, manifest: dict[str, Any]) -> None:
        """An explicit flag, then the boolean the manifest recorded, then on."""
        recorded = manifest.get("shell_auto", True)
        if not isinstance(recorded, bool):
            raise InstallError(f"{self.manifest_path}: shell_auto must be true or false")
        self.shell_auto = recorded if self.shell_auto_flag is None else self.shell_auto_flag

    def excluded_skills(self) -> set[str]:
        return optional_components.excluded_skills(self.components, self.selection)

    def excluded_servers(self) -> set[str]:
        return optional_components.excluded_servers(self.components, self.selection)

    # -- output ---------------------------------------------------------------
    def say(self, text: str) -> None:
        self.messages.append(("[dry-run] " if self.dry_run else "") + text)

    def warn(self, text: str) -> None:
        self.warnings.append(text)

    def display(self, path: Path | str) -> str:
        text = str(path)
        home = str(self.home)
        return "~" + text[len(home) :] if text == home or text.startswith(home + os.sep) else text

    def display_text(self, text: str) -> str:
        return text.replace(str(self.home), "~")

    def plan_summary(
        self, files: dict[str, Any], hooks: dict[str, Any], settings: dict[str, Any], mcp: dict[str, Any]
    ) -> list[str]:
        def verb(text: Any, changed: str) -> str:
            return changed if text is not None else "unchanged"

        file_parts = [f"{len(files['writes'])} to write", f"{self.counts['unchanged']} unchanged"]
        if files["removals"]:
            file_parts.append(f"{len(files['removals'])} to remove")
        if self.counts["kept"]:
            file_parts.append(f"{self.counts['kept']} kept")
        return [
            self.ui.style(self.display(self.gemini_dir), "cyan"),
            f"  {self.ui.style('files', 'green')}: {', '.join(file_parts)}",
            f"  {self.ui.style('hooks', 'green')}: {self.display(self.hooks_path)} {verb(hooks['text'], 'merged')}",
            f"  {self.ui.style('settings', 'green')}: {self.display(self.settings_path)} {verb(settings['text'], 'merged')}",
            f"  {self.ui.style('mcp', 'green')}: {self.display(self.mcp_path)} {verb(mcp['text'], 'merged')}",
            f"  {self.ui.style('optional', 'green')}: {optional_components.summary(self.components, self.selection)}",
            f"  {self.ui.style('shell', 'green')}: {SHELL_ALLOW_RULE} allow {'on' if self.shell_auto else 'off'}",
        ]

    # -- destinations -------------------------------------------------------------
    def guard(self, path: Path) -> None:
        """Refuse the other runtimes' files and anything that resolves outside ~/.gemini."""
        guard_destination(path, AGY_INSTALL_PROTECTED)
        real_gemini = Path(os.path.realpath(self.gemini_dir))
        resolved = Path(os.path.realpath(path))
        if resolved != real_gemini and real_gemini not in resolved.parents:
            raise InstallError(f"refusing to write outside {self.gemini_dir}: {path}")

    def chain(self, path: Path) -> None:
        """Every existing component from the home directory down to `path` must be a real directory."""
        check_directory_chain(path, self.home, AGY_INSTALL_PROTECTED)
        self.guard(path)

    def managed_path(self, relative: str) -> Path:
        """A payload destination: only real directories may sit between the home directory and the file."""
        path = self.config_dir / safe_relative(relative)
        self.chain(path.parent)
        if path.is_dir() and not path.is_symlink():
            raise InstallError(f"{path} is a directory; expected a file")
        self.guard(path)
        return path

    def config_target(self, path: Path) -> Path:
        """A user-owned config file; a symlinked file is written through only while it stays under ~/.gemini."""
        self.chain(path.parent)
        target = Path(os.path.realpath(path)) if path.is_symlink() else path
        self.guard(target)
        if target.exists() and not target.is_file():
            raise InstallError(f"{target} exists but is not a regular file")
        for ancestor in target.parents:
            if ancestor.exists():
                if not ancestor.is_dir():
                    raise InstallError(f"{ancestor} exists but is not a directory (needed for {target})")
                break
        return target

    def check_aliases(self, relatives: list[str]) -> None:
        """Config files, the manifest, and every payload destination must be pairwise distinct."""
        destinations: list[tuple[str, Path]] = [
            ("hooks.json", self.config_target(self.hooks_path)),
            ("mcp_config.json", self.config_target(self.mcp_path)),
            ("settings.json", self.config_target(self.settings_path)),
            ("the install manifest", self.manifest_path),
        ]
        for relative in relatives:
            path = self.config_dir / safe_relative(relative)
            if not path.is_symlink():  # a user-owned symlinked payload file is left alone
                destinations.append((relative, path))
        check_disjoint(destinations)

    def preflight(self) -> None:
        """Validate every directory the run may create or write into, before the first write."""
        if self.gemini_dir.exists() and not self.gemini_dir.is_dir():
            raise InstallError(f"{self.gemini_dir} exists but is not a directory")
        self.chain(self.assets_dir)
        manifest = self.manifest_path
        if manifest.is_symlink() or (manifest.exists() and not manifest.is_file()):
            raise InstallError(f"{manifest} must be a regular file")
        self.guard(manifest)
        self.chain(self.assets_dir / "backups")
        for path in (self.hooks_path, self.mcp_path, self.settings_path):
            self.config_target(path)
        self.check_aliases([])

    # -- writes (only called after planning) ----------------------------------------
    def write_bytes(self, path: Path, data: bytes) -> None:
        self.guard(path)
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
        self.guard(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)

    def remove_file(self, path: Path) -> None:
        self.guard(path)
        path.unlink(missing_ok=True)
        directory = path.parent
        while directory != self.config_dir and directory.is_dir() and not any(directory.iterdir()):
            self.guard(directory)
            directory.rmdir()
            directory = directory.parent

    # -- payload --------------------------------------------------------------
    def payload(self) -> dict[str, bytes]:
        files: dict[str, bytes] = {}
        agy = self.source / "antigravity"
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
                    (agy / "skills" / name / "SKILL.md").read_bytes().decode(),
                    excluded,
                    optional_components.optional_skills(self.components),
                )
            except ValueError as exc:
                raise InstallError(f"antigravity/skills/{name}/SKILL.md: {exc}") from exc
            files[f"skills/{name}/SKILL.md"] = body.encode()
        for path in sorted((agy / "agents").glob("b-*.md")):
            files[f"agents/{path.name}"] = path.read_bytes()
        files[RULE_RELATIVE] = self.rule_text().encode()
        for pattern in ("*.mjs", "*.py"):
            for path in sorted((self.source / "claude" / "bin").glob(pattern)):
                if path.name != STATUSLINE_SCRIPT:
                    files[f"b-agentic/bin/{path.name}"] = path.read_bytes()
        for path in sorted((self.source / "claude" / "hooks").glob("*.mjs")):
            files[f"b-agentic/hooks/{path.name}"] = path.read_bytes()
        files["b-agentic/hooks/b-agy-hook.mjs"] = (agy / "hooks" / "b-agy-hook.mjs").read_bytes()
        for name in ("capabilities.yaml", "mcp_operations.yaml", "artifacts.yaml"):
            files[f"b-agentic/references/{name}"] = (self.source / "references" / name).read_bytes()
        return files

    def rule_text(self) -> str:
        text = (self.source / "antigravity" / "rules" / "b-agentic.md").read_text()
        try:
            return optional_components.filter_kernel(text, self.excluded_skills())
        except ValueError as exc:
            raise InstallError(f"antigravity/rules/b-agentic.md: {exc}") from exc

    def hook_group(self, bun: str) -> dict[str, Any]:
        """The template's hook group with an absolute Bun and an absolute home path in every command.

        Whether agy expands `$HOME` or parses quotes in a hook command is unverified (ADR-025), and a broken
        guard hook blocks every tool, so the installed command uses neither: it is refused when a path would
        need shell quoting."""
        group = json.loads((self.source / "antigravity" / "configs" / "hooks.template.json").read_text())[HOOK_GROUP]
        for entries in group.values():
            for entry in entries:
                for hook in entry.get("hooks", [entry]):
                    match = TEMPLATE_HOOK_COMMAND.match(hook["command"])
                    if not match:
                        raise InstallError(f"unexpected hook command in the antigravity template: {hook['command']!r}")
                    script = str(self.home) + match.group(1)
                    for part in (bun, script):
                        if shlex.quote(part) != part:
                            raise InstallError(
                                f"{part} would need shell quoting in the hook command, which is installed unquoted "
                                "because agy's parsing is unverified; use a Bun and a home path without spaces or "
                                "special characters"
                            )
                    hook["command"] = " ".join((bun, *BUN_FLAGS, script))
        return group

    # -- manifest -------------------------------------------------------------
    def read_manifest(self) -> dict[str, Any]:
        manifest = read_json(self.manifest_path)
        if manifest and (manifest.get("schema") != MANIFEST_SCHEMA or manifest.get("target") != "antigravity"):
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

    @staticmethod
    def hook_candidates(manifest: dict[str, Any]) -> list[Any]:
        committed = manifest.get("hooks", {}).get("value")
        pending = manifest.get("pending", {}).get("hooks", [])
        return [value for value in [committed, *pending] if value is not None]

    @staticmethod
    def created(manifest: dict[str, Any], key: str, existed: bool) -> bool:
        return bool(manifest.get("created", {}).get(key, False)) or not existed

    # -- planning -----------------------------------------------------------------
    def plan_all(self, previous: dict[str, Any]) -> tuple[dict[str, Any], ...]:
        self.counts = {name: 0 for name in self.counts}
        self.warnings.clear()
        files = self.plan_files(previous)
        hooks = self.plan_hooks(previous)
        settings = self.plan_settings(previous.get("settings", {}), previous)
        mcp = self.plan_mcp(previous)
        # A retired script that hooks.json still names (an edited or unrecorded group) stays, still owned,
        # so a hook never points at a script this run deleted; a later run removes it once that group is gone.
        hooks_dir = self.assets_dir / "hooks"
        removals: list[Path] = []
        for path in files["removals"]:
            if path.parent == hooks_dir and path.name in hooks["named_scripts"]:
                relative = path.relative_to(self.config_dir).as_posix()
                files["recorded"][relative] = sha256(path.read_bytes())
                self.warn(f"kept {path}: hooks.json still runs it; remove that hook group and re-run to delete it")
            else:
                removals.append(path)
        files["removals"] = removals
        return files, hooks, settings, mcp

    def plan_files(self, manifest: dict[str, Any]) -> dict[str, Any]:
        recorded: dict[str, str] = {}
        writes: list[tuple[Path, bytes, bool]] = []
        removals: list[Path] = []
        committed = manifest.get("files", {})
        desired = self.payload()
        for relative, data in desired.items():
            path = self.managed_path(relative)
            digest = sha256(data)
            owners = Installer.file_owners(manifest, relative)
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
            if sha256(path.read_bytes()) in Installer.file_owners(manifest, relative):
                removals.append(path)
            else:
                self.warn(f"kept retired file {path} (modified since install)")
                if relative in committed:
                    recorded[relative] = committed[relative]
        return {"recorded": recorded, "writes": writes, "removals": removals}

    def plan_hooks(self, manifest: dict[str, Any]) -> dict[str, Any]:
        target = self.config_target(self.hooks_path)
        existed = target.exists()
        config = read_json(target)
        original = json.loads(json.dumps(config))
        # Resolved here, not in the constructor, so an uninstall never needs Bun.
        wanted = self.hook_group(find_bun())
        existing = config.get(HOOK_GROUP)
        candidates = self.hook_candidates(manifest)
        owned: Any = None
        if existing is None:
            config[HOOK_GROUP] = wanted
            owned = wanted
        elif existing == wanted:
            owned = wanted if candidates else None  # identical content is ours only if a run recorded one
        elif existing in candidates:
            config[HOOK_GROUP] = wanted
            owned = wanted
        else:
            self.warn(
                f"kept your existing '{HOOK_GROUP}' hook group in {self.hooks_path} (not installed by b-agentic or "
                "modified since install); remove it and install again to use the managed hooks"
            )
        named = set(re.findall(r"b-agentic/hooks/([\w.-]+\.mjs)", json.dumps(config.get(HOOK_GROUP, {}))))
        return {
            "target": target,
            "text": json_text(config) if config != original or not existed else None,
            "existed": existed,
            "owned": owned,
            "named_scripts": named,
            "created": self.created(manifest, "hooks", existed),
        }

    def plan_settings(self, previous: dict[str, Any], manifest: dict[str, Any]) -> dict[str, Any]:
        target = self.config_target(self.settings_path)
        existed = target.exists()
        settings = read_json(target)
        original = json.loads(json.dumps(settings))
        validate_settings_shape(settings, str(self.settings_path))
        template = json.loads((self.source / "antigravity" / "configs" / "settings.template.json").read_text())
        record: dict[str, Any] = {"permissions": {}}
        permissions = settings.setdefault("permissions", {})
        for kind in ("allow", "ask", "deny"):
            existing = permissions.setdefault(kind, [])
            wanted = filter_agy_rules(template["permissions"][kind], self.excluded_servers(), kind)
            if kind == "allow" and self.shell_auto:
                wanted.append(SHELL_ALLOW_RULE)
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
        if not self.shell_auto and SHELL_ALLOW_RULE in permissions["allow"]:
            message = f"kept your own {SHELL_ALLOW_RULE} allow rule in {self.settings_path}; --no-shell-auto does not remove it"
            if message not in self.warnings:
                self.warn(message)
        return {
            "target": target,
            "text": json_text(settings) if settings != original or not existed else None,
            "record": record,
            "existed": existed,
            "created": self.created(manifest, "settings", existed),
        }

    def plan_mcp(self, manifest: dict[str, Any]) -> dict[str, Any]:
        target = self.config_target(self.mcp_path)
        existed = target.exists()
        config = read_json(target)
        original = json.loads(json.dumps(config))
        validate_mcp_shape(config, str(self.mcp_path))
        servers = config.setdefault("mcpServers", {})
        excluded = self.excluded_servers()
        template = json.loads((self.source / "antigravity" / "configs" / "mcp.template.json").read_text())
        desired = {name: entry for name, entry in template["mcpServers"].items() if name not in excluded}
        recorded: dict[str, Any] = {}
        for name, entry in desired.items():
            candidates = Installer.mcp_candidates(manifest, name)
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
        for name in Installer.mcp_names(manifest):
            if name in recorded or name not in servers:
                continue
            if servers[name] in Installer.mcp_candidates(manifest, name):
                del servers[name]
            elif name in excluded:
                self.warn(f"kept your edited MCP server '{name}' although its optional component is not selected")
        if servers == {} and "mcpServers" not in original:
            del config["mcpServers"]
        return {
            "target": target,
            "text": json_text(config) if config != original or not existed else None,
            "recorded": recorded,
            "existed": existed,
            "created": self.created(manifest, "mcp", existed),
        }

    # -- operations -----------------------------------------------------------
    def validate_destinations(self) -> tuple[dict[str, Any], list[str]]:
        """Preflight the destinations and read the manifest; repeated after a prompt, so a change
        made while it was open (an alias, a symlink) is refused rather than planned around."""
        self.preflight()
        previous = self.read_manifest()
        payload = list(self.payload())
        self.check_aliases(
            merge_unique(
                payload,
                list(previous.get("files", {})),
                list(previous.get("pending", {}).get("files", {})),
            )
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
        self.select_shell_auto(manifest)
        previous, payload = self.validate_destinations()
        skill_count = len({relative.split("/")[1] for relative in payload if relative.startswith("skills/")})
        agent_count = sum(1 for relative in payload if relative.startswith("agents/"))
        self.ui.step(f"Found {skill_count} skills, {agent_count} agents, {len(payload)} managed files")
        # Plan everything first: any structural refusal happens before the first write.
        files, hooks, settings, mcp = self.plan_all(previous)
        if self.ui.fancy:
            self.ui.box("Installation Summary", self.plan_summary(files, hooks, settings, mcp))
            if self.ui.interactive:
                if not self.ui.confirm("Proceed with installation?", default=True):
                    raise InstallError(f"installation cancelled; nothing under {self.gemini_dir} was changed")
                # The prompt may stay open for minutes: plan again from the files as they are now, so
                # edits made meanwhile are merged rather than overwritten by the earlier snapshot.
                previous, _ = self.validate_destinations()
                files, hooks, settings, mcp = self.plan_all(previous)
        final = {
            "schema": MANIFEST_SCHEMA,
            "target": "antigravity",
            "created": {"hooks": hooks["created"], "mcp": mcp["created"], "settings": settings["created"]},
            "files": dict(sorted(files["recorded"].items())),
            "hooks": {"file": str(self.hooks_path), "group": HOOK_GROUP, "value": hooks["owned"]},
            "settings": settings["record"],
            "mcp": {"file": str(self.mcp_path), "servers": mcp["recorded"]},
            "optional_components": dict(self.selection),
            "shell_auto": self.shell_auto,
        }
        if final["hooks"]["value"] is None:
            del final["hooks"]["value"]
        # Intent: keep the last committed ownership and list what this run may write as `pending`,
        # so an interruption leaves a manifest that recognizes both the old and the new state.
        old_pending = previous.get("pending", {})
        intent = json.loads(json.dumps(previous)) if previous else {"schema": MANIFEST_SCHEMA, "target": "antigravity"}
        intent.update(
            {"created": final["created"], "optional_components": dict(self.selection), "shell_auto": self.shell_auto}
        )
        intent.setdefault("files", {})
        intent.setdefault("hooks", {"file": str(self.hooks_path), "group": HOOK_GROUP})
        intent.setdefault("mcp", {"file": str(self.mcp_path), "servers": {}})
        old_settings = intent.setdefault("settings", {"permissions": {}})
        old_settings["permissions"] = {
            kind: merge_unique(old_settings.get("permissions", {}).get(kind, []), rules)
            for kind, rules in settings["record"]["permissions"].items()
        }
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
            "hooks": merge_unique(old_pending.get("hooks", []), [hooks["owned"]] if hooks["owned"] is not None else []),
            "mcp_servers": pending_servers,
        }
        self.write_manifest(intent)
        for path, data, replace in files["writes"]:
            if not self.dry_run:
                if replace:
                    self.backup(path)
                self.write_bytes(path, data)
            self.counts["written"] += 1
        for plan, message in (
            (hooks, f"hook group merged in {self.hooks_path}"),
            (settings, f"permissions merged in {self.settings_path}"),
            (mcp, f"MCP servers merged in {self.mcp_path}"),
        ):
            if plan["text"] is None:
                continue
            if not self.dry_run:
                self.backup(plan["target"])
                self.write_bytes(plan["target"], plan["text"].encode())
            self.say(message)
        # Retired files go last: new scripts exist before hooks.json names them, and hooks.json stops
        # naming a retired script before it is deleted (`plan_all` already kept one that is still named).
        for path in files["removals"]:
            if not self.dry_run:
                self.remove_file(path)
            self.counts["removed"] += 1
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
            if sha256(path.read_bytes()) in Installer.file_owners(manifest, relative):
                removals.append(path)
            else:
                self.warn(f"kept {path} (modified since install)")
        plans = (
            (self.plan_hooks_removal(manifest), f"hook group removed from {self.hooks_path}"),
            (self.plan_settings_removal(manifest), f"permissions removed from {self.settings_path}"),
            (self.plan_mcp_removal(manifest), f"MCP servers removed from {self.mcp_path}"),
        )
        # Decided while planning, so a malformed hooks.json refuses before any write.
        # A `b-agentic` group the user edited, or one the manifest never recorded, stays in hooks.json. A hook
        # that exits non-zero blocks every agy tool, so while that group names the managed scripts the runtime
        # files under b-agentic/ (the adapter imports its siblings) and the manifest that owns them stay.
        keep_runtime = plans[0][0] is None and self.hook_group_names_scripts()
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
        if keep_runtime:
            kept = [path for path in removals if self.assets_dir in path.parents]
            removals = [path for path in removals if path not in kept]
            self.warn(
                f"kept b-agentic/ under {self.config_dir}: the '{HOOK_GROUP}' hook group in {self.hooks_path} "
                "still runs it, and agy blocks every tool when a hook fails; remove that group and run "
                "--uninstall again to finish"
            )
        # Scripts are removed after the recorded hook group stops naming them.
        for path in removals:
            if not self.dry_run:
                self.remove_file(path)
            self.counts["removed"] += 1
        if keep_runtime:
            if not self.dry_run:
                self.write_manifest(self.reduced_manifest(manifest))
        elif not self.dry_run:
            self.guard(self.manifest_path)
            self.manifest_path.unlink(missing_ok=True)
            for folder in ("bin", "hooks", "references"):
                directory = self.assets_dir / folder
                if directory.is_dir() and not any(directory.iterdir()):
                    self.guard(directory)
                    directory.rmdir()
            if self.assets_dir.is_dir() and not any(self.assets_dir.iterdir()):
                self.guard(self.assets_dir)
                self.assets_dir.rmdir()
            elif (self.assets_dir / "backups").is_dir():
                self.say(f"backups kept in {self.assets_dir / 'backups'}")

    def hook_group_names_scripts(self) -> bool:
        """Whether the `b-agentic` group now in hooks.json still runs a script under b-agentic/hooks."""
        target = self.config_target(self.hooks_path)
        if not target.exists():
            return False
        group = read_json(target).get(HOOK_GROUP)
        return group is not None and bool(re.search(r"b-agentic/hooks/[\w.-]+\.mjs", json.dumps(group)))

    @staticmethod
    def reduced_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
        """The manifest after an uninstall that kept b-agentic/: only the runtime files and the hook ownership
        remain, so removing the stale group and uninstalling again finishes the job."""
        keep = {
            relative: digest
            for relative, digest in manifest.get("files", {}).items()
            if relative.startswith("b-agentic/")
        }
        pending = manifest.get("pending", {})
        return {
            "schema": MANIFEST_SCHEMA,
            "target": "antigravity",
            "created": {key: value for key, value in manifest.get("created", {}).items() if key == "hooks"},
            "files": keep,
            "hooks": manifest.get("hooks", {}),
            "settings": {"permissions": {}},
            "mcp": {"file": manifest.get("mcp", {}).get("file", ""), "servers": {}},
            "optional_components": manifest.get("optional_components", {}),
            **({"shell_auto": manifest["shell_auto"]} if "shell_auto" in manifest else {}),
            "pending": {
                "files": {k: v for k, v in pending.get("files", {}).items() if k.startswith("b-agentic/")},
                "hooks": pending.get("hooks", []),
                "mcp_servers": {},
            },
        }

    def removal_plan(self, target: Path, config: dict[str, Any], manifest: dict[str, Any], key: str) -> dict[str, Any]:
        """Delete a file this installer created once nothing is left in it; otherwise write the remainder."""
        if config == {} and manifest.get("created", {}).get(key):
            return {"target": target, "delete": True}
        return {"target": target, "text": json_text(config)}

    def plan_hooks_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        candidates = self.hook_candidates(manifest)
        target = self.config_target(self.hooks_path)
        if not candidates or not target.exists():
            return None
        config = read_json(target)
        if config.get(HOOK_GROUP) is None:
            return None
        if config[HOOK_GROUP] not in candidates:
            self.warn(f"kept the modified '{HOOK_GROUP}' hook group in {self.hooks_path}")
            return None
        del config[HOOK_GROUP]
        return self.removal_plan(target, config, manifest, "hooks")

    def plan_settings_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        target = self.config_target(self.settings_path)
        if not target.exists():
            return None
        settings = read_json(target)
        validate_settings_shape(settings, str(self.settings_path))
        changed = False
        permissions = settings.get("permissions", {})
        for kind, rules in manifest.get("settings", {}).get("permissions", {}).items():
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
        return self.removal_plan(target, settings, manifest, "settings") if changed else None

    def plan_mcp_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        names = Installer.mcp_names(manifest)
        target = self.config_target(self.mcp_path)
        if not target.exists() or not names:
            return None
        config = read_json(target)
        validate_mcp_shape(config, str(self.mcp_path))
        servers = config.get("mcpServers", {})
        removed = [name for name in names if servers.get(name) in Installer.mcp_candidates(manifest, name)]
        for name in removed:
            del servers[name]
        if not removed:
            return None
        if servers == {}:
            del config["mcpServers"]
        return self.removal_plan(target, config, manifest, "mcp")

    def next_steps(self) -> list[str]:
        missing = [tool for tool in PREREQUISITES if shutil.which(tool) is None]
        lines = [
            "Next steps:",
            "  1. Quit agy before the next run and start it again, so skills, agents, rules, hooks, permissions, and MCP",
            "     servers load (agy rewrites settings.json while it runs).",
            "  2. The managed hooks block every tool when they fail: if agy refuses to run tools, roll back with",
            "     ./install.sh --runtime=antigravity --uninstall (an edited 'b-agentic' hook group stays and keeps",
            "     its scripts; remove that group from ~/.gemini/config/hooks.json and uninstall again)",
            "  3. The Codex review gate needs the Claude Code Codex plugin (b-codex-review looks for it under",
            "     ~/.claude/plugins); without it, b-review uses the read-only b-reviewer subagent.",
        ]
        lines.append(
            f"  Shell commands: {SHELL_ALLOW_RULE} allow is "
            + (
                "on, so only the ask and deny rules prompt; re-run with --no-shell-auto to turn it off."
                if self.shell_auto
                else "off."
            )
        )
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
        lines = [f"{self.ui.style(ok, 'green')} {self.display(self.gemini_dir)}", f"  {summary or 'no changes'}"]
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
        print(f"{label}b-agentic {operation} for Antigravity CLI ({self.gemini_dir}): {summary or 'no changes'}")
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
    parser.add_argument(
        "--shell-auto", action="store_true", help=f"add the {SHELL_ALLOW_RULE} shell allow rule (default)"
    )
    parser.add_argument(
        "--no-shell-auto", action="store_true", help=f"remove the {SHELL_ALLOW_RULE} rule this installer added"
    )
    args = parser.parse_args(argv)
    try:
        if args.uninstall and (args.with_ids or args.without_ids):
            raise InstallError("--with and --without cannot be combined with --uninstall")
        if args.shell_auto and args.no_shell_auto:
            raise InstallError("--shell-auto and --no-shell-auto cannot be combined")
        if args.uninstall and (args.shell_auto or args.no_shell_auto):
            raise InstallError("--shell-auto and --no-shell-auto cannot be combined with --uninstall")
        source = Path(args.source).resolve()
        if not (source / "skills" / "registry.yaml").is_file() or not (source / "antigravity" / "agents").is_dir():
            raise InstallError(f"{source} is not a b-agentic source checkout with the antigravity tree")
        ui = Ui(enabled=not (args.yes or args.dry_run or args.uninstall))
        ui.header()
        shell_auto = True if args.shell_auto else False if args.no_shell_auto else None
        installer = AntigravityInstaller(
            source, args.dry_run, args.force, ui, *parse_optional_arguments(source, args), shell_auto=shell_auto
        )
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
