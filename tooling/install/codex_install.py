#!/usr/bin/env python3
"""Install, sync, or remove b-agentic's Codex assets.

The installer owns only what it records in `~/.codex/b-agentic/install.json`: copied skills
(under `~/.agents/skills`), agent roles, rules, hooks, and CLIs (by sha256), the kernel block in
`~/.codex/AGENTS.md` (by sha256), the hook entries it adds to `~/.codex/hooks.json` (exact values),
and the `[mcp_servers.<name>]` tables it adds to `~/.codex/config.toml` (by name and parsed value, so Codex
rewriting or reordering the file never orphans them). Everything else in those
files is user-owned and preserved, and byte equality with a managed value is never ownership.

It reuses the Claude Code installer's planning, ownership, backup, and manifest machinery: every
operation first plans in memory, validates every user file and destination before the first write,
records its intent in the manifest as a `pending` section, applies the plan, and commits. A hook
the user edited, or a `[mcp_servers.<name>]` table the user already defines, is kept and reported.
Sandbox and approval policy stay yours: nothing here writes `sandbox_mode` or `approval_policy`.
Nothing is ever written under ~/.pi or ~/.claude, and only the default ~/.codex directory is
supported because the managed hooks and instructions refer to it.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
import tomllib
import uuid
from pathlib import Path
from typing import Any

import claude_install as base
from claude_install import (
    InstallError,
    Installer,
    check_directory_chain,
    check_disjoint,
    guard_destination,
    home_dir,
    json_text,
    merge_unique,
    read_json,
    remove_hook_items,
    sha256,
    source_revision,
    validate_settings_shape,
)
from claude_install_ui import Ui

ROOT = Path(__file__).resolve().parents[2]
MANIFEST_SCHEMA = 1
SKILLS_PREFIX = ".agents/skills/"
CODEX_PREFIX = ".codex/"
MANAGED_PREFIXES = (SKILLS_PREFIX, ".codex/agents/", ".codex/rules/", ".codex/b-agentic/")
SKILL_NAME = re.compile(r"^b-[a-z0-9-]+$")
SERVER_TABLE = re.compile(r"^\[mcp_servers\.([A-Za-z0-9_-]+|\"[^\"]+\")\]$", re.MULTILINE)
PREREQUISITES = ("node", "git", "rtk", "codegraph", "bunx", "codex")
# Hook scripts shared with the Claude Code runtime and installed beside the Codex adapter.
SHARED_HOOKS = ("b-verify-gate.mjs",)
TABLE_LINE = re.compile(r"^[ \t]*\[")
SERVER_HEADER = re.compile(
    r'^[ \t]*\[[ \t]*mcp_servers[ \t]*\.[ \t]*(?:"([^"]+)"|([A-Za-z0-9_-]+))[ \t]*(?:\.[^\]\n]*)?\][ \t]*(?:#.*)?$'
)


def resolve_codex_dir() -> Path:
    """The default ~/.codex directory; any other CODEX_HOME is refused."""
    default = home_dir() / ".codex"
    value = os.environ.get("CODEX_HOME")
    if value and os.path.realpath(os.path.expanduser(value)) != os.path.realpath(default):
        raise InstallError(
            f"CODEX_HOME={value} is not supported: the managed hooks and instructions refer to {default}. "
            f"Unset it to install into {default}."
        )
    return default


def parse_toml(text: str, label: str) -> dict[str, Any]:
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise InstallError(f"{label} is not valid TOML ({exc}); fix or move it, then retry") from exc


def template_servers(path: Path) -> tuple[dict[str, Any], dict[str, str]]:
    """A generated config template as (parsed value, text chunk) per `[mcp_servers.<name>]` server."""
    text = path.read_text()
    values = parse_toml(text, str(path)).get("mcp_servers", {})
    chunks: dict[str, str] = {}
    matches = list(SERVER_TABLE.finditer(text))
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        chunks[match[1].strip('"')] = text[match.start() : end].strip("\n")
    return values, chunks


def table_end(lines: list[str], start: int, limit: int) -> int:
    """Where a table that starts at `start` and may run to `limit` ends: after its last key line and the blank
    lines that follow it, so a comment or heading after the table belongs to whatever comes next."""
    end = limit
    while end > start + 1 and (not lines[end - 1].strip() or lines[end - 1].lstrip().startswith("#")):
        end -= 1
    while end < limit and not lines[end].strip():
        end += 1
    return end


def server_ranges(lines: list[str]) -> dict[str, list[tuple[int, int]]]:
    """Line ranges of each server's `[mcp_servers.<name>...]` tables: a header to its last key line (plus the
    blank lines after it). A server defined by inline or dotted keys has no range, so it is never edited textually."""
    ranges: dict[str, list[tuple[int, int]]] = {}
    current: tuple[str, int] | None = None
    for index, line in enumerate([*lines, "["]):
        if not TABLE_LINE.match(line):
            continue
        if current is not None:
            ranges.setdefault(current[0], []).append((current[1], table_end(lines, current[1], index)))
        match = SERVER_HEADER.match(line)
        current = (match[1] or match[2], index) if match else None
    return ranges


def remove_servers(text: str, names: list[str]) -> str:
    """The text without the named servers' tables; every other line, comments and headings after a table included, stays."""
    lines = text.split("\n")
    spans = sorted(
        (span for name, found in server_ranges(lines).items() if name in names for span in found), reverse=True
    )
    for start, end in spans:
        del lines[start : min(end, len(lines))]
    result = "\n".join(lines)
    return result + "\n" if text.endswith("\n") and result and not result.endswith("\n") else result


def append_servers(text: str, chunks: list[str]) -> str:
    body = "\n\n".join(chunks)
    return body + "\n" if not text.strip() else text.rstrip("\n") + "\n\n" + body + "\n"


def untouched(document: dict[str, Any], names: set[str]) -> dict[str, Any]:
    """A parsed config without the servers a run may change, for the proof that nothing else moved."""
    rest = {key: value for key, value in document.items() if key != "mcp_servers"}
    rest["mcp_servers"] = {name: value for name, value in document.get("mcp_servers", {}).items() if name not in names}
    return rest


class CodexInstaller(Installer):
    CREATED_KEY = "agents_md_created"
    runtime_label = "Codex"

    def __init__(self, source: Path, dry_run: bool, force: bool, clickup: bool | None, ui: Ui | None = None) -> None:
        # Refuse Claude Code's tree, so a symlink cannot make this install write into it.
        base.FOREIGN_RUNTIME_ROOTS = (".claude",)
        base.FOREIGN_RUNTIME_FILES = (".claude.json",)
        self.source = source
        self.ui = ui if ui is not None else Ui(enabled=False)
        self.home = home_dir()
        self.codex_dir = resolve_codex_dir()
        self.claude_dir = self.codex_dir  # the shared report and removal helpers read this name
        self.skills_dir = self.home / ".agents" / "skills"
        self.assets_dir = self.codex_dir / "b-agentic"
        self.manifest_path = self.assets_dir / "install.json"
        self.kernel_path = self.codex_dir / "AGENTS.md"
        self.config_path = self.codex_dir / "config.toml"
        self.hooks_path = self.codex_dir / "hooks.json"
        self.dry_run = dry_run
        self.force = force
        self.clickup_choice = clickup
        self.stamp = f"{time.strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:6]}"
        self.messages: list[str] = []
        self.warnings: list[str] = []
        self.counts = {"written": 0, "unchanged": 0, "kept": 0, "removed": 0}
        self.backed_up: set[Path] = set()
        for path in (self.codex_dir, self.skills_dir, self.kernel_path, self.config_path, self.hooks_path):
            guard_destination(path)

    # -- destinations -------------------------------------------------------------
    @staticmethod
    def safe(relative: str) -> str:
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts or not any(relative.startswith(p) for p in MANAGED_PREFIXES):
            raise InstallError(f"unsafe managed path: {relative!r}")
        return relative

    def managed_path(self, relative: str) -> Path:
        """A payload destination: only real directories may sit between its root and the file."""
        self.safe(relative)
        if relative.startswith(SKILLS_PREFIX):
            root, path = self.skills_dir, self.skills_dir / relative[len(SKILLS_PREFIX) :]
        else:
            root, path = self.codex_dir, self.codex_dir / relative[len(CODEX_PREFIX) :]
        check_directory_chain(path.parent, root)
        if path.is_dir() and not path.is_symlink():
            raise InstallError(f"{path} is a directory; expected a file")
        guard_destination(path)
        return path

    def check_aliases(self, relatives: list[str]) -> None:
        destinations: list[tuple[str, Path]] = [
            ("AGENTS.md", self.config_target(self.kernel_path)),
            ("hooks.json", self.config_target(self.hooks_path)),
            ("config.toml", self.config_target(self.config_path)),
            ("the install manifest", self.manifest_path),
        ]
        for relative in relatives:
            path = self.managed_path(relative)
            if not path.is_symlink():  # a user-owned symlinked payload file is left alone
                destinations.append((relative, path))
        check_disjoint(destinations)

    def preflight(self) -> None:
        for directory in (self.codex_dir, self.skills_dir):
            if directory.exists() and not directory.is_dir():
                raise InstallError(f"{directory} exists but is not a directory")
        check_directory_chain(self.assets_dir, self.codex_dir)
        manifest = self.manifest_path
        if manifest.is_symlink() or (manifest.exists() and not manifest.is_file()):
            raise InstallError(f"{manifest} must be a regular file")
        guard_destination(manifest)
        check_directory_chain(self.assets_dir / "backups", self.codex_dir)
        for path in (self.kernel_path, self.hooks_path, self.config_path):
            self.config_target(path)
        self.check_aliases([])

    def remove_file(self, path: Path) -> None:
        guard_destination(path)
        path.unlink(missing_ok=True)
        stops = {self.codex_dir, self.skills_dir, self.skills_dir.parent, self.home}
        directory = path.parent
        while directory not in stops and directory.is_dir() and not any(directory.iterdir()):
            guard_destination(directory)
            directory.rmdir()
            directory = directory.parent

    # -- payload and manifest ------------------------------------------------------
    def payload(self) -> dict[str, bytes]:
        files: dict[str, bytes] = {}
        codex = self.source / "codex"
        registry = json.loads((self.source / "skills" / "registry.yaml").read_text())
        for skill in registry["skills"]:
            name = skill["name"]
            if not isinstance(name, str) or not SKILL_NAME.fullmatch(name):
                raise InstallError(f"registry skill name is not a safe b-* name: {name!r}")
            files[f"{SKILLS_PREFIX}{name}/SKILL.md"] = (codex / "skills" / name / "SKILL.md").read_bytes()
        for path in sorted((codex / "agents").glob("b-*.toml")):
            files[f".codex/agents/{path.name}"] = path.read_bytes()
        files[".codex/rules/b-agentic.rules"] = (codex / "rules" / "b-agentic.rules").read_bytes()
        files[".codex/b-agentic/hooks/b-codex-hooks.mjs"] = (codex / "hooks" / "b-codex-hooks.mjs").read_bytes()
        for script in SHARED_HOOKS:
            files[f".codex/b-agentic/hooks/{script}"] = (self.source / "claude" / "hooks" / script).read_bytes()
        files[".codex/b-agentic/bin/b-candidate-snapshot.mjs"] = (
            self.source / "claude" / "bin" / "b-candidate-snapshot.mjs"
        ).read_bytes()
        for name in ("capabilities.yaml", "mcp_operations.yaml", "specialist-tools.json"):
            files[f".codex/b-agentic/references/{name}"] = (codex / "references" / name).read_bytes()
        files[".codex/b-agentic/references/kernel.md"] = (codex / "configs" / "kernel.md").read_bytes()
        return files

    def kernel_block(self) -> str:
        kernel = (self.source / "codex" / "configs" / "kernel.md").read_text().strip("\n")
        return f"{base.KERNEL_BLOCK_START}\n{kernel}\n{base.KERNEL_BLOCK_END}"

    def read_manifest(self) -> dict[str, Any]:
        manifest = read_json(self.manifest_path)
        if manifest and (manifest.get("schema") != MANIFEST_SCHEMA or manifest.get("target") != "codex"):
            raise InstallError(f"{self.manifest_path} has an unsupported schema; uninstall with the matching version")
        for relative in [*manifest.get("files", {}), *manifest.get("pending", {}).get("files", {})]:
            self.safe(relative)
        return manifest

    @staticmethod
    def config_candidates(manifest: dict[str, Any], name: str) -> list[Any]:
        """Every table value a run of this installer recorded for `name`, committed or interrupted."""
        committed = manifest.get("config", {}).get("servers", {}).get(name)
        pending = manifest.get("pending", {}).get("config_servers", {}).get(name, [])
        return [value for value in [committed, *pending] if value is not None]

    @staticmethod
    def config_names(manifest: dict[str, Any]) -> list[str]:
        return merge_unique(
            list(manifest.get("config", {}).get("servers", {})),
            list(manifest.get("pending", {}).get("config_servers", {})),
        )

    # -- planning ---------------------------------------------------------------------
    def plan_hooks(self, recorded: list[Any]) -> dict[str, Any]:
        target = self.config_target(self.hooks_path)
        existed = target.exists()
        data = read_json(target)
        validate_settings_shape(data, str(self.hooks_path))
        template_text = (self.source / "codex" / "configs" / "hooks.template.json").read_text()
        template = json.loads(template_text.replace("$HOME", str(self.home)))
        hooks = data.setdefault("hooks", {})
        record = self.merge_hooks(hooks, template["hooks"], recorded, self.hooks_path)
        for event in [name for name, value in hooks.items() if value == []]:
            del hooks[event]
        if not hooks:
            del data["hooks"]
        text = json_text(data)
        commands = " ".join(
            hook.get("command", "")
            for entries in hooks.values()
            for entry in entries
            if isinstance(entry, dict)
            for hook in entry.get("hooks", [])
            if isinstance(hook, dict)
        )
        return {
            "target": target,
            "text": text if not existed or target.read_text() != text else None,
            "record": record,
            "existed": existed,
            "commands": commands,
        }

    def plan_config(self, clickup: bool, manifest: dict[str, Any]) -> dict[str, Any]:
        """Add, replace, or retire the managed `[mcp_servers.<name>]` tables by name. A server is ours only
        while its parsed value equals one this installer recorded, wherever Codex or the user moved it."""
        target = self.config_target(self.config_path)
        existed = target.exists()
        text = target.read_text() if existed else ""
        document = parse_toml(text, str(self.config_path))
        features = document.get("features", {})
        if isinstance(features, dict) and features.get("hooks") is False:
            self.warn(f"{self.config_path} sets features.hooks = false; the b-agentic hooks will not run")
        current = document.get("mcp_servers", {})
        values, chunks = template_servers(self.source / "codex" / "configs" / "config.template.toml")
        if clickup:
            more_values, more_chunks = template_servers(self.source / "codex" / "configs" / "config.clickup.toml")
            values.update(more_values)
            chunks.update(more_chunks)
        ranges = server_ranges(text.split("\n"))
        recorded: dict[str, Any] = {}
        remove: list[str] = []
        add: list[str] = []
        for name, value in values.items():
            have = current.get(name)
            owned = self.config_candidates(manifest, name)
            if have is None:
                add.append(name)
                recorded[name] = value
            elif have == value:
                # Identical content is not ownership: only a table a previous run recorded is ours.
                if owned:
                    recorded[name] = value
            elif (have in owned or self.force) and name in ranges:
                remove.append(name)
                add.append(name)
                recorded[name] = value
            else:
                reason = "modified since install" if owned else "not installed by b-agentic"
                self.warn(
                    f"kept your MCP server '{name}' in {self.config_path} ({reason}); "
                    "pass --force to replace a managed one after a backup"
                )
                self.counts["kept"] += 1
                if name in manifest.get("config", {}).get("servers", {}):
                    recorded[name] = manifest["config"]["servers"][name]  # still ours once it is reset
        for name in self.config_names(manifest):
            have = current.get(name)
            if name in values or have is None:
                continue
            if have in self.config_candidates(manifest, name) and name in ranges:
                remove.append(name)
            else:
                self.warn(f"kept the retired MCP server '{name}' in {self.config_path} (modified since install)")
                if name in manifest.get("config", {}).get("servers", {}):
                    recorded[name] = manifest["config"]["servers"][name]
        new_text = text
        if remove:
            new_text = remove_servers(new_text, remove)
        if add:
            new_text = append_servers(new_text, [chunks[name] for name in add])
        changed = {*remove, *add}
        if new_text != text:
            after = parse_toml(new_text, f"the merged {self.config_path}")
            if (
                untouched(after, changed) != untouched(document, changed)
                or any(after.get("mcp_servers", {}).get(name) != values[name] for name in add)
                or any(name in after.get("mcp_servers", {}) for name in set(remove) - set(add))
            ):
                raise InstallError(
                    f"refusing to edit {self.config_path}: the change would alter more than the managed MCP servers; "
                    "move the file aside or edit it by hand, then retry"
                )
        return {
            "target": target,
            "text": new_text if new_text != text else None,
            "existed": existed,
            "recorded": recorded,
            "created": bool(manifest.get("config_created", False)) or not existed,
        }

    def plan_all(self, previous: dict[str, Any], clickup: bool) -> tuple[dict[str, Any], ...]:
        self.counts = {name: 0 for name in self.counts}
        self.warnings.clear()
        files = self.plan_files(previous)
        kernel = self.plan_kernel(previous)
        hooks = self.plan_hooks(previous.get("hooks", []))
        config = self.plan_config(clickup, previous)
        # A retired script that hooks.json still names (an edited or unrecorded hook) stays, still
        # owned, so a hook never points at a script this run deleted.
        hooks_dir = self.assets_dir / "hooks"
        removals: list[Path] = []
        for path in files["removals"]:
            if path.parent == hooks_dir and path.name in hooks["commands"]:
                files["recorded"][path.relative_to(self.home).as_posix()] = sha256(path.read_bytes())
                self.warn(f"kept {path}: hooks.json still runs it; remove that hook entry and re-run to delete it")
            else:
                removals.append(path)
        files["removals"] = removals
        return files, kernel, hooks, config

    def plan_summary(
        self,
        files: dict[str, Any],
        kernel: dict[str, Any],
        hooks: dict[str, Any],
        config: dict[str, Any],
        clickup: bool,
    ) -> list[str]:
        def verb(text: Any, changed: str) -> str:
            return changed if text is not None else "unchanged"

        file_parts = [f"{len(files['writes'])} to write", f"{self.counts['unchanged']} unchanged"]
        if files["removals"]:
            file_parts.append(f"{len(files['removals'])} to remove")
        if self.counts["kept"]:
            file_parts.append(f"{self.counts['kept']} kept")
        return [
            self.ui.style(self.display(self.codex_dir), "cyan"),
            f"  {self.ui.style('files', 'green')}: {', '.join(file_parts)} (skills in {self.display(self.skills_dir)})",
            f"  {self.ui.style('kernel', 'green')}: AGENTS.md block "
            f"{verb(kernel['text'], 'updated' if kernel['existed'] else 'written')}",
            f"  {self.ui.style('hooks', 'green')}: hooks.json {verb(hooks['text'], 'merged')}",
            f"  {self.ui.style('mcp', 'green')}: config.toml servers {verb(config['text'], 'merged')}"
            f" (ClickUp {'on' if clickup else 'off'})",
        ]

    # -- operations -----------------------------------------------------------------
    def install(self) -> None:
        previous, payload = self.validate_destinations()
        skill_count = sum(1 for relative in payload if relative.startswith(SKILLS_PREFIX))
        agent_count = sum(1 for relative in payload if relative.startswith(".codex/agents/"))
        for note in (line for line in os.environ.get("B_AGENTIC_NOTES", "").splitlines() if line):
            if self.ui.fancy:
                self.ui.step(self.display_text(note))
            else:
                print(note)
        self.ui.step(f"Source: {self.display(self.source)}")
        self.ui.step(f"Found {skill_count} skills, {agent_count} agents, {len(payload)} managed files")
        if self.clickup_choice is None and "clickup" not in previous and self.ui.interactive:
            self.clickup_choice = self.ui.confirm("Add the optional ClickUp MCP server?", default=False)
        clickup = self.clickup_choice if self.clickup_choice is not None else bool(previous.get("clickup", False))
        files, kernel, hooks, config = self.plan_all(previous, clickup)
        if self.ui.fancy:
            self.ui.box("Installation Summary", self.plan_summary(files, kernel, hooks, config, clickup))
            if self.ui.interactive:
                if not self.ui.confirm("Proceed with installation?", default=True):
                    raise InstallError(f"installation cancelled; nothing under {self.codex_dir} was changed")
                previous, _ = self.validate_destinations()
                files, kernel, hooks, config = self.plan_all(previous, clickup)
        final = {
            "schema": MANIFEST_SCHEMA,
            "target": "codex",
            "clickup": clickup,
            self.CREATED_KEY: kernel["created"],
            "hooks_created": bool(previous.get("hooks_created", False)) or not hooks["existed"],
            "config_created": config["created"],
            "kernel_sha256": kernel["sha256"],
            "files": dict(sorted(files["recorded"].items())),
            "hooks": hooks["record"],
            "config": {"servers": config["recorded"]},
        }
        old_pending = previous.get("pending", {})
        intent = json.loads(json.dumps(previous)) if previous else {"schema": MANIFEST_SCHEMA, "target": "codex"}
        intent.update(
            {
                "clickup": clickup,
                self.CREATED_KEY: kernel["created"],
                "hooks_created": final["hooks_created"],
                "config_created": config["created"],
            }
        )
        intent.setdefault("kernel_sha256", None)
        intent.setdefault("files", {})
        intent.setdefault("config", {"servers": {}})
        intent["hooks"] = merge_unique(intent.get("hooks", []), hooks["record"])
        pending_files = {relative: list(digests) for relative, digests in old_pending.get("files", {}).items()}
        for relative, digest in files["recorded"].items():
            pending_files[relative] = merge_unique(pending_files.get(relative, []), [digest])
        pending_servers = {name: list(values) for name, values in old_pending.get("config_servers", {}).items()}
        for name, value in config["recorded"].items():
            pending_servers[name] = merge_unique(pending_servers.get(name, []), [value])
        intent["pending"] = {
            "files": pending_files,
            "kernel": merge_unique(old_pending.get("kernel", []), [kernel["sha256"]] if kernel["sha256"] else []),
            "config_servers": pending_servers,
        }
        self.write_manifest(intent)
        for path, data, replace in files["writes"]:
            if not self.dry_run:
                if replace:
                    self.backup(path)
                self.write_bytes(path, data)
            self.counts["written"] += 1
        for plan, message in (
            (kernel, f"kernel block {'updated' if kernel['existed'] else 'written'} in {self.kernel_path}"),
            (hooks, f"hooks merged in {self.hooks_path}; review and trust them in Codex with /hooks"),
            (config, f"MCP servers merged in {self.config_path}; restart Codex to load them"),
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
            self.say("nothing to uninstall: no b-agentic manifest found")
            return
        keys = merge_unique(list(manifest.get("files", {})), list(manifest.get("pending", {}).get("files", {})))
        self.check_aliases(keys)
        removals: list[Path] = []
        for relative in keys:
            path = self.managed_path(relative)
            if path.is_symlink() or not path.exists():
                continue
            if sha256(path.read_bytes()) in self.file_owners(manifest, relative):
                removals.append(path)
            else:
                self.warn(f"kept {path} (modified since install)")
        plans = (
            (self.plan_kernel_removal(manifest), f"kernel block removed from {self.kernel_path}"),
            (self.plan_hooks_removal(manifest), f"hook entries removed from {self.hooks_path}"),
            (self.plan_config_removal(manifest), f"MCP servers removed from {self.config_path}"),
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
            guard_destination(self.manifest_path)
            self.manifest_path.unlink(missing_ok=True)
            for folder in ("bin", "hooks", "references", "verify-gate"):
                directory = self.assets_dir / folder
                if directory.is_dir() and not any(directory.iterdir()):
                    guard_destination(directory)
                    directory.rmdir()
            if self.assets_dir.is_dir() and not any(self.assets_dir.iterdir()):
                guard_destination(self.assets_dir)
                self.assets_dir.rmdir()
            elif (self.assets_dir / "backups").is_dir():
                self.say(f"backups kept in {self.assets_dir / 'backups'}")

    def plan_hooks_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        target = self.config_target(self.hooks_path)
        if not target.exists() or not manifest.get("hooks"):
            return None
        data = read_json(target)
        validate_settings_shape(data, str(self.hooks_path))
        hooks = data.get("hooks", {})
        if not remove_hook_items(hooks, manifest["hooks"]):
            return None
        if hooks == {}:
            data.pop("hooks", None)
        if data == {} and manifest.get("hooks_created"):
            return {"target": target, "delete": True}
        return {"target": target, "text": json_text(data)}

    def plan_config_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        names = self.config_names(manifest)
        target = self.config_target(self.config_path)
        if not names or not target.exists():
            return None
        text = target.read_text()
        document = parse_toml(text, str(self.config_path))
        current = document.get("mcp_servers", {})
        ranges = server_ranges(text.split("\n"))
        remove = []
        for name in names:
            have = current.get(name)
            if have is None:
                continue
            if have in self.config_candidates(manifest, name) and name in ranges:
                remove.append(name)
            else:
                self.warn(f"kept the MCP server '{name}' in {self.config_path} (modified since install)")
        if not remove:
            return None
        new_text = remove_servers(text, remove)
        after = parse_toml(new_text, f"the reduced {self.config_path}")
        if untouched(after, set(remove)) != untouched(document, set(remove)) or any(
            name in after.get("mcp_servers", {}) for name in remove
        ):
            raise InstallError(
                f"refusing to edit {self.config_path}: removing the managed MCP servers would alter other tables"
            )
        if manifest.get("config_created") and not new_text.strip():
            return {"target": target, "delete": True}
        return {"target": target, "text": new_text}

    def next_steps(self) -> list[str]:
        missing = [tool for tool in PREREQUISITES if shutil.which(tool) is None]
        lines = [
            "Next steps:",
            "  1. Restart Codex so skills, agents, rules, hooks, and MCP servers load.",
            "  2. Run /hooks in Codex and trust the b-agentic hooks; Codex skips unreviewed hooks and asks again after any change.",
            "  3. Set sandbox_mode and approval_policy in config.toml yourself (workspace-write with on-request prompts for outside-project writes); b-agentic never writes them.",
            "  4. Export the API keys the managed MCP servers read (for example BRAVE_API_KEY, FIRECRAWL_API_KEY, CONTEXT7_API_KEY).",
        ]
        if missing:
            lines.append(
                f"  Tools not found on PATH (install them to enable the affected workflows): {', '.join(missing)}"
            )
        return lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uninstall", action="store_true", help="remove what the manifest recorded")
    parser.add_argument("--dry-run", action="store_true", help="print the plan and change nothing")
    parser.add_argument("--force", action="store_true", help="replace modified or unmanaged files after a backup")
    parser.add_argument("-y", "--yes", action="store_true", help="skip interactive questions and use defaults")
    parser.add_argument("--source", default=str(ROOT), help="b-agentic source checkout (default: this repository)")
    clickup = parser.add_mutually_exclusive_group()
    clickup.add_argument("--with-clickup", action="store_true", help="add the optional ClickUp MCP server")
    clickup.add_argument("--without-clickup", action="store_true", help="drop the optional ClickUp MCP server")
    args = parser.parse_args(argv)
    try:
        source = Path(args.source).resolve()
        if not (source / "skills" / "registry.yaml").is_file() or not (source / "codex" / "agents").is_dir():
            raise InstallError(f"{source} is not a b-agentic Codex source checkout")
        choice = True if args.with_clickup else False if args.without_clickup else None
        if choice is None and os.environ.get("B_AGENTIC_CLICKUP_MCP", "").lower() in {"y", "yes", "true", "1"}:
            choice = True
        ui = Ui(enabled=not (args.yes or args.dry_run or args.uninstall))
        ui.header()
        installer = CodexInstaller(source, args.dry_run, args.force, choice, ui)
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
