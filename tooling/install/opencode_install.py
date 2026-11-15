#!/usr/bin/env python3
"""Install, sync, or remove b-agentic's OpenCode assets (ADR-019).

The installer owns only what it records in `~/.config/opencode/b-agentic/install.json`:
copied skills, commands, agents, the safety plugin and its guard core, hooks, and CLIs (by
sha256), the kernel block in AGENTS.md (by sha256), the permission rules it appends to
opencode.json (exact values), the MCP servers it adds under `mcp.servers`, and the
`experimental.todo` flag when it set it. Everything else in those files is user-owned and
preserved, and byte equality with a managed value is never treated as ownership.

It follows the Claude Code installer's safety model: every operation first plans in memory,
validates every user file and destination, and refuses before the first write; it then
records its intent as a `pending` manifest section, applies the plan, and commits. Nothing
is written under ~/.claude, ~/.claude.json, or ~/.pi, it never runs `opencode`, npm, or any
vendor installer, and only the default ~/.config/opencode directory is supported because the
managed plugin, skills, and instructions refer to it.

OpenCode applies the last matching permission rule, so the managed rules are always the
final block of `permissions`. An `opencode.jsonc` file cannot be merged without losing its
comments, so it is refused. A schema-1 manifest from an earlier b-agentic OpenCode install is
adopted and upgraded in place: the rules, servers, and files it recorded are retired exactly
when still unmodified. A manifest from the first OpenCode runtime (no `schema`) is refused.
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

# What an OpenCode install never touches: Claude Code's and Pi's directories and configuration.
PROTECTED = (
    (".claude", "the Claude Code directory"),
    (".claude.json", "the Claude Code configuration"),
    (".pi", "the Pi runtime directory"),
)

ROOT = Path(__file__).resolve().parents[2]
MANIFEST_SCHEMA = 1
MANAGED_ROOTS = ("skills", "commands", "agents", "plugins", "b-agentic")
PREREQUISITES = ("node", "git", "rg", "rtk", "codegraph", "bunx", "opencode")
NOT_PORTED_SCRIPTS = frozenset({"b-statusline.mjs"})
REFERENCES = ("capabilities.yaml", "mcp_operations.yaml", "artifacts.yaml")
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


def rule_key(rule: dict[str, Any]) -> str:
    return json.dumps(rule, sort_keys=True)


def remove_last(rules: list[Any], rule: Any) -> None:
    for index in range(len(rules) - 1, -1, -1):
        if rules[index] == rule:
            del rules[index]
            return


class Installer:
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
        self.opencode_dir = resolve_opencode_dir()
        self.assets_dir = self.opencode_dir / "b-agentic"
        self.manifest_path = self.assets_dir / "install.json"
        self.config_path = self.opencode_dir / "opencode.json"
        self.kernel_path = self.opencode_dir / "AGENTS.md"
        self.dry_run = dry_run
        self.force = force
        self.stamp = f"{time.strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:6]}"
        self.messages: list[str] = []
        self.warnings: list[str] = []
        self.counts = {"written": 0, "unchanged": 0, "kept": 0, "removed": 0}
        self.backed_up: set[Path] = set()
        guard_destination(self.opencode_dir, PROTECTED)

    # -- optional components --------------------------------------------------
    def load_components(self) -> dict[str, dict[str, Any]]:
        try:
            return optional_components.load(self.source)
        except ValueError as exc:
            raise InstallError(str(exc)) from exc

    def select_components(self, manifest: dict[str, Any]) -> None:
        """Fix the optional-component selection before any planning: flags, then a checkbox on a
        terminal when no flag was given, over the recorded (or inferred) state."""
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

    def plan_summary(self, files: dict[str, Any], kernel: dict[str, Any], config: dict[str, Any]) -> list[str]:
        parts = [f"{len(files['writes'])} to write", f"{self.counts['unchanged']} unchanged"]
        if files["removals"]:
            parts.append(f"{len(files['removals'])} to remove")
        if self.counts["kept"]:
            parts.append(f"{self.counts['kept']} kept")
        return [
            "Runtime: OpenCode",
            self.ui.style(self.display(self.opencode_dir), "cyan"),
            f"  files: {', '.join(parts)}",
            f"  kernel: AGENTS.md block {'merge' if kernel['text'] is not None else 'unchanged'}",
            f"  config: opencode.json {'merge' if config['text'] is not None else 'unchanged'}",
            f"  permissions: {len(config['permissions'])} managed rules (last block)",
            f"  MCP: {len(config['mcp'])} managed servers",
            f"  todo: experimental.todo {'set' if config['todo_set'] else 'left as you configured it'}",
            f"  optional: {optional_components.summary(self.components, self.selection)}",
        ]

    def show_warnings(self) -> None:
        if self.warnings:
            self.ui.box("Warnings", [self.display_text(warning) for warning in self.warnings], tone="yellow")

    # -- destinations -----------------------------------------------------------
    def managed_path(self, relative: str) -> Path:
        path = self.opencode_dir / safe_relative(relative)
        check_directory_chain(path.parent, self.opencode_dir, PROTECTED)
        if path.is_dir() and not path.is_symlink():
            raise InstallError(f"{path} is a directory; expected a file")
        guard_destination(path, PROTECTED)
        return path

    def config_target(self, path: Path) -> Path:
        """A user-owned config file; a symlinked file is written through, never replaced."""
        target = Path(os.path.realpath(path)) if path.is_symlink() else path
        guard_destination(target, PROTECTED)
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
        check_directory_chain(self.assets_dir, self.opencode_dir, PROTECTED)
        manifest = self.manifest_path
        if manifest.is_symlink() or (manifest.exists() and not manifest.is_file()):
            raise InstallError(f"{manifest} must be a regular file")
        guard_destination(manifest, PROTECTED)
        check_directory_chain(self.assets_dir / "backups", self.opencode_dir, PROTECTED)
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
        guard_destination(path, PROTECTED)
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
        guard_destination(target, PROTECTED)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)

    def remove_file(self, path: Path) -> None:
        guard_destination(path, PROTECTED)
        path.unlink(missing_ok=True)
        directory = path.parent
        while directory != self.opencode_dir and directory.is_dir() and not any(directory.iterdir()):
            guard_destination(directory, PROTECTED)
            directory.rmdir()
            directory = directory.parent

    # -- payload ------------------------------------------------------------------
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
                    (self.source / "opencode" / "skills" / name / "SKILL.md").read_bytes().decode(),
                    excluded,
                    optional_components.optional_skills(self.components),
                )
            except ValueError as exc:
                raise InstallError(f"opencode/skills/{name}/SKILL.md: {exc}") from exc
            files[f"skills/{name}/SKILL.md"] = body.encode()
            files[f"commands/{name}.md"] = (self.source / "opencode" / "commands" / f"{name}.md").read_bytes()
        for path in sorted((self.source / "opencode" / "agents").glob("b-*.md")):
            files[f"agents/{path.name}"] = path.read_bytes()
        files["plugins/b-agentic.js"] = (self.source / "opencode" / "plugins" / "b-agentic.js").read_bytes()
        files["b-agentic/guard.mjs"] = (self.source / "opencode" / "guard.mjs").read_bytes()
        # The hooks and CLIs are runtime-neutral scripts shared with the Claude Code install; the Codex review
        # wrapper and its guard travel with them, and they keep their approval store beside the installed hooks.
        for folder in ("bin", "hooks"):
            for path in sorted((self.source / "claude" / folder).glob("*.mjs")):
                if path.name not in NOT_PORTED_SCRIPTS:
                    files[f"b-agentic/{folder}/{path.name}"] = path.read_bytes()
        files["b-agentic/bin/b_run.py"] = (self.source / "claude" / "bin" / "b_run.py").read_bytes()
        for name in REFERENCES:
            files[f"b-agentic/references/{name}"] = (self.source / "references" / name).read_bytes()
        return files

    def kernel_block(self) -> str:
        kernel = (self.source / "opencode" / "kernel.md").read_text().strip("\n")
        try:
            kernel = optional_components.filter_kernel(kernel, self.excluded_skills())
        except ValueError as exc:
            raise InstallError(str(exc)) from exc
        return f"{KERNEL_BLOCK_START}\n{kernel}\n{KERNEL_BLOCK_END}"

    def template(self) -> dict[str, Any]:
        return json.loads((self.source / "opencode" / "configs" / "opencode.template.json").read_text())

    # -- manifest -----------------------------------------------------------------
    def read_manifest(self) -> dict[str, Any]:
        manifest = read_json(self.manifest_path)
        if manifest and "schema" not in manifest and manifest.get("suite") == "b-agentic":
            raise InstallError(
                f"{self.manifest_path} belongs to the first OpenCode install (before ADR-019); remove its skills, "
                "agents, commands, kernel, and the b-agentic folder by hand, then retry"
            )
        if manifest and manifest.get("schema") != MANIFEST_SCHEMA:
            raise InstallError(f"{self.manifest_path} has an unsupported schema; uninstall with the matching version")
        if manifest and manifest.get("target") != "opencode":
            raise InstallError(f"{self.manifest_path} was not written by the OpenCode installer")
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
    def strip_owned_rules(rules: list[Any], manifest: dict[str, Any]) -> tuple[bool, dict[str, int]]:
        """Remove the rules this installer applied; return whether any was removed and what is left of each.

        Committed rules and a legacy list-form pending group were applied. A pending group written by this
        version is only an intent: it records how many identical rules the file held before the write, so a
        run interrupted before the write never removes a rule the user already had. A removal is also not
        repeatable by value: the manifest keeps the count each owned rule must be left at (`strip`), written
        before the config, so a retry after the config was already rewritten removes nothing more.
        """
        groups = manifest.get("pending", {}).get("permissions", [])
        strip = manifest.get("strip", {})
        before = len(rules)
        applied = merge_unique(manifest.get("permissions", []), *[group for group in groups if isinstance(group, list)])
        for rule in reversed(applied):
            key = rule_key(rule)
            if key in strip:
                while rules.count(rule) > strip[key]:
                    remove_last(rules, rule)
            else:
                remove_last(rules, rule)
        for group in groups:
            if not isinstance(group, dict):
                continue
            baseline = group.get("baseline", {})
            for rule in reversed(group.get("rules", [])):
                if rules.count(rule) > baseline.get(rule_key(rule), 0):
                    remove_last(rules, rule)
        return len(rules) != before, {rule_key(rule): rules.count(rule) for rule in applied}

    # -- planning -----------------------------------------------------------------------
    def plan_all(self, previous: dict[str, Any]) -> tuple[dict[str, Any], ...]:
        self.counts = {name: 0 for name in self.counts}
        self.warnings.clear()
        return (
            self.plan_files(previous),
            self.plan_kernel(previous),
            self.plan_config(previous),
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

    def plan_config(self, manifest: dict[str, Any]) -> dict[str, Any]:
        """opencode.json: the managed permission block goes last, and missing MCP servers are added."""
        target = self.config_target(self.config_path)
        config = read_json(target)
        label = str(self.config_path)
        validate_permissions_shape(config, label)
        validate_mcp_shape(config, label)
        template = self.template()
        excluded = self.excluded_servers()
        wanted = optional_components.filter_opencode_rules(template["permissions"], excluded)
        rules = list(config.get("permissions", []))
        _, strip = self.strip_owned_rules(rules, manifest)
        baseline = {rule_key(rule): rules.count(rule) for rule in wanted}
        rules.extend(dict(rule) for rule in wanted)
        config["permissions"] = rules
        todo_set = False
        experimental = config.get("experimental")
        if experimental is not None and not isinstance(experimental, dict):
            raise InstallError(f"{label}: experimental must be an object")
        if experimental is None or "todo" not in experimental:
            config.setdefault("experimental", {})["todo"] = True
            todo_set = True
        elif experimental["todo"] is True and manifest.get("todo_set"):
            todo_set = True
        servers = config.setdefault("mcp", {}).setdefault("servers", {})
        desired = {name: entry for name, entry in template["mcp"]["servers"].items() if name not in excluded}
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
        text = json_text(config)
        return {
            "target": target,
            "text": text if not target.exists() or target.read_text() != text else None,
            "permissions": [dict(rule) for rule in wanted],
            "baseline": baseline,
            "strip": strip,
            "mcp": recorded,
            "todo_set": todo_set,
        }

    # -- operations ---------------------------------------------------------------------
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
        raw = self.read_manifest()
        for note in os.environ.get("B_AGENTIC_NOTES", "").splitlines():
            if note:
                if self.ui.fancy:
                    self.ui.step(self.display_text(note))
                else:
                    print(note)
        self.ui.step("Runtime: OpenCode", self.display(self.opencode_dir))
        self.ui.step(f"Source: {self.display(self.source)}")
        self.select_components(raw)
        previous, payload = self.validate_destinations()
        skill_count = len({relative.split("/")[1] for relative in payload if relative.startswith("skills/")})
        agent_count = sum(1 for relative in payload if relative.startswith("agents/"))
        self.ui.step(f"Found {skill_count} skills, {agent_count} agents, {len(payload)} managed files")
        files, kernel, config = self.plan_all(previous)
        if self.ui.fancy:
            self.ui.box("Installation Summary", self.plan_summary(files, kernel, config))
            self.show_warnings()
            if self.ui.interactive:
                if not self.ui.confirm("Proceed with installation?", default=True):
                    raise InstallError(f"installation cancelled; nothing under {self.opencode_dir} was changed")
                # Prompts may stay open for minutes. Revalidate paths and merge fresh user content.
                self.preflight()
                previous, _ = self.validate_destinations()
                files, kernel, config = self.plan_all(previous)
        final = {
            "schema": MANIFEST_SCHEMA,
            "target": "opencode",
            "agents_md_created": kernel["created"],
            "kernel_sha256": kernel["sha256"],
            "files": dict(sorted(files["recorded"].items())),
            "permissions": config["permissions"],
            "mcp": {"file": str(self.config_path), "servers": config["mcp"]},
            "todo_set": config["todo_set"],
            "optional_components": dict(self.selection),
        }
        old_pending = previous.get("pending", {})
        intent = json.loads(json.dumps(previous)) if previous else {"schema": MANIFEST_SCHEMA, "target": "opencode"}
        intent.update({"agents_md_created": kernel["created"], "optional_components": dict(self.selection)})
        # The flag is recorded as ours only once it is written (the final manifest), never as an intent.
        intent["todo_set"] = bool(previous.get("todo_set"))
        intent.setdefault("kernel_sha256", None)
        intent.setdefault("files", {})
        intent["strip"] = config["strip"]
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
            "permissions": [
                *old_pending.get("permissions", []),
                {"rules": config["permissions"], "baseline": config["baseline"]},
            ],
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
            self.say(f"permissions, MCP servers, and todo merged in {self.config_path}; restart OpenCode to load them")
        self.write_manifest(final)

    def uninstall(self) -> None:
        self.preflight()
        manifest = self.read_manifest()
        if not manifest:
            self.say("nothing to uninstall: no b-agentic manifest found")
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
        kernel_plan = self.plan_kernel_removal(manifest)
        config_plan = self.plan_config_removal(manifest)
        if config_plan is not None:
            # Persist what each owned rule must be left at before the config is rewritten, so a retry after an
            # interruption between the config write and the manifest removal cannot remove a rule twice.
            self.write_manifest({**manifest, "strip": config_plan["strip"]})
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
            guard_destination(self.manifest_path, PROTECTED)
            self.manifest_path.unlink(missing_ok=True)
            for folder in ("bin", "hooks", "references"):
                directory = self.assets_dir / folder
                if directory.is_dir() and not any(directory.iterdir()):
                    guard_destination(directory, PROTECTED)
                    directory.rmdir()
            if self.assets_dir.is_dir() and not any(self.assets_dir.iterdir()):
                guard_destination(self.assets_dir, PROTECTED)
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
        rules = config.get("permissions", [])
        changed, strip = self.strip_owned_rules(rules, manifest)
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
        experimental = config.get("experimental")
        if manifest.get("todo_set") and isinstance(experimental, dict) and experimental.get("todo") is True:
            del experimental["todo"]
            if experimental == {}:
                del config["experimental"]
            changed = True
        return {"target": target, "text": json_text(config), "strip": strip} if changed else None

    def next_steps(self) -> list[str]:
        missing = [tool for tool in PREREQUISITES if shutil.which(tool) is None]
        lines = [
            "Next steps:",
            "  1. Restart OpenCode so skills, agents, the safety plugin, permissions, and MCP servers load.",
            "  2. Sign in to a provider in OpenCode, then try /b-plan. MCP OAuth servers (Notion) need `opencode mcp auth <name>`.",
            "  3. The review gate runs Codex through the b-codex-review wrapper (it needs the Codex plugin from a Claude "
            "Code install and a per-repository approval); the read-only b-reviewer subagent is the fallback.",
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

    def report(self, operation: str) -> None:
        if self.ui.fancy:
            summary = ", ".join(f"{count} {name}" for name, count in self.counts.items() if count)
            self.ui.step("Installation complete for OpenCode", done=True)
            self.ui.box(
                "Installed",
                [
                    self.ui.style(self.display(self.opencode_dir), "cyan"),
                    summary or "no changes",
                    *[self.display_text(message) for message in self.messages],
                ],
                tone="green",
            )
            self.show_warnings()
            self.ui.box("Next steps", [line[2:] if line.startswith("  ") else line for line in self.next_steps()[1:]])
            self.ui.emit()
            return
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
    parser.add_argument("-y", "--yes", action="store_true", help="skip interactive questions and use defaults")
    parser.add_argument("--source", default=str(ROOT), help="b-agentic source checkout (default: this repository)")
    add_optional_arguments(parser)
    args = parser.parse_args(argv)
    try:
        if args.uninstall and (args.with_ids or args.without_ids):
            raise InstallError("--with and --without cannot be combined with --uninstall")
        source = Path(args.source).resolve()
        if not (source / "skills" / "registry.yaml").is_file() or not (source / "opencode" / "kernel.md").is_file():
            raise InstallError(f"{source} is not a b-agentic source checkout with OpenCode assets")
        ui = Ui(enabled=not (args.yes or args.dry_run or args.uninstall))
        try:
            ui.header()
            installer = Installer(source, args.dry_run, args.force, ui, *parse_optional_arguments(source, args))
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
