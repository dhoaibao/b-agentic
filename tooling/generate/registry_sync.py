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
CAPABILITIES_PATH = ROOT / "references" / "capabilities.yaml"
CAPABILITIES_OUTPUT_PATH = ROOT / "adapters" / "pi" / "extensions" / "b-agentic-support" / "capabilities.ts"
PERMISSIONS_PATH = ROOT / "references" / "permissions.yaml"
PERMISSIONS_OUTPUT_PATH = ROOT / "adapters" / "pi" / "extensions" / "b-agentic-support" / "permissions-data.ts"

README_SKILLS_START = "<!-- generated:skills-table:start -->"
README_SKILLS_END = "<!-- generated:skills-table:end -->"
MCP_OPERATIONS_START = "<!-- generated:mcp-operations:start -->"
MCP_OPERATIONS_END = "<!-- generated:mcp-operations:end -->"
KERNEL_ROUTING_START = "<!-- generated:kernel-routing:start -->"
KERNEL_ROUTING_END = "<!-- generated:kernel-routing:end -->"
MCP_RUNTIME_POLICY_START = "// generated:mcp-runtime-policy:start"
MCP_RUNTIME_POLICY_END = "// generated:mcp-runtime-policy:end"

SKILL_SUPPORT_PATH_TOKEN = "{{skill_support_path}}"
TEMPLATE_TOKEN_RE = re.compile(r"\{\{[a-z0-9_]+\}\}")

PROMPT_FRONTMATTER_FIELDS = [
    ("when_to_use", "when_to_use"),
    ("user_invocable", "user-invocable"),
]
ALLOWED_PROMPT_KEYS = {"description", *[field for field, _ in PROMPT_FRONTMATTER_FIELDS]}


def load_json_subset_yaml(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{path}: registry files must use the JSON-compatible YAML subset: {exc}") from exc


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


def load_capabilities() -> dict:
    contract = load_json_subset_yaml(CAPABILITIES_PATH)
    capabilities = contract.get("capabilities")
    if not isinstance(capabilities, list):
        raise SystemExit(f"{CAPABILITIES_PATH}: missing capabilities array")
    return contract


def load_permissions() -> dict:
    try:
        return load_json_subset_yaml(PERMISSIONS_PATH)
    except SystemExit as exc:
        raise SystemExit(f"{exc}") from exc


def validate_permissions(data: dict) -> list[str]:
    errors: list[str] = []
    if data.get("schema_version") != 1:
        errors.append(f"{PERMISSIONS_PATH}: schema_version must be 1")
    if data.get("format") != "json-subset-of-yaml":
        errors.append(f"{PERMISSIONS_PATH}: format must be json-subset-of-yaml")
    if not isinstance(data.get("description"), str) or not data["description"]:
        errors.append(f"{PERMISSIONS_PATH}: description must be a non-empty string")

    command_sets = ("ask_commands", "deny_commands", "service_commands", "dangerous_ask_commands")
    seen: dict[str, set[tuple[str, ...]]] = {}
    for field in command_sets:
        entries = data.get(field)
        if not isinstance(entries, list) or not entries:
            errors.append(f"{PERMISSIONS_PATH}: {field} must be a non-empty array")
            seen[field] = set()
            continue
        unique: set[tuple[str, ...]] = set()
        for index, pattern in enumerate(entries, start=1):
            if (
                not isinstance(pattern, list)
                or not pattern
                or not all(isinstance(token, str) and token and " " not in token for token in pattern)
            ):
                errors.append(f"{PERMISSIONS_PATH}: {field}[{index}] must be a non-empty array of single-token strings")
                continue
            unique.add(tuple(pattern))
        seen[field] = unique

    overlap = seen.get("ask_commands", set()) & seen.get("deny_commands", set())
    if overlap:
        errors.append(f"{PERMISSIONS_PATH}: ask_commands and deny_commands must not overlap: {sorted(overlap)}")

    markers = data.get("protected_path_markers")
    if (
        not isinstance(markers, list)
        or not markers
        or not all(isinstance(marker, str) and marker for marker in markers)
    ):
        errors.append(f"{PERMISSIONS_PATH}: protected_path_markers must be a non-empty string array")
    elif len(markers) != len(set(markers)):
        errors.append(f"{PERMISSIONS_PATH}: protected_path_markers must be unique")
    return errors


def render_permissions_module(data: dict) -> str:
    def const(name: str, entries: list) -> str:
        body = json.dumps(entries, indent=2, ensure_ascii=False)
        return f"export const {name}: string[][] = {body};"

    return """/** Generated from references/permissions.yaml. Do not edit this file. */
export const PERMISSIONS_CONTRACT_VERSION = %d as const;

/** Ordered token prefixes that require user approval. */
%s

/** Ordered token prefixes that are always refused. */
%s

/** Long-running service starters that require user approval. */
%s

/** Destructive or service-disrupting commands that require user approval. */
%s

/** Substring or path-segment markers for secret-like and protected paths. */
export const PROTECTED_PATH_MARKERS: string[] = %s;
""" % (
        data["schema_version"],
        const("ASK_COMMANDS", data["ask_commands"]),
        const("DENY_COMMANDS", data["deny_commands"]),
        const("SERVICE_COMMANDS", data["service_commands"]),
        const("DANGEROUS_ASK_COMMANDS", data["dangerous_ask_commands"]),
        json.dumps(data["protected_path_markers"], indent=2, ensure_ascii=False),
    )


def _non_empty_string_list(value: object, label: str, errors: list[str]) -> None:
    if not isinstance(value, list) or not value or not all(isinstance(item, str) and item for item in value):
        errors.append(f"{label}: expected a non-empty string array")


def _installer_package_metadata() -> tuple[set[str], set[str]]:
    """Pi-adapter installer specs, retained for adapter-side smoke tooling only."""
    installer = ROOT / "adapters" / "pi" / "scripts" / "install.sh"
    text = installer.read_text() if installer.exists() else ""
    specs = set(re.findall(r'^\s*PI_[A-Z0-9_]+_SPEC="([^"]+)"\s*$', text, re.MULTILINE))
    names = set(re.findall(r'^\s*PI_[A-Z0-9_]+_PACKAGE="([^"]+)"\s*$', text, re.MULTILINE))
    return specs, names


def validate_capabilities(contract: dict) -> list[str]:
    errors: list[str] = []
    known_hosts = {"pi", "claude-code", "codex", "opencode", "antigravity"}
    if contract.get("schema_version") != 2:
        errors.append(f"{CAPABILITIES_PATH}: schema_version must be 2")
    if contract.get("format") != "json-subset-of-yaml":
        errors.append(f"{CAPABILITIES_PATH}: format must be json-subset-of-yaml")

    capabilities = contract.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities:
        errors.append(f"{CAPABILITIES_PATH}: capabilities must be a non-empty array")
        return errors

    ids: list[str] = []
    package_names: set[str] = set()
    package_specs: set[str] = set()
    mcp_servers: set[str] = set()
    extension_names: set[str] = set()
    expected_state_keys = {"action", "state"}
    allowed_kinds = {"package", "mcp", "extension"}
    known_install_state_keys = {
        "extensionAction",
        "extensionState",
        "mcpAction",
        "mcpState",
        "mcpAdapterAction",
        "mcpAdapterState",
        "piObservationalMemoryAction",
        "piObservationalMemoryState",
        "piUsageAction",
        "piUsageState",
        "piAnthropicAuthAction",
        "piAnthropicAuthState",
        "piIntercomAction",
        "piIntercomState",
        "piAskUserQuestionAction",
        "piAskUserQuestionState",
        "piTodoAction",
        "piTodoState",
    }
    for index, capability in enumerate(capabilities, start=1):
        label = f"capabilities[{index}]"
        if not isinstance(capability, dict):
            errors.append(f"{label}: expected object")
            continue
        capability_id = ensure_string(capability.get("id"), f"{label}.id", errors)
        if capability_id:
            ids.append(capability_id)
        kind = ensure_string(capability.get("kind"), f"{label}.kind", errors)
        if kind and kind not in allowed_kinds:
            errors.append(f"{label}.kind: expected one of {sorted(allowed_kinds)}, got {kind!r}")
        for field in ("purpose", "owner", "trigger", "readiness", "fallback"):
            ensure_string(capability.get(field), f"{label}.{field}", errors)
        _non_empty_string_list(capability.get("prerequisites"), f"{label}.prerequisites", errors)
        hosts = capability.get("hosts")
        if (
            not isinstance(hosts, list)
            or not hosts
            or not all(isinstance(host, str) and host in known_hosts for host in hosts)
        ):
            errors.append(f"{label}.hosts: expected non-empty host ids from {sorted(known_hosts)}")
        if isinstance(capability.get("fallback"), str) and not capability["fallback"].strip():
            errors.append(f"{label}.fallback: required for every capability; prompts resolve [cap: id] to it")

        signal = capability.get("status_signal")
        if not isinstance(signal, dict):
            errors.append(f"{label}.status_signal: expected object")
        else:
            for field in ("source", "description"):
                ensure_string(signal.get(field), f"{label}.status_signal.{field}", errors)
            _non_empty_string_list(signal.get("states"), f"{label}.status_signal.states", errors)
            if signal.get("sensitive") is not False:
                errors.append(f"{label}.status_signal.sensitive: must be false")

        probe = capability.get("probe")
        if not isinstance(probe, dict):
            errors.append(f"{label}.probe: expected object")
        else:
            probe_type = ensure_string(probe.get("type"), f"{label}.probe.type", errors)
            if probe_type != kind:
                errors.append(f"{label}.probe.type: must match capability kind {kind!r}")

        install_state = capability.get("install_state")
        if not isinstance(install_state, dict) or set(install_state) != expected_state_keys:
            errors.append(f"{label}.install_state: expected action and state keys")
        else:
            for field in sorted(expected_state_keys):
                value = ensure_string(install_state.get(field), f"{label}.install_state.{field}", errors)
                if value and value not in known_install_state_keys:
                    errors.append(f"{label}.install_state.{field}: unknown manifest field {value!r}")

        source = capability.get("source")
        if (
            not isinstance(source, dict)
            or not source
            or not all(
                isinstance(key, str) and key and isinstance(value, str) and value for key, value in source.items()
            )
        ):
            errors.append(f"{label}.source: expected a non-empty string reference map")

        if kind == "package":
            package = capability.get("package")
            package_meta = package if isinstance(package, dict) else {}
            if not isinstance(package, dict):
                errors.append(f"{label}.package: expected name and spec")
            else:
                package_name = ensure_string(package.get("name"), f"{label}.package.name", errors)
                package_spec = ensure_string(package.get("spec"), f"{label}.package.spec", errors)
                if package_name:
                    package_names.add(package_name)
                if package_spec:
                    package_specs.add(package_spec)
                package_state_keys = {
                    "pi-mcp-adapter": ("mcpAdapterAction", "mcpAdapterState"),
                    "pi-observational-memory": ("piObservationalMemoryAction", "piObservationalMemoryState"),
                    "@sreetej510/pi-usage": ("piUsageAction", "piUsageState"),
                    "@gotgenes/pi-anthropic-auth": ("piAnthropicAuthAction", "piAnthropicAuthState"),
                    "pi-intercom": ("piIntercomAction", "piIntercomState"),
                    "@juicesharp/rpiv-ask-user-question": ("piAskUserQuestionAction", "piAskUserQuestionState"),
                    "@juicesharp/rpiv-todo": ("piTodoAction", "piTodoState"),
                }
                if package_name in package_state_keys and isinstance(install_state, dict):
                    expected_action, expected_state = package_state_keys[package_name]
                    if install_state.get("action") != expected_action or install_state.get("state") != expected_state:
                        errors.append(f"{label}.install_state: package mapping does not match installer state fields")
            if not isinstance(probe, dict) or probe.get("name") != package_meta.get("name"):
                errors.append(f"{label}.probe.name: must match package.name")
        elif kind == "mcp":
            mcp = capability.get("mcp")
            mcp_meta = mcp if isinstance(mcp, dict) else {}
            if not isinstance(mcp, dict):
                errors.append(f"{label}.mcp: expected server metadata")
            else:
                server = ensure_string(mcp.get("server"), f"{label}.mcp.server", errors)
                if server:
                    mcp_servers.add(server)
                for field in ("auth",):
                    ensure_string(mcp.get(field), f"{label}.mcp.{field}", errors)
                required_env = mcp.get("required_env")
                if not isinstance(required_env, list) or not all(isinstance(item, str) for item in required_env):
                    errors.append(f"{label}.mcp.required_env: expected a string array")
                if isinstance(probe, dict):
                    for field in ("launcher", "required_env", "auth"):
                        if probe.get(field) != mcp.get(field):
                            errors.append(f"{label}.probe.{field}: must match mcp.{field}")
            if not isinstance(probe, dict) or probe.get("server") != mcp_meta.get("server"):
                errors.append(f"{label}.probe.server: must match mcp.server")
        elif kind == "extension":
            extension = capability.get("extension")
            extension_meta = extension if isinstance(extension, dict) else {}
            if not isinstance(extension, dict):
                errors.append(f"{label}.extension: expected name and source")
            else:
                extension_name = ensure_string(extension.get("name"), f"{label}.extension.name", errors)
                source = ensure_string(extension.get("source"), f"{label}.extension.source", errors)
                if extension_name:
                    extension_names.add(extension_name)
                    source_path = ROOT / source if source else None
                    if source_path is not None:
                        try:
                            source_path.relative_to(ROOT)
                        except ValueError:
                            errors.append(f"{label}.extension.source: must stay inside the repository")
                        if not source_path.exists():
                            errors.append(f"{label}.extension.source: missing {source!r}")
                        if extension_name and source_path.name != extension_name:
                            errors.append(f"{label}.extension.source: basename must match extension.name")
            if not isinstance(probe, dict) or probe.get("name") != extension_meta.get("name"):
                errors.append(f"{label}.probe.name: must match extension.name")

    if len(ids) != len(set(ids)):
        errors.append(f"{CAPABILITIES_PATH}: capability ids must be unique")

    forbidden_packages = {"pi-lens", "pi-subagents", "background-task", "background-tasks"}
    forbidden_found = sorted((package_names | package_specs) & forbidden_packages)
    if forbidden_found:
        errors.append(f"{CAPABILITIES_PATH}: forbidden packages are not managed: {forbidden_found}")

    try:
        template = json.loads((ROOT / "adapters" / "pi" / "configs" / "mcp.user.template.json").read_text())
    except Exception as exc:
        errors.append(f"adapters/pi/configs/mcp.user.template.json: invalid JSON: {exc}")
        template = {}
    template_servers = set((template.get("mcpServers") or {}).keys())
    try:
        policy = load_json_subset_yaml(MCP_OPERATIONS_PATH)
    except SystemExit as exc:
        errors.append(str(exc))
        policy = {}
    policy_servers = set((policy.get("servers") or {}).keys())
    if template_servers != policy_servers:
        errors.append(
            f"MCP template/policy server sets differ (template={sorted(template_servers)}, policy={sorted(policy_servers)})"
        )
    if mcp_servers != template_servers:
        errors.append(
            f"{CAPABILITIES_PATH}: MCP capabilities must match template servers "
            f"(contract={sorted(mcp_servers)}, template={sorted(template_servers)})"
        )

    return errors


def render_capability_module(contract: dict) -> str:
    capabilities = json.dumps(contract["capabilities"], indent=2, ensure_ascii=False)
    return """/** Generated from references/capabilities.yaml. Do not edit this file. */
export type CapabilityKind = "package" | "mcp" | "extension";

export type CapabilityDefinition = {
  readonly id: string;
  readonly kind: CapabilityKind;
  readonly purpose: string;
  readonly owner: string;
  readonly hosts: readonly string[];
  readonly trigger: string;
  readonly prerequisites: readonly string[];
  readonly readiness: string;
  readonly fallback: string;
  readonly status_signal: {
    readonly source: string;
    readonly states: readonly string[];
    readonly description: string;
    readonly sensitive: false;
  };
  readonly probe: {
    readonly type: CapabilityKind;
    readonly name?: string;
    readonly server?: string;
    readonly launcher?: string | null;
    readonly required_env?: readonly string[];
    readonly auth?: string;
  };
  readonly package?: { readonly name: string; readonly spec: string };
  readonly mcp?: {
    readonly server: string;
    readonly launcher?: string | null;
    readonly required_env: readonly string[];
    readonly auth: string;
  };
  readonly extension?: { readonly name: string; readonly source: string };
  readonly install_state: { readonly action: string; readonly state: string };
  readonly source: Record<string, string>;
};

export const CAPABILITY_CONTRACT_VERSION = %d as const;
// prettier-ignore
export const CAPABILITIES: readonly CapabilityDefinition[] = %s as const;
export const CAPABILITY_IDS = new Set(
  CAPABILITIES.map((capability) => capability.id),
);
""" % (contract["schema_version"], capabilities)


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

    for index, skill in enumerate(skills, start=1):
        if not isinstance(skill, dict):
            errors.append(f"skills[{index}]: expected object")
            continue
        name = ensure_string(skill.get("name"), f"skills[{index}].name", errors)
        phase = ensure_string(skill.get("phase"), f"skills[{index}].phase", errors)
        use = ensure_string(skill.get("use"), f"skills[{index}].use", errors)

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
        if phase == "Ship" and routing is not None:
            errors.append(f"skills[{index}]: ship-only skills must omit routing metadata")
        if phase != "Ship" and routing is None:
            errors.append(f"skills[{index}]: non-ship skills must include routing metadata")
        if not use:
            errors.append(f"skills[{index}]: missing README/use summary")

    if len(names) != len(set(names)):
        errors.append("skills/registry.yaml: duplicate skill names")
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


def render_mcp_runtime_policy(policy: dict) -> str:
    servers = policy.get("servers", {})
    if not isinstance(servers, dict):
        raise SystemExit(f"{MCP_OPERATIONS_PATH}: missing servers map")
    conditional_arguments = policy.get("conditional_arguments", {})
    if not isinstance(conditional_arguments, dict):
        raise SystemExit(f"{MCP_OPERATIONS_PATH}: missing conditional_arguments map")
    runtime_sets = {
        "codegraph": "CODEGRAPH_TRUSTED_TOOLS",
        "context7": "CONTEXT7_TRUSTED_TOOLS",
        "brave-search": "BRAVE_SEARCH_TRUSTED_TOOLS",
        "firecrawl": "FIRECRAWL_TRUSTED_TOOLS",
        "playwright": "PLAYWRIGHT_TRUSTED_TOOLS",
    }
    conditional_classes = {"conditional-read", "conditional-local"}
    safe = {"read-only", *conditional_classes}
    lines = [
        "/** Generated from references/mcp_operations.yaml. */",
        f"const MANAGED_MCP_SERVERS = new Set({json.dumps(sorted(servers), indent=2)});",
        "",
        "/** Operations autonomous only for a validated safe argument shape. */",
        f"const MCP_CONDITIONAL_TOOLS = new Set({json.dumps(sorted(f'{server}:{tool}' for server, record in servers.items() if isinstance(record, dict) for tool, operation in record.get('tools', {}).items() if operation in conditional_classes), indent=2)});",
        "",
        "/** Known arguments for conditional operations, generated from the canonical policy. */",
        f"const MCP_CONDITIONAL_ARGUMENTS: Record<string, readonly string[]> = {json.dumps({key: value['known'] for key, value in sorted(conditional_arguments.items())}, indent=2)};",
        "",
    ]
    for server, set_name in runtime_sets.items():
        tools = servers.get(server, {}).get("tools", {})
        if not isinstance(tools, dict):
            raise SystemExit(f"{MCP_OPERATIONS_PATH}: {server} has no tools map")
        lines.extend(
            [
                f"const {set_name} = new Set({json.dumps(sorted(tool for tool, operation in tools.items() if operation in safe), indent=2)});",
                "",
            ]
        )
    return "\n".join(lines).rstrip()


def render_routing(skills: list[dict]) -> str:
    lines: list[str] = []
    for skill in skills:
        routing = skill.get("routing")
        if isinstance(routing, dict):
            lines.append(f"- {routing['intent']} -> `{skill['name']}`.")
        elif skill["name"] == "b-commit":
            lines.append("- Split and commit working-tree changes -> `b-commit` only on explicit user request.")
        elif skill["name"] == "b-pr-summary":
            lines.append(
                "- Commit-backed PR summary or supplied PR-prose review/rewrite -> `b-pr-summary` only on explicit user request."
            )
    return "\n".join(lines)


def render_folded_yaml_block(key: str, value: str) -> list[str]:
    wrapper = textwrap.TextWrapper(
        width=74, initial_indent="  ", subsequent_indent="  ", break_long_words=False, break_on_hyphens=False
    )
    return [f"{key}: >", *wrapper.fill(value).splitlines()]


def render_skill_file(skill: dict) -> str:
    prompt_path = ROOT / "skills" / skill["name"] / "prompt.md"
    body = apply_template_tokens(
        prompt_path.read_text().rstrip() + "\n", {SKILL_SUPPORT_PATH_TOKEN: "."}, prompt_path
    ).rstrip()
    routing = skill.get("routing")
    description = skill["prompt"]["description"]
    if isinstance(routing, dict):
        description += f" Routing signals: {', '.join(routing['triggers'])}."
    lines = ["---", f"name: {skill['name']}"]
    lines.extend(render_folded_yaml_block("description", description))
    for field, yaml_key in PROMPT_FRONTMATTER_FIELDS:
        if field in skill["prompt"]:
            lines.append(f"{yaml_key}: {json.dumps(skill['prompt'][field], ensure_ascii=False)}")
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


def replace_block(text: str, start_marker: str, end_marker: str, body: str) -> str:
    try:
        start = text.index(start_marker) + len(start_marker)
        end = text.index(end_marker, start)
    except ValueError as exc:
        raise SystemExit(f"missing generated block markers: {start_marker} / {end_marker}") from exc
    return text[:start] + "\n" + body.rstrip() + "\n" + text[end:]


def render_outputs(skills: list[dict], capabilities: dict, permissions: dict) -> dict[Path, str]:
    outputs: dict[Path, str] = {}
    readme = ROOT / "README.md"
    outputs[readme] = replace_block(
        readme.read_text(), README_SKILLS_START, README_SKILLS_END, render_readme_skills_table(skills)
    )

    kernel = KERNEL_TEMPLATE_PATH.read_text()
    kernel = replace_block(kernel, KERNEL_ROUTING_START, KERNEL_ROUTING_END, render_routing(skills))
    policy = load_json_subset_yaml(MCP_OPERATIONS_PATH)
    outputs[KERNEL_TEMPLATE_PATH] = replace_block(
        kernel, MCP_OPERATIONS_START, MCP_OPERATIONS_END, render_mcp_operations_table(policy)
    )
    extension = ROOT / "adapters" / "pi" / "extensions" / "b-agentic-support" / "mcp.ts"
    runtime_policy = re.sub(r"^const ", "export const ", render_mcp_runtime_policy(policy), flags=re.MULTILINE)
    outputs[extension] = replace_block(
        extension.read_text(), MCP_RUNTIME_POLICY_START, MCP_RUNTIME_POLICY_END, runtime_policy
    )
    outputs[CAPABILITIES_OUTPUT_PATH] = render_capability_module(capabilities)
    outputs[PERMISSIONS_OUTPUT_PATH] = render_permissions_module(permissions)
    for skill in skills:
        outputs[ROOT / "skills" / skill["name"] / "SKILL.md"] = render_skill_file(skill)
    return outputs


def validate_capability_regressions(contract: dict) -> list[str]:
    errors: list[str] = []
    capabilities = contract.get("capabilities", [])
    if not capabilities:
        return ["capability regression: baseline contract is empty"]

    missing_signal = json.loads(json.dumps(contract))
    missing_signal["capabilities"][0].pop("status_signal", None)
    if validate_capabilities(missing_signal):
        pass
    else:
        errors.append("capability regression: missing status signal must be rejected")

    missing_source = json.loads(json.dumps(contract))
    missing_source["capabilities"][0].pop("source", None)
    if validate_capabilities(missing_source):
        pass
    else:
        errors.append("capability regression: missing source references must be rejected")

    duplicate_id = json.loads(json.dumps(contract))
    if len(duplicate_id["capabilities"]) >= 2:
        duplicate_id["capabilities"][1]["id"] = duplicate_id["capabilities"][0]["id"]
        if validate_capabilities(duplicate_id):
            pass
        else:
            errors.append("capability regression: duplicate ids must be rejected")
    else:
        errors.append("capability regression: baseline must contain at least two capabilities")

    mismatched_server = json.loads(json.dumps(contract))
    mcp = next(
        (item for item in mismatched_server["capabilities"] if isinstance(item, dict) and item.get("kind") == "mcp"),
        None,
    )
    if isinstance(mcp, dict):
        mcp["mcp"]["server"] = "unmanaged-server"
        if validate_capabilities(mismatched_server):
            pass
        else:
            errors.append("capability regression: MCP coverage mismatch must be rejected")
    return errors


def validate_permission_regressions(data: dict) -> list[str]:
    errors: list[str] = []
    missing_set = json.loads(json.dumps(data))
    missing_set.pop("deny_commands", None)
    if not any("deny_commands" in error for error in validate_permissions(missing_set)):
        errors.append("permissions regression: missing deny_commands must be rejected")

    overlap = json.loads(json.dumps(data))
    overlap["deny_commands"].append(list(overlap["ask_commands"][0]))
    if not any("must not overlap" in error for error in validate_permissions(overlap)):
        errors.append("permissions regression: ask/deny overlap must be rejected")

    spaced_token = json.loads(json.dumps(data))
    spaced_token["ask_commands"][0] = ["git", "push --force"]
    if not any("single-token" in error for error in validate_permissions(spaced_token)):
        errors.append("permissions regression: multi-token pattern entries must be rejected")
    return errors


def sync_outputs(check: bool) -> int:
    skills = load_skills()
    capabilities = load_capabilities()
    permissions = load_permissions()
    errors = validate_skills(skills)
    errors.extend(validate_capabilities(capabilities))
    errors.extend(validate_permissions(permissions))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    dirty: list[str] = []
    for path, content in render_outputs(skills, capabilities, permissions).items():
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
    parser.add_argument("--self-test", action="store_true", help="verify invalid capability contracts fail validation")
    args = parser.parse_args()
    if args.self_test:
        errors = validate_capability_regressions(load_capabilities())
        errors.extend(validate_permission_regressions(load_permissions()))
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        print("Capability contract validation regressions passed.")
    return sync_outputs(args.check)


if __name__ == "__main__":
    sys.exit(main())
