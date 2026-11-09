"""Optional b-agentic components: skills and MCP servers installed only after an explicit choice.

`skills/registry.yaml` owns the `optional_components` object. Generated skills, agents, templates, and
kernels stay complete; the installers filter them with the helpers here. Standard library only.

Deselecting removes a component's skill, kernel routing line, MCP server entry, and `allow` permission rules.
Its `ask` and `deny` rules stay, so a server that is still configured never loses its approval prompts.
Installed skills also drop any line ending in ` <!-- requires: b-x -->` whose named skill was not installed,
so a skill never sends the user to an absent sibling. A full install keeps those lines byte for byte.

Selection precedence per component: an explicit `--with`/`--without` flag, then the value recorded in the
install manifest, then (for a manifest that predates this feature) what the manifest already owns, then
unselected.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

COMPONENT_ID = re.compile(r"^[a-z][a-z0-9-]*$")
ROUTING_START = "<!-- generated:kernel-routing:start -->"
ROUTING_END = "<!-- generated:kernel-routing:end -->"
ROUTING_LINE = re.compile(r"^- .* -> `(b-[a-z0-9-]+)`.*\.$")
REQUIRES_MARKER = re.compile(r" <!-- requires: (b-[a-z0-9-]+(?:, b-[a-z0-9-]+)*) -->$")


def load(source: Path) -> dict[str, dict[str, Any]]:
    """The registry's optional components, validated for shape; empty when the registry declares none."""
    registry = json.loads((source / "skills" / "registry.yaml").read_text())
    components = registry.get("optional_components", {})
    if not isinstance(components, dict):
        raise ValueError("registry optional_components must be an object")
    for key, value in components.items():
        if not COMPONENT_ID.fullmatch(key) or not isinstance(value, dict):
            raise ValueError(f"registry optional component {key!r} is malformed")
        if not isinstance(value.get("label"), str):
            raise ValueError(f"registry optional component {key!r} needs a string label")
        for field in ("skills", "mcp_servers"):
            names = value.get(field, [])
            if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
                raise ValueError(f"registry optional component {key!r}: {field} must be a list of strings")
    return components


def parse_ids(values: list[str], known: dict[str, Any], flag: str) -> list[str]:
    """Split repeated comma-separated flag values and reject unknown ids."""
    ids: list[str] = []
    for value in values:
        for item in value.split(","):
            item = item.strip()
            if not item:
                raise ValueError(f"{flag} has an empty component id")
            if item not in known:
                valid = ", ".join(sorted(known)) or "none defined"
                raise ValueError(f"unknown optional component {item!r} for {flag}; valid ids: {valid}")
            if item not in ids:
                ids.append(item)
    return ids


def infer_legacy(manifest: dict[str, Any], components: dict[str, dict[str, Any]]) -> dict[str, bool]:
    """For a manifest without a recorded choice: a component counts as selected when it already owns one."""
    owned_files = set(manifest.get("files", {})) | set(manifest.get("pending", {}).get("files", {}))
    owned_servers = set(manifest.get("mcp", {}).get("servers", {})) | set(
        manifest.get("pending", {}).get("mcp_servers", {})
    )
    result: dict[str, bool] = {}
    for key, component in components.items():
        has_skill = any(f"skills/{name}/SKILL.md" in owned_files for name in component.get("skills", []))
        has_server = any(name in owned_servers for name in component.get("mcp_servers", []))
        result[key] = has_skill or has_server
    return result


def resolve(
    components: dict[str, dict[str, Any]],
    manifest: dict[str, Any],
    with_ids: list[str],
    without_ids: list[str],
) -> dict[str, bool]:
    overlap = sorted(set(with_ids) & set(without_ids))
    if overlap:
        raise ValueError(f"--with and --without both name: {', '.join(overlap)}")
    recorded = manifest.get("optional_components")
    base = infer_legacy(manifest, components) if not isinstance(recorded, dict) else {}
    selection: dict[str, bool] = {}
    for key in components:
        if key in with_ids:
            selection[key] = True
        elif key in without_ids:
            selection[key] = False
        elif isinstance(recorded, dict):
            selection[key] = bool(recorded.get(key, False))
        else:
            selection[key] = base[key]
    return selection


def excluded_skills(components: dict[str, dict[str, Any]], selection: dict[str, bool]) -> set[str]:
    return {name for key, c in components.items() if not selection.get(key) for name in c.get("skills", [])}


def excluded_servers(components: dict[str, dict[str, Any]], selection: dict[str, bool]) -> set[str]:
    return {name for key, c in components.items() if not selection.get(key) for name in c.get("mcp_servers", [])}


def summary(components: dict[str, dict[str, Any]], selection: dict[str, bool]) -> str:
    return ", ".join(f"{key} {'on' if selection.get(key) else 'off'}" for key in components)


def filter_kernel(text: str, skills: set[str]) -> str:
    """Drop the routing lines of the excluded skills; exactly one line per skill must exist."""
    if not skills:
        return text
    lines = text.split("\n")
    try:
        start = lines.index(ROUTING_START)
        end = lines.index(ROUTING_END)
    except ValueError as exc:
        raise ValueError("the kernel has no generated routing block to filter") from exc
    kept: list[str] = []
    dropped: dict[str, int] = {}
    for line in lines[start + 1 : end]:
        match = ROUTING_LINE.match(line)
        if match and match.group(1) in skills:
            dropped[match.group(1)] = dropped.get(match.group(1), 0) + 1
            continue
        kept.append(line)
    missing = sorted(name for name in skills if dropped.get(name) != 1)
    if missing:
        raise ValueError(f"expected exactly one kernel routing line for: {', '.join(missing)}")
    return "\n".join([*lines[: start + 1], *kept, *lines[end:]])


def optional_skills(components: dict[str, dict[str, Any]]) -> set[str]:
    return {name for c in components.values() for name in c.get("skills", [])}


def filter_skill(text: str, excluded: set[str], optional: set[str]) -> str:
    """Drop skill-body lines marked `<!-- requires: b-x -->` when a named skill is excluded; keep the rest
    byte for byte. A marker naming a skill that is not an optional component's skill is rejected."""
    kept: list[str] = []
    for line in text.split("\n"):
        match = REQUIRES_MARKER.search(line)
        if match:
            names = set(match.group(1).split(", "))
            unknown = sorted(names - optional)
            if unknown:
                raise ValueError(f"skill marker names a skill that is not optional: {', '.join(unknown)}")
            if names & excluded:
                continue
        kept.append(line)
    return "\n".join(kept)


def filter_claude_rules(rules: list[str], servers: set[str], kind: str) -> list[str]:
    """Drop only the `allow` rules of excluded servers. `ask` and `deny` rules stay: a server b-agentic does
    not install (DataGrip) or keeps because the user edited it must keep prompting for its writes."""
    if kind != "allow":
        return list(rules)
    prefixes = tuple(f"mcp__{name}__" for name in servers)
    return [rule for rule in rules if not (isinstance(rule, str) and rule.startswith(prefixes))]


def filter_opencode_rules(rules: list[dict[str, Any]], servers: set[str]) -> list[dict[str, Any]]:
    """Drop only the `allow` rules of excluded servers; their `ask` and `deny` rules stay (see above)."""
    prefixes = tuple(f"{name}_" for name in servers)
    return [
        rule
        for rule in rules
        if not (rule.get("effect") == "allow" and str(rule.get("action", "")).startswith(prefixes))
    ]
