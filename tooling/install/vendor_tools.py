"""Opt-in interactive installation of external runtime and workflow tools via native curl installers."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from claude_install_ui import Ui

CLAUDE_INSTALL_CMD = "curl -fsSL https://claude.ai/install.sh | bash"
PI_INSTALL_CMD = "curl -fsSL https://pi.dev/install.sh | sh"
RTK_INSTALL_CMD = "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh"
CODEGRAPH_INSTALL_CMD = "curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh"
RTK_HOOK_CMD = "rtk init -g --hook-only --auto-patch"

RUNTIME_TOOLS: dict[str, tuple[tuple[str, str], ...]] = {
    "claude": (
        ("claude", CLAUDE_INSTALL_CMD),
        ("rtk", RTK_INSTALL_CMD),
        ("codegraph", CODEGRAPH_INSTALL_CMD),
    ),
    "pi": (
        ("pi", PI_INSTALL_CMD),
        ("rtk", RTK_INSTALL_CMD),
        ("codegraph", CODEGRAPH_INSTALL_CMD),
    ),
}


def local_bin_dir() -> Path:
    return Path.home() / ".local" / "bin"


def find_tool(name: str) -> str | None:
    """Locate a tool on PATH first, then in ~/.local/bin (where RTK and native scripts may install)."""
    found = shutil.which(name)
    if found is not None:
        return found
    candidate = local_bin_dir() / name
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    return None


def rtk_hook_configured(rtk_path: str) -> bool:
    """Return True when `rtk init --show` reports the Claude settings.json PreToolUse hook is configured."""
    try:
        result = subprocess.run(
            [rtk_path, "init", "--show"],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
            stdin=subprocess.DEVNULL,
            check=False,
        )
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return False
    if result.returncode != 0:
        return False
    output = result.stdout + "\n" + result.stderr
    return any(
        "[ok]" in line and "settings.json" in line and "RTK hooks configured" in line for line in output.splitlines()
    )


def _run_shell(command: str) -> int:
    result = subprocess.run(
        ["bash", "-o", "pipefail", "-c", command],
        stdin=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode


def _run_hook(rtk_path: str) -> int:
    result = subprocess.run(
        [rtk_path, "init", "-g", "--hook-only", "--auto-patch"],
        stdin=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode


def _warn_local_bin_if_needed(tools: list[str], warnings: list[str]) -> None:
    local_bin = local_bin_dir()
    path_entries = [os.path.realpath(entry) for entry in os.environ.get("PATH", "").split(os.pathsep) if entry]
    if os.path.realpath(local_bin) in path_entries:
        return
    off_path = [name for name in tools if shutil.which(name) is None and find_tool(name) is not None]
    if off_path:
        warnings.append(
            f"installed {', '.join(off_path)} into {local_bin}, which is not on PATH; add {local_bin} to PATH"
        )


def offer(runtime: str, ui: Ui) -> tuple[list[str], set[str]]:
    """Interactively offer native curl installs for missing tools (and RTK hook on Claude).

    Returns (warnings, installed_names). Never raises on declined, skipped, or failed vendor commands.
    """
    if runtime not in RUNTIME_TOOLS:
        raise ValueError(f"unsupported runtime for vendor tool prompts: {runtime!r}")
    if not ui.interactive:
        return [], set()

    warnings: list[str] = []
    installed: set[str] = set()
    missing_curl_tools = [(name, cmd) for name, cmd in RUNTIME_TOOLS[runtime] if find_tool(name) is None]
    skipped_for_curl: list[str] = []
    curl_path = shutil.which("curl") if missing_curl_tools else None

    if missing_curl_tools and curl_path is None:
        skipped_for_curl = [name for name, _ in missing_curl_tools]
        warnings.append(f"curl is not on PATH; skipped offering {', '.join(skipped_for_curl)}")
    else:
        for name, command in missing_curl_tools:
            try:
                if not ui.confirm(f"Install {name} ({command})?", default=False):
                    continue
                ui.step(f"Installing {name}", command)
                rc = _run_shell(command)
            except KeyboardInterrupt:
                warnings.append(f"{name} install cancelled")
                return warnings, installed
            except OSError as exc:
                warnings.append(f"could not run {name} install: {exc}")
                continue
            if rc != 0:
                warnings.append(f"{name} install exited with status {rc}")
                continue
            if find_tool(name) is not None:
                installed.add(name)

    if runtime == "claude":
        rtk_path = find_tool("rtk")
        if rtk_path is not None:
            try:
                if not rtk_hook_configured(rtk_path) and ui.confirm(
                    f"Configure RTK Claude Code hook ({RTK_HOOK_CMD})?", default=False
                ):
                    ui.step("Configuring RTK hook", RTK_HOOK_CMD)
                    rc = _run_hook(rtk_path)
                    if rc != 0:
                        warnings.append(f"rtk hook init exited with status {rc}")
                    else:
                        installed.add("rtk-hook")
            except KeyboardInterrupt:
                warnings.append("rtk hook init cancelled")
            except OSError as exc:
                warnings.append(f"could not run rtk hook init: {exc}")

    _warn_local_bin_if_needed([name for name, _ in RUNTIME_TOOLS[runtime] if name in installed], warnings)
    return warnings, installed
