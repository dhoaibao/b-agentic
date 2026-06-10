from __future__ import annotations

from dataclasses import dataclass
import re
import shlex
from typing import Any


RiskClass = str

READ_ONLY: RiskClass = "read-only"
PROJECT_WRITE: RiskClass = "project-write"
DEPENDENCY_WRITE: RiskClass = "dependency-write"
ENVIRONMENT_WRITE: RiskClass = "environment-write"
EXTERNAL_WRITE: RiskClass = "external-write"
DESTRUCTIVE: RiskClass = "destructive"
UNKNOWN: RiskClass = "unknown"

HIGH_RISK = {PROJECT_WRITE, DEPENDENCY_WRITE, ENVIRONMENT_WRITE, EXTERNAL_WRITE, DESTRUCTIVE}
APPROVAL_REQUIRED = {DEPENDENCY_WRITE, ENVIRONMENT_WRITE, EXTERNAL_WRITE, DESTRUCTIVE}

READ_ONLY_TOOLS = {
    "read",
    "glob",
    "grep",
    "webfetch",
    "serena_find_symbol",
    "serena_get_symbols_overview",
    "serena_find_referencing_symbols",
    "serena_get_diagnostics_for_file",
}

PROJECT_WRITE_TOOLS = {
    "apply_patch",
    "edit",
    "write",
    "serena_replace_content",
    "serena_replace_symbol_body",
    "serena_insert_after_symbol",
    "serena_insert_before_symbol",
    "serena_rename_symbol",
    "serena_safe_delete_symbol",
}

DESTRUCTIVE_RE = re.compile(
    r"(^|\s)(rm\s+-\S+|git\s+reset\s+--hard|git\s+clean\s+-f|git\s+branch\s+-D|"
    r"git\s+push\s+--force|drop\s+database|truncate\s+table)(\s|$)",
    re.IGNORECASE,
)
DEPENDENCY_RE = re.compile(
    r"(^|\s)(npm|pnpm|yarn|bun|cargo|go|pip|poetry|uv)\s+"
    r"(install|add|remove|update|upgrade|sync|dlx)(\s|$)",
    re.IGNORECASE,
)
ENVIRONMENT_RE = re.compile(
    r"(^|\s)(docker|docker-compose|podman|kubectl|terraform|make)\s+"
    r"(up|run|start|apply|deploy|serve|dev)(\s|$)",
    re.IGNORECASE,
)
EXTERNAL_RE = re.compile(
    r"(^|\s)(gh\s+(pr\s+create|pr\s+merge|release|api)|vercel|netlify|flyctl|aws|gcloud|az)\b",
    re.IGNORECASE,
)
READ_ONLY_RE = re.compile(
    r"^([A-Za-z_][A-Za-z0-9_=-]*\s+)*(git\s+(status|diff|log|show|rev-parse)|"
    r"rg|grep|fd|find|ls|pwd|python3?\s+-m\s+py_compile|pytest|ruff|mypy|tsc)(\s|$)",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class Action:
    tool: str
    risk: RiskClass
    command: str | None = None
    files: tuple[str, ...] = ()
    reason: str = ""


def _payload_value(payload: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key in payload:
            return payload[key]
    for value in payload.values():
        if isinstance(value, dict):
            found = _payload_value(value, *keys)
            if found is not None:
                return found
    return None


def _string_list(value: Any) -> tuple[str, ...]:
    if isinstance(value, str) and value:
        return (value,)
    if isinstance(value, list):
        return tuple(item for item in value if isinstance(item, str) and item)
    return ()


def _shell_risk(command: str) -> tuple[RiskClass, str]:
    stripped = command.strip()
    if not stripped:
        return UNKNOWN, "empty shell command"
    if DESTRUCTIVE_RE.search(stripped):
        return DESTRUCTIVE, "destructive shell command"
    if DEPENDENCY_RE.search(stripped):
        return DEPENDENCY_WRITE, "dependency-changing shell command"
    if ENVIRONMENT_RE.search(stripped):
        return ENVIRONMENT_WRITE, "environment-mutating shell command"
    if EXTERNAL_RE.search(stripped):
        return EXTERNAL_WRITE, "external-write shell command"
    if READ_ONLY_RE.search(stripped):
        return READ_ONLY, "read-only shell command"

    try:
        parts = shlex.split(stripped)
    except ValueError:
        return UNKNOWN, "unparseable shell command"
    if parts and parts[0] in {"python", "python3", "node", "bash", "sh", "zsh"}:
        return UNKNOWN, "arbitrary code shell command"
    return UNKNOWN, "unclassified shell command"


def derive_intent_from_action(action: Action, active_skill: str | None = None) -> dict[str, str]:
    """Derive an intent record from a classified action.

    Returns a dict with the same fields as an [intent] block.
    Project-write actions are auto-approved (source of truth already authorizes).
    All other high-risk actions get approval: pending (hook will block until
    explicit approval is recorded or a manual [intent] with approval: approved
    is emitted).
    """
    files_value = ",".join(action.files) if action.files else "none"
    commands_value = action.command if action.command else "none"
    approval = "not-required" if action.risk == PROJECT_WRITE else "pending"
    return {
        "skill": active_skill or "unknown",
        "action": action.risk,
        "files": files_value,
        "commands": commands_value,
        "source": "auto-derived",
        "approval": approval,
        "reason": f"auto-derived from {action.tool} payload",
    }


def classify_action(payload: dict[str, Any]) -> Action:
    tool_value = _payload_value(payload, "tool", "tool_name", "toolName", "name")
    tool = str(tool_value or "unknown")
    normalized_tool = tool.replace("functions.", "").split("__")[-1]
    command_value = _payload_value(payload, "command", "cmd", "shell_command")
    command = str(command_value) if isinstance(command_value, str) else None
    files = _string_list(_payload_value(payload, "file", "files", "filePath", "path", "paths"))

    if normalized_tool.lower() in {"bash", "shell"} or command:
        risk, reason = _shell_risk(command or "")
        return Action(tool=normalized_tool, risk=risk, command=command, files=files, reason=reason)

    lowered = normalized_tool.lower()
    if lowered in READ_ONLY_TOOLS:
        return Action(tool=normalized_tool, risk=READ_ONLY, files=files, reason="read-only tool")
    if lowered in PROJECT_WRITE_TOOLS:
        return Action(tool=normalized_tool, risk=PROJECT_WRITE, files=files, reason="project-write tool")
    if "delete" in lowered or "remove" in lowered:
        return Action(tool=normalized_tool, risk=DESTRUCTIVE, files=files, reason="destructive tool name")
    if "write" in lowered or "edit" in lowered or "patch" in lowered:
        return Action(tool=normalized_tool, risk=PROJECT_WRITE, files=files, reason="mutating tool name")

    return Action(tool=normalized_tool, risk=UNKNOWN, files=files, reason="unclassified tool")
