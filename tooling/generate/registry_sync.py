#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import sys
import textwrap
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SKILL_REGISTRY_PATH = ROOT / "skills" / "registry.yaml"
KERNEL_TEMPLATE_PATH = ROOT / "references" / "kernel.template.md"
MCP_OPERATIONS_PATH = ROOT / "references" / "mcp_operations.yaml"

README_SKILLS_START = "<!-- generated:skills-table:start -->"
README_SKILLS_END = "<!-- generated:skills-table:end -->"
MCP_OPERATIONS_START = "<!-- generated:mcp-operations:start -->"
MCP_OPERATIONS_END = "<!-- generated:mcp-operations:end -->"
KERNEL_ROUTING_START = "<!-- generated:kernel-routing:start -->"
KERNEL_ROUTING_END = "<!-- generated:kernel-routing:end -->"

SKILL_SUPPORT_PATH_TOKEN = "{{skill_support_path}}"
TEMPLATE_TOKEN_RE = re.compile(r"\{\{[a-z0-9_]+\}\}")

PROMPT_FRONTMATTER_FIELDS = [
    ("argument_hint", "argument-hint"),
    ("when_to_use", "when_to_use"),
    ("user_invocable", "user-invocable"),
]
ALLOWED_PROMPT_KEYS = {"description", *[field for field, _ in PROMPT_FRONTMATTER_FIELDS]}


def load_json_subset_yaml(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(
            f"{path}: registry files must use the JSON-compatible YAML subset: {exc}"
        ) from exc


def ensure_string(value: object, label: str, errors: list[str]) -> str:
    if not isinstance(value, str) or not value:
        errors.append(f"{label}: expected non-empty string")
        return ""
    return value


def ensure_optional_string(value: object, label: str, errors: list[str]) -> None:
    if value is not None and (not isinstance(value, str) or not value):
        errors.append(f"{label}: expected non-empty string when present")


def apply_template_tokens(text: str, replacements: dict[str, str], source: Path) -> str:
    rendered = text
    for token, value in replacements.items():
        rendered = rendered.replace(token, value)

    unresolved = sorted(set(TEMPLATE_TOKEN_RE.findall(rendered)))
    if unresolved:
        raise SystemExit(f"{source}: unresolved template tokens: {', '.join(unresolved)}")
    return rendered


def load_skills() -> list[dict]:
    registry = load_json_subset_yaml(SKILL_REGISTRY_PATH)
    skills = registry.get("skills")
    if not isinstance(skills, list):
        raise SystemExit(f"{SKILL_REGISTRY_PATH}: missing skills array")
    return skills


def validate_kernel_template(errors: list[str]) -> None:
    if not KERNEL_TEMPLATE_PATH.exists():
        errors.append(f"{KERNEL_TEMPLATE_PATH}: missing Pi kernel template")
        return
    if TEMPLATE_TOKEN_RE.search(KERNEL_TEMPLATE_PATH.read_text()):
        errors.append(f"{KERNEL_TEMPLATE_PATH}: Pi kernel must not contain unresolved template placeholders")


def validate_skill_prompt_source(skill: dict, errors: list[str]) -> None:
    name = skill.get("name")
    if not isinstance(name, str) or not name:
        return

    prompt_meta = skill.get("prompt")
    label = f"skills[{name}].prompt"
    if not isinstance(prompt_meta, dict):
        errors.append(f"{label}: expected object")
    else:
        unexpected = sorted(set(prompt_meta) - ALLOWED_PROMPT_KEYS)
        if unexpected:
            errors.append(f"{label}: unexpected keys {unexpected}")
        ensure_string(prompt_meta.get("description"), f"{label}.description", errors)
        for field, _ in PROMPT_FRONTMATTER_FIELDS:
            ensure_optional_string(prompt_meta.get(field), f"{label}.{field}", errors)

    prompt_path = ROOT / "skills" / name / "prompt.md"
    if not prompt_path.exists():
        errors.append(f"{prompt_path}: missing canonical prompt source")
        return
    prompt_text = prompt_path.read_text()
    unresolved = sorted(
        token for token in set(TEMPLATE_TOKEN_RE.findall(prompt_text)) if token != SKILL_SUPPORT_PATH_TOKEN
    )
    if unresolved:
        errors.append(f"{prompt_path}: unexpected canonical prompt tokens {unresolved}")


def validate_skills(skills: list[dict]) -> list[str]:
    errors: list[str] = []
    validate_kernel_template(errors)
    skill_dirs = {path.parent.name for path in (ROOT / "skills").glob("*/prompt.md")}
    names: list[str] = []
    aliases: list[str] = []

    for index, skill in enumerate(skills, start=1):
        if not isinstance(skill, dict):
            errors.append(f"skills[{index}]: expected object")
            continue
        name = ensure_string(skill.get("name"), f"skills[{index}].name", errors)
        phase = ensure_string(skill.get("phase"), f"skills[{index}].phase", errors)
        use = ensure_string(skill.get("use"), f"skills[{index}].use", errors)
        command = skill.get("command")
        if not isinstance(command, dict):
            errors.append(f"skills[{index}].command: expected object")
            continue
        alias = ensure_string(command.get("alias"), f"skills[{index}].command.alias", errors)
        ensure_string(command.get("description"), f"skills[{index}].command.description", errors)
        if not isinstance(command.get("exposed"), bool):
            errors.append(f"skills[{index}].command.exposed: expected boolean")
        target = command.get("target", "request")
        if target not in {"request", "workflow"}:
            errors.append(f"skills[{index}].command.target: expected 'request' or 'workflow', found {target!r}")

        routing = skill.get("routing")
        if routing is not None:
            if not isinstance(routing, dict):
                errors.append(f"skills[{index}].routing: expected object or null")
            else:
                ensure_string(routing.get("intent"), f"skills[{index}].routing.intent", errors)
                triggers = routing.get("triggers")
                if not isinstance(triggers, list) or not triggers:
                    errors.append(f"skills[{index}].routing.triggers: expected non-empty array")
                else:
                    for trigger_index, trigger in enumerate(triggers, start=1):
                        ensure_string(trigger, f"skills[{index}].routing.triggers[{trigger_index}]", errors)

        validate_skill_prompt_source(skill, errors)
        if name:
            names.append(name)
        if alias and command.get("exposed"):
            aliases.append(alias)
        if name and alias and name != alias:
            errors.append(f"skills[{index}]: command.alias {alias!r} must match skill name {name!r}")
        if phase == "Ship" and routing is not None:
            errors.append(f"skills[{index}]: ship-only skills must omit routing metadata")
        if phase != "Ship" and routing is None:
            errors.append(f"skills[{index}]: non-ship skills must include routing metadata")
        if not use:
            errors.append(f"skills[{index}]: missing README/use summary")

    if len(names) != len(set(names)):
        errors.append("skills/registry.yaml: duplicate skill names")
    if len(aliases) != len(set(aliases)):
        errors.append("skills/registry.yaml: duplicate exposed command aliases")
    missing = sorted(skill_dirs - set(names))
    extra = sorted(set(names) - skill_dirs)
    if missing or extra:
        errors.append(
            "skills/registry.yaml: registry must match canonical skill prompt directories "
            f"(missing: {missing}, extra: {extra})"
        )
    return errors


def render_readme_skills_table(skills: list[dict]) -> str:
    lines = ["| Skill | Phase | Use |", "|---|---|---|"]
    lines.extend(f"| `{skill['name']}` | {skill['phase']} | {skill['use']} |" for skill in skills)
    return "\n".join(lines)


def render_mcp_operations_table(policy: dict) -> str:
    lines = ["| Class | Policy | Scope |", "|---|---|---|"]
    for class_name, meta in policy.get("classes", {}).items():
        record = meta if isinstance(meta, dict) else {}
        lines.append(f"| `{class_name}` | {record.get('policy', '')} | {record.get('notes', '')} |")
    return "\n".join(lines)


def render_routing(skills: list[dict]) -> str:
    lines: list[str] = []
    for skill in skills:
        routing = skill.get("routing")
        if isinstance(routing, dict):
            lines.append(f"- {routing['intent']} -> `{skill['name']}` (triggers: {', '.join(routing['triggers'])}).")
        elif skill["name"] == "b-summary":
            lines.append("- Commit or PR summary for staged changes -> `b-summary` only on explicit user request.")
    return "\n".join(lines)


def render_folded_yaml_block(key: str, value: str) -> list[str]:
    wrapper = textwrap.TextWrapper(width=74, initial_indent="  ", subsequent_indent="  ", break_long_words=False, break_on_hyphens=False)
    return [f"{key}: >", *wrapper.fill(value).splitlines()]


def render_skill_file(skill: dict) -> str:
    prompt_path = ROOT / "skills" / skill["name"] / "prompt.md"
    body = apply_template_tokens(prompt_path.read_text().rstrip() + "\n", {SKILL_SUPPORT_PATH_TOKEN: "."}, prompt_path).rstrip()
    lines = ["---", f"name: {skill['name']}"]
    lines.extend(render_folded_yaml_block("description", skill["prompt"]["description"]))
    for field, yaml_key in PROMPT_FRONTMATTER_FIELDS:
        if field in skill["prompt"]:
            lines.append(f"{yaml_key}: {json.dumps(skill['prompt'][field], ensure_ascii=False)}")
    lines.extend(["---", "", f"<!-- Generated from skills/registry.yaml and skills/{skill['name']}/prompt.md. Edit those sources, not this file. -->", "", body, ""])
    return "\n".join(lines)


def replace_block(text: str, start_marker: str, end_marker: str, body: str) -> str:
    try:
        start = text.index(start_marker) + len(start_marker)
        end = text.index(end_marker, start)
    except ValueError as exc:
        raise SystemExit(f"missing generated block markers: {start_marker} / {end_marker}") from exc
    return text[:start] + "\n" + body.rstrip() + "\n" + text[end:]


def render_outputs(skills: list[dict]) -> dict[Path, str]:
    outputs: dict[Path, str] = {}
    readme = ROOT / "README.md"
    outputs[readme] = replace_block(readme.read_text(), README_SKILLS_START, README_SKILLS_END, render_readme_skills_table(skills))

    kernel = KERNEL_TEMPLATE_PATH.read_text()
    kernel = replace_block(kernel, KERNEL_ROUTING_START, KERNEL_ROUTING_END, render_routing(skills))
    outputs[KERNEL_TEMPLATE_PATH] = replace_block(
        kernel, MCP_OPERATIONS_START, MCP_OPERATIONS_END, render_mcp_operations_table(load_json_subset_yaml(MCP_OPERATIONS_PATH))
    )
    for skill in skills:
        outputs[ROOT / "skills" / skill["name"] / "SKILL.md"] = render_skill_file(skill)
    return outputs


def sync_outputs(check: bool) -> int:
    skills = load_skills()
    errors = validate_skills(skills)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    dirty: list[str] = []
    for path, content in render_outputs(skills).items():
        if path.exists() and path.read_text() == content:
            continue
        dirty.append(str(path.relative_to(ROOT)))
        if not check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    if check and dirty:
        print("\n".join(f"generated output out of date: {path}" for path in dirty), file=sys.stderr)
        return 1
    if not check:
        print("Generated Pi suite outputs refreshed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Render generated Pi assets from canonical sources.")
    parser.add_argument("--check", action="store_true", help="fail if generated outputs are stale")
    return sync_outputs(parser.parse_args().check)


if __name__ == "__main__":
    sys.exit(main())
