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
CAPABILITIES_OUTPUT_PATH = ROOT / "pi" / "extensions" / "b-agentic-support" / "capabilities.ts"

README_SKILLS_START = "<!-- generated:skills-table:start -->"
README_SKILLS_END = "<!-- generated:skills-table:end -->"
MCP_OPERATIONS_START = "<!-- generated:mcp-operations:start -->"
MCP_OPERATIONS_END = "<!-- generated:mcp-operations:end -->"
KERNEL_ROUTING_START = "<!-- generated:kernel-routing:start -->"
KERNEL_ROUTING_END = "<!-- generated:kernel-routing:end -->"
KERNEL_DELEGATION_START = "<!-- generated:delegation:start -->"
KERNEL_DELEGATION_END = "<!-- generated:delegation:end -->"
MCP_RUNTIME_POLICY_START = "// generated:mcp-runtime-policy:start"
MCP_RUNTIME_POLICY_END = "// generated:mcp-runtime-policy:end"

SKILL_SUPPORT_PATH_TOKEN = "{{skill_support_path}}"
TEMPLATE_TOKEN_RE = re.compile(r"\{\{[a-z0-9_]+\}\}")

PROMPT_FRONTMATTER_FIELDS = [
    ("when_to_use", "when_to_use"),
    ("user_invocable", "user-invocable"),
]
ALLOWED_PROMPT_KEYS = {"description", *[field for field, _ in PROMPT_FRONTMATTER_FIELDS]}
EXECUTION_MODES = {"main", "subagent"}
PHASES = {"Decide", "Build", "Validate", "Ship"}
MANAGED_SUBAGENT_NAMES = {"b-planner", "b-researcher", "b-debugger", "b-reviewer"}


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


def _non_empty_string_list(value: object, label: str, errors: list[str]) -> None:
    if not isinstance(value, list) or not value or not all(isinstance(item, str) and item for item in value):
        errors.append(f"{label}: expected a non-empty string array")


def _installer_package_metadata() -> tuple[set[str], set[str]]:
    installer = ROOT / "pi" / "scripts" / "install.sh"
    text = installer.read_text() if installer.exists() else ""
    specs = set(re.findall(r'^\s*PI_[A-Z0-9_]+_SPEC="([^"]+)"\s*$', text, re.MULTILINE))
    names = set(re.findall(r'^\s*PI_[A-Z0-9_]+_PACKAGE="([^"]+)"\s*$', text, re.MULTILINE))
    return specs, names


def _installer_extension_names() -> set[str]:
    installer = ROOT / "pi" / "scripts" / "install.sh"
    text = installer.read_text() if installer.exists() else ""
    match = re.search(r"EXTENSION_NAMES=\(\n(.*?)\n\)", text, re.DOTALL)
    if not match:
        return set()
    return {line.strip() for line in match.group(1).splitlines() if line.strip() and not line.lstrip().startswith("#")}


def validate_capabilities(contract: dict) -> list[str]:
    errors: list[str] = []
    if contract.get("schema_version") != 1:
        errors.append(f"{CAPABILITIES_PATH}: schema_version must be 1")
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
    allowed_kinds = {"package", "mcp", "extension", "agent"}
    known_install_state_keys = {
        "extensionAction",
        "extensionState",
        "mcpAction",
        "mcpState",
        "mcpAdapterAction",
        "mcpAdapterState",
        "piMagicContextAction",
        "piMagicContextState",
        "piUsageAction",
        "piUsageState",
        "piAnthropicAuthAction",
        "piAnthropicAuthState",
        "piSubagentsAction",
        "piSubagentsState",
        "subagentProfilesAction",
        "subagentProfilesState",
        "subagentSettingsAction",
        "subagentSettingsState",
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
                    "@cortexkit/pi-magic-context": ("piMagicContextAction", "piMagicContextState"),
                    "@sreetej510/pi-usage": ("piUsageAction", "piUsageState"),
                    "@gotgenes/pi-anthropic-auth": ("piAnthropicAuthAction", "piAnthropicAuthState"),
                    "pi-subagents": ("piSubagentsAction", "piSubagentsState"),
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
        elif kind == "agent":
            agent = capability.get("agent")
            agent_meta = agent if isinstance(agent, dict) else {}
            if not isinstance(agent, dict):
                errors.append(f"{label}.agent: expected managed profile or settings metadata")
            else:
                names = agent.get("names")
                settings = agent.get("settings")
                guard = agent.get("guard")
                source = ensure_string(agent.get("source"), f"{label}.agent.source", errors)
                if names is not None:
                    if (
                        not isinstance(names, list)
                        or not names
                        or not all(isinstance(name, str) and name for name in names)
                    ):
                        errors.append(f"{label}.agent.names: expected a non-empty string array")
                    elif set(names) != MANAGED_SUBAGENT_NAMES:
                        errors.append(f"{label}.agent.names: must name exactly {sorted(MANAGED_SUBAGENT_NAMES)}")
                    elif not (ROOT / source).is_dir():
                        errors.append(f"{label}.agent.source: missing managed profile directory {source!r}")
                    if guard != "subagent-read-only-guard.ts":
                        errors.append(f"{label}.agent.guard: expected 'subagent-read-only-guard.ts'")
                    elif not (ROOT / "pi" / guard).is_file():
                        errors.append(f"{label}.agent.guard: missing managed guard {guard!r}")
                    source_map = capability.get("source")
                    if isinstance(source_map, dict):
                        guard_source = source_map.get("guard")
                        if guard_source is not None and not (ROOT / guard_source).is_file():
                            errors.append(f"{label}.source.guard: missing guard source {guard_source!r}")
                elif settings is not None:
                    if not isinstance(settings, str) or not settings:
                        errors.append(f"{label}.agent.settings: expected a non-empty string")
                    elif settings != "settings.json":
                        errors.append(f"{label}.agent.settings: expected 'settings.json'")
                    elif not (ROOT / source).is_file():
                        errors.append(f"{label}.agent.source: missing managed settings template {source!r}")
                else:
                    errors.append(f"{label}.agent: requires names or settings metadata")
            if not isinstance(probe, dict):
                continue
            if (
                probe.get("names") != agent_meta.get("names")
                or probe.get("settings") != agent_meta.get("settings")
                or probe.get("guard") != agent_meta.get("guard")
            ):
                errors.append(f"{label}.probe: must match agent names, guard, or settings metadata")
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

    installer_specs, installer_names = _installer_package_metadata()
    if package_specs != installer_specs:
        errors.append(
            f"{CAPABILITIES_PATH}: package specs must match pi/scripts/install.sh "
            f"(contract={sorted(package_specs)}, installer={sorted(installer_specs)})"
        )
    if package_names != installer_names:
        errors.append(
            f"{CAPABILITIES_PATH}: package names must match pi/scripts/install.sh "
            f"(contract={sorted(package_names)}, installer={sorted(installer_names)})"
        )

    forbidden_packages = {"pi-lens", "background-task", "background-tasks"}
    forbidden_found = sorted((package_names | package_specs) & forbidden_packages)
    if forbidden_found:
        errors.append(f"{CAPABILITIES_PATH}: forbidden packages are not managed: {forbidden_found}")

    installer_extensions = _installer_extension_names()
    expected_entrypoints = {path.name for path in (ROOT / "pi" / "extensions").glob("*.ts")}
    preview_source = ROOT / "pi" / "packages" / "preview-markdown" / "extensions" / "b-agentic-preview-markdown.ts"
    if preview_source.exists():
        expected_entrypoints.add(preview_source.name)
    if extension_names != expected_entrypoints:
        errors.append(
            f"{CAPABILITIES_PATH}: extension names must cover first-party entrypoints "
            f"(contract={sorted(extension_names)}, entrypoints={sorted(expected_entrypoints)})"
        )
    missing_installer_extensions = sorted(extension_names - installer_extensions)
    if missing_installer_extensions:
        errors.append(
            f"{CAPABILITIES_PATH}: first-party entrypoints missing from installer EXTENSION_NAMES: "
            f"{missing_installer_extensions}"
        )

    try:
        template = json.loads((ROOT / "pi" / "configs" / "mcp.user.template.json").read_text())
    except Exception as exc:
        errors.append(f"pi/configs/mcp.user.template.json: invalid JSON: {exc}")
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
export type CapabilityKind = "package" | "mcp" | "extension" | "agent";

export type CapabilityDefinition = {
  readonly id: string;
  readonly kind: CapabilityKind;
  readonly purpose: string;
  readonly owner: string;
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
    readonly names?: readonly string[];
    readonly settings?: string;
    readonly guard?: string;
  };
  readonly package?: { readonly name: string; readonly spec: string };
  readonly mcp?: {
    readonly server: string;
    readonly launcher?: string | null;
    readonly required_env: readonly string[];
    readonly auth: string;
  };
  readonly extension?: { readonly name: string; readonly source: string };
  readonly agent?: {
    readonly names?: readonly string[];
    readonly settings?: string;
    readonly guard?: string;
    readonly source: string;
  };
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
        execution = skill.get("execution")
        if not isinstance(execution, dict):
            errors.append(f"skills[{index}].execution: expected object")
        else:
            mode = ensure_string(execution.get("mode"), f"skills[{index}].execution.mode", errors)
            if mode and mode not in EXECUTION_MODES:
                errors.append(
                    f"skills[{index}].execution.mode: expected one of {sorted(EXECUTION_MODES)}, got {mode!r}"
                )
            agent = execution.get("agent")
            if mode == "subagent":
                ensure_string(agent, f"skills[{index}].execution.agent", errors)
            elif agent is not None:
                errors.append(f"skills[{index}].execution.agent: only subagent execution may name an agent")
        phase = ensure_string(skill.get("phase"), f"skills[{index}].phase", errors)
        if phase and phase not in PHASES:
            errors.append(f"skills[{index}].phase: expected one of {sorted(PHASES)}, got {phase!r}")
        use = ensure_string(skill.get("use"), f"skills[{index}].use", errors)

        routing = skill.get("routing")
        if routing is not None:
            if not isinstance(routing, dict):
                errors.append(f"skills[{index}].routing: expected object or null")
            else:
                ensure_string(routing.get("intent"), f"skills[{index}].routing.intent", errors)
                explicit_request = routing.get("explicit_request", False)
                if not isinstance(explicit_request, bool):
                    errors.append(f"skills[{index}].routing.explicit_request: expected boolean")
                triggers = routing.get("triggers")
                if explicit_request:
                    if triggers is not None:
                        errors.append(f"skills[{index}].routing.triggers: explicit-request skills must omit triggers")
                elif not isinstance(triggers, list) or not triggers:
                    errors.append(f"skills[{index}].routing.triggers: expected non-empty array")
                else:
                    for trigger_index, trigger in enumerate(triggers, start=1):
                        ensure_string(trigger, f"skills[{index}].routing.triggers[{trigger_index}]", errors)

        validate_skill_prompt_source(skill, errors)
        if name:
            names.append(name)
        if phase == "Ship" and not (isinstance(routing, dict) and routing.get("explicit_request") is True):
            errors.append(f"skills[{index}]: ship-only skills must declare explicit-request routing metadata")
        if phase != "Ship" and (not isinstance(routing, dict) or routing.get("explicit_request") is True):
            errors.append(f"skills[{index}]: non-ship skills must include intent-and-triggers routing metadata")
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
        "mobbin": "MOBBIN_TRUSTED_TOOLS",
        "shadcn": "SHADCN_TRUSTED_TOOLS",
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


def render_delegation(skills: list[dict]) -> str:
    delegated = [skill for skill in skills if skill["execution"]["mode"] == "subagent"]
    main = [skill["name"] for skill in skills if skill["execution"]["mode"] == "main"]
    lines = [
        f"- The main session owns user interaction and worktree changes: {', '.join(f'`{name}`' for name in main)}.",
        "- Delegated skills run once through their named pi-subagents; the main session waits for the result, evaluates it, and performs any next user-facing or worktree action:",
    ]
    lines.extend(f"  - `{skill['name']}` -> `{skill['execution']['agent']}`." for skill in delegated)
    lines.append(
        "- Subagents are read-only workflow specialists. They do not select a main session, discover peers, use Intercom, ask users questions, or launch nested subagents."
    )
    return "\n".join(lines)


def render_routing(skills: list[dict]) -> str:
    lines: list[str] = []
    for skill in skills:
        routing = skill.get("routing")
        if not isinstance(routing, dict):
            raise SystemExit(f"render_routing: {skill.get('name')} has no routing metadata")
        suffix = " only on explicit user request" if routing.get("explicit_request") is True else ""
        lines.append(f"- {routing['intent']} -> `{skill['name']}`{suffix}.")
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
    if isinstance(routing, dict) and routing.get("triggers"):
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


def render_outputs(skills: list[dict], capabilities: dict) -> dict[Path, str]:
    outputs: dict[Path, str] = {}
    readme = ROOT / "README.md"
    outputs[readme] = replace_block(
        readme.read_text(), README_SKILLS_START, README_SKILLS_END, render_readme_skills_table(skills)
    )

    kernel = KERNEL_TEMPLATE_PATH.read_text()
    kernel = replace_block(kernel, KERNEL_ROUTING_START, KERNEL_ROUTING_END, render_routing(skills))
    kernel = replace_block(kernel, KERNEL_DELEGATION_START, KERNEL_DELEGATION_END, render_delegation(skills))
    policy = load_json_subset_yaml(MCP_OPERATIONS_PATH)
    outputs[KERNEL_TEMPLATE_PATH] = replace_block(
        kernel, MCP_OPERATIONS_START, MCP_OPERATIONS_END, render_mcp_operations_table(policy)
    )
    extension = ROOT / "pi" / "extensions" / "b-agentic-support" / "mcp.ts"
    runtime_policy = re.sub(r"^const ", "export const ", render_mcp_runtime_policy(policy), flags=re.MULTILINE)
    outputs[extension] = replace_block(
        extension.read_text(), MCP_RUNTIME_POLICY_START, MCP_RUNTIME_POLICY_END, runtime_policy
    )
    outputs[CAPABILITIES_OUTPUT_PATH] = render_capability_module(capabilities)
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

    missing_guard_source = json.loads(json.dumps(contract))
    guard_cap = next(
        (
            item
            for item in missing_guard_source["capabilities"]
            if isinstance(item, dict) and isinstance(item.get("source"), dict) and "guard" in item["source"]
        ),
        None,
    )
    if isinstance(guard_cap, dict):
        guard_cap["source"]["guard"] = "pi/nonexistent-guard.ts"
        if validate_capabilities(missing_guard_source):
            pass
        else:
            errors.append("capability regression: missing source.guard file must be rejected")
    else:
        errors.append("capability regression: baseline must contain a capability with source.guard")
    return errors


def validate_execution_regressions(skills: list[dict]) -> list[str]:
    errors: list[str] = []
    for label, execution in (
        ("missing", None),
        ("invalid", {"mode": "coordinator"}),
        ("main-agent", {"mode": "main", "agent": "b-planner"}),
    ):
        fixture = json.loads(json.dumps(skills))
        if execution is None:
            fixture[0].pop("execution", None)
        else:
            fixture[0]["execution"] = execution
        if not any("execution" in error for error in validate_skills(fixture)):
            errors.append(f"execution regression: {label} execution metadata must be rejected")

    ship = next((s for s in skills if s.get("phase") == "Ship"), None)
    non_ship = next((s for s in skills if s.get("phase") != "Ship"), None)
    if ship is None or non_ship is None:
        errors.append("routing regression: baseline must contain ship and non-ship skills")
        return errors
    for label, target, routing in (
        ("ship-with-triggers", ship, {"intent": "x", "explicit_request": True, "triggers": ["x"]}),
        ("ship-missing-explicit-request", ship, {"intent": "x", "triggers": ["x"]}),
        ("non-ship-explicit-request", non_ship, {"intent": "x", "explicit_request": True}),
        ("non-ship-missing-routing", non_ship, None),
        ("non-ship-missing-triggers", non_ship, {"intent": "x"}),
    ):
        fixture = json.loads(json.dumps(skills))
        index = next(i for i, s in enumerate(fixture) if s.get("name") == target.get("name"))
        if routing is None:
            fixture[index].pop("routing", None)
        else:
            fixture[index]["routing"] = routing
        if not any("routing" in error for error in validate_skills(fixture)):
            errors.append(f"routing regression: {label} routing metadata must be rejected")

    bad_phase = json.loads(json.dumps(skills))
    bad_phase[0]["phase"] = "ship"
    if not any("phase" in error for error in validate_skills(bad_phase)):
        errors.append("phase regression: an unknown phase must be rejected")
    return errors


def sync_outputs(check: bool) -> int:
    skills = load_skills()
    capabilities = load_capabilities()
    errors = validate_skills(skills)
    errors.extend(validate_capabilities(capabilities))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    dirty: list[str] = []
    for path, content in render_outputs(skills, capabilities).items():
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
    parser.add_argument(
        "--self-test", action="store_true", help="verify invalid skill execution metadata fails validation"
    )
    args = parser.parse_args()
    if args.self_test:
        errors = validate_execution_regressions(load_skills())
        errors.extend(validate_capability_regressions(load_capabilities()))
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        print("Skill execution and capability contract validation regressions passed.")
    return sync_outputs(args.check)


if __name__ == "__main__":
    sys.exit(main())
