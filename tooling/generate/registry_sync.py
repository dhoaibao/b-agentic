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
RUNTIME_REGISTRY_PATH = ROOT / "runtimes" / "registry.yaml"
KERNEL_TEMPLATE_PATH = ROOT / "references" / "contract" / "kernel.template.md"

README_SKILLS_START = "<!-- generated:skills-table:start -->"
README_SKILLS_END = "<!-- generated:skills-table:end -->"
README_RUNTIME_CAPABILITIES_START = "<!-- generated:runtime-capabilities:start -->"
README_RUNTIME_CAPABILITIES_END = "<!-- generated:runtime-capabilities:end -->"
ROUTING_INTENTS_START = "<!-- generated:routing-intents:start -->"
ROUTING_INTENTS_END = "<!-- generated:routing-intents:end -->"
ROUTING_TRIGGERS_START = "<!-- generated:routing-triggers:start -->"
ROUTING_TRIGGERS_END = "<!-- generated:routing-triggers:end -->"

SKILL_SUPPORT_PATH_TOKEN = "{{skill_support_path}}"
RUNTIME_REFERENCE_ROOT_TOKEN = "{{runtime_reference_root}}"
RUNTIME_DISPLAY_NAME_TOKEN = "{{runtime_display_name}}"
RUNTIME_METADATA_ROOT_TOKEN = "{{runtime_metadata_root}}"
RUNTIME_MEMORY_FILE_TOKEN = "{{runtime_memory_file}}"
RUNTIME_ENFORCEMENT_NOTICE_TOKEN = "{{runtime_enforcement_notice}}"
RENDERED_SKILL_SUPPORT_PATH = "."
RENDERED_RUNTIME_REFERENCE_ROOT = "../../b-agentic/references"
TEMPLATE_TOKEN_RE = re.compile(r"\{\{[a-z0-9_]+\}\}")

PROMPT_FRONTMATTER_FIELDS = [
    ("argument_hint", "argument-hint"),
    ("when_to_use", "when_to_use"),
    ("user_invocable", "user-invocable"),
    ("context", "context"),
    ("agent", "agent"),
    ("paths", "paths"),
    ("shell", "shell"),
]
ALLOWED_PROMPT_KEYS = {"description", *[field for field, _ in PROMPT_FRONTMATTER_FIELDS]}
RUNTIME_CAPABILITY_KEYS = [
    "skills",
    "permissions",
    "hooks",
    "rules",
    "subagents",
    "plugins",
    "command_wrappers",
    "custom_tools",
]
RUNTIME_CAPABILITY_SUPPORT = {"native", "adapter", "unsupported"}
RUNTIME_CAPABILITY_ADOPTION = {"shared", "adapter-only", "deferred", "unsupported"}


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
    if value is None:
        return
    if not isinstance(value, str) or not value:
        errors.append(f"{label}: expected non-empty string when present")


def load_registries() -> tuple[list[dict], list[dict]]:
    skill_registry = load_json_subset_yaml(SKILL_REGISTRY_PATH)
    runtime_registry = load_json_subset_yaml(RUNTIME_REGISTRY_PATH)

    skills = skill_registry.get("skills")
    runtimes = runtime_registry.get("runtimes")
    if not isinstance(skills, list):
        raise SystemExit(f"{SKILL_REGISTRY_PATH}: missing skills array")
    if not isinstance(runtimes, list):
        raise SystemExit(f"{RUNTIME_REGISTRY_PATH}: missing runtimes array")
    return skills, runtimes


def apply_template_tokens(text: str, replacements: dict[str, str], source: Path) -> str:
    rendered = text
    for token, value in replacements.items():
        rendered = rendered.replace(token, value)

    unresolved = sorted(set(TEMPLATE_TOKEN_RE.findall(rendered)))
    if unresolved:
        token_list = ", ".join(unresolved)
        raise SystemExit(f"{source}: unresolved template tokens: {token_list}")
    return rendered


def validate_kernel_template(errors: list[str]) -> None:
    if not KERNEL_TEMPLATE_PATH.exists():
        errors.append(f"{KERNEL_TEMPLATE_PATH}: missing shared kernel template")
        return

    template_text = KERNEL_TEMPLATE_PATH.read_text()
    for token in [
        RUNTIME_DISPLAY_NAME_TOKEN,
        RUNTIME_METADATA_ROOT_TOKEN,
        RUNTIME_MEMORY_FILE_TOKEN,
    ]:
        if token not in template_text:
            errors.append(f"{KERNEL_TEMPLATE_PATH}: missing kernel template token {token!r}")

    if "CLAUDE.md" in template_text or "AGENTS.md" in template_text:
        errors.append(
            f"{KERNEL_TEMPLATE_PATH}: canonical kernel template must use {RUNTIME_MEMORY_FILE_TOKEN}, not a runtime-specific memory file"
        )
    if "~/.claude/b-agentic" in template_text or "~/.config/opencode/b-agentic" in template_text:
        errors.append(
            f"{KERNEL_TEMPLATE_PATH}: canonical kernel template must use {RUNTIME_METADATA_ROOT_TOKEN}, not a runtime-specific metadata root"
        )
    if "${CLAUDE_SKILL_DIR}" in template_text:
        errors.append(f"{KERNEL_TEMPLATE_PATH}: canonical kernel template must not use ${{CLAUDE_SKILL_DIR}}")


def validate_skill_prompt_source(skill: dict, errors: list[str]) -> None:
    name = skill.get("name")
    if not isinstance(name, str) or not name:
        return

    prompt_meta = skill.get("prompt")
    prompt_label = f"skills[{name}].prompt"
    if not isinstance(prompt_meta, dict):
        errors.append(f"{prompt_label}: expected object")
    else:
        unexpected = sorted(set(prompt_meta) - ALLOWED_PROMPT_KEYS)
        if unexpected:
            errors.append(f"{prompt_label}: unexpected keys {unexpected}")
        ensure_string(prompt_meta.get("description"), f"{prompt_label}.description", errors)
        for field, _ in PROMPT_FRONTMATTER_FIELDS:
            ensure_optional_string(prompt_meta.get(field), f"{prompt_label}.{field}", errors)

    prompt_path = ROOT / "skills" / name / "prompt.md"
    if not prompt_path.exists():
        errors.append(f"{prompt_path}: missing canonical prompt source")
        return

    prompt_text = prompt_path.read_text()
    if "${CLAUDE_SKILL_DIR}" in prompt_text:
        errors.append(
            f"{prompt_path}: canonical prompt must use {SKILL_SUPPORT_PATH_TOKEN} instead of ${{CLAUDE_SKILL_DIR}}"
        )

    unresolved = sorted(
        token
        for token in set(TEMPLATE_TOKEN_RE.findall(prompt_text))
        if token not in {SKILL_SUPPORT_PATH_TOKEN, RUNTIME_REFERENCE_ROOT_TOKEN}
    )
    if unresolved:
        errors.append(f"{prompt_path}: unexpected canonical prompt tokens {unresolved}")


def validate_registries(skills: list[dict], runtimes: list[dict]) -> list[str]:
    errors: list[str] = []
    skill_dirs = {path.parent.name for path in (ROOT / "skills").glob("*/prompt.md")}
    runtime_dirs = {path.name for path in (ROOT / "runtimes").glob("*/")}

    validate_kernel_template(errors)

    registry_skill_names: list[str] = []
    command_aliases: list[str] = []
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
        description = ensure_string(
            command.get("description"), f"skills[{index}].command.description", errors
        )
        exposed = command.get("exposed")
        if not isinstance(exposed, bool):
            errors.append(f"skills[{index}].command.exposed: expected boolean")
        target = command.get("target", "request")
        if target not in {"request", "workflow"}:
            errors.append(
                f"skills[{index}].command.target: expected 'request' or 'workflow', found {target!r}"
            )

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
                        ensure_string(
                            trigger,
                            f"skills[{index}].routing.triggers[{trigger_index}]",
                            errors,
                        )

        validate_skill_prompt_source(skill, errors)

        if name:
            registry_skill_names.append(name)
        if alias and exposed is True:
            command_aliases.append(alias)
        if not description:
            errors.append(f"skills[{index}]: missing command description")

        if name and alias and alias != name:
            errors.append(
                f"skills[{index}]: command.alias {alias!r} must match skill name {name!r} in phase 1"
            )

        if phase == "Ship" and routing is not None:
            errors.append(f"skills[{index}]: ship-only skills must omit routing metadata in phase 1")
        if phase != "Ship" and routing is None:
            errors.append(f"skills[{index}]: non-ship skills must include routing metadata")
        if not use:
            errors.append(f"skills[{index}]: missing README/use summary")

    if len(registry_skill_names) != len(set(registry_skill_names)):
        errors.append("skills/registry.yaml: duplicate skill names")
    if len(command_aliases) != len(set(command_aliases)):
        errors.append("skills/registry.yaml: duplicate exposed command aliases")

    missing_skill_entries = sorted(skill_dirs - set(registry_skill_names))
    extra_skill_entries = sorted(set(registry_skill_names) - skill_dirs)
    if missing_skill_entries or extra_skill_entries:
        errors.append(
            "skills/registry.yaml: registry must match canonical skill prompt directories "
            f"(missing: {missing_skill_entries}, extra: {extra_skill_entries})"
        )

    registry_runtime_names: list[str] = []
    reference_runtime_count = 0
    reference_capabilities: dict[str, dict] | None = None
    for index, runtime in enumerate(runtimes, start=1):
        if not isinstance(runtime, dict):
            errors.append(f"runtimes[{index}]: expected object")
            continue

        name = ensure_string(runtime.get("name"), f"runtimes[{index}].name", errors)
        ensure_string(runtime.get("display_name"), f"runtimes[{index}].display_name", errors)
        ensure_string(runtime.get("kernel_source"), f"runtimes[{index}].kernel_source", errors)
        ensure_string(runtime.get("memory_file"), f"runtimes[{index}].memory_file", errors)
        ensure_string(runtime.get("memory_install_path"), f"runtimes[{index}].memory_install_path", errors)
        ensure_string(runtime.get("metadata_root"), f"runtimes[{index}].metadata_root", errors)
        ensure_string(runtime.get("skills_install_root"), f"runtimes[{index}].skills_install_root", errors)
        ensure_string(runtime.get("config_template_dir"), f"runtimes[{index}].config_template_dir", errors)
        ensure_string(runtime.get("config_schema_family"), f"runtimes[{index}].config_schema_family", errors)

        reference_runtime = runtime.get("reference_runtime")
        if not isinstance(reference_runtime, bool):
            errors.append(f"runtimes[{index}].reference_runtime: expected boolean")
        elif reference_runtime:
            reference_runtime_count += 1

        capabilities = runtime.get("capabilities")
        if not isinstance(capabilities, dict):
            errors.append(f"runtimes[{index}].capabilities: expected object")
        else:
            missing_capabilities = sorted(set(RUNTIME_CAPABILITY_KEYS) - set(capabilities))
            extra_capabilities = sorted(set(capabilities) - set(RUNTIME_CAPABILITY_KEYS))
            if missing_capabilities or extra_capabilities:
                errors.append(
                    f"runtimes[{index}].capabilities: keys must match {RUNTIME_CAPABILITY_KEYS} "
                    f"(missing: {missing_capabilities}, extra: {extra_capabilities})"
                )
            for capability in RUNTIME_CAPABILITY_KEYS:
                capability_record = capabilities.get(capability)
                if not isinstance(capability_record, dict):
                    errors.append(f"runtimes[{index}].capabilities.{capability}: expected object")
                    continue
                support = capability_record.get("support")
                adoption = capability_record.get("adoption")
                if support not in RUNTIME_CAPABILITY_SUPPORT:
                    errors.append(
                        f"runtimes[{index}].capabilities.{capability}.support: "
                        f"expected one of {sorted(RUNTIME_CAPABILITY_SUPPORT)}, found {support!r}"
                    )
                if adoption not in RUNTIME_CAPABILITY_ADOPTION:
                    errors.append(
                        f"runtimes[{index}].capabilities.{capability}.adoption: "
                        f"expected one of {sorted(RUNTIME_CAPABILITY_ADOPTION)}, found {adoption!r}"
                    )
                if support == "unsupported" and adoption != "unsupported":
                    errors.append(
                        f"runtimes[{index}].capabilities.{capability}: unsupported capabilities "
                        "must use adoption 'unsupported'"
                    )
                if support != "unsupported" and adoption == "unsupported":
                    errors.append(
                        f"runtimes[{index}].capabilities.{capability}: supported capabilities "
                        "must not use adoption 'unsupported'"
                    )
            if reference_runtime is True:
                reference_capabilities = capabilities

        command_wrappers = runtime.get("command_wrappers")
        if not isinstance(command_wrappers, dict):
            errors.append(f"runtimes[{index}].command_wrappers: expected object")
        else:
            supported = command_wrappers.get("supported")
            source_dir = command_wrappers.get("source_dir")
            install_root = command_wrappers.get("install_root")
            if not isinstance(supported, bool):
                errors.append(f"runtimes[{index}].command_wrappers.supported: expected boolean")
            elif supported:
                ensure_string(source_dir, f"runtimes[{index}].command_wrappers.source_dir", errors)
                ensure_string(install_root, f"runtimes[{index}].command_wrappers.install_root", errors)
            else:
                if source_dir is not None or install_root is not None:
                    errors.append(
                        f"runtimes[{index}].command_wrappers: unsupported runtimes must use null wrapper paths"
                    )
            if isinstance(capabilities, dict):
                wrapper_capability = capabilities.get("command_wrappers")
                if isinstance(wrapper_capability, dict):
                    wrapper_support = wrapper_capability.get("support")
                    if supported is True and wrapper_support == "unsupported":
                        errors.append(
                            f"runtimes[{index}].capabilities.command_wrappers: "
                            "supported command wrappers cannot be marked unsupported"
                        )
                    if supported is False and wrapper_support != "unsupported":
                        errors.append(
                            f"runtimes[{index}].capabilities.command_wrappers: "
                            "unsupported command wrappers must be marked unsupported"
                        )

        if name:
            registry_runtime_names.append(name)

    if len(registry_runtime_names) != len(set(registry_runtime_names)):
        errors.append("runtimes/registry.yaml: duplicate runtime names")
    if reference_runtime_count != 1:
        errors.append("runtimes/registry.yaml: expected exactly one reference runtime")
    elif isinstance(reference_capabilities, dict):
        for runtime_index, runtime in enumerate(runtimes, start=1):
            if not isinstance(runtime, dict):
                continue
            capabilities = runtime.get("capabilities")
            if not isinstance(capabilities, dict):
                continue
            for capability in RUNTIME_CAPABILITY_KEYS:
                record = capabilities.get(capability)
                reference_record = reference_capabilities.get(capability)
                if not isinstance(record, dict) or not isinstance(reference_record, dict):
                    continue
                if record.get("adoption") == "shared" and reference_record.get("adoption") != "shared":
                    errors.append(
                        f"runtimes[{runtime_index}].capabilities.{capability}: shared adoption "
                        "requires shared adoption in the reference runtime"
                    )

    scaffold_runtime_dirs = {"runtime-template"}
    missing_runtimes = sorted((runtime_dirs - scaffold_runtime_dirs) - set(registry_runtime_names))
    extra_runtimes = sorted(set(registry_runtime_names) - runtime_dirs)
    if missing_runtimes or extra_runtimes:
        errors.append(
            "runtimes/registry.yaml: registry must match runtimes/ directories "
            f"(missing: {missing_runtimes}, extra: {extra_runtimes})"
        )

    return errors


def render_readme_skills_table(skills: list[dict]) -> str:
    lines = ["| Skill | Phase | Use |", "|---|---|---|"]
    for skill in skills:
        lines.append(f"| `{skill['name']}` | {skill['phase']} | {skill['use']} |")
    return "\n".join(lines)


def render_capability_cell(record: dict) -> str:
    support = record["support"]
    adoption = record["adoption"]
    if support == adoption:
        return support
    if adoption == "shared":
        return support
    return f"{support}; {adoption}"


def render_readme_runtime_capabilities_table(runtimes: list[dict]) -> str:
    capability_labels = {
        "skills": "Skills",
        "permissions": "Permissions",
        "hooks": "Hooks",
        "rules": "Rules",
        "subagents": "Subagents",
        "plugins": "Plugins",
        "command_wrappers": "Wrappers",
        "custom_tools": "Custom tools",
    }
    headers = ["Runtime", *[capability_labels[key] for key in RUNTIME_CAPABILITY_KEYS]]
    lines = ["| " + " | ".join(headers) + " |", "|" + "|".join(["---"] * len(headers)) + "|"]
    for runtime in runtimes:
        capabilities = runtime["capabilities"]
        cells = [runtime["display_name"]]
        cells.extend(render_capability_cell(capabilities[key]) for key in RUNTIME_CAPABILITY_KEYS)
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines)


def render_routing_intents_table(skills: list[dict]) -> str:
    lines = ["| Intent | Skill |", "|---|---|"]
    for skill in skills:
        routing = skill.get("routing")
        if not isinstance(routing, dict):
            continue
        lines.append(f"| {routing['intent']} | `{skill['name']}` |")
    return "\n".join(lines)


def render_routing_triggers_table(skills: list[dict]) -> str:
    lines = ["| Skill | Triggers |", "|---|---|"]
    for skill in skills:
        routing = skill.get("routing")
        if not isinstance(routing, dict):
            continue
        trigger_text = ", ".join(routing["triggers"])
        lines.append(f"| `{skill['name']}` | {trigger_text} |")
    return "\n".join(lines)


def render_command_wrapper(skill: dict) -> str:
    command = skill["command"]
    target = command.get("target", "request")
    return "\n".join(
        [
            "---",
            f"description: {command['description']}",
            "---",
            "",
            "<!-- Generated from skills/registry.yaml. Edit the registry, not this wrapper. -->",
            "",
            f"Load the `{skill['name']}` skill and follow it for this {target}.",
            "",
            "$ARGUMENTS",
            "",
        ]
    )


def render_folded_yaml_block(key: str, value: str) -> list[str]:
    wrapper = textwrap.TextWrapper(
        width=74,
        initial_indent="  ",
        subsequent_indent="  ",
        break_long_words=False,
        break_on_hyphens=False,
    )
    lines = [f"{key}: >"]
    lines.extend(wrapper.fill(value).splitlines())
    return lines


def render_yaml_scalar(key: str, value: object) -> str:
    rendered = json.dumps(value, ensure_ascii=False)
    return f"{key}: {rendered}"


def render_skill_file(skill: dict) -> str:
    prompt_meta = skill["prompt"]
    prompt_path = ROOT / "skills" / skill["name"] / "prompt.md"
    prompt_text = prompt_path.read_text().rstrip() + "\n"
    body = apply_template_tokens(
        prompt_text,
        {
            SKILL_SUPPORT_PATH_TOKEN: RENDERED_SKILL_SUPPORT_PATH,
            RUNTIME_REFERENCE_ROOT_TOKEN: RENDERED_RUNTIME_REFERENCE_ROOT,
        },
        prompt_path,
    ).rstrip()

    lines = ["---", f"name: {skill['name']}"]
    lines.extend(render_folded_yaml_block("description", prompt_meta["description"]))
    for field, yaml_key in PROMPT_FRONTMATTER_FIELDS:
        if field not in prompt_meta:
            continue
        lines.append(render_yaml_scalar(yaml_key, prompt_meta[field]))
    lines.extend(
        [
            "---",
            "",
            f"<!-- Generated from skills/registry.yaml and skills/{skill['name']}/prompt.md. Edit those sources, not this file. -->",
            "",
            body,
            "",
        ]
    )
    return "\n".join(lines)


def _enforcement_notice(runtime: dict) -> str:
    hooks_support = runtime.get("capabilities", {}).get("hooks", {}).get("support", "unsupported")
    if hooks_support in ("native", "adapter"):
        return ""
    return (
        "> **Advisory-only runtime:** This runtime does not support pre-action hook interception. "
        "Strict governance is a model-level recommendation only — high-risk actions are warned "
        "about after the fact but cannot be blocked before execution. "
        "Set `B_AGENTIC_ADVISORY=1` or use `--advisory` to make this explicit."
    )


def render_kernel(runtime: dict) -> str:
    template_text = KERNEL_TEMPLATE_PATH.read_text()
    return apply_template_tokens(
        template_text,
        {
            RUNTIME_DISPLAY_NAME_TOKEN: runtime["display_name"],
            RUNTIME_METADATA_ROOT_TOKEN: runtime["metadata_root"],
            RUNTIME_MEMORY_FILE_TOKEN: runtime["memory_file"],
            RUNTIME_ENFORCEMENT_NOTICE_TOKEN: _enforcement_notice(runtime),
        },
        KERNEL_TEMPLATE_PATH,
    )


def replace_block(text: str, start_marker: str, end_marker: str, body: str) -> str:
    try:
        start_index = text.index(start_marker) + len(start_marker)
        end_index = text.index(end_marker, start_index)
    except ValueError as exc:
        raise SystemExit(f"missing generated block markers: {start_marker} / {end_marker}") from exc

    return text[:start_index] + "\n" + body.rstrip() + "\n" + text[end_index:]


def render_outputs(skills: list[dict], runtimes: list[dict]) -> dict[Path, str]:
    outputs: dict[Path, str] = {}

    readme_path = ROOT / "README.md"
    readme_text = readme_path.read_text()
    readme_text = replace_block(
        readme_text,
        README_SKILLS_START,
        README_SKILLS_END,
        render_readme_skills_table(skills),
    )
    outputs[readme_path] = replace_block(
        readme_text,
        README_RUNTIME_CAPABILITIES_START,
        README_RUNTIME_CAPABILITIES_END,
        render_readme_runtime_capabilities_table(runtimes),
    )

    routing_path = ROOT / "references" / "contract" / "runtime.md"
    routing_text = routing_path.read_text()
    routing_text = replace_block(
        routing_text,
        ROUTING_INTENTS_START,
        ROUTING_INTENTS_END,
        render_routing_intents_table(skills),
    )
    outputs[routing_path] = replace_block(
        routing_text,
        ROUTING_TRIGGERS_START,
        ROUTING_TRIGGERS_END,
        render_routing_triggers_table(skills),
    )

    for skill in skills:
        outputs[ROOT / "skills" / skill["name"] / "SKILL.md"] = render_skill_file(skill)

    exposed_skills = [skill for skill in skills if skill["command"]["exposed"]]
    for runtime in runtimes:
        outputs[ROOT / runtime["kernel_source"]] = render_kernel(runtime)
        command_wrappers = runtime.get("command_wrappers")
        if not isinstance(command_wrappers, dict) or not command_wrappers.get("supported"):
            continue
        command_dir = ROOT / command_wrappers["source_dir"]
        for skill in exposed_skills:
            alias = skill["command"]["alias"]
            outputs[command_dir / f"{alias}.md"] = render_command_wrapper(skill)

    return outputs


def sync_outputs(check: bool) -> int:
    skills, runtimes = load_registries()
    errors = validate_registries(skills, runtimes)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    outputs = render_outputs(skills, runtimes)
    dirty_paths: list[str] = []
    for path, content in outputs.items():
        current = path.read_text() if path.exists() else None
        if current == content:
            continue
        dirty_paths.append(str(path.relative_to(ROOT)))
        if not check:
            path.write_text(content)

    if check and dirty_paths:
        for path in dirty_paths:
            print(f"generated output out of date: {path}", file=sys.stderr)
        return 1

    if not check:
        print("Generated suite outputs refreshed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Render generated suite outputs from canonical source.")
    parser.add_argument("--check", action="store_true", help="fail if generated outputs are stale")
    args = parser.parse_args()
    return sync_outputs(check=args.check)


if __name__ == "__main__":
    sys.exit(main())
