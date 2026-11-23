#!/usr/bin/env python3
"""Install, sync, or remove b-agentic's Pi assets (equal main-flow runtime installed via --runtime=pi; ADR-030, ADR-032).

The installer owns only what it records in `~/.pi/agent/b-agentic/install.json`: the skills, prompts, agents,
owned extension, hooks, helper CLIs, wrappers, and references it copies (by sha256), the kernel block in
AGENTS.md (by sha256), the package names and default tools it adds to settings.json, the rules it adds to the
permission-system config, and the MCP servers it adds to mcp.json. Everything else in those files is user-owned and
preserved, and byte equality with a managed value is never treated as ownership.

The Pi tree is rendered at install time by `registry_sync.py --render pi` into a fresh folder outside the checkout
and is never committed. Every operation plans in memory first and refuses on a problem before the first write; it
then records its intent in the manifest as a `pending` section beside the last committed ownership, applies the
plan, and commits, so an interruption leaves a manifest from which a retry or an uninstall still recognizes both
states.

The installer never installs Pi or a package (Pi installs the packages named in settings.json on its next start),
never contacts the network, and runs `pi --version` only, to warn below the floor. Only the default ~/.pi/agent
directory is written; ~/.claude and ~/.claude.json are never touched, and Pi's own bin, install, npm, sessions, and
auth.json stay out of reach because only the managed roots below and six config files are ever written. The classifier's own config file is created
only when it is absent: it is never overwritten, even with --force, because /permission-model keeps its choices there.
"""

from __future__ import annotations

import argparse
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

import claude_install as base
import optional_components
from claude_install import InstallError, find_block, json_text, merge_unique, read_json, sha256
from claude_install_ui import Ui

ROOT = base.ROOT
MANIFEST_SCHEMA = 1
PI_FLOOR = (1, 6, 0)
PI_PACKAGE = "@earendil-works/pi-coding-agent"
MANAGED_ROOTS = ("skills", "prompts", "agents", "extensions", "b-agentic", "themes")
WRAPPERS = ("b-run", "b-snapshot", "b-state")
WRAPPER_MODE = 0o700
STRICTNESS = {"allow": 0, "ask": 1, "deny": 2}
# Files Pi itself reads and writes in the agent directory: never a config target, even through a link.
PI_OWNED_FILES = ("auth.json", "models.json", "models-store.json", "keybindings.json")
# Folders whose files the wrappers, the guard extension, and the hooks execute or read as policy.
EXECUTED_ROOTS = ("b-agentic/bin/", "b-agentic/hooks/", "b-agentic/references/", "extensions/b-agentic/")
# The hook files claude/hooks ships and the owned extension imports (HOOK_FILES in guard.mjs).
HOOK_FILES = (
    "b-path-guard.mjs",
    "b-verify-gate.mjs",
    "b-spec-context.mjs",
    "b-run-context.mjs",
    "b-alexandria-guard.mjs",
)
HELPER_FILE = re.compile(r"^(?:b-state(?:-[a-z]+)?\.mjs|b-candidate-snapshot\.mjs|b-protected\.mjs|b_run\.py)$")
REFERENCES = ("capabilities.yaml", "mcp_operations.yaml", "artifacts.yaml")
CLASSIFIER_PACKAGE = "npm:pi-permission-classifier"
PERMISSION_PACKAGE = "npm:@gotgenes/pi-permission-system"
PERMISSION_CONFIG = "extensions/pi-permission-system/config.json"
# The classifier registers a link only when this file exists, and the permission system consults only the links
# the permission config's `authorizerChain` names; the package enables neither itself.
CLASSIFIER_CONFIG = "extensions/pi-permission-classifier/config.json"
CLASSIFIER_CONFIG_TEXT = "{}\n"
SUBAGENT_CONFIG = "extensions/subagent/config.json"
# Before 20.9.0 the permission system rejects the whole config file for the unknown `authorizerChain` key, and before
# 0.6.0 the classifier registers only its old link name. The installer cannot tell which version Pi will load for a
# pin or a range, so a package entry that carries any version spec keeps the chain and the classifier config out.
CHAIN_PACKAGES = (PERMISSION_PACKAGE, CLASSIFIER_PACKAGE)
MAX_CHAIN = 1000  # the permission system rejects a config array of more entries
TOP = "@top"  # the section name of a top-level permission-config key such as yoloMode
PI_PROTECTED = (
    (".claude", "the Claude Code directory"),
    (".claude.json", "the Claude Code configuration"),
    (".config/opencode", "the retired OpenCode runtime directory"),
)
Triple = tuple[str, "str | None", Any]


def pi_dir() -> Path:
    """The default ~/.pi/agent directory; any other configured directory is refused."""
    default = base.home_dir() / ".pi" / "agent"
    value = os.environ.get("PI_CODING_AGENT_DIR")
    if value and os.path.realpath(os.path.expanduser(value)) != os.path.realpath(default):
        raise InstallError(
            f"PI_CODING_AGENT_DIR={value} is not supported: the managed hooks, wrappers, and instructions refer to "
            f"{default}. Unset it to install into {default}."
        )
    return default


def guard(path: Path) -> None:
    base.guard_destination(path, PI_PROTECTED)


def safe_relative(relative: str) -> str:
    parts = Path(relative).parts
    if Path(relative).is_absolute() or not parts or ".." in parts or parts[0] not in MANAGED_ROOTS:
        raise InstallError(f"unsafe managed path: {relative!r}")
    if parts[0] == "extensions" and (len(parts) < 2 or parts[1] not in ("b-agentic", "pi-permission-system")):
        raise InstallError(f"unsafe managed path: {relative!r}")
    return relative


def package_name(entry: Any) -> str | None:
    """`npm:name` for a packages entry written as `npm:name@1.2.3`, `npm:name`, or an object with a source."""
    source = entry if isinstance(entry, str) else entry.get("source") if isinstance(entry, dict) else None
    if not isinstance(source, str):
        return None
    match = re.fullmatch(r"(npm:(?:@[^/@]+/)?[^/@]+)(?:@.+)?", source)
    return match.group(1) if match else source


def version_spec(entry: Any) -> str | None:
    """The version part of a packages entry written `npm:name@SPEC` (a pin, a range or a tag); None when unpinned.

    The installer does not read npm semver: Pi accepts ranges and keeps whatever version is already installed, so no
    spec says which version Pi will load.
    """
    source = entry if isinstance(entry, str) else entry.get("source") if isinstance(entry, dict) else None
    match = re.fullmatch(r"npm:(?:@[^/@]+/)?[^/@]+@(.+)", source) if isinstance(source, str) else None
    return match.group(1) if match else None


def same_json_value(left: Any, right: Any) -> bool:
    """Compare decoded JSON values without conflating booleans and integers (False == 0)."""
    return json.dumps(left, sort_keys=True) == json.dumps(right, sort_keys=True)


def triples(permission: dict[str, Any]) -> list[Triple]:
    """A permission config as (section, pattern, value) rules; a scalar rule has no pattern."""
    found: list[Triple] = []
    for key, value in permission.items():
        if key == "yoloMode":
            found.append((TOP, None, value))
        elif key == "permission":
            for section, rule in value.items():
                if isinstance(rule, dict):
                    found.extend((section, pattern, verdict) for pattern, verdict in rule.items())
                else:
                    found.append((section, None, rule))
    return found


def triple_values(*groups: list[Any]) -> dict[tuple[str, str | None], list[Any]]:
    index: dict[tuple[str, str | None], list[Any]] = {}
    for group in groups:
        for section, pattern, value in group:
            values = index.setdefault((section, pattern), [])
            if value not in values:
                values.append(value)
    return index


def pi_version_warning() -> str | None:
    """A warning when Pi is missing or older than the floor. Only `pi --version` ever runs, offline."""
    floor = ".".join(map(str, PI_FLOOR))
    path = shutil.which("pi")
    if path is None:
        return f"pi is not on PATH; install Pi ({PI_PACKAGE}) {floor} or newer yourself, as the installer never does"
    environment = {**os.environ, "PI_OFFLINE": "1", "PI_SKIP_VERSION_CHECK": "1", "PI_TELEMETRY": "0"}
    try:
        result = subprocess.run(
            [path, "--version"],
            capture_output=True,
            text=True,
            timeout=15,
            stdin=subprocess.DEVNULL,
            env=environment,
        )
    except (OSError, subprocess.SubprocessError):
        return f"could not run {path} --version; b-agentic was spiked on Pi {floor}"
    found = re.search(r"(\d+)\.(\d+)\.(\d+)", result.stdout + result.stderr)
    if found is None:
        return f"{path} --version printed no version; b-agentic was spiked on Pi {floor}"
    version = tuple(int(part) for part in found.groups())
    if version < PI_FLOOR:
        return f"Pi {'.'.join(map(str, version))} is below the {floor} floor b-agentic was spiked on; upgrade Pi"
    return None


class Installer:
    def __init__(
        self,
        source: Path,
        dry_run: bool,
        force: bool,
        with_ids: list[str] | None = None,
        without_ids: list[str] | None = None,
        *,
        ui: Ui | None = None,
    ) -> None:
        self.source = source
        self.ui = ui or Ui(enabled=False)
        self.components = self.load_components()
        self.with_ids = with_ids or []
        self.without_ids = without_ids or []
        self.selection: dict[str, bool] = {key: False for key in self.components}
        self.agent_dir = pi_dir()
        self.assets_dir = self.agent_dir / "b-agentic"
        self.manifest_path = self.assets_dir / "install.json"
        self.dry_run = dry_run
        self.force = force
        self.stamp = f"{time.strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:6]}"
        self.messages: list[str] = []
        self.warnings: list[str] = []
        self.counts = {"written": 0, "unchanged": 0, "kept": 0, "removed": 0}
        self.backed_up: set[Path] = set()
        self.rendered: dict[str, str] | None = None
        self.chain_problem: str | None = None
        guard(self.agent_dir)

    # -- output ---------------------------------------------------------------
    def say(self, text: str) -> None:
        self.messages.append(("[dry-run] " if self.dry_run else "") + text)

    def warn(self, text: str) -> None:
        self.warnings.append(text)

    @staticmethod
    def display_text(text: str) -> str:
        return text.replace(str(base.home_dir()), "~")

    def display(self, path: Path | str) -> str:
        text, home = str(path), str(base.home_dir())
        return "~" + text[len(home) :] if text == home or text.startswith(home + os.sep) else text

    def plan_summary(self, plan: dict[str, Any]) -> list[str]:
        def verb(text: Any, changed: str) -> str:
            return changed if text is not None else "unchanged"

        files = plan["files"]
        kernel = plan["kernel"]
        settings = plan["settings"]
        permission = plan["permission"]
        classifier = plan["classifier"]
        mcp = plan["mcp"]
        subagent = plan["subagent"]
        file_parts = [f"{len(files['writes'])} to write", f"{self.counts['unchanged']} unchanged"]
        if files["removals"]:
            file_parts.append(f"{len(files['removals'])} to remove")
        if self.counts["kept"]:
            file_parts.append(f"{self.counts['kept']} kept")
        classifier_state = (
            "created" if classifier["text"] is not None else ("kept" if classifier["target"].exists() else "skipped")
        )
        return [
            self.ui.style(self.display(self.agent_dir), "cyan"),
            f"  {self.ui.style('files', 'green')}: {', '.join(file_parts)}",
            f"  {self.ui.style('kernel', 'green')}: AGENTS.md block "
            f"{verb(kernel['text'], 'updated' if kernel['existed'] else 'written')}",
            f"  {self.ui.style('settings', 'green')}: settings.json {verb(settings['text'], 'merged')}",
            f"  {self.ui.style('permission', 'green')}: {PERMISSION_CONFIG} {verb(permission['text'], 'merged')}",
            f"  {self.ui.style('classifier', 'green')}: {CLASSIFIER_CONFIG} {classifier_state}",
            f"  {self.ui.style('subagent', 'green')}: {SUBAGENT_CONFIG} {verb(subagent['text'], 'merged')}",
            f"  {self.ui.style('mcp', 'green')}: mcp.json {verb(mcp['text'], 'merged')}",
            f"  {self.ui.style('optional', 'green')}: {optional_components.summary(self.components, self.selection)}",
        ]

    # -- optional components ----------------------------------------------------
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

    # -- destinations -------------------------------------------------------------
    def managed_path(self, relative: str) -> Path:
        path = self.agent_dir / safe_relative(relative)
        base.check_directory_chain(path.parent, self.agent_dir, PI_PROTECTED)
        if path.is_dir() and not path.is_symlink():
            raise InstallError(f"{path} is a directory; expected a file")
        guard(path)
        return path

    def config_target(self, path: Path) -> Path:
        """A user-owned config file; a symlinked file is written through, never replaced."""
        target = Path(os.path.realpath(path)) if path.is_symlink() else path
        guard(target)
        if path.is_symlink():
            # A link may leave the agent directory (a dotfiles checkout), but it may not alias Pi's own state.
            inside = Path(os.path.realpath(self.agent_dir)) in target.parents
            if inside or target.name in PI_OWNED_FILES:
                raise InstallError(
                    f"{path} is a link to {target}, which is Pi's own state or sits inside {self.agent_dir}; "
                    "link it to a file of its own, or remove the link"
                )
        if target.exists() and not target.is_file():
            raise InstallError(f"{target} exists but is not a regular file")
        for ancestor in target.parents:
            if ancestor.exists():
                if not ancestor.is_dir():
                    raise InstallError(f"{ancestor} exists but is not a directory (needed for {target})")
                break
        return target

    def config_paths(self) -> dict[str, Path]:
        return {
            "AGENTS.md": self.agent_dir / "AGENTS.md",
            "settings.json": self.agent_dir / "settings.json",
            "mcp.json": self.agent_dir / "mcp.json",
            "the permission config": self.agent_dir / PERMISSION_CONFIG,
            "the classifier config": self.agent_dir / CLASSIFIER_CONFIG,
            "the subagent config": self.agent_dir / SUBAGENT_CONFIG,
        }

    def preflight(self) -> None:
        """Validate every directory the run may create or write into, before the first write."""
        if self.agent_dir.exists() and not self.agent_dir.is_dir():
            raise InstallError(f"{self.agent_dir} exists but is not a directory")
        base.check_directory_chain(self.assets_dir, self.agent_dir, PI_PROTECTED)
        if self.manifest_path.is_symlink() or (self.manifest_path.exists() and not self.manifest_path.is_file()):
            raise InstallError(f"{self.manifest_path} must be a regular file")
        guard(self.manifest_path)
        base.check_directory_chain(self.assets_dir / "backups", self.agent_dir, PI_PROTECTED)
        for path in self.config_paths().values():
            base.check_directory_chain(path.parent, self.agent_dir, PI_PROTECTED)
            self.config_target(path)
        self.check_aliases([])

    def check_aliases(self, relatives: list[str]) -> None:
        destinations: list[tuple[str, Path]] = [
            (label, self.config_target(path)) for label, path in self.config_paths().items()
        ]
        destinations.append(("the install manifest", self.manifest_path))
        for relative in relatives:
            path = self.agent_dir / safe_relative(relative)
            if not path.is_symlink():  # a user-owned symlinked payload file is left alone
                destinations.append((relative, path))
        base.check_disjoint(destinations)

    def check_context_files(self) -> None:
        """Pi reads one context file per folder: a CLAUDE.md here would compete with the AGENTS.md block."""
        for name in ("CLAUDE.md", "CLAUDE.MD"):
            if (self.agent_dir / name).exists():
                raise InstallError(
                    f"{self.agent_dir / name} exists; Pi reads one context file per folder, so move its content "
                    f"into {self.agent_dir / 'AGENTS.md'} and remove it, then retry"
                )
        if (self.agent_dir / "AGENTS.override.md").exists():
            self.warn(
                f"{self.agent_dir / 'AGENTS.override.md'} replaces AGENTS.md in this folder, so the b-agentic kernel "
                "block will not load until it is removed"
            )

    # -- rendering ----------------------------------------------------------------
    def render(self) -> dict[str, str]:
        """The rendered Pi tree, read into memory from a fresh folder outside the checkout and then deleted."""
        if self.rendered is not None:
            return self.rendered
        script = self.source / "tooling" / "generate" / "registry_sync.py"
        staging = Path(tempfile.mkdtemp(prefix="b-agentic-pi-render-"))
        try:
            out = staging / "pi"
            result = subprocess.run(
                [sys.executable, "-I", "-B", str(script), "--render", "pi", "--out", str(out)],
                capture_output=True,
                text=True,
                stdin=subprocess.DEVNULL,
                cwd=str(self.source),
            )
            if result.returncode != 0:
                raise InstallError(f"rendering the Pi tree failed: {(result.stderr or result.stdout).strip()}")
            self.rendered = {
                path.relative_to(out).as_posix(): path.read_text() for path in sorted(out.rglob("*")) if path.is_file()
            }
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        for required in (
            "kernel.md",
            "config/settings.json",
            "config/permission.json",
            "config/mcp.json",
            "config/subagent.json",
        ):
            if required not in self.rendered:
                raise InstallError(f"the rendered Pi tree has no {required}")
        return self.rendered

    def rendered_config(self, name: str) -> dict[str, Any]:
        return json.loads(self.render()[f"config/{name}.json"])

    # -- payload --------------------------------------------------------------
    def payload(self) -> dict[str, bytes]:
        rendered = self.render()
        excluded = self.excluded_skills()
        optional = optional_components.optional_skills(self.components)
        files: dict[str, bytes] = {}
        late: dict[str, bytes] = {}
        registry = json.loads((self.source / "skills" / "registry.yaml").read_text())
        for skill in registry["skills"]:
            name = skill["name"]
            if not isinstance(name, str) or not base.SKILL_NAME.fullmatch(name):
                raise InstallError(f"registry skill name is not a safe b-* name: {name!r}")
            if name in excluded:
                continue
            for relative in (f"skills/{name}/SKILL.md", f"prompts/{name}.md"):
                if relative not in rendered:
                    raise InstallError(f"the rendered Pi tree has no {relative}")
                try:
                    late[relative] = optional_components.filter_skill(rendered[relative], excluded, optional).encode()
                except ValueError as exc:
                    raise InstallError(f"{relative}: {exc}") from exc
        for relative, text in sorted(rendered.items()):
            if relative.startswith("agents/"):
                files[relative] = text.encode()
        extension = self.source / "pi" / "extensions" / "b-agentic"
        for name in ("index.ts", "guard.mjs"):
            files[f"extensions/b-agentic/{name}"] = (extension / name).read_bytes()
        guard_text = (extension / "guard.mjs").read_text()
        for name in HOOK_FILES:
            if f'"{name}"' not in guard_text:
                raise InstallError(f"pi/extensions/b-agentic/guard.mjs no longer names the hook {name}")
            files[f"b-agentic/hooks/{name}"] = (self.source / "claude" / "hooks" / name).read_bytes()
        helpers = sorted(
            path for path in (self.source / "claude" / "bin").iterdir() if HELPER_FILE.fullmatch(path.name)
        )
        if not any(path.name == "b-protected.mjs" for path in helpers):
            raise InstallError("claude/bin/b-protected.mjs is missing")
        for path in helpers:
            files[f"b-agentic/bin/{path.name}"] = path.read_bytes()
        for name in REFERENCES:
            files[f"b-agentic/references/{name}"] = (self.source / "references" / name).read_bytes()
        for name in WRAPPERS:
            files[f"b-agentic/bin/{name}"] = (self.source / "pi" / "bin" / name).read_bytes()
        theme = self.rendered_config("settings").get("theme")
        if theme:
            theme_path = self.source / "pi" / "themes" / f"{theme}.json"
            if not theme_path.is_file():
                raise InstallError(f"theme file missing from source checkout: {theme_path}")
            files[f"themes/{theme}.json"] = theme_path.read_bytes()
        # Skills and prompts call the agents, helpers, and wrappers above, so they are written last: an
        # interrupted upgrade then never publishes a skill that points at a command that was not installed yet.
        files.update(late)
        return files

    def kernel_block(self) -> str:
        kernel = self.render()["kernel.md"].strip("\n")
        try:
            kernel = optional_components.filter_kernel(kernel, self.excluded_skills())
        except ValueError as exc:
            raise InstallError(str(exc)) from exc
        return f"{base.KERNEL_BLOCK_START}\n{kernel}\n{base.KERNEL_BLOCK_END}"

    def is_wrapper(self, path: Path) -> bool:
        return path.parent == self.assets_dir / "bin" and path.name in WRAPPERS

    # -- writes (only called after planning) ----------------------------------------
    def write_bytes(self, path: Path, data: bytes) -> None:
        guard(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
        try:
            with os.fdopen(handle, "wb") as stream:
                stream.write(data)
            if path.exists():
                os.chmod(temporary, path.stat().st_mode & 0o777)
            if self.is_wrapper(path):
                os.chmod(temporary, WRAPPER_MODE)
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
        guard(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)

    def remove_file(self, path: Path) -> None:
        guard(path)
        path.unlink(missing_ok=True)
        directory = path.parent
        # Only folders inside the agent directory are pruned: a config symlink can put a target anywhere.
        while (
            directory != self.agent_dir
            and self.agent_dir in directory.parents
            and directory.is_dir()
            and not any(directory.iterdir())
        ):
            guard(directory)
            directory.rmdir()
            directory = directory.parent

    def write_config(self, plan: dict[str, Any], message: str) -> None:
        if plan["text"] is None:
            return
        if not self.dry_run:
            self.backup(plan["target"])
            self.write_bytes(plan["target"], plan["text"].encode())
        self.say(message)

    # -- manifest -------------------------------------------------------------
    def read_manifest(self) -> dict[str, Any]:
        manifest = read_json(self.manifest_path)
        if manifest and (manifest.get("schema") != MANIFEST_SCHEMA or manifest.get("target") != "pi"):
            raise InstallError(f"{self.manifest_path} is not a Pi manifest this version understands")
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
    def theme_owners(manifest: dict[str, Any]) -> list[str]:
        committed = manifest.get("settings", {}).get("theme")
        pending = manifest.get("pending", {}).get("settings_theme", [])
        return merge_unique([committed] if isinstance(committed, str) and committed else [], pending)

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
    def permission_owned(manifest: dict[str, Any]) -> dict[tuple[str, str | None], list[Any]]:
        return triple_values(manifest.get("permission", []), manifest.get("pending", {}).get("permission", []))

    @staticmethod
    def chain_owned(manifest: dict[str, Any]) -> list[str]:
        return merge_unique(
            list(manifest.get("permission_chain", [])), list(manifest.get("pending", {}).get("permission_chain", []))
        )

    @staticmethod
    def classifier_owners(manifest: dict[str, Any]) -> set[str]:
        """Only a committed record counts: an install cut short between creating the file and committing leaves a
        stray `{}` after an uninstall, which is the safer failure than deleting a file someone else may have made."""
        committed = manifest.get("classifier_sha256")
        return {committed} if committed else set()

    @staticmethod
    def subagent_candidates(manifest: dict[str, Any], key: str) -> list[Any]:
        committed = manifest.get("subagent", {})
        pending = manifest.get("pending", {}).get("subagent", {}).get(key, [])
        candidates: list[Any] = [committed[key]] if key in committed else []
        for value in pending:
            if not any(same_json_value(value, existing) for existing in candidates):
                candidates.append(value)
        return candidates

    @staticmethod
    def subagent_keys(manifest: dict[str, Any]) -> list[str]:
        return merge_unique(
            list(manifest.get("subagent", {})),
            list(manifest.get("pending", {}).get("subagent", {})),
        )

    # -- planning -----------------------------------------------------------------
    def plan_all(self, previous: dict[str, Any]) -> dict[str, Any]:
        self.counts = {name: 0 for name in self.counts}
        self.warnings.clear()
        self.check_context_files()
        self.chain_problem = self.pinned_too_old()
        if self.chain_problem:
            self.warn(self.chain_problem)
        files = self.plan_files(previous)
        kernel = self.plan_kernel(previous)
        settings = self.plan_settings(previous)
        mcp = self.plan_mcp(previous)
        permission = self.plan_permission(previous)
        classifier = self.plan_classifier(previous)
        subagent = self.plan_subagent(previous)
        return {
            "files": files,
            "kernel": kernel,
            "settings": settings,
            "permission": permission,
            "mcp": mcp,
            "classifier": classifier,
            "subagent": subagent,
        }

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
            if relative.startswith(EXECUTED_ROOTS):
                self.require_executed_slot(path, digest, owners)
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
                    lost_exec_bit = (
                        (owners or self.force) and self.is_wrapper(path) and path.stat().st_mode & 0o777 != WRAPPER_MODE
                    )
                    if lost_exec_bit:
                        writes.append((path, data, True))
                        recorded[relative] = digest
                    else:
                        self.counts["unchanged"] += 1
                        if owners:  # byte equality is not ownership: only a recorded file is ours
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

    def require_executed_slot(self, path: Path, digest: str, owners: set[str]) -> None:
        """The wrappers, helpers, hooks, and extension run each other, so refuse, before anything is written, a
        link or a file that b-agentic does not own (or that was edited since install) there, instead of keeping
        it and publishing wrappers and skills that would run stale code."""
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise InstallError(f"{path} is not a regular file, but the installed commands run it; remove it and re-run")
        if not path.exists() or self.force:
            return
        current = sha256(path.read_bytes())
        if current != digest and current not in owners:
            reason = "was edited since install" if owners else "was not installed by b-agentic"
            raise InstallError(
                f"{path} {reason} and differs from the file the installed commands run; "
                "move it aside, or pass --force to replace it after a backup"
            )
        if self.is_wrapper(path) and current == digest and not owners and not os.access(path, os.X_OK):
            raise InstallError(f"{path} is not executable, but skills call it; run chmod u+x on it, or pass --force")

    def plan_kernel(self, manifest: dict[str, Any]) -> dict[str, Any]:
        path = self.agent_dir / "AGENTS.md"
        target = self.config_target(path)
        existed = target.exists()
        text = target.read_text() if existed else ""
        span = find_block(text, str(path))
        block = self.kernel_block()
        digest = sha256(block.encode())
        owners = self.kernel_owners(manifest)
        committed = manifest.get("kernel_sha256")
        created = bool(manifest.get("created", {}).get("agents_md", False)) or not existed
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
                self.warn(f"kept the kernel block in {path} ({reason}); pass --force to replace it after a backup")
                self.counts["kept"] += 1
                new_text, owned = None, committed
        return {"target": target, "text": new_text, "existed": existed, "sha256": owned, "created": created}

    def plan_settings(self, manifest: dict[str, Any]) -> dict[str, Any]:
        path = self.agent_dir / "settings.json"
        target = self.config_target(path)
        existed = target.exists()
        settings = read_json(target)
        packages = settings.setdefault("packages", [])
        if not isinstance(packages, list):
            raise InstallError(f"{path}: packages must be an array")
        tools = settings.get("defaultTools")
        if tools is not None and (not isinstance(tools, list) or not all(isinstance(item, str) for item in tools)):
            raise InstallError(f"{path}: defaultTools must be an array of strings")
        wanted = self.rendered_config("settings")
        recorded = manifest.get("settings", {})
        owned_packages: list[str] = []
        for name in recorded.get("packages", []):
            if name not in wanted["packages"] and name in packages:
                packages.remove(name)  # retired: still exactly the recorded entry
        for name in wanted["packages"]:
            names = [package_name(entry) for entry in packages]
            if name in names:
                if name in packages and name in recorded.get("packages", []):
                    owned_packages.append(name)
                continue
            position = (
                names.index(PERMISSION_PACKAGE)
                if name == CLASSIFIER_PACKAGE and PERMISSION_PACKAGE in names
                else len(packages)
            )
            packages.insert(position, name)
            owned_packages.append(name)
        names = [package_name(entry) for entry in packages]
        if (
            CLASSIFIER_PACKAGE in names
            and PERMISSION_PACKAGE in names
            and names.index(CLASSIFIER_PACKAGE) > names.index(PERMISSION_PACKAGE)
        ):
            # The classifier must load first: move the user's entry as it is, so a pin or object fields survive.
            packages.insert(names.index(PERMISSION_PACKAGE), packages.pop(names.index(CLASSIFIER_PACKAGE)))
            self.warn(
                f"moved {CLASSIFIER_PACKAGE} before {PERMISSION_PACKAGE} in {path}; the classifier must load first"
            )
        for entry in packages:
            filtered = isinstance(entry, dict) and ("extensions" in entry or entry.get("autoload") is False)
            if filtered and package_name(entry) in wanted["packages"]:
                if package_name(entry) == PERMISSION_PACKAGE:
                    raise InstallError(
                        f"{path} filters the extensions of {PERMISSION_PACKAGE} (extensions or autoload: false), but "
                        "it enforces the managed shell and path rules; remove that filter and retry"
                    )
                self.warn(f"{path} filters the extensions of {package_name(entry)}; b-agentic expects it to load")
        owned_tools: list[str] = []
        previous_tools = recorded.get("defaultTools", [])
        if tools is None:
            settings["defaultTools"] = list(wanted["defaultTools"])
            owned_tools = list(wanted["defaultTools"])
        else:
            for item in previous_tools:
                if item not in wanted["defaultTools"] and item in tools:
                    tools.remove(item)
            missing = [item for item in wanted["defaultTools"] if item not in tools]
            plain = [item for item in tools if not item.startswith("+")]
            if missing and (plain or tools == []):
                kind = "an empty list that disables the built-in tools" if tools == [] else "a plain list"
                self.warn(
                    f"kept your defaultTools in {path}: it is {kind} without {', '.join(missing)}; "
                    "the guard covers those tools once you enable them"
                )
            else:
                tools.extend(missing)
            owned_tools = [
                item for item in wanted["defaultTools"] if item in tools and (item in missing or item in previous_tools)
            ]
        wanted_theme = wanted.get("theme")
        theme_owners = self.theme_owners(manifest)
        owned_theme: str | None = None
        if "theme" not in settings:
            if wanted_theme:
                settings["theme"] = wanted_theme
                owned_theme = wanted_theme
        else:
            current_theme = settings["theme"]
            if current_theme == wanted_theme:
                if current_theme in theme_owners:
                    owned_theme = current_theme
            elif current_theme in theme_owners:
                if wanted_theme:
                    settings["theme"] = wanted_theme
                    owned_theme = wanted_theme
                else:
                    del settings["theme"]
        record: dict[str, Any] = {"packages": owned_packages, "defaultTools": owned_tools}
        if owned_theme is not None:
            record["theme"] = owned_theme
        text = json_text(settings)
        return {
            "target": target,
            "text": text if not existed or target.read_text() != text else None,
            "record": record,
            "created": bool(manifest.get("created", {}).get("settings", False)) or not existed,
        }

    def plan_permission(self, manifest: dict[str, Any]) -> dict[str, Any]:
        path = self.agent_dir / PERMISSION_CONFIG
        target = self.config_target(path)
        existed = target.exists()
        config = read_json(target)
        permission = config.setdefault("permission", {})
        if not isinstance(permission, dict):
            raise InstallError(f"{path}: permission must be an object")
        wanted_config = self.rendered_config("permission")
        excluded = self.excluded_servers()
        # Automatic approvals apply to every selected server in the shipped template (including entries the user edited);
        # deselected optional components and servers without a shipped template (DataGrip) keep the catch-all verdict.
        approved = set(self.rendered_config("mcp")["mcpServers"]) - excluded

        def keeps(rule: Triple) -> bool:
            section, pattern, value = rule
            if section != "mcp" or value != "allow" or pattern is None or not pattern.startswith("mcp__"):
                return True
            return pattern.split("__")[1] in approved

        wanted = [rule for rule in triples(wanted_config) if keeps(rule)]
        owned = self.permission_owned(manifest)
        # A catch-all of the user's that differs from the shipped one sets a floor: b-agentic installs only rules
        # at least as strict as it, so managed rules can tighten the user's setup and never loosen it.
        shipped = {(section, pattern): value for section, pattern, value in wanted if pattern == "*"}
        floors: dict[str, int] = {}
        for section, rules in permission.items():
            value = rules.get("*") if isinstance(rules, dict) else None
            if value is not None and not isinstance(value, str):
                raise InstallError(f'{path}: permission.{section}["*"] must be allow, ask, or deny')
            if value is not None and (section, "*") in shipped:
                if value not in owned.get((section, "*"), []) and value != shipped[(section, "*")]:
                    floors[section] = STRICTNESS.get(value, 1)

        def loosens(rule: Triple) -> bool:
            section, pattern, value = rule
            return pattern not in (None, "*") and section in floors and STRICTNESS.get(value, 1) < floors[section]

        loosened = {rule[0] for rule in wanted if loosens(rule)}
        wanted = [rule for rule in wanted if not loosens(rule)]
        for section in sorted(loosened):
            self.warn(
                f"your permission.{section} catch-all in {path} is stricter than b-agentic's, so the managed "
                f"{section} rules that are looser than it were not installed"
            )
        wanted_keys = {(section, pattern) for section, pattern, _ in wanted}
        record: list[Triple] = []
        kept = 0  # map rules the user already set differently
        # A rule an earlier version added and this version no longer ships is retired, but only if it is still ours.
        for (section, pattern), values in owned.items():
            if (section, pattern) not in wanted_keys:
                self.remove_rule(config, section, pattern, values)
        for section, pattern, value in wanted:
            container = config if section == TOP else permission
            key = "yoloMode" if section == TOP else section
            if pattern is None:
                if key not in container:
                    container[key] = value
                    record.append((section, None, value))
                elif container[key] == value:
                    if value in owned.get((section, None), []):
                        record.append((section, None, value))
                elif container[key] in owned.get((section, None), []):
                    container[key] = value
                    record.append((section, None, value))
                else:
                    self.warn(f"kept your {key} rule {container[key]!r} in {path} (b-agentic ships {value!r})")
                continue
            rules = permission.setdefault(section, {})
            if not isinstance(rules, dict):
                raise InstallError(
                    f"{path}: permission.{section} must be an object; write the single value {rules!r} as "
                    f'{{"*": {json.dumps(rules)}}} so b-agentic can add its rules after it'
                )
            if pattern not in rules:
                rules[pattern] = value
                record.append((section, pattern, value))
            elif rules[pattern] == value:
                if value in owned.get((section, pattern), []):
                    record.append((section, pattern, value))
            elif rules[pattern] in owned.get((section, pattern), []):
                rules[pattern] = value
                record.append((section, pattern, value))
            else:
                kept += 1
        # Later rules win. The user's rules up to and including their catch-all come first, then every rule b-agentic
        # owns, then the user's remaining rules: a specific user rule after the catch-all keeps precedence over an
        # overlapping managed pattern, and the catch-all can neither cancel a managed deny or ask (the managed block
        # follows it) nor be loosened by one (the floor above drops those).
        managed = {(section, pattern) for section, pattern, _ in record if pattern is not None}
        for section, rules in list(permission.items()):
            if isinstance(rules, dict):
                # Managed rules keep the rendered policy order (the catch-all first), whatever order the file had.
                order = [pattern for sec, pattern, _ in wanted if sec == section and (sec, pattern) in managed]
                ours = {key: rules[key] for key in order if key in rules}
                theirs = {key: value for key, value in rules.items() if (section, key) not in managed}
                # The user's own rules keep their relative order, with the managed block right after their catch-all:
                # rules the user wrote before it stay shadowed by it exactly as before, so nothing of theirs loosens.
                keys = list(theirs)
                split = keys.index("*") + 1 if "*" in theirs else 0
                permission[section] = {
                    **{key: theirs[key] for key in keys[:split]},
                    **ours,
                    **{key: theirs[key] for key in keys[split:]},
                }
        if kept:
            self.warn(f"kept {kept} of your permission rules in {path} that differ from b-agentic's")
        for section in [name for name, rules in permission.items() if rules == {} and any(s == name for s, _ in owned)]:
            del permission[section]
        owned_links, chain_created = self.merge_chain(config, wanted_config.get("authorizerChain", []), manifest, path)
        text = json_text(config)
        return {
            "target": target,
            "text": text if not existed or target.read_text() != text else None,
            "record": [list(rule) for rule in record],
            "chain": owned_links,
            "chain_created": chain_created,
            "created": bool(manifest.get("created", {}).get("permission", False)) or not existed,
        }

    def pinned_too_old(self) -> str | None:
        """A reason not to name the classifier in the chain: the user gave a package a version spec."""
        target = self.config_target(self.agent_dir / "settings.json")
        packages = read_json(target).get("packages") if target.exists() else None
        for entry in packages if isinstance(packages, list) else []:
            if package_name(entry) in CHAIN_PACKAGES and version_spec(entry) is not None:
                return (
                    f"{target} gives {package_name(entry)} the version spec {version_spec(entry)}; the classifier needs "
                    "permission system 20.9.0 or newer and classifier 0.6.0 or newer, and b-agentic cannot tell which "
                    "version Pi will load, so it left authorizerChain and the classifier config alone; remove the "
                    "version spec (or add the chain yourself) and install again"
                )
        return None

    def merge_chain(
        self, config: dict[str, Any], wanted: list[str], manifest: dict[str, Any], path: Path
    ) -> tuple[list[str], bool]:
        """Append the links b-agentic ships to the user's `authorizerChain`; the user's own links and order stay.

        Only a link this installer added (and that is still there) is recorded, so an uninstall removes nothing the user
        wrote, and a link the user took out comes back on the next install, as a rule or package would. Also returns
        whether the field was created by this installer: an empty array the user wrote stays an empty array (it blocks
        links inherited from a wider config), but a field this installer created goes away with its last link.
        """
        present = "authorizerChain" in config
        chain = config.get("authorizerChain")
        if present and (not isinstance(chain, list) or not all(isinstance(link, str) and link for link in chain)):
            raise InstallError(f"{path}: authorizerChain must be an array of non-empty strings")
        recorded = self.chain_owned(manifest)
        created = bool(manifest.get("created", {}).get("permission_chain", False)) or not present
        chain = list(chain or [])
        if self.chain_problem:
            wanted = []
        for link in recorded:
            if link not in wanted and link in chain:
                chain.remove(link)  # retired: no longer shipped, or the pinned package cannot use it
        owned: list[str] = []
        for link in wanted:
            if link not in chain:
                chain.append(link)
                owned.append(link)
            elif link in recorded:
                owned.append(link)
        if len(chain) > MAX_CHAIN:
            raise InstallError(
                f"{path}: authorizerChain would hold {len(chain)} entries; the permission system accepts at most "
                f"{MAX_CHAIN}, so shorten your list first"
            )
        if chain or not created:
            config["authorizerChain"] = chain
            return owned, created
        # The field goes away with its last link, so it is no longer ours: an empty array the user writes later is theirs.
        config.pop("authorizerChain", None)
        return owned, False

    def plan_classifier(self, manifest: dict[str, Any]) -> dict[str, Any]:
        """The classifier's own config: `{}` is written only when the file is absent, never over a file that exists.

        /permission-model keeps the user's judge choices in this file, so an existing one is neither parsed nor
        replaced (not even with --force). It is recorded, and later removed, only while it is byte for byte the `{}`
        this installer wrote; a file the user wrote or edited stays theirs.
        """
        path = self.agent_dir / CLASSIFIER_CONFIG
        target = self.config_target(path)
        wanted = CLASSIFIER_PACKAGE in self.rendered_config("settings")["packages"] and not self.chain_problem
        digest = sha256(CLASSIFIER_CONFIG_TEXT.encode())
        owners = self.classifier_owners(manifest)
        # A link is never owned: it points at a file kept somewhere else (a dotfiles checkout), which may be replaced
        # or retargeted at any time, and the bytes alone do not say who wrote it.
        linked = path.is_symlink()
        if target.exists():
            owned = digest if wanted and not linked and sha256(target.read_bytes()) in owners else None
            return {"target": target, "text": None, "sha256": owned}
        if not wanted:
            return {"target": target, "text": None, "sha256": None}
        return {"target": target, "text": CLASSIFIER_CONFIG_TEXT, "sha256": None if linked else digest}

    def create_classifier(self, classifier: dict[str, Any]) -> None:
        """Create the file only if it is still absent: a file that appears after planning is the user's."""
        if classifier["text"] is None:
            return
        target = classifier["target"]
        if not self.dry_run:
            guard(target)
            target.parent.mkdir(parents=True, exist_ok=True)
            # The whole file is written beside the target and then linked into place, which fails if the target exists:
            # the final path never holds a partial file and never replaces one that appeared after planning.
            handle, temporary = tempfile.mkstemp(dir=target.parent, prefix=f".{target.name}.")
            try:
                with os.fdopen(handle, "w") as stream:
                    stream.write(classifier["text"])
                os.chmod(temporary, 0o644)
                try:
                    os.link(temporary, target)
                except FileExistsError:
                    classifier["sha256"] = None
                    self.warn(f"kept {target}: it appeared while b-agentic was installing")
                    return
            finally:
                os.unlink(temporary)
        self.say(f"classifier config created at {target}")

    @staticmethod
    def remove_rule(config: dict[str, Any], section: str, pattern: str | None, values: list[Any]) -> bool:
        container = config if section == TOP else config.get("permission", {})
        key = "yoloMode" if section == TOP else section
        if pattern is None:
            if key in container and container[key] in values:
                del container[key]
                return True
            return False
        rules = container.get(key)
        if isinstance(rules, dict) and pattern in rules and rules[pattern] in values:
            del rules[pattern]
            return True
        return False

    def plan_mcp(self, manifest: dict[str, Any]) -> dict[str, Any]:
        path = self.agent_dir / "mcp.json"
        target = self.config_target(path)
        existed = target.exists()
        config = read_json(target)
        base.validate_mcp_shape(config, str(path))
        servers = config.setdefault("mcpServers", {})
        excluded = self.excluded_servers()
        desired = {
            name: entry for name, entry in self.rendered_config("mcp")["mcpServers"].items() if name not in excluded
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
        text = json_text(config)
        return {
            "target": target,
            "text": text if not existed or target.read_text() != text else None,
            "recorded": recorded,
            "created": bool(manifest.get("created", {}).get("mcp", False)) or not existed,
        }

    def plan_subagent(self, manifest: dict[str, Any]) -> dict[str, Any]:
        path = self.agent_dir / SUBAGENT_CONFIG
        target = self.config_target(path)
        existed = target.exists()
        config = read_json(target)
        desired = self.rendered_config("subagent")
        recorded: dict[str, Any] = {}
        for key, value in desired.items():
            candidates = self.subagent_candidates(manifest, key)
            if key not in config:
                config[key] = value
                recorded[key] = value
            elif same_json_value(config[key], value):
                if candidates:
                    recorded[key] = value
            elif any(same_json_value(config[key], candidate) for candidate in candidates):
                config[key] = value
                recorded[key] = value
            else:
                self.warn(f"kept your subagent setting '{key}' in {path} (differs from b-agentic's)")
        for key in self.subagent_keys(manifest):
            if key in recorded or key not in config:
                continue
            if any(same_json_value(config[key], candidate) for candidate in self.subagent_candidates(manifest, key)):
                del config[key]
        text = json_text(config)
        return {
            "target": target,
            "text": text if not existed or target.read_text() != text else None,
            "recorded": recorded,
            "created": bool(manifest.get("created", {}).get("subagent", False)) or not existed,
        }

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
        # The probe can take seconds, so it runs before any user file is read for the plan.
        warning = pi_version_warning()
        self.preflight()
        manifest = self.read_manifest()
        notes = [line for line in os.environ.get("B_AGENTIC_NOTES", "").splitlines() if line]
        for note in notes:
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
        plan = self.plan_all(previous)
        if warning:
            self.warn(warning)
        if self.ui.fancy:
            self.ui.box("Installation Summary", self.plan_summary(plan))
            if self.ui.interactive:
                if not self.ui.confirm("Proceed with installation?", default=True):
                    raise InstallError(f"installation cancelled; nothing under {self.agent_dir} was changed")
                # Re-validate and re-plan after the prompt so concurrent edits or new aliases are caught.
                previous, _ = self.validate_destinations()
                plan = self.plan_all(previous)
                if warning:
                    self.warn(warning)
        files, kernel, settings, permission, mcp, classifier, subagent = (
            plan[key] for key in ("files", "kernel", "settings", "permission", "mcp", "classifier", "subagent")
        )
        created = {
            "agents_md": kernel["created"],
            "settings": settings["created"],
            "permission": permission["created"],
            "permission_chain": permission["chain_created"],
            "mcp": mcp["created"],
            "subagent": subagent["created"],
        }
        final = {
            "schema": MANIFEST_SCHEMA,
            "target": "pi",
            "created": created,
            "kernel_sha256": kernel["sha256"],
            "files": dict(sorted(files["recorded"].items())),
            "settings": settings["record"],
            "permission": permission["record"],
            "permission_chain": permission["chain"],
            "classifier_sha256": classifier["sha256"],
            "mcp": {"servers": mcp["recorded"]},
            "subagent": subagent["recorded"],
            "optional_components": dict(self.selection),
        }
        # Intent: keep the last committed ownership and list what this run may write as `pending`, so an
        # interruption leaves a manifest that recognizes both the old and the new state.
        old_pending = previous.get("pending", {})
        intent = json.loads(json.dumps(previous)) if previous else {"schema": MANIFEST_SCHEMA, "target": "pi"}
        # The intent keeps the field marked as created if either the old or the new record says so: a run cut short while
        # it removes the field must still let an uninstall delete the empty array it leaves behind.
        old_created = previous.get("created", {}).get("permission_chain", False)
        intent.update(
            {
                "created": {**created, "permission_chain": bool(created["permission_chain"] or old_created)},
                "optional_components": dict(self.selection),
            }
        )
        intent.setdefault("kernel_sha256", None)
        intent.setdefault("files", {})
        intent.setdefault("permission", [])
        intent.setdefault("permission_chain", [])
        intent.setdefault("classifier_sha256", None)
        intent.setdefault("mcp", {"servers": {}})
        intent.setdefault("subagent", {})
        old_settings = intent.setdefault("settings", {"packages": [], "defaultTools": []})
        for key in ("packages", "defaultTools"):
            old_settings[key] = merge_unique(old_settings.get(key, []), settings["record"][key])
        pending_files = {relative: list(digests) for relative, digests in old_pending.get("files", {}).items()}
        for relative, digest in files["recorded"].items():
            pending_files[relative] = merge_unique(pending_files.get(relative, []), [digest])
        pending_servers = {name: list(entries) for name, entries in old_pending.get("mcp_servers", {}).items()}
        for name, entry in mcp["recorded"].items():
            pending_servers[name] = merge_unique(pending_servers.get(name, []), [entry])
        pending_subagent = {key: list(values) for key, values in old_pending.get("subagent", {}).items()}
        for key, value in subagent["recorded"].items():
            values = pending_subagent.setdefault(key, [])
            if not any(same_json_value(value, existing) for existing in values):
                values.append(value)
        intent["pending"] = {
            "files": pending_files,
            "kernel": merge_unique(old_pending.get("kernel", []), [kernel["sha256"]] if kernel["sha256"] else []),
            "mcp_servers": pending_servers,
            "permission": merge_unique(old_pending.get("permission", []), permission["record"]),
            "permission_chain": merge_unique(old_pending.get("permission_chain", []), permission["chain"]),
            "settings_theme": merge_unique(
                old_pending.get("settings_theme", []),
                [settings["record"]["theme"]] if settings["record"].get("theme") else [],
            ),
            "subagent": pending_subagent,
        }
        if not self.dry_run and self.has_changes(plan):
            self.write_manifest(intent)
        for path, data, replace in files["writes"]:
            if not self.dry_run:
                if replace:
                    self.backup(path)
                self.write_bytes(path, data)
            self.counts["written"] += 1
        self.write_kernel(kernel)
        # The policy goes first and settings.json last: settings.json is what makes Pi load the packages, so a
        # failed write leaves the new integration inactive instead of running without the managed rules.
        self.write_config(permission, f"permission rules merged in {self.agent_dir / PERMISSION_CONFIG}")
        self.create_classifier(classifier)
        final["classifier_sha256"] = classifier["sha256"]
        self.write_config(mcp, f"MCP servers merged in {self.agent_dir / 'mcp.json'}")
        self.write_config(subagent, f"subagent config merged in {self.agent_dir / SUBAGENT_CONFIG}")
        self.write_config(settings, f"settings merged in {self.agent_dir / 'settings.json'}")
        for path in files["removals"]:
            if not self.dry_run:
                self.remove_file(path)
            self.counts["removed"] += 1
        if not self.dry_run and (self.has_changes(plan) or previous != final):
            self.write_manifest(final)

    @staticmethod
    def has_changes(plan: dict[str, Any]) -> bool:
        return bool(
            plan["files"]["writes"]
            or plan["files"]["removals"]
            or any(
                plan[key]["text"] is not None
                for key in ("kernel", "settings", "permission", "mcp", "classifier", "subagent")
            )
        )

    def write_kernel(self, kernel: dict[str, Any]) -> None:
        if kernel["text"] is None:
            return
        if not self.dry_run:
            self.backup(kernel["target"])
            self.write_bytes(kernel["target"], kernel["text"].encode())
        self.say(f"kernel block {'updated' if kernel['existed'] else 'written'} in {self.agent_dir / 'AGENTS.md'}")

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
            (self.plan_kernel_removal(manifest), f"kernel block removed from {self.agent_dir / 'AGENTS.md'}"),
            (self.plan_settings_removal(manifest), f"settings entries removed from {self.agent_dir / 'settings.json'}"),
            (
                self.plan_permission_removal(manifest),
                f"permission rules removed from {self.agent_dir / PERMISSION_CONFIG}",
            ),
            (self.plan_mcp_removal(manifest), f"MCP servers removed from {self.agent_dir / 'mcp.json'}"),
            (
                self.plan_classifier_removal(manifest),
                f"classifier config removed from {self.agent_dir / CLASSIFIER_CONFIG}",
            ),
            (
                self.plan_subagent_removal(manifest),
                f"subagent config entries removed from {self.agent_dir / SUBAGENT_CONFIG}",
            ),
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
            guard(self.manifest_path)
            self.manifest_path.unlink(missing_ok=True)
            for folder in ("bin", "hooks", "references"):
                directory = self.assets_dir / folder
                if directory.is_dir() and not any(directory.iterdir()):
                    guard(directory)
                    directory.rmdir()
            if self.assets_dir.is_dir() and not any(self.assets_dir.iterdir()):
                guard(self.assets_dir)
                self.assets_dir.rmdir()
            elif (self.assets_dir / "backups").is_dir():
                self.say(f"backups kept in {self.assets_dir / 'backups'}")

    def removal_plan(self, target: Path, config: dict[str, Any], created: bool) -> dict[str, Any]:
        """A config file after an uninstall edit: deleted when b-agentic created it and nothing else remains."""
        if created and config in ({}, {"packages": []}, {"permission": {}}, {"mcpServers": {}}):
            return {"target": target, "delete": True}
        return {"target": target, "text": json_text(config)}

    def plan_kernel_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        owners = self.kernel_owners(manifest)
        path = self.agent_dir / "AGENTS.md"
        target = self.config_target(path)
        if not owners or not target.exists():
            return None
        text = target.read_text()
        span = find_block(text, str(path))
        if span is None:
            return None
        if sha256(text[span[0] : span[1]].encode()) not in owners:
            self.warn(f"kept the modified kernel block in {path}")
            return None
        remaining = (text[: span[0]].rstrip("\n") + "\n\n" + text[span[1] :].lstrip("\n")).strip("\n")
        if manifest.get("created", {}).get("agents_md") and not remaining:
            return {"target": target, "delete": True}
        return {"target": target, "text": remaining + "\n" if remaining else ""}

    def plan_settings_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        record = manifest.get("settings", {})
        theme_owners = self.theme_owners(manifest)
        path = self.agent_dir / "settings.json"
        target = self.config_target(path)
        if not target.exists() or not (record.get("packages") or record.get("defaultTools") or theme_owners):
            return None
        settings = read_json(target)
        changed = False
        for key in ("packages", "defaultTools"):
            existing = settings.get(key)
            if isinstance(existing, list):
                kept = [item for item in existing if item not in record.get(key, [])]
                if kept != existing:
                    changed = True
                    settings[key] = kept
                    if kept == []:
                        del settings[key]
        if "theme" in settings and settings["theme"] in theme_owners:
            del settings["theme"]
            changed = True
        if not changed:
            return None
        return self.removal_plan(target, settings, bool(manifest.get("created", {}).get("settings")))

    def plan_permission_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        owned = self.permission_owned(manifest)
        links = self.chain_owned(manifest)
        path = self.agent_dir / PERMISSION_CONFIG
        target = self.config_target(path)
        if not (owned or links) or not target.exists():
            return None
        config = read_json(target)
        changed = False
        for (section, pattern), values in owned.items():
            changed = self.remove_rule(config, section, pattern, values) or changed
        chain = config.get("authorizerChain")
        if isinstance(chain, list) and any(link in chain for link in links):
            kept_links = [link for link in chain if link not in links]
            changed = True
            if kept_links or not manifest.get("created", {}).get("permission_chain", False):
                config["authorizerChain"] = kept_links  # an empty array of the user's own stays: it blocks inheritance
            else:
                del config["authorizerChain"]
        permission = config.get("permission")
        if isinstance(permission, dict):
            for section in [
                name for name, rules in permission.items() if rules == {} and any(s == name for s, _ in owned)
            ]:
                del permission[section]
            if permission == {}:
                del config["permission"]
        if not changed:
            return None
        return self.removal_plan(target, config, bool(manifest.get("created", {}).get("permission")))

    def plan_classifier_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        """The `{}` this installer wrote, only while it is still exactly that; anything else is the user's."""
        owners = self.classifier_owners(manifest)
        path = self.agent_dir / CLASSIFIER_CONFIG
        target = self.config_target(path)
        if not owners or not target.is_file():
            return None
        if path.is_symlink():
            self.warn(f"kept {path}: it is a link now, so the file it points at is not b-agentic's to remove")
            return None
        if sha256(target.read_bytes()) not in owners:
            self.warn(f"kept {target} (modified since install)")
            return None
        return {"target": target, "delete": True}

    def plan_mcp_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        names = self.mcp_names(manifest)
        target = self.config_target(self.agent_dir / "mcp.json")
        if not target.exists() or not names:
            return None
        config = read_json(target)
        base.validate_mcp_shape(config, str(target))
        servers = config.get("mcpServers", {})
        removed = [name for name in names if servers.get(name) in self.mcp_candidates(manifest, name)]
        for name in removed:
            del servers[name]
        if not removed:
            return None
        if servers == {}:
            del config["mcpServers"]
        return self.removal_plan(target, config, bool(manifest.get("created", {}).get("mcp")))

    def plan_subagent_removal(self, manifest: dict[str, Any]) -> dict[str, Any] | None:
        keys = self.subagent_keys(manifest)
        target = self.config_target(self.agent_dir / SUBAGENT_CONFIG)
        if not target.exists() or not keys:
            return None
        config = read_json(target)
        removed = [
            key
            for key in keys
            if key in config
            and any(same_json_value(config[key], candidate) for candidate in self.subagent_candidates(manifest, key))
        ]
        if not removed:
            return None
        for key in removed:
            del config[key]
        return self.removal_plan(target, config, bool(manifest.get("created", {}).get("subagent")))

    def next_steps(self) -> list[str]:
        lines = [
            "Next steps:",
            f"  1. Install Pi ({PI_PACKAGE}, {'.'.join(map(str, PI_FLOOR))} or newer) yourself if it is not installed; "
            "the installer never installs Pi or a package.",
            "  2. Start pi: it installs the packages named in "
            f"{self.display(self.agent_dir / 'settings.json')} on its next start (that step needs the network).",
            "  3. Optional: run /permission-model in Pi to pick the model that judges permission asks; until you do, "
            "the classifier uses the session's chat model.",
        ]
        if self.components:
            lines.append(
                "  Optional components ("
                + optional_components.summary(self.components, self.selection)
                + "): re-run with --with=<id> or --without=<id> to change them."
            )
        return lines

    def report_fancy(self, operation: str) -> None:
        verb = "Uninstalled" if operation == "uninstall" else "Installed"
        summary = ", ".join(f"{count} {name}" for name, count in self.counts.items() if count)
        label = "[dry-run] " if self.dry_run else ""
        ok = self.ui.glyph["ok"]
        self.ui.step(f"{label}{'Uninstall' if operation == 'uninstall' else 'Installation'} complete", done=True)
        lines = [f"{self.ui.style(ok, 'green')} {self.display(self.agent_dir)}", f"  {summary or 'no changes'}"]
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
        print(f"{label}b-agentic {operation} for Pi ({self.agent_dir}): {summary or 'no changes'}")
        if operation.startswith("install") and not self.dry_run:
            print("\n".join(self.next_steps()))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uninstall", action="store_true", help="remove what the manifest recorded")
    parser.add_argument("--dry-run", action="store_true", help="print the plan and change nothing")
    parser.add_argument("--force", action="store_true", help="replace modified or unmanaged files after a backup")
    parser.add_argument("-y", "--yes", action="store_true", help="skip interactive questions and use defaults")
    parser.add_argument("--source", default=str(ROOT), help="b-agentic source checkout (default: this repository)")
    base.add_optional_arguments(parser)
    args = parser.parse_args(argv)
    try:
        if args.uninstall and (args.with_ids or args.without_ids):
            raise InstallError("--with and --without cannot be combined with --uninstall")
        source = Path(args.source).resolve()
        if (
            not (source / "skills" / "registry.yaml").is_file()
            or not (source / "pi" / "extensions" / "b-agentic").is_dir()
        ):
            raise InstallError(f"{source} is not a b-agentic source checkout with the Pi runtime")
        with_ids, without_ids = base.parse_optional_arguments(source, args)
        ui = Ui(enabled=not (args.yes or args.dry_run or args.uninstall))
        ui.header()
        installer = Installer(source, args.dry_run, args.force, with_ids, without_ids, ui=ui)
        try:
            if args.uninstall:
                installer.uninstall()
                installer.report("uninstall")
            else:
                installer.install()
                installer.report(f"install ({base.source_revision(source) or 'unversioned source'})")
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
