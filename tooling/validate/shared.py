#!/usr/bin/env python3
"""Shared static checks for the native Pi b-agentic delivery surface."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    errors: list[str] = []
    for path in (
        ROOT / "skills" / "registry.yaml",
        ROOT / "references" / "mcp_operations.yaml",
        ROOT / "references" / "capabilities.yaml",
        ROOT / "pi" / "configs" / "mcp.base.json",
        ROOT / "pi" / "configs" / "settings.base.json",
        ROOT / "pi" / "configs" / "permission.user.template.json",
    ):
        try:
            json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(f"{path.relative_to(ROOT)}: invalid JSON-compatible source: {exc}")

    kernel = ROOT / "references" / "kernel.template.md"
    text = kernel.read_text() if kernel.exists() else ""
    for marker in (
        "Pi Workflow Kernel",
        "reads the installed `skills/<name>/SKILL.md`",
        "Pi `subagent` type",
        "`ask_user_question`",
        "direct `<server>_<tool>` names",
        "Track multi-step work in concise prose",
    ):
        if marker not in text:
            errors.append(f"references/kernel.template.md: missing native Pi marker {marker!r}")

    registry = json.loads((ROOT / "skills" / "registry.yaml").read_text())
    agents = registry.get("agents", {})
    if not isinstance(agents, dict):
        errors.append("skills/registry.yaml: missing generated agent definitions")
        agents = {}
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
        path = ROOT / "pi" / "agents" / f"{name}.md"
        body = path.read_text() if path.exists() else ""
        for marker in (
            "tools: read, grep, find, ls, bash",
            "permission:",
            '  "*": deny',
            "  external_directory: deny",
            "  mcp:",
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

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Native Pi shared validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
