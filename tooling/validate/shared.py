#!/usr/bin/env python3
"""Shared static checks for the Claude Code b-agentic delivery surface."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SETTINGS_HOOKS = (
    "b-path-guard.mjs",
    "b-codex-guard.mjs",
    "b-clickup-guard.mjs",
    "b-verify-gate.mjs",
)


def main() -> int:
    errors: list[str] = []
    for path in (
        ROOT / "skills" / "registry.yaml",
        ROOT / "references" / "mcp_operations.yaml",
        ROOT / "references" / "capabilities.yaml",
        ROOT / "claude" / "configs" / "mcp.base.json",
        ROOT / "claude" / "configs" / "mcp.clickup.json",
        ROOT / "claude" / "configs" / "settings.template.json",
    ):
        try:
            json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(f"{path.relative_to(ROOT)}: invalid JSON-compatible source: {exc}")

    kernel = ROOT / "references" / "kernel.template.md"
    text = kernel.read_text() if kernel.exists() else ""
    for marker in (
        "Claude Code Workflow Kernel",
        "reads the installed `skills/<name>/SKILL.md`",
        "`Agent` subagent type",
        "`AskUserQuestion`",
        "`mcp__<server>__<tool>`",
        "Track multi-step work in concise prose",
    ):
        if marker not in text:
            errors.append(f"references/kernel.template.md: missing Claude Code marker {marker!r}")

    registry = json.loads((ROOT / "skills" / "registry.yaml").read_text())
    for skill in registry.get("skills", []):
        name = skill.get("name") if isinstance(skill, dict) else None
        if not isinstance(name, str):
            errors.append("skills/registry.yaml: invalid skill name")
            continue
        generated = ROOT / "skills" / name / "SKILL.md"
        if not generated.exists() or "Generated from skills/registry.yaml" not in generated.read_text():
            errors.append(f"{generated.relative_to(ROOT)}: missing or not generated")

    bindings: dict[str, list[str]] = {}
    for skill in registry.get("skills", []):
        execution = skill.get("execution", {}) if isinstance(skill, dict) else {}
        if execution.get("mode") == "subagent":
            bindings.setdefault(execution.get("agent", ""), []).append(skill.get("name", ""))

    for name, skill_names in bindings.items():
        path = ROOT / "claude" / "agents" / f"{name}.md"
        body = path.read_text() if path.exists() else ""
        front_matter = body.split("\n---\n", 1)[0] if body.startswith("---\n") else ""
        tools_line = next((line for line in front_matter.splitlines() if line.startswith("tools: ")), "")
        tools = [tool.strip() for tool in tools_line.removeprefix("tools: ").split(",") if tool.strip()]
        if not tools:
            errors.append(f"{path.relative_to(ROOT)}: missing explicit tools allowlist")
        for tool in ("Read", "Grep", "Glob", "Bash"):
            if tool not in tools:
                errors.append(f"{path.relative_to(ROOT)}: tools must include {tool}")
        for tool in ("Edit", "Write", "NotebookEdit", "Agent", "Task"):
            if tool in tools:
                errors.append(f"{path.relative_to(ROOT)}: read-only specialist must not list {tool}")
        if f"name: {name}\n" not in front_matter:
            errors.append(f"{path.relative_to(ROOT)}: front matter name must be {name}")
        for marker in (
            "Remain read-only.",
            "Do not edit, write, commit, stage",
            "If the harness warns about your turn budget",
        ):
            if marker not in body:
                errors.append(f"{path.relative_to(ROOT)}: missing {marker!r}")
        if "Generated from skills/registry.yaml" not in body:
            errors.append(f"{path.relative_to(ROOT)}: missing generated marker")
        if "Managed by b-agentic" not in body:
            errors.append(f"{path.relative_to(ROOT)}: missing installer-managed marker")
        if "Read and execute the named skill" not in body or "Return that skill's own Output format" not in body:
            errors.append(f"{path.relative_to(ROOT)}: missing named-skill output contract")
        if "Do not execute external/shared mutation, local upload, lifecycle, or authentication actions" not in body:
            errors.append(f"{path.relative_to(ROOT)}: missing consequential-operation boundary")
        for skill_name in skill_names:
            if f"`{skill_name}`" not in body:
                errors.append(f"{path.relative_to(ROOT)}: missing binding for {skill_name}")

    hooks = json.loads((ROOT / "claude" / "configs" / "settings.template.json").read_text()).get("hooks", {})
    commands = {
        hook.get("command", "") for entries in hooks.values() for entry in entries for hook in entry.get("hooks", [])
    }
    for script in SETTINGS_HOOKS:
        if not (ROOT / "claude" / "hooks" / script).is_file():
            errors.append(f"claude/hooks/{script}: missing hook script")
        if not any(command.endswith(f'/{script}"') for command in commands):
            errors.append(f"claude/configs/settings.template.json: no hook runs {script}")
    for script in ("b-candidate-snapshot.mjs", "b-codex-verdict.mjs", "b-codex-review.mjs"):
        if not (ROOT / "claude" / "bin" / script).is_file():
            errors.append(f"claude/bin/{script}: missing CLI")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Claude Code shared validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
