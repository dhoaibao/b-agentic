#!/usr/bin/env python3
"""Claude Code hook guard for high-risk Bash commands.

The hook reads Claude Code hook JSON from stdin. It denies clearly destructive
commands and asks for user approval on dependency, commit, and production-like
mutations. SessionStart emits a short context note so Claude knows the managed
governance hooks are active.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys


DENY_PATTERNS = [
    (r"\b(?:mkfs|dd)\b", "disk-level commands are outside normal coding workflow"),
]

ASK_PATTERNS = [
    (r"\bgit\s+reset\s+--hard\b", "git reset --hard would discard worktree state"),
    (r"\bgit\s+clean\s+-[^\n]*[fd]", "git clean with file or directory deletion is destructive"),
    (r"\bgit\s+checkout\s+--\b", "git checkout -- can discard unrelated user changes"),
    (r"\bgit\s+restore\b.*(?:--source|--worktree|--staged|\s\.)", "git restore can discard unrelated user changes"),
    (r"\bgit\s+push\b.*--force(?:-with-lease)?\b", "force push requires explicit approval"),
    (r"\bfind\b.*\s-delete\b", "find -delete can remove broad file sets"),
    (r"\b(?:npm|pnpm|yarn|bun)\s+(?:install|add|remove|update|upgrade|uninstall)\b", "dependency mutation requires approval"),
    (r"\b(?:pip|pip3|uv|poetry|pipenv)\s+(?:install|add|remove|sync|update)\b", "Python dependency mutation requires approval"),
    (r"\b(?:cargo|go|gem|bundle|composer)\s+(?:add|get|install|update|remove|require)\b", "dependency mutation requires approval"),
    (r"\b(?:apt|apt-get|apk|dnf|yum|brew)\s+(?:install|remove|upgrade|update)\b", "system package mutation requires approval"),
    (r"\bgit\s+(?:commit|tag|push|rebase|merge|cherry-pick)\b", "git history or remote mutation requires approval"),
    (r"\b(?:npm|pnpm|yarn|bun)\s+publish\b", "package publishing requires approval"),
    (r"\b(?:docker|podman)\s+push\b", "image publishing requires approval"),
    (r"\b(?:kubectl|helm)\s+(?:apply|delete|scale|rollout|upgrade|install)\b", "cluster mutation requires approval"),
    (r"\b(?:terraform|tofu)\s+(?:apply|destroy|import|state)\b", "infrastructure mutation requires approval"),
    (r"\b(?:aws|gcloud|az|doctl|fly|railway|vercel|wrangler|supabase)\b.*\b(?:deploy|delete|destroy|apply|publish|promote|prod|production)\b", "production-like external mutation requires approval"),
    (r"\b(?:sed|perl)\b.*\s-i(?:\s|$)", "bulk in-place rewrite requires approval"),
]

SHELL_OPERATORS = {"&&", "||", ";", "|"}


def split_command(command: str) -> list[str]:
    try:
        return shlex.split(command, posix=True)
    except ValueError:
        return command.split()


def is_dangerous_rm_target(token: str) -> bool:
    target = token.strip().strip("'\"")
    root_targets = {"/", "/.", "/.."}
    home_targets = {"~", "$HOME", "${HOME}"}
    return target in root_targets or target in home_targets or target.startswith(("/*", "/.*", "~/", "$HOME/", "${HOME", "$HOME"))


def is_rm_command(token: str) -> bool:
    return os.path.basename(token) == "rm"


def has_dangerous_recursive_rm(command: str) -> bool:
    tokens = split_command(command)
    for index, token in enumerate(tokens):
        if token in {"command", "builtin"}:
            continue
        if not is_rm_command(token):
            continue
        recursive = False
        for arg in tokens[index + 1 :]:
            if arg in SHELL_OPERATORS:
                break
            if arg == "--":
                continue
            if arg.startswith("-") and arg != "-":
                flags = arg.lstrip("-")
                recursive = recursive or "r" in flags or "R" in flags
                continue
            if recursive and is_dangerous_rm_target(arg):
                return True
    return False


def emit_decision(event_name: str, decision: str, reason: str) -> None:
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": event_name,
                    "permissionDecision": decision,
                    "permissionDecisionReason": reason,
                }
            }
        )
    )


def get_event_name(payload: dict) -> str:
    return str(payload.get("hook_event_name") or payload.get("hookEventName") or "PreToolUse")


def get_command(payload: dict) -> str:
    tool_input = payload.get("tool_input") or payload.get("toolInput") or payload.get("input") or {}
    if not isinstance(tool_input, dict):
        return ""
    command = tool_input.get("command")
    return command if isinstance(command, str) else ""


def classify(command: str) -> tuple[str | None, str | None]:
    normalized = re.sub(r"\s+", " ", command.strip())
    if has_dangerous_recursive_rm(normalized):
        return "deny", "recursive removal of root, home, or HOME is destructive"
    for pattern, reason in DENY_PATTERNS:
        if re.search(pattern, normalized):
            return "deny", reason
    for pattern, reason in ASK_PATTERNS:
        if re.search(pattern, normalized):
            return "ask", reason
    return None, None


def main() -> int:
    if "--session-start" in sys.argv:
        print("b-skills governance hooks active: risky Bash mutations are denied or approval-gated.")
        return 0

    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0

    command = get_command(payload)
    if not command:
        return 0

    decision, reason = classify(command)
    if decision and reason:
        emit_decision(get_event_name(payload), decision, reason)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
