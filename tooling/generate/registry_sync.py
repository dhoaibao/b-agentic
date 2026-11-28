#!/usr/bin/env python3
"""Render Claude Code delivery assets from b-agentic's canonical sources.

With `--render pi --out DIR` it renders Pi (kernel, skills, prompt templates, agents) into a
new or empty DIR outside the checkout; the install step calls this, and no Pi file is ever committed. `--check`
and `--self-test` render Pi in memory and fail on any Pi output error (ADR-030, ADR-032).
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import re
import shutil
import sys
import tempfile
import textwrap
from pathlib import Path, PurePosixPath
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SKILL_REGISTRY_PATH = ROOT / "skills" / "registry.yaml"
KERNEL_TEMPLATE_PATH = ROOT / "references" / "kernel.template.md"
MCP_OPERATIONS_PATH = ROOT / "references" / "mcp_operations.yaml"
CAPABILITIES_PATH = ROOT / "references" / "capabilities.yaml"
RUNTIMES_PATH = ROOT / "references" / "runtimes.yaml"
CLAUDE_DIR = ROOT / "claude"
CLAUDE_AGENTS_DIR = CLAUDE_DIR / "agents"
CLAUDE_CONFIGS_DIR = CLAUDE_DIR / "configs"
SETTINGS_TEMPLATE_PATH = CLAUDE_CONFIGS_DIR / "settings.template.json"
SNAPSHOT_CLI_PATH = CLAUDE_DIR / "bin" / "b-candidate-snapshot.mjs"
PROTECTED_RULES_PATH = CLAUDE_DIR / "bin" / "b-protected.mjs"
RUN_CLI_PATH = CLAUDE_DIR / "bin" / "b_run_lib.py"
STATE_CORE_PATH = CLAUDE_DIR / "bin" / "b-state-core.mjs"
ARTIFACTS_PATH = ROOT / "references" / "artifacts.yaml"
ARTIFACT_KINDS = ("spec", "plan", "qa", "followups")
B_REVIEW_PROMPT_PATH = ROOT / "skills" / "b-review" / "prompt.md"
# Both b-review blocker-class sentences ("... is one of: a, b, or c.") list the classes in the same order as the enum.
BLOCKER_CLASS_SENTENCE = re.compile(r"is one of: ([^.]+)\.")
BLOCKER_CLASS_SENTENCES = 2
# A prompt line that starts with this marker is emitted only for the named runtimes (marker removed).
RUNTIME_MARKER = re.compile(r"^<!-- runtime: ([a-z]+(?:,[a-z]+)*) --> ")
# A bare marker line opens a block that closes at the closing line; the lines between them are emitted
# only for the named runtimes, and both marker lines are always dropped.
# Marker lines may be indented, so a block inside a Markdown list item keeps the list unbroken.
RUNTIME_BLOCK_OPEN = re.compile(r"^ *<!-- runtime: ([a-z]+(?:,[a-z]+)*) -->$")
RUNTIME_BLOCK_CLOSE = re.compile(r"^ *<!-- /runtime -->$")

MAX_KERNEL_BYTES = 12_000
MAX_KERNEL_LINES = 100
README_SKILLS_START = "<!-- generated:skills-table:start -->"
README_SKILLS_END = "<!-- generated:skills-table:end -->"
MCP_OPERATIONS_START = "<!-- generated:mcp-operations:start -->"
MCP_OPERATIONS_END = "<!-- generated:mcp-operations:end -->"
KERNEL_ROUTING_START = "<!-- generated:kernel-routing:start -->"
KERNEL_ROUTING_END = "<!-- generated:kernel-routing:end -->"
KERNEL_DELEGATION_START = "<!-- generated:delegation:start -->"
KERNEL_DELEGATION_END = "<!-- generated:delegation:end -->"

STATE_CORE_PATH = CLAUDE_DIR / "bin" / "b-state-core.mjs"
# What a skill is to a b-flow run: it completes a run phase, supplies evidence to one, stays outside
# every run, or sequences the run itself.
CONTRACT_ROLES = {"phase", "provider", "utility", "orchestrator"}
# Run phases only a phase skill completes; in `verify` the main session runs the plan checks itself.
SKILL_RUN_PHASES = ("clarify", "implement", "review", "fix", "qa", "commit")
# A phase skill here edits files, the index, or HEAD, so it can never run beside another.
TREE_CHANGING_PHASES = {"implement", "fix", "commit"}
PHASE_CONTRACTS_PLACEHOLDER = "{{phase_contracts}}"
# The kernel line of the routing entry: changes go through the orchestrator unless the user names a skill.
ENTRY_ROUTING_SUFFIX = ", as a quick or full run; a typed `/b-<name>` runs standalone"

EXECUTION_MODES = {"main", "subagent"}
PHASES = {"Decide", "Build", "Validate", "Ship"}
MANAGED_SUBAGENT_NAMES = {"b-planner", "b-researcher", "b-debugger", "b-auditor", "b-reviewer"}
# The one writer child of a b-flow run (ADR-015). It lives in its own registry map, so every
# read-only assertion about `agents` stays unconditional.
MANAGED_WORKER_NAMES = {"b-worker"}
WORKER_TOOLS = ("Read", "Grep", "Glob", "Edit", "Write", "Bash")
CODEGRAPH_TOOL = "mcp__codegraph__codegraph_explore"
WORKER_FORBIDDEN_TOOLS = {"NotebookEdit", "Agent", "Task", "Skill", "AskUserQuestion"}
WORKER_FORBIDDEN_FIELDS = {"tools", "permission_mode", "isolation", "hooks", "skills", "background"}
CAPABILITY_KINDS = {"mcp", "agent", "plugin"}
CAPABILITY_TIERS = {"shared", "adapted", "exclusive"}
# Likely-secret path gate; the snapshot CLI mirrors everything after "*".
PATH_RULES = {
    "*": "allow",
    "*.env": "deny",
    "*.env.*": "deny",
    "*.env.example": "allow",
    "*.pem": "deny",
    "*credentials.*": "deny",
    "*secrets.*": "deny",
}
# Claude Code permission deny rules cannot carve out `.env.example`, so the
# settings layer denies only unambiguous secret files; the path-guard hook
# enforces PATH_RULES exactly.
DENY_READ_GLOBS = (
    "**/.env",
    "**/.env.local",
    "**/.env.*.local",
    "**/*.pem",
    "**/*credentials.*",
    "**/*secrets.*",
)
# Pushes that name a destination, PR creation, and `gh auth switch` ask each time; the patterns
# below stay denied, including the destination-less `git push` and `git push origin`.
# Claude Code evaluates deny before ask before allow, so the denies carve
# exceptions out of the ask rules. `*` matches any characters, so every flag and
# protected-branch pattern is anchored on argument boundaries (a leading space,
# or the start of the arguments) to keep names such as `feature-f` or
# `main-fix` pushable. The `git * push` and `gh * pr create` ask forms catch
# global options such as `git -C <dir> push`; those forms are asked about but not
# pattern-denied, except the `git -c <key=value> push` form b-pr uses for HTTPS,
# where force and main or master pushes are denied too. `:branch` delete refspecs
# (a trailing `:*` is the legacy prefix form) and default branches not named main
# or master also stay at the ask prompt.
# Other `gh` commands that change GitHub state are grouped below: the destructive,
# credential, and code-execution ones are denied, the reversible ones ask, and read
# commands (`gh pr view`, a plain `gh api <path>`) stay allowed. Each command also gets
# its `gh * <group> <verb>` global-option form (for example `gh -R o/r release delete`).
DENIED_GH_COMMANDS = (
    "gh pr merge",
    "gh repo delete",
    "gh repo archive",
    "gh repo rename",
    "gh repo edit",
    "gh repo deploy-key add",
    "gh repo deploy-key delete",
    "gh release delete",
    "gh release delete-asset",
    "gh extension install",
    "gh alias set",
    "gh alias import",
    "gh secret set",
    "gh secret delete",
    "gh ssh-key add",
    "gh ssh-key delete",
    "gh gpg-key add",
    "gh gpg-key delete",
    "gh auth login",
    "gh auth logout",
    "gh auth token",
    "gh auth refresh",
)
ASKED_GH_COMMANDS = (
    "gh pr create",
    "gh pr close",
    "gh pr edit",
    "gh auth switch",
    "gh release create",
    "gh release upload",
    "gh release edit",
    "gh variable set",
    "gh variable delete",
    "gh repo create",
    "gh repo fork",
    "gh gist create",
    "gh gist delete",
    "gh issue close",
    "gh issue delete",
    "gh issue edit",
    "gh workflow run",
    "gh workflow disable",
    "gh run delete",
    "gh cache delete",
    "gh label delete",
    "gh codespace delete",
)
# `gh api` mutates through a method or request-body flag; a plain `gh api <path>` read stays allowed.
GH_API_DENIED_METHODS = ("DELETE", "PUT", "PATCH")
GH_API_ASKED_FLAGS = ("-f", "-F", "--field", "--raw-field", "--input", "-X", "--method")


def gh_forms(command: str) -> tuple[str, str]:
    """A `gh` command and its global-option form, such as `gh -R o/r pr merge`."""
    return command, command.replace("gh ", "gh * ", 1)


ASKED_COMMANDS = (
    "git push",
    "git * push",
    *(form for command in ASKED_GH_COMMANDS for form in gh_forms(command)),
)
PROTECTED_BRANCHES = ("main", "master")


def c_push_deny_patterns() -> list[str]:
    """Force and protected-branch denies for `git -c <key=value> push`, the form b-pr uses for HTTPS."""
    head = "git -c * push"
    patterns = []
    for flag in ("-f", "--force*", "+*"):
        patterns += [f"{head} {flag}", f"{head} * {flag}"]
    patterns += [f"{head} -f *", f"{head} * -f *"]
    for branch in PROTECTED_BRANCHES:
        for target in (f"* {branch}", f"*:{branch}", f"*refs/heads/{branch}"):
            patterns += [f"{head} {target}", f"{head} {target} *"]
    return patterns


def gh_flag_deny_patterns() -> list[str]:
    """Denies for `gh auth status` printing a token and `gh api` with a mutating method."""
    patterns = []
    for base in gh_forms("gh auth status"):
        patterns += [f"{base} *--show-token*"]
        patterns += [f"{base} -t", f"{base} -t *", f"{base} * -t", f"{base} * -t *"]
    # The method value must directly follow the flag (`-X DELETE`, `-XDELETE`, `-X=DELETE`,
    # `--method DELETE`, `--method=DELETE`), so a method word in an endpoint or field stays allowed.
    flag_forms = ("-X ", "-X", "-X=", "--method ", "--method=")
    for base in gh_forms("gh api"):
        for form in flag_forms:
            for method in GH_API_DENIED_METHODS:
                patterns += [f"{base} *{form}{method}*", f"{base} *{form}{method.lower()}*"]
    return patterns


def gh_api_ask_patterns() -> list[str]:
    """Asks for `gh api` calls that send a request body or choose a method."""
    patterns = []
    for base in gh_forms("gh api"):
        for flag in GH_API_ASKED_FLAGS:
            patterns += [f"{base} {flag}*", f"{base} * {flag}*"]
    return patterns


def push_deny_patterns() -> tuple[str, ...]:
    patterns = ["git push", "git push origin"]
    for flag in ("-f", "-d"):
        patterns += [f"git push {flag}", f"git push {flag} *", f"git push * {flag}", f"git push * {flag} *"]
    for flag in ("--force*", "--delete*", "--mirror*", "--all*", "--branches*", "--prune*", "+*"):
        patterns += [f"git push {flag}", f"git push * {flag}"]
    for branch in PROTECTED_BRANCHES:
        for target in (f"* {branch}", f"*:{branch}", f"*refs/heads/{branch}"):
            patterns += [f"git push {target}", f"git push {target} *"]
    patterns += c_push_deny_patterns()
    for command in DENIED_GH_COMMANDS:
        for form in gh_forms(command):
            patterns += [form, f"{form} *"]
    patterns += gh_flag_deny_patterns()
    return tuple(patterns)


def flag_pair_patterns(command: str, first: tuple[str, ...], second: tuple[str, ...]) -> list[str]:
    """Patterns for a flag from `first` and a flag from `second` given as separate words, in either order and anywhere after the command."""
    patterns = []
    for left, right in [*itertools.product(first, second), *itertools.product(second, first)]:
        for lead in (f"{command} ", f"{command} * "):
            for separator in (" ", " * "):
                patterns.append(f"{lead}{left}{separator}{right}*")
    return patterns


def destructive_deny_patterns() -> tuple[str, ...]:
    """Option-placement and combined-flag spellings of the destructive commands in `DENIED_COMMANDS`.

    `*` spans spaces, so a flag word is anchored on its leading space: `git clean -n`, `git reset --soft`,
    `git branch -d`, `rm -r` and `rm -f notes-r.txt` stay allowed. Not matched, so only the kernel's prose rule
    stops them: global-option forms (`git -C dir clean -fd`), flag clusters not listed here (`rm -Irf`), wrappers
    (`command rm`, `/bin/rm`, `xargs rm -rf`, `bash -c '...'`), and other destructive commands
    (`git checkout -- .`, `git restore`, `find -delete`).
    """
    patterns = ["git reset * --hard", "git reset * --hard *"]
    clean_words = ("-f*", "--force*", "-df*", "-xf*", "-Xf*", "-qf*", "-dxf*", "-xdf*", "-dXf*", "-Xdf*")
    rm_words = ("-rf*", "-fr*", "-Rf*", "-fR*", "-vrf*", "-vfr*", "-vRf*", "-vfR*", "-rvf*", "-fvr*", "-Rvf*", "-fvR*")
    for command, words in (("git clean", clean_words), ("git branch", ("-D*", "-df*", "-fd*")), ("rm", rm_words)):
        for word in words:
            patterns += [f"{command} {word}", f"{command} * {word}"]
    patterns += flag_pair_patterns("git branch", ("-d", "--delete"), ("-f", "--force"))
    patterns += flag_pair_patterns("rm", ("-r", "-R", "--recursive"), ("-f", "--force"))
    return tuple(patterns)


DENIED_PUSH_PATTERNS = push_deny_patterns()
DENIED_DESTRUCTIVE_PATTERNS = destructive_deny_patterns()
DENIED_COMMANDS = (
    "git pull",
    "git reset --hard",
    "git clean -f",
    "git branch -D",
    "rm -rf",
    "sudo",
    "doas",
    "docker system prune",
    "bash -s",
    "sh -s",
)
DENIED_BARE_COMMANDS = ("bash", "sh")
ALLOWED_TOOLS = ("Read", "Glob", "Grep", "Edit", "Write", "Bash", "Agent", "Task", "Skill", "AskUserQuestion")
ARGUMENT_HINT_MAX = 60
ARGUMENT_HINT_TOKEN = r"(?:<[A-Za-z0-9 ,/|._-]+>|\[[A-Za-z0-9 ,/|._-]+\])"
ARGUMENT_HINT_PATTERN = re.compile(rf"{ARGUMENT_HINT_TOKEN}(?: {ARGUMENT_HINT_TOKEN})*")


def load_json_subset_yaml(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{path}: must use the JSON-compatible YAML subset: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit(f"{path}: expected an object")
    return value


def load_runtimes() -> dict[str, dict[str, Any]]:
    runtimes = load_json_subset_yaml(RUNTIMES_PATH).get("runtimes")
    if not isinstance(runtimes, dict) or not isinstance(runtimes.get("claude"), dict):
        raise SystemExit(f"{RUNTIMES_PATH}: missing runtimes object with a claude entry")
    return runtimes


RUNTIMES = load_runtimes()
CLAUDE_RUNTIME = RUNTIMES["claude"]
AGENT_MODELS = set(CLAUDE_RUNTIME["agent_models"])
# Effort levels Claude Code accepts in subagent frontmatter (support varies by model).
AGENT_EFFORTS = {"low", "medium", "high", "xhigh", "max"}
# Tools a read-only specialist must never receive, whatever the registry says.
EDITING_TOOLS = tuple(CLAUDE_RUNTIME["editing_tools"])


def ensure_string(value: object, label: str, errors: list[str]) -> str:
    if not isinstance(value, str) or not value:
        errors.append(f"{label}: expected non-empty string")
        return ""
    return value


def non_empty_string_list(value: object, label: str, errors: list[str]) -> None:
    if not isinstance(value, list) or not value or not all(isinstance(item, str) and item for item in value):
        errors.append(f"{label}: expected a non-empty string array")


def load_registry() -> dict[str, Any]:
    return load_json_subset_yaml(SKILL_REGISTRY_PATH)


def load_skills() -> list[dict[str, Any]]:
    skills = load_registry().get("skills")
    if not isinstance(skills, list):
        raise SystemExit(f"{SKILL_REGISTRY_PATH}: missing skills array")
    return skills


def load_agents() -> dict[str, dict[str, Any]]:
    agents = load_registry().get("agents")
    if not isinstance(agents, dict):
        raise SystemExit(f"{SKILL_REGISTRY_PATH}: missing agents object")
    return agents


def load_workers() -> dict[str, dict[str, Any]]:
    workers = load_registry().get("workers")
    if not isinstance(workers, dict):
        raise SystemExit(f"{SKILL_REGISTRY_PATH}: missing workers object")
    return workers


def load_policy() -> dict[str, Any]:
    return load_json_subset_yaml(MCP_OPERATIONS_PATH)


def load_capabilities() -> dict[str, Any]:
    return load_json_subset_yaml(CAPABILITIES_PATH)


def mcp_tool_name(server: str, tool: str) -> str:
    """Claude Code's name for an MCP tool: mcp__<server>__<tool>."""
    return CLAUDE_RUNTIME["mcp_tool_format"].format(server=server, tool=tool)


def apply_markers(text: str, runtime: str) -> str:
    """Keep each runtime-marked line or block only for its runtime, with the markers removed.

    Unmarked lines are shared. An unknown runtime name is an error, so a typo cannot silently drop a line;
    so is a block that is unterminated, nested, closed twice, or holds a per-line marker.
    """

    def named_runtimes(group: str, line: str) -> list[str]:
        named = group.split(",")
        for name in named:
            if name not in RUNTIMES:
                raise ValueError(f"unknown runtime {name!r} in marker: {line[:60]!r}")
        return named

    kept: list[str] = []
    block: list[str] | None = None
    for line in text.split("\n"):
        if RUNTIME_BLOCK_CLOSE.match(line):
            if block is None:
                raise ValueError(f"runtime block close with no open block: {line[:60]!r}")
            block = None
            continue
        opened = RUNTIME_BLOCK_OPEN.match(line)
        if opened is not None:
            if block is not None:
                raise ValueError(f"runtime blocks do not nest: {line[:60]!r}")
            block = named_runtimes(opened.group(1), line)
            continue
        match = RUNTIME_MARKER.match(line)
        if match is None:
            if "<!-- runtime:" in line or "<!-- /runtime" in line:
                raise ValueError(f"malformed runtime marker (it must start the line): {line[:60]!r}")
            if block is None or runtime in block:
                kept.append(line)
            continue
        if block is not None:
            raise ValueError(f"a per-line runtime marker inside a runtime block: {line[:60]!r}")
        if runtime in named_runtimes(match.group(1), line):
            kept.append(line[match.end() :])
    if block is not None:
        raise ValueError("a runtime block is not closed")
    return "\n".join(kept)


def apply_glossary(text: str, runtime: str, hits: set[str] | None = None) -> str:
    """Ordered literal replacements that turn Claude Code wording into the runtime's own, then MCP tool names."""
    for entry in RUNTIMES[runtime].get("glossary", []):
        if entry["from"] in text:
            if hits is not None:
                hits.add(entry["from"])
            text = text.replace(entry["from"], entry["to"])
    return text


def apply_kernel_overrides(text: str, runtime: str) -> str:
    """Replace each kernel override once; an override that matches nothing or twice has drifted from the template."""
    for entry in RUNTIMES[runtime].get("kernel_overrides", []):
        count = text.count(entry["from"])
        if count != 1:
            raise ValueError(f"kernel override {entry['from']!r} matched {count} times, expected exactly 1")
        text = text.replace(entry["from"], entry["to"])
    return text


def tidy_blank_lines(text: str) -> str:
    return re.sub(r"\n{3,}", "\n\n", text)


def validate_kernel_template(errors: list[str]) -> None:
    if not KERNEL_TEMPLATE_PATH.is_file():
        errors.append(f"{KERNEL_TEMPLATE_PATH}: missing Claude Code kernel template")
        return
    text = KERNEL_TEMPLATE_PATH.read_text()
    for marker in (
        "Claude Code Workflow Kernel",
        "<!-- b-agentic-managed -->",
        KERNEL_ROUTING_START,
        KERNEL_DELEGATION_START,
    ):
        if marker not in text:
            errors.append(f"{KERNEL_TEMPLATE_PATH}: missing {marker!r}")
    if len(text.encode()) > MAX_KERNEL_BYTES:
        errors.append(f"{KERNEL_TEMPLATE_PATH}: exceeds {MAX_KERNEL_BYTES:,} byte kernel budget")
    if len(text.splitlines()) > MAX_KERNEL_LINES:
        errors.append(f"{KERNEL_TEMPLATE_PATH}: exceeds {MAX_KERNEL_LINES} line kernel budget")


def validate_skills(skills: list[dict[str, Any]], agents: dict[str, dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    validate_kernel_template(errors)
    prompt_dirs = {path.parent.name for path in (ROOT / "skills").glob("*/prompt.md")}
    names: list[str] = []
    delegated_agents: set[str] = set()

    for index, skill in enumerate(skills, start=1):
        label = f"skills[{index}]"
        if not isinstance(skill, dict):
            errors.append(f"{label}: expected object")
            continue
        name = ensure_string(skill.get("name"), f"{label}.name", errors)
        names.append(name)
        execution = skill.get("execution")
        if not isinstance(execution, dict):
            errors.append(f"{label}.execution: expected object")
        else:
            mode = ensure_string(execution.get("mode"), f"{label}.execution.mode", errors)
            if mode and mode not in EXECUTION_MODES:
                errors.append(f"{label}.execution.mode: expected {sorted(EXECUTION_MODES)}")
            agent = execution.get("agent")
            if mode == "subagent":
                agent_name = ensure_string(agent, f"{label}.execution.agent", errors)
                delegated_agents.add(agent_name)
                if agent_name and agent_name not in MANAGED_SUBAGENT_NAMES:
                    errors.append(f"{label}.execution.agent: unmanaged agent {agent_name!r}")
            elif agent is not None:
                errors.append(f"{label}.execution.agent: only subagent skills may name an agent")
        handoff = skill.get("handoff")
        if handoff is not None:
            if not isinstance(execution, dict) or execution.get("mode") != "subagent":
                errors.append(f"{label}.handoff: only subagent skills may define a handoff")
            non_empty_string_list(handoff, f"{label}.handoff", errors)
        gate = skill.get("primary_gate")
        if gate is not None:
            if not isinstance(execution, dict) or execution.get("mode") != "subagent":
                errors.append(f"{label}.primary_gate: only subagent skills may define a primary gate")
            if not isinstance(gate, dict) or set(gate) != {"runtimes", "label", "note"}:
                errors.append(f"{label}.primary_gate: expected runtimes, label, and note")
            else:
                if (
                    not isinstance(gate["runtimes"], list)
                    or not gate["runtimes"]
                    or not set(gate["runtimes"]) <= set(RUNTIMES)
                ):
                    errors.append(f"{label}.primary_gate.runtimes: expected a non-empty subset of {sorted(RUNTIMES)}")
                ensure_string(gate["label"], f"{label}.primary_gate.label", errors)
                ensure_string(gate["note"], f"{label}.primary_gate.note", errors)
        phase = ensure_string(skill.get("phase"), f"{label}.phase", errors)
        if phase and phase not in PHASES:
            errors.append(f"{label}.phase: expected {sorted(PHASES)}")
        ensure_string(skill.get("use"), f"{label}.use", errors)
        hint = skill.get("argument_hint")
        if hint is not None:
            hint = ensure_string(hint, f"{label}.argument_hint", errors)
            if hint and (len(hint) > ARGUMENT_HINT_MAX or not ARGUMENT_HINT_PATTERN.fullmatch(hint)):
                errors.append(
                    f"{label}.argument_hint: expected <required> or [optional] text of at most {ARGUMENT_HINT_MAX} characters"
                )
        prompt = skill.get("prompt")
        if not isinstance(prompt, dict):
            errors.append(f"{label}.prompt: expected object")
        else:
            ensure_string(prompt.get("description"), f"{label}.prompt.description", errors)
            if set(prompt) != {"description"}:
                errors.append(f"{label}.prompt: only description is supported by native skill front matter")
        routing = skill.get("routing")
        if not isinstance(routing, dict):
            errors.append(f"{label}.routing: expected object")
        else:
            ensure_string(routing.get("intent"), f"{label}.routing.intent", errors)
            explicit = routing.get("explicit_request", False)
            if not isinstance(explicit, bool):
                errors.append(f"{label}.routing.explicit_request: expected boolean")
            triggers = routing.get("triggers")
            entry = routing.get("entry", False)
            if not isinstance(entry, bool):
                errors.append(f"{label}.routing.entry: expected boolean")
            if explicit and entry:
                errors.append(f"{label}.routing: a skill is the routing entry or explicit-request, not both")
            if explicit:
                if triggers is not None:
                    errors.append(f"{label}.routing.triggers: explicit-request skills must omit triggers")
            elif entry is True:
                if triggers is not None:
                    errors.append(f"{label}.routing.triggers: the routing entry must omit triggers")
            elif not isinstance(triggers, list) or not triggers:
                errors.append(f"{label}.routing.triggers: expected non-empty array")
            elif not all(isinstance(trigger, str) and trigger for trigger in triggers):
                errors.append(f"{label}.routing.triggers: expected non-empty strings")
        if name and not (ROOT / "skills" / name / "prompt.md").is_file():
            errors.append(f"skills/{name}/prompt.md: missing canonical prompt source")
        elif name and f"\n{DELEGATION_BOUNDARY_HEADING}" in (ROOT / "skills" / name / "prompt.md").read_text():
            errors.append(
                f"skills/{name}/prompt.md: '{DELEGATION_BOUNDARY_HEADING}' is generator-owned; remove it from the prompt"
            )

    if len(names) != len(set(names)):
        errors.append("skills/registry.yaml: duplicate skill names")
    missing = sorted(prompt_dirs - set(names))
    extra = sorted(set(names) - prompt_dirs)
    if missing or extra:
        errors.append(f"skills/registry.yaml: prompt directory mismatch (missing={missing}, extra={extra})")
    if set(agents) != MANAGED_SUBAGENT_NAMES:
        errors.append(f"skills/registry.yaml: agents must name {sorted(MANAGED_SUBAGENT_NAMES)}")
    for name, agent in agents.items():
        label = f"agents.{name}"
        if not isinstance(agent, dict):
            errors.append(f"{label}: expected object")
            continue
        ensure_string(agent.get("description"), f"{label}.description", errors)
        model = ensure_string(agent.get("model"), f"{label}.model", errors)
        if model and model not in AGENT_MODELS:
            errors.append(f"{label}.model: expected one of {sorted(AGENT_MODELS)}")
        allowed_fields = {"description", "model", "mcp_tools"}
        if "effort" in agent:
            allowed_fields.add("effort")
            effort = ensure_string(agent["effort"], f"{label}.effort", errors)
            if effort and effort not in AGENT_EFFORTS:
                errors.append(f"{label}.effort: expected one of {sorted(AGENT_EFFORTS)}")
        if "max_turns" in agent:
            allowed_fields.add("max_turns")
            turns = agent["max_turns"]
            if isinstance(turns, bool) or not isinstance(turns, int) or turns < 1:
                errors.append(f"{label}.max_turns: expected positive integer")
        if name == "b-researcher":
            allowed_fields.add("conditional_tools")
            non_empty_string_list(agent.get("conditional_tools"), f"{label}.conditional_tools", errors)
        if set(agent) != allowed_fields:
            errors.append(f"{label}: expected only {sorted(allowed_fields)}")
    if delegated_agents != MANAGED_SUBAGENT_NAMES:
        errors.append(f"skills/registry.yaml: delegated skills must use {sorted(MANAGED_SUBAGENT_NAMES)}")
    return errors


def validate_workers(workers: dict[str, dict[str, Any]], agents: dict[str, dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    if set(workers) != MANAGED_WORKER_NAMES:
        errors.append(f"skills/registry.yaml: workers must name {sorted(MANAGED_WORKER_NAMES)}")
    if set(workers) & set(agents):
        errors.append("skills/registry.yaml: a worker must not share a name with a read-only specialist")
    for name, worker in workers.items():
        label = f"workers.{name}"
        if not isinstance(worker, dict):
            errors.append(f"{label}: expected object")
            continue
        ensure_string(worker.get("description"), f"{label}.description", errors)
        model = ensure_string(worker.get("model"), f"{label}.model", errors)
        if model and model not in AGENT_MODELS:
            errors.append(f"{label}.model: expected one of {sorted(AGENT_MODELS)}")
        allowed_fields = {"description", "model"}
        if "effort" in worker:
            allowed_fields.add("effort")
            effort = ensure_string(worker["effort"], f"{label}.effort", errors)
            if effort and effort not in AGENT_EFFORTS:
                errors.append(f"{label}.effort: expected one of {sorted(AGENT_EFFORTS)}")
        if "max_turns" in worker:
            allowed_fields.add("max_turns")
            turns = worker["max_turns"]
            if isinstance(turns, bool) or not isinstance(turns, int) or turns < 1:
                errors.append(f"{label}.max_turns: expected positive integer")
        # The tools are the generator's: a registry entry cannot widen or narrow them.
        for field in sorted(WORKER_FORBIDDEN_FIELDS & set(worker)):
            errors.append(f"{label}.{field}: not a worker field; the generator owns the tool list and the frontmatter")
        if set(worker) - WORKER_FORBIDDEN_FIELDS != allowed_fields:
            errors.append(f"{label}: expected only {sorted(allowed_fields)}")
    return errors


def validate_agent_tools(agents: dict[str, dict[str, Any]], policy: dict[str, Any]) -> list[str]:
    conditional = {
        mcp_tool_name(server, tool)
        for server, record in policy["servers"].items()
        for tool, classification in record["tools"].items()
        if classification == "conditional-read"
    }
    read_only = set(read_only_mcp_tools(policy))
    errors: list[str] = []
    for name, agent in agents.items():
        scoped = agent.get("mcp_tools")
        if (
            not isinstance(scoped, list)
            or not all(isinstance(tool, str) for tool in scoped)
            or len(scoped) != len(set(scoped))
        ):
            errors.append(f"agents.{name}.mcp_tools: expected unique tool names")
        else:
            errors.extend(
                f"agents.{name}.mcp_tools: {tool!r} is not a read-only tool" for tool in scoped if tool not in read_only
            )
            if CODEGRAPH_TOOL not in scoped:
                errors.append(f"agents.{name}.mcp_tools: must include {CODEGRAPH_TOOL}")
        tools = agent.get("conditional_tools", [])
        if (
            not isinstance(tools, list)
            or not all(isinstance(tool, str) for tool in tools)
            or len(tools) != len(set(tools))
        ):
            errors.append(f"agents.{name}.conditional_tools: expected unique tool names")
            continue
        for tool in tools:
            if tool not in conditional:
                errors.append(f"agents.{name}.conditional_tools: {tool!r} is not a conditional-read tool")
    return errors


def validate_snapshot_cli() -> list[str]:
    """Keep the snapshot CLI and the path rules in step."""
    errors: list[str] = []
    label = SNAPSHOT_CLI_PATH.relative_to(ROOT)
    if not SNAPSHOT_CLI_PATH.is_file():
        return [f"{label}: missing managed snapshot CLI"]
    text = SNAPSHOT_CLI_PATH.read_text()
    if 'SNAPSHOT_SCHEMA = "b-candidate-snapshot/4"' not in text:
        errors.append(f"{label}: snapshot schema must stay b-candidate-snapshot/4")
    flags_block = re.search(r"SNAPSHOT_DIFF_FLAGS = \[(.*?)\];", text, re.S)
    flags = re.findall(r'"([^"]+)"', flags_block.group(1)) if flags_block else []
    if not flags:
        errors.append(f"{label}: SNAPSHOT_DIFF_FLAGS not found")
    rules_label = PROTECTED_RULES_PATH.relative_to(ROOT)
    if not PROTECTED_RULES_PATH.is_file():
        return [*errors, f"{rules_label}: missing protected-path rules module"]
    rules_block = re.search(r"PROTECTED_RULES[^=]*= \[(.*?)\n\];", PROTECTED_RULES_PATH.read_text(), re.S)
    rules = re.findall(r'\["([^"]+)", "(allow|deny)"\]', rules_block.group(1)) if rules_block else []
    policy_rules = [(pattern, action) for pattern, action in PATH_RULES.items() if pattern != "*"]
    if rules != policy_rules:
        errors.append(f"{rules_label}: PROTECTED_RULES must match the generated path rules")
    return errors


def blocker_class_errors(classes: Any, prompt: str, label: str) -> list[str]:
    """Require the blocker_class enum to equal both blocker-class sentences of the b-review prompt (ADR-010)."""
    sentences = BLOCKER_CLASS_SENTENCE.findall(prompt)
    # One sentence per reviewer path (Codex gate and b-reviewer): a reworded or missing one must not go unchecked.
    if len(sentences) != BLOCKER_CLASS_SENTENCES:
        return [
            f"{label}: expected {BLOCKER_CLASS_SENTENCES} blocker class sentences "
            f"(Codex gate and reviewer) matching the blocker_class enum, found {len(sentences)}"
        ]
    errors = []
    for found in sentences:
        listed = [re.sub(r"^or ", "", part.strip()) for part in found.split(",")]
        if listed != classes:
            errors.append(
                f"{label}: a blocker class sentence differs from the blocker_class enum in references/artifacts.yaml"
            )
    return errors


STATS_FIELD_TYPES = ("count", "seconds", "enum", "bool", "hexkey", "date", "counts", "object")


def run_stats_errors(block: Any, enums: Any, label: str) -> list[str]:
    """Keep the run_stats field list numeric: no line, text, or unknown type can enter the local store (ADR-035)."""
    if not isinstance(block, dict):
        return [f"{label}: run_stats must be an object"]
    errors: list[str] = []
    if block.get("version") != 1:
        errors.append(f"{label}: run_stats.version must be 1")
    if block.get("field_types") != list(STATS_FIELD_TYPES):
        errors.append(f"{label}: run_stats.field_types must be exactly {list(STATS_FIELD_TYPES)}")
    for name in ("max_line", "max_file"):
        if not isinstance(block.get(name), int) or isinstance(block.get(name), bool) or block[name] < 1:
            errors.append(f"{label}: run_stats.{name} must be a positive integer")
    for name in ("store", "off"):
        if not isinstance(block.get(name), str) or not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", block[name]):
            errors.append(f"{label}: run_stats.{name} must be a plain file name")
    named_enums = enums if isinstance(enums, dict) else {}

    def string_list(value: Any) -> bool:
        return isinstance(value, list) and bool(value) and all(isinstance(item, str) and item for item in value)

    def walk(spec: Any, where: str) -> None:
        kind = spec.get("type") if isinstance(spec, dict) else None
        if kind not in STATS_FIELD_TYPES:
            errors.append(f"{label}: run_stats.{where} has a type outside {list(STATS_FIELD_TYPES)}")
            return
        if kind == "enum" and not string_list(spec.get("values")):
            errors.append(f"{label}: run_stats.{where} needs a list of values")
        if kind == "hexkey" and not (isinstance(spec.get("length"), int) and spec["length"] > 0):
            errors.append(f"{label}: run_stats.{where} needs a key length")
        if kind == "counts":
            keys, named = spec.get("keys"), spec.get("enum")
            if (keys is None) == (named is None):
                errors.append(f"{label}: run_stats.{where} needs exactly one of keys or enum")
            if keys is not None and not string_list(keys):
                errors.append(f"{label}: run_stats.{where}.keys must be a list of names")
            if named is not None and named not in named_enums:
                errors.append(f"{label}: run_stats.{where} names an unknown enum")
            if "extra" in spec and not string_list(spec["extra"]):
                errors.append(f"{label}: run_stats.{where}.extra must be a list of names")
        if kind == "object":
            fields = spec.get("fields")
            if not isinstance(fields, dict) or not fields:
                errors.append(f"{label}: run_stats.{where} needs fields")
                return
            for name, sub in fields.items():
                walk(sub, f"{where}.{name}")

    fields = block.get("fields")
    if not isinstance(fields, dict) or not fields:
        return [*errors, f"{label}: run_stats.fields must list the fields"]
    for name, sub in fields.items():
        walk(sub, name)
    return errors


def validate_artifacts_schema() -> list[str]:
    """Keep references/artifacts.yaml, the run CLI, and the path rules in step (ADR-010)."""
    errors: list[str] = []
    label = ARTIFACTS_PATH.relative_to(ROOT)
    try:
        schema = json.loads(ARTIFACTS_PATH.read_text())
    except (OSError, ValueError) as exc:
        return [f"{label}: unreadable ({exc})"]
    if schema.get("version") != 1:
        errors.append(f"{label}: version must be 1")
    kinds = schema.get("kinds", {})
    if set(kinds) != set(ARTIFACT_KINDS):
        errors.append(f"{label}: kinds must be exactly {list(ARTIFACT_KINDS)}")
    enums = schema.get("enums", {})
    run_files = schema.get("run_files", [])
    for required in ("state.json", "artifacts.json", "lock", "mutex"):
        if required not in run_files:
            errors.append(f"{label}: run_files must include {required}")

    def walk(spec: Any, where: str) -> None:
        if not isinstance(spec, dict) or spec.get("type") not in {"line", "text", "id", "enum", "list", "object"}:
            errors.append(f"{label}: {where} has an unknown field type")
            return
        if spec["type"] == "enum" and not (spec.get("values") or spec.get("enum") in enums):
            errors.append(f"{label}: {where} names an unknown enum")
        if spec["type"] == "id":
            try:
                re.compile(spec.get("pattern", ""))
            except re.error:
                errors.append(f"{label}: {where} has an invalid pattern")
        if spec["type"] == "list":
            walk(spec.get("items"), f"{where}[]")
        if spec["type"] == "object":
            for name, sub in spec.get("fields", {}).items():
                walk(sub, f"{where}.{name}")

    for kind in ARTIFACT_KINDS:
        entry = kinds.get(kind)
        if not isinstance(entry, dict):
            continue
        if entry.get("file") not in run_files:
            errors.append(f"{label}: {kind}.file must be listed in run_files")
        if not entry.get("phases") or not entry.get("example"):
            errors.append(f"{label}: {kind} needs phases and an example")
        for name, sub in entry.get("fields", {}).items():
            walk(sub, f"{kind}.{name}")
    errors += run_stats_errors(schema.get("run_stats"), enums, str(label))
    review_label = str(B_REVIEW_PROMPT_PATH.relative_to(ROOT))
    if B_REVIEW_PROMPT_PATH.is_file():
        errors += blocker_class_errors(enums.get("blocker_class"), B_REVIEW_PROMPT_PATH.read_text(), review_label)
    else:
        errors.append(f"{review_label}: missing, so the blocker_class enum cannot be checked")
    if not RUN_CLI_PATH.is_file():
        return [*errors, f"{RUN_CLI_PATH.relative_to(ROOT)}: missing run artifact CLI"]
    text = RUN_CLI_PATH.read_text()
    block = re.search(r"PROTECTED_RULES = \[(.*?)\n\]", text, re.S)
    mirror = re.findall(r'\("([^"]+)", "(allow|deny)"\)', block.group(1)) if block else []
    policy = [(pattern, action) for pattern, action in PATH_RULES.items() if pattern != "*"]
    if mirror != policy:
        errors.append(f"{RUN_CLI_PATH.relative_to(ROOT)}: PROTECTED_RULES must match the generated path rules")
    # The prune hint threshold lives in both CLIs; a drift would make init and prune disagree about the same folder count.
    state_core = STATE_CORE_PATH.read_text() if STATE_CORE_PATH.is_file() else ""
    hint_js = re.search(r"export const HINT_RUNS = (\d+);", state_core)
    hint_py = re.search(r"^HINT_RUNS = (\d+)$", text, re.M)
    if not hint_js or not hint_py or hint_js.group(1) != hint_py.group(1):
        errors.append(
            f"{STATE_CORE_PATH.relative_to(ROOT)} and {RUN_CLI_PATH.relative_to(ROOT)}: HINT_RUNS must be defined and equal"
        )
    return errors


def packet_phases() -> tuple[str, ...]:
    """The run phases `b_run.py handoff` renders a packet for, read from the CLI itself."""
    block = re.search(r"^HANDOFF_PHASES = \((.*?)\)$", RUN_CLI_PATH.read_text(), re.M)
    return tuple(re.findall(r'"([a-z]+)"', block.group(1))) if block else ()


def state_phases() -> tuple[str, ...]:
    block = re.search(r"export const PHASES = \[(.*?)\];", STATE_CORE_PATH.read_text(), re.S)
    return tuple(re.findall(r'"([a-z]+)"', block.group(1))) if block else ()


def validate_contracts(skills: list[dict[str, Any]]) -> list[str]:
    """Every skill says what it is to a run, in phases the run CLIs know, and every phase has a skill."""
    errors: list[str] = []
    packets = packet_phases()
    if not packets or not set(packets) <= set(state_phases()):
        errors.append(f"{RUN_CLI_PATH.relative_to(ROOT)}: HANDOFF_PHASES must be run phases of b-state.mjs")
    covered: set[str] = set()
    orchestrators: list[str] = []
    for skill in skills:
        label = f"skills.{skill.get('name')}.contract"
        contract = skill.get("contract")
        if not isinstance(contract, dict) or contract.get("role") not in CONTRACT_ROLES:
            errors.append(f"{label}.role: expected one of {sorted(CONTRACT_ROLES)}")
            continue
        role = contract["role"]
        if role in ("utility", "orchestrator"):
            if set(contract) != {"role"}:
                errors.append(f"{label}: a {role} declares only its role")
            if role == "orchestrator":
                orchestrators.append(skill.get("name"))
            continue
        if set(contract) != {"role", "phases", "evidence", "parallel_safe"}:
            errors.append(f"{label}: expected role, phases, evidence, and parallel_safe")
            continue
        phases = contract["phases"]
        if (
            not isinstance(phases, list)
            or not phases
            or not all(isinstance(phase, str) for phase in phases)
            or len(set(phases)) != len(phases)
            or not set(phases) <= set(packets)
        ):
            errors.append(f"{label}.phases: expected distinct run phases from {list(packets)}")
            continue
        ensure_string(contract["evidence"], f"{label}.evidence", errors)
        if not isinstance(contract["parallel_safe"], bool):
            errors.append(f"{label}.parallel_safe: expected boolean")
        elif role == "phase":
            covered.update(phases)
            if contract["parallel_safe"] and TREE_CHANGING_PHASES & set(phases):
                errors.append(f"{label}.parallel_safe: a skill for {sorted(TREE_CHANGING_PHASES)} changes the tree")
    if orchestrators != ["b-flow"]:
        errors.append("skills/registry.yaml: b-flow, and only b-flow, is the orchestrator")
    elif PHASE_CONTRACTS_PLACEHOLDER not in (ROOT / "skills" / "b-flow" / "prompt.md").read_text():
        errors.append(f"skills/b-flow/prompt.md: missing {PHASE_CONTRACTS_PLACEHOLDER}")
    missing = [phase for phase in SKILL_RUN_PHASES if phase not in covered]
    if missing:
        errors.append(f"skills/registry.yaml: no phase skill for run phase(s) {missing}")
    # Change requests enter a run through the orchestrator, and its routing line names exactly the
    # skills whose work that is: the phase skills of `implement`.
    entries = [skill for skill in skills if isinstance(skill.get("routing"), dict) and skill["routing"].get("entry")]
    if [skill.get("name") for skill in entries] != orchestrators:
        errors.append("skills/registry.yaml: the orchestrator, and only the orchestrator, is the routing entry")
    else:
        implementers = {
            skill.get("name")
            for skill in skills
            if isinstance(skill.get("contract"), dict)
            and skill["contract"].get("role") == "phase"
            and "implement" in (skill["contract"].get("phases") or [])
        }
        for skill in entries:
            if set(re.findall(r"b-[a-z0-9-]+", str(skill["routing"].get("intent")))) != implementers:
                errors.append(
                    f"skills.{skill.get('name')}.routing.intent: must name exactly the implement-phase skills"
                    f" {sorted(implementers)}"
                )
    return errors


def render_phase_contracts(skills: list[dict[str, Any]]) -> str:
    """The orchestrator's phase table: who works in each run phase, its packet, and what each skill returns."""

    def names(phase: str, role: str) -> str:
        return ", ".join(
            f"`{skill['name']}`"
            for skill in skills
            if skill["contract"]["role"] == role and phase in skill["contract"]["phases"]
        )

    lines = ["| Run phase | Phase skills | Evidence providers | Packet |", "| --- | --- | --- | --- |"]
    for phase in packet_phases():
        lines.append(
            f"| {phase} | {names(phase, 'phase') or 'main session'} | {names(phase, 'provider') or 'none'}"
            f" | `b_run.py handoff {phase}` |"
        )
    # Skills that return the same evidence share one line.
    returned: dict[str, list[str]] = {}
    for skill in skills:
        if skill["contract"]["role"] in ("phase", "provider"):
            returned.setdefault(skill["contract"]["evidence"], []).append(f"`{skill['name']}`")
    lines += ["", "What each skill returns to the run:", ""]
    lines += [f"- {', '.join(names_)}: {evidence}." for evidence, names_ in returned.items()]
    return "\n".join(lines)


def validate_optional_components(skills: list[dict[str, Any]], policy: dict[str, Any]) -> list[str]:
    """Optional components name real main-session skills and policy servers, never overlap, and can be
    filtered out of both kernels (exactly one routing line per skill)."""
    sys.path.insert(0, str(ROOT / "tooling" / "install"))
    try:
        import optional_components
    finally:
        sys.path.pop(0)
    try:
        components = optional_components.load(ROOT)
    except ValueError as exc:
        return [str(exc)]
    errors: list[str] = []
    by_name = {skill.get("name"): skill for skill in skills if isinstance(skill, dict)}
    servers = policy.get("servers", {})
    seen_skills: dict[str, str] = {}
    seen_servers: dict[str, str] = {}
    for key, component in components.items():
        label = f"optional_components.{key}"
        if not component.get("skills") and not component.get("mcp_servers"):
            errors.append(f"{label}: expected at least one skill or MCP server")
        for name in component.get("skills", []):
            skill = by_name.get(name)
            if skill is None:
                errors.append(f"{label}: unknown skill {name!r}")
            elif skill.get("execution", {}).get("mode") != "main":
                errors.append(f"{label}: {name} must run in the main session (a delegated skill needs its agent)")
            if name in seen_skills:
                errors.append(f"{label}: skill {name} is also in optional_components.{seen_skills[name]}")
            seen_skills[name] = key
        for name in component.get("mcp_servers", []):
            if name not in servers:
                errors.append(f"{label}: MCP server {name!r} is not in the MCP operations policy")
            if name in seen_servers:
                errors.append(f"{label}: server {name} is also in optional_components.{seen_servers[name]}")
            seen_servers[name] = key
    for key, component in components.items():
        try:
            optional_components.filter_kernel(KERNEL_TEMPLATE_PATH.read_text(), set(component.get("skills", [])))
        except (OSError, ValueError) as exc:
            errors.append(f"optional_components.{key}: {KERNEL_TEMPLATE_PATH.relative_to(ROOT)}: {exc}")
    return errors


def validate_policy(policy: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if policy.get("schema_version") != 1:
        errors.append(f"{MCP_OPERATIONS_PATH}: schema_version must be 1")
    if policy.get("format") != "json-subset-of-yaml":
        errors.append(f"{MCP_OPERATIONS_PATH}: format must be json-subset-of-yaml")
    classes = policy.get("classes")
    servers = policy.get("servers")
    if not isinstance(classes, dict) or not classes:
        errors.append(f"{MCP_OPERATIONS_PATH}: classes must be a non-empty object")
    if not isinstance(servers, dict) or not servers:
        errors.append(f"{MCP_OPERATIONS_PATH}: servers must be a non-empty object")
    if not isinstance(classes, dict) or not isinstance(servers, dict):
        return errors
    for name, meta in classes.items():
        if not isinstance(name, str) or not isinstance(meta, dict):
            errors.append(f"{MCP_OPERATIONS_PATH}: invalid class {name!r}")
            continue
        for field in ("policy", "native_permission", "notes"):
            ensure_string(meta.get(field), f"classes.{name}.{field}", errors)
        if meta.get("native_permission") not in {"allow", "ask", "deny"}:
            errors.append(f"classes.{name}.native_permission: expected allow, ask, or deny")
    seen_tools: set[str] = set()
    for server, record in servers.items():
        if not isinstance(server, str) or not re.fullmatch(r"[a-z][a-z0-9_]*", server):
            errors.append(f"servers.{server}: server name must be lowercase letters, digits, and underscores")
            continue
        tools = record.get("tools") if isinstance(record, dict) else None
        if not isinstance(tools, dict) or not tools:
            errors.append(f"servers.{server}.tools: expected non-empty object")
            continue
        if set(record) != {"tools"}:
            errors.append(f"servers.{server}: expected only a tools object")
        for tool, class_name in tools.items():
            if not re.fullmatch(r"[A-Za-z0-9_.-]+", str(tool)):
                errors.append(f"servers.{server}.tools.{tool}: invalid tool name")
                continue
            name = mcp_tool_name(server, str(tool))
            if name in seen_tools:
                errors.append(f"{MCP_OPERATIONS_PATH}: duplicate tool name {name!r}")
            seen_tools.add(name)
            if class_name not in classes:
                errors.append(f"servers.{server}.tools.{tool}: unknown class {class_name!r}")
    return errors


def validate_capabilities(contract: dict[str, Any], policy: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if contract.get("schema_version") != 1:
        errors.append(f"{CAPABILITIES_PATH}: schema_version must be 1")
    if contract.get("format") != "json-subset-of-yaml":
        errors.append(f"{CAPABILITIES_PATH}: format must be json-subset-of-yaml")
    capabilities = contract.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities:
        return [*errors, f"{CAPABILITIES_PATH}: capabilities must be a non-empty array"]
    identifiers: set[str] = set()
    mcp_servers: set[str] = set()
    agent_names: set[str] = set()
    for index, capability in enumerate(capabilities, start=1):
        label = f"capabilities[{index}]"
        if not isinstance(capability, dict):
            errors.append(f"{label}: expected object")
            continue
        identifier = ensure_string(capability.get("id"), f"{label}.id", errors)
        if identifier in identifiers:
            errors.append(f"{label}.id: duplicate {identifier!r}")
        identifiers.add(identifier)
        kind = ensure_string(capability.get("kind"), f"{label}.kind", errors)
        if kind not in CAPABILITY_KINDS:
            errors.append(f"{label}.kind: expected one of {sorted(CAPABILITY_KINDS)}")
        tier = ensure_string(capability.get("tier"), f"{label}.tier", errors)
        if tier and tier not in CAPABILITY_TIERS:
            errors.append(f"{label}.tier: expected one of {sorted(CAPABILITY_TIERS)}")
        if kind == "agent" and tier == "exclusive":
            errors.append(f"{label}.tier: agent capabilities may not be exclusive (ADR-032)")
        for field in ("purpose", "owner", "trigger", "readiness", "fallback"):
            ensure_string(capability.get(field), f"{label}.{field}", errors)
        non_empty_string_list(capability.get("prerequisites"), f"{label}.prerequisites", errors)
        has_runtimes = "runtimes" in capability
        runtimes = capability.get("runtimes")
        valid_runtimes = isinstance(runtimes, list) and bool(runtimes) and set(runtimes) <= set(RUNTIMES)
        if has_runtimes and not valid_runtimes:
            errors.append(f"{label}.runtimes: expected a non-empty subset of {sorted(RUNTIMES)}")
        if tier == "exclusive":
            if not valid_runtimes or set(runtimes) == set(RUNTIMES):
                errors.append(
                    f"{label}.runtimes: exclusive capabilities require a non-empty proper subset of {sorted(RUNTIMES)}"
                )
        elif tier in CAPABILITY_TIERS and has_runtimes:
            errors.append(f"{label}.runtimes: {tier} capabilities must not carry runtimes")
        signal = capability.get("status_signal")
        if not isinstance(signal, dict) or signal.get("sensitive") is not False:
            errors.append(f"{label}.status_signal: must be a non-sensitive object")
        probe = capability.get("probe")
        if not isinstance(probe, dict) or probe.get("type") != kind:
            errors.append(f"{label}.probe.type: must match capability kind")
        state = capability.get("install_state")
        if not isinstance(state, dict) or set(state) != {"action", "state"}:
            errors.append(f"{label}.install_state: expected action and state")
        source = capability.get("source")
        if not isinstance(source, dict) or not source:
            errors.append(f"{label}.source: expected non-empty object")
        if kind == "mcp":
            mcp = capability.get("mcp")
            if not isinstance(mcp, dict):
                errors.append(f"{label}.mcp: expected object")
            else:
                server = ensure_string(mcp.get("server"), f"{label}.mcp.server", errors)
                mcp_servers.add(server)
                if isinstance(probe, dict) and probe.get("server") != server:
                    errors.append(f"{label}.probe.server: must match mcp.server")
        if kind == "agent":
            agent = capability.get("agent")
            names = agent.get("names") if isinstance(agent, dict) else None
            if not isinstance(names, list) or set(names) != MANAGED_SUBAGENT_NAMES:
                errors.append(f"{label}.agent.names: must name {sorted(MANAGED_SUBAGENT_NAMES)}")
            else:
                agent_names.update(names)
                source_dir = agent.get("source")
                if source_dir != str(CLAUDE_AGENTS_DIR.relative_to(ROOT)):
                    errors.append(f"{label}.agent.source: expected generated Claude Code agent directory")
        if kind == "plugin" and (
            not isinstance(probe, dict) or not isinstance(probe.get("plugin"), str) or not probe["plugin"]
        ):
            errors.append(f"{label}.probe.plugin: expected plugin identifier")
    policy_servers = set((policy.get("servers") or {}).keys())
    if mcp_servers != policy_servers:
        errors.append(f"{CAPABILITIES_PATH}: MCP server set differs from policy")
    if agent_names != MANAGED_SUBAGENT_NAMES:
        errors.append(f"{CAPABILITIES_PATH}: missing managed specialist agents")
    return errors


def render_readme_skills_table(skills: list[dict[str, Any]]) -> str:
    optional = {
        name: component_id
        for component_id, component in load_registry().get("optional_components", {}).items()
        for name in component.get("skills", [])
    }

    def use(skill: dict[str, Any]) -> str:
        component_id = optional.get(skill["name"])
        return skill["use"] if component_id is None else f"{skill['use']} (optional: `--with={component_id}`)"

    rows = ["| Skill | Phase | Use |", "|---|---|---|"]
    rows.extend(f"| `{skill['name']}` | {skill['phase']} | {use(skill)} |" for skill in skills)
    return "\n".join(rows)


def render_mcp_operations_table(policy: dict[str, Any]) -> str:
    groups: dict[str, list[str]] = {}
    for name, meta in policy["classes"].items():
        groups.setdefault(meta["policy"], []).append(f"`{name}`")
    lines = [f"- {label}: {', '.join(names)}." for label, names in groups.items()]
    lines.append(
        "- Unclassified MCP tools require user approval even without a native prompt; `trusted-mutation` runs in the main session only."
    )
    return "\n".join(lines)


def primary_gate(skill: dict[str, Any], runtime: str) -> dict[str, Any] | None:
    """The gate a delegated skill tries first on this runtime, with its subagent as the fallback."""
    gate = skill.get("primary_gate")
    return gate if gate and runtime in gate["runtimes"] else None


def render_delegation(skills: list[dict[str, Any]], runtime: str = "claude") -> str:
    delegated = [skill for skill in skills if skill["execution"]["mode"] == "subagent"]
    lines = [
        "- Delegated skills run only in their named `Agent` subagent type with a bounded task naming the exact skill. Never do their work with main-session tools, even for a quick lookup or when a tool description invites it; if the subagent is unavailable, report the gap and ask. "
        f"{RUNTIMES[runtime]['delegation_unavailable']} Skill -> agent:",
    ]
    lines.extend(f"  - `{skill['name']}` -> `{skill['execution']['agent']}`." for skill in delegated)
    lines.extend(f"  - {gate['note']}" for gate in (primary_gate(skill, runtime) for skill in delegated) if gate)
    lines.append("- All other skills run in the main session.")
    return "\n".join(lines)


DELEGATION_BOUNDARY_HEADING = "## Delegation boundary"


def render_delegation_boundary(skill: dict[str, Any], runtime: str = "claude") -> str:
    name = skill["name"]
    agent = skill["execution"]["agent"]
    config = RUNTIMES[runtime]
    editing = ", ".join(f"`{tool}`" for tool in config["editing_tools"])
    check = config["profile_check"].format(agent=agent, editing=editing, name=name)
    gate = primary_gate(skill, runtime)
    if gate:
        intro = f"`{name}` runs the {gate['label']} gate first, from the main session as the Steps direct; it runs in the `{agent}` subagent only when that gate is unavailable or the user chooses it after a refused or void run."
        main_line = f"- Main session: reading this file prepares both paths. The {gate['label']} gate is not your own review, and the Steps say when it counts as unavailable or when the user may choose the subagent. Only then gather the parent-owned evidence below and {check}. Do not do this skill's work with your own tools, even for a quick, small, or single-lookup request. If the subagent is unavailable or fails, or its result notes an unknown agent type or `general-purpose` fallback (discard that result), report the gap and ask the user; never fall back to self-execution. Evaluate the returned result before any user-facing or worktree action."
    else:
        intro = f"`{name}` runs only in the `{agent}` subagent."
        main_line = f"- Main session: reading this file prepares the handoff; it never authorizes running the steps below yourself. Gather the parent-owned evidence and {check}. Do not do this skill's work with your own tools, even for a quick, small, or single-lookup request. If the subagent is unavailable or fails, or its result notes an unknown agent type or `general-purpose` fallback (discard that result), report the gap and ask the user; never fall back to self-execution. Evaluate the returned result before any user-facing or worktree action."
    lines = [
        DELEGATION_BOUNDARY_HEADING,
        "",
        intro,
        "",
        main_line,
        f"- `{agent}` child: execute the {'reviewer steps below only (never the ' + gate['label'] + ' gate)' if gate else 'steps below'} read-only, return this skill's Output format to the main session, and do not delegate again.",
    ]
    handoff = skill.get("handoff", [])
    if handoff:
        lines.extend(
            [
                "",
                "Parent-owned evidence to gather and pass to the child (or state what is unavailable):",
                "",
                *[f"- {item}" for item in handoff],
            ]
        )
    lines.extend(["", f"User arguments for the bounded task: {config['arguments_placeholder']}"])
    return "\n".join(lines)


def render_routing(skills: list[dict[str, Any]]) -> str:
    lines = []
    for skill in skills:
        suffix = " only on explicit user request" if skill["routing"].get("explicit_request") else ""
        if skill["routing"].get("entry"):
            suffix = ENTRY_ROUTING_SUFFIX
        lines.append(f"- {skill['routing']['intent']} -> `{skill['name']}`{suffix}.")
    return "\n".join(lines)


def fold_yaml(key: str, value: str) -> list[str]:
    wrapper = textwrap.TextWrapper(width=74, initial_indent="  ", subsequent_indent="  ", break_long_words=False)
    return [f"{key}: >", *wrapper.fill(value).splitlines()]


def render_skill_file(skill: dict[str, Any], runtime: str = "claude", hits: set[str] | None = None) -> str:
    name = skill["name"]
    description = skill["prompt"]["description"]
    body = (ROOT / "skills" / name / "prompt.md").read_text().rstrip()
    body = apply_markers(body, runtime)
    body = body.replace("{{skill_support_path}}", "<skill-dir>")
    if PHASE_CONTRACTS_PLACEHOLDER in body:
        body = body.replace(PHASE_CONTRACTS_PLACEHOLDER, render_phase_contracts(load_skills()))
    execution = skill["execution"]
    if execution["mode"] == "subagent":
        head, sep, rest = body.partition("\n## ")
        if not sep:
            raise SystemExit(f"skills/{name}/prompt.md: expected a '## ' section to place the delegation boundary")
        body = f"{head}\n{render_delegation_boundary(skill, runtime)}\n\n## {rest}"
    if runtime != "claude":
        body = tidy_blank_lines(apply_glossary(body, runtime, hits))
    lines = ["---", f"name: {name}"]
    lines.extend(fold_yaml("description", description))
    if skill.get("argument_hint") and runtime == "claude":
        lines.append(f"argument-hint: {json.dumps(skill['argument_hint'], ensure_ascii=False)}")
    lines.extend(
        [
            "metadata:",
            f"  phase: {skill['phase']}",
            f"  execution_mode: {execution['mode']}",
        ]
    )
    if execution["mode"] == "subagent":
        lines.append(f"  agent: {execution['agent']}")
    lines.extend(
        [
            "---",
            "",
            f"<!-- Generated from skills/registry.yaml and skills/{name}/prompt.md. Edit those sources, not this file. -->",
            "",
            body,
            "",
        ]
    )
    return "\n".join(lines)


TURN_BUDGET_NOTICE = (
    "If the harness warns about your turn budget, make no further tool calls: return the skill's Output format "
    "now with partial findings, explicit gaps, and the narrowest next step for the main session."
)


def read_only_mcp_tools(policy: dict[str, Any]) -> list[str]:
    return [
        mcp_tool_name(server, tool)
        for server, record in policy["servers"].items()
        for tool, class_name in record["tools"].items()
        if class_name == "read-only"
    ]


def agent_mcp_tools(agent: dict[str, Any], policy: dict[str, Any]) -> list[str]:
    """The agent's own MCP allowlist, in policy order; every tool loaded into a child costs context on each spawn."""
    scoped = set(agent["mcp_tools"])
    return [tool for tool in read_only_mcp_tools(policy) if tool in scoped]


def agent_tool_list(agent: dict[str, Any], policy: dict[str, Any]) -> list[str]:
    return ["Read", "Grep", "Glob", "Bash", *agent_mcp_tools(agent, policy), *agent.get("conditional_tools", [])]


def render_agent_file(
    name: str, agent: dict[str, Any], skills: list[dict[str, Any]], policy: dict[str, Any] | None = None
) -> str:
    policy = policy if policy is not None else load_policy()
    bound_skills = [
        skill["name"]
        for skill in skills
        if skill["execution"]["mode"] == "subagent" and skill["execution"]["agent"] == name
    ]
    skill_list = " or ".join(f"`{skill}`" for skill in bound_skills)
    return "\n".join(
        [
            "---",
            f"name: {name}",
            f"description: {json.dumps(agent['description'])}",
            f"tools: {', '.join(agent_tool_list(agent, policy))}",
            f"model: {agent['model']}",
            *([f"effort: {agent['effort']}"] if "effort" in agent else []),
            *([f"maxTurns: {agent['max_turns']}"] if "max_turns" in agent else []),
            "---",
            "",
            f"You are the b-agentic `{name}` subagent. The main session delegates only {skill_list} to you and has already selected the exact skill; do not route again or launch a nested subagent.",
            "",
            "Read and execute the named skill from the installed `~/.claude/skills/<name>/SKILL.md` for the supplied bounded task. Return that skill's own Output format; do not substitute a profile-specific template. The skill's Delegation boundary directs the main session to delegate; you are the named child, so execute its steps.",
            "",
            "Remain read-only. Do not edit, write, commit, stage, run generators or fixers, or ask the user questions. Do not execute external/shared mutation, local upload, lifecycle, or authentication actions; report the required operation to the main session. A returned result is not authority to change files, commit, push, or report task completion. If a required tool is absent, tell the main session rather than bypassing the allowlist.",
            "",
            TURN_BUDGET_NOTICE,
            "",
            "<!-- Managed by b-agentic. Generated from skills/registry.yaml. Do not edit this file. -->",
            "",
        ]
    )


WORKER_TURN_BUDGET_NOTICE = (
    "If the harness warns about your turn budget, make no further tool calls: return the report now, stating what "
    "is done, what is not, and the narrowest next step for the main session."
)


def worker_tool_list(agents: dict[str, dict[str, Any]], policy: dict[str, Any]) -> list[str]:
    """Edit and Write on top of the planner's reads; never a mutating MCP class, a prompt, or a child."""
    return [*WORKER_TOOLS, *agent_mcp_tools(agents["b-planner"], policy)]


def render_worker_body(name: str, runtime: str = "claude") -> list[str]:
    is_pi = runtime == "pi"
    config_dir = RUNTIMES[runtime]["config_dir"]
    prompt_tool = "ask_user_question" if is_pi else "AskUserQuestion"
    file_tools = "`read`, `edit`, `write`, and `grep`" if is_pi else "`Read`, `Edit`, `Write`, and `Grep`"
    return [
        f"You are the b-agentic `{name}` subagent: a writer child of a `/b-flow` run. The main session gives you exactly one approved plan step with its packet and waits; it edits nothing while you work. Do not route, ask the user, delegate, or launch a nested subagent.",
        "",
        f"Read the phase skill the main session names from the installed `{config_dir}/skills/<name>/SKILL.md` and follow its editing guidance for this step only. These parts do not apply in a child: `b-implement` steps 1-3 and 6-7 and its Output format; `b-frontend`'s questions, its browser hand-off, and adding a component with the package runner; any `{prompt_tool}` in `b-refactor` or `b-test`; every review, commit, and spec-recording step.",
        "",
        "Edit in place, only inside the approved scope and preferably only the step's own paths. Never touch `.b-agentic`, likely-secret files (`.env`, `*.pem`, `credentials.*`, `secrets.*`), or git history: no commit, stage, stash, reset, checkout, rebase, or push. Install nothing. Run no generator or fixer the step does not name, no `b-state.mjs` or `b_run.py` command (nor its `b-state` or `b-run` wrapper), and no external, upload, lifecycle, or authentication action. If you need a path outside the scope, a decision, or a dependency, stop and answer `NEEDS INPUT: <one question>`.",
        "",
        f"If the packet has a `Working directory` line, work only there: it is your own git worktree, and another worker may run beside you in a different one. Use absolute paths under it for {file_tools}, start every shell command with `cd <that directory> &&`, and never write to the main repository or to another worktree. CodeGraph indexes the main tree: use it for orientation only, and read and edit the files under your own directory. Your check runs there; if it needs something a fresh checkout lacks, such as installed packages, report that instead of installing it. Without that line, work in the repository root.",
        "",
        "Run the step's narrowest check, then report in this order: the step id; the changed paths; the check command and its exit code; deviations; open questions or `NEEDS INPUT`. Your report is evidence, not authority: the main session inspects the diff, reruns the check, and records the step.",
        "",
        WORKER_TURN_BUDGET_NOTICE,
        "",
        "<!-- Managed by b-agentic. Generated from skills/registry.yaml. Do not edit this file. -->",
        "",
    ]


def render_worker_file(
    name: str, worker: dict[str, Any], agents: dict[str, dict[str, Any]], policy: dict[str, Any] | None = None
) -> str:
    policy = policy if policy is not None else load_policy()
    return "\n".join(
        [
            "---",
            f"name: {name}",
            f"description: {json.dumps(worker['description'])}",
            f"tools: {', '.join(worker_tool_list(agents, policy))}",
            f"model: {worker['model']}",
            *([f"effort: {worker['effort']}"] if "effort" in worker else []),
            *([f"maxTurns: {worker['max_turns']}"] if "max_turns" in worker else []),
            "---",
            "",
            *render_worker_body(name, "claude"),
        ]
    )


HOOK_DIR = f'"{CLAUDE_RUNTIME["hook_dir"]}'
# Claude Code runs the managed scripts with Bun (ADR-018). The flags keep Bun from loading the working
# directory's bunfig.toml preload and .env files into a hook or helper; the installer replaces the leading
# `bun` with the absolute path it found.
BUN_COMMAND = "bun --no-env-file --config=/dev/null"


def hook_command(script: str) -> str:
    return f'{BUN_COMMAND} {HOOK_DIR}/{script}"'


def render_hooks() -> dict[str, Any]:
    """Hook entries merged into the user's settings.json, keyed by exact command."""
    return {
        "PreToolUse": [
            {
                "matcher": "Read|Edit|Write|NotebookEdit|Grep|Glob",
                "hooks": [{"type": "command", "command": hook_command("b-path-guard.mjs"), "onFailure": "block"}],
            },
            {
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": hook_command("b-codex-guard.mjs")}],
            },
            {
                # Permission rules match tool names only, so the alexandria argument of the auto-allowed
                # scrape tool needs a hook to reach the prompt the policy keeps for the billed lookups.
                "matcher": "mcp__firecrawl__firecrawl_scrape",
                "hooks": [{"type": "command", "command": hook_command("b-alexandria-guard.mjs"), "onFailure": "block"}],
            },
        ],
        "PostToolUse": [
            {
                "matcher": "Edit|Write|NotebookEdit|Bash",
                "hooks": [{"type": "command", "command": hook_command("b-verify-gate.mjs")}],
            }
        ],
        "Stop": [{"hooks": [{"type": "command", "command": hook_command("b-verify-gate.mjs")}]}],
        "SessionStart": [
            {
                "matcher": "compact",
                "hooks": [{"type": "command", "command": hook_command("b-spec-context.mjs")}],
            },
            {
                "matcher": "startup|resume|clear|compact",
                "hooks": [{"type": "command", "command": hook_command("b-run-context.mjs")}],
            },
        ],
    }


def render_status_line() -> dict[str, Any]:
    """The status line entry set in the user's settings.json only when none is configured."""
    bin_dir = str(CLAUDE_RUNTIME["hook_dir"]).removesuffix("/hooks") + "/bin"
    return {"type": "command", "command": f'{BUN_COMMAND} "{bin_dir}/b-statusline.mjs"', "refreshInterval": 5}


def render_settings(policy: dict[str, Any]) -> dict[str, Any]:
    return {**render_permissions(policy), "hooks": render_hooks(), "statusLine": render_status_line()}


def shell_pattern_rules() -> tuple[list[str], list[str]]:
    """Shell command patterns the settings layer asks about and denies, as (ask, deny)."""
    deny: list[str] = []
    ask: list[str] = []
    for command in DENIED_COMMANDS:
        for prefix in ("", "rtk "):
            deny.extend([f"{prefix}{command}", f"{prefix}{command} *"])
    for pattern in (*DENIED_PUSH_PATTERNS, *DENIED_DESTRUCTIVE_PATTERNS):
        for prefix in ("", "rtk "):
            deny.append(f"{prefix}{pattern}")
    for command in ASKED_COMMANDS:
        for prefix in ("", "rtk "):
            ask.extend([f"{prefix}{command}", f"{prefix}{command} *"])
    for pattern in gh_api_ask_patterns():
        for prefix in ("", "rtk "):
            ask.append(f"{prefix}{pattern}")
    deny.extend(DENIED_BARE_COMMANDS)
    return ask, deny


def render_permissions(policy: dict[str, Any]) -> dict[str, Any]:
    """Permission rules merged into the user's Claude Code settings.json."""
    allow = list(ALLOWED_TOOLS)
    shell_ask, shell_deny = shell_pattern_rules()
    ask = [f"Bash({pattern})" for pattern in shell_ask]
    deny = [f"Bash({pattern})" for pattern in shell_deny]
    # Claude Code warns about and ignores Write(path) rules: Edit(path) rules cover every file-editing tool.
    for tool in ("Read", "Edit"):
        deny.extend(f"{tool}({glob})" for glob in DENY_READ_GLOBS)
    for server, record in policy["servers"].items():
        for tool, class_name in record["tools"].items():
            permission = policy["classes"][class_name]["native_permission"]
            name = mcp_tool_name(server, tool)
            if permission == "allow":
                allow.append(name)
            elif permission == "ask":
                ask.append(name)
            else:
                deny.append(name)
    return {"permissions": {"allow": allow, "ask": ask, "deny": deny}}


def replace_block(text: str, start: str, end: str, body: str) -> str:
    try:
        body_start = text.index(start) + len(start)
        body_end = text.index(end, body_start)
    except ValueError as exc:
        raise SystemExit(f"missing generated block markers: {start} / {end}") from exc
    return text[:body_start] + "\n" + body.rstrip() + "\n" + text[body_end:]


def build_kernel(skills: list[dict[str, Any]], policy: dict[str, Any], runtime: str = "claude") -> str:
    """The kernel template with its generated blocks filled in for one runtime."""
    kernel = KERNEL_TEMPLATE_PATH.read_text()
    kernel = replace_block(kernel, KERNEL_ROUTING_START, KERNEL_ROUTING_END, render_routing(skills))
    kernel = replace_block(kernel, KERNEL_DELEGATION_START, KERNEL_DELEGATION_END, render_delegation(skills, runtime))
    return replace_block(kernel, MCP_OPERATIONS_START, MCP_OPERATIONS_END, render_mcp_operations_table(policy))


def forbidden_hits(text: str, runtime: str) -> list[str]:
    return [token for token in RUNTIMES[runtime].get("forbidden_tokens", []) if token in text]


def render_outputs(
    skills: list[dict[str, Any]],
    agents: dict[str, dict[str, Any]],
    policy: dict[str, Any],
    workers: dict[str, dict[str, Any]],
) -> dict[Path, str]:
    readme = ROOT / "README.md"
    kernel = build_kernel(skills, policy)
    outputs = {
        readme: replace_block(
            readme.read_text(), README_SKILLS_START, README_SKILLS_END, render_readme_skills_table(skills)
        ),
        KERNEL_TEMPLATE_PATH: kernel,
        SETTINGS_TEMPLATE_PATH: json.dumps(render_settings(policy), indent=2) + "\n",
    }
    for skill in skills:
        outputs[ROOT / "skills" / skill["name"] / "SKILL.md"] = render_skill_file(skill)
    for name, agent in agents.items():
        outputs[CLAUDE_AGENTS_DIR / f"{name}.md"] = render_agent_file(name, agent, skills, policy)
    for name, worker in workers.items():
        outputs[CLAUDE_AGENTS_DIR / f"{name}.md"] = render_worker_file(name, worker, agents, policy)
    return outputs


def validate_worker_regressions(
    agents: dict[str, dict[str, Any]], policy: dict[str, Any], workers: dict[str, dict[str, Any]]
) -> list[str]:
    """The writer child is the one exception to read-only children, and only as the generator renders it."""
    errors: list[str] = []
    if validate_workers(workers, agents):
        errors.append("worker regression: the registry's own workers must pass")

    def worker_errors(change: Any) -> list[str]:
        candidate = json.loads(json.dumps(workers))
        change(candidate)
        return validate_workers(candidate, agents)

    cases = (
        (lambda w: w["b-worker"].pop("model"), "a missing model"),
        (lambda w: w["b-worker"].update(model="gpt-9"), "an unknown model alias"),
        (lambda w: w["b-worker"].update(effort="extreme"), "an unknown effort"),
        (lambda w: w["b-worker"].update(max_turns=0), "a non-positive max_turns"),
        (lambda w: w["b-worker"].update(tools=["NotebookEdit"]), "a registry tool list"),
        (lambda w: w["b-worker"].update(permission_mode="acceptEdits"), "a permission_mode"),
        (lambda w: w["b-worker"].update(isolation="worktree"), "an isolation field"),
        (lambda w: w["b-worker"].update(hooks={}), "a hooks field"),
        (lambda w: w["b-worker"].update(skills=["b-flow"]), "a skills field"),
        (lambda w: w["b-worker"].update(background=True), "a background field"),
        (lambda w: w["b-worker"].update(color="red"), "an unknown field"),
        (lambda w: w.update({"b-worker-2": dict(w["b-worker"])}), "a second worker"),
        (lambda w: w.update({"b-planner": w.pop("b-worker")}), "a worker named like a specialist"),
        (lambda w: w.clear(), "no worker"),
    )
    for change, why in cases:
        if not worker_errors(change):
            errors.append(f"worker regression: {why} must fail")
    if not validate_workers({**workers, **agents}, agents):
        errors.append("worker regression: specialists listed as workers must fail")
    invalid_agent_tools = json.loads(json.dumps(agents))
    invalid_agent_tools["b-researcher"]["conditional_tools"].append("Edit")
    if not validate_agent_tools(invalid_agent_tools, policy):
        errors.append("agent regression: a read-only specialist given Edit must still fail")
    for name, worker in workers.items():
        rendered = render_worker_file(name, worker, agents, policy)
        head, _, _body = rendered.partition("\n---\n")
        frontmatter = dict(line.split(": ", 1) for line in head.removeprefix("---\n").splitlines() if ": " in line)
        tools = [tool.strip() for tool in frontmatter.get("tools", "").split(",")]
        if tools[: len(WORKER_TOOLS)] != list(WORKER_TOOLS) or tools[len(WORKER_TOOLS) :] != agent_mcp_tools(
            agents["b-planner"], policy
        ):
            errors.append(f"worker regression: {name} tools must be the worker set plus b-planner's MCP tools")
        if WORKER_FORBIDDEN_TOOLS & set(tools) or any(tool.startswith("mcp__notion__") for tool in tools):
            errors.append(f"worker regression: {name} must not receive a prompt, delegation, notebook, or Notion tool")
        if set(frontmatter) - {"name", "description", "tools", "model", "effort", "maxTurns"}:
            errors.append(
                f"worker regression: {name} frontmatter must carry only name, description, tools, model, effort"
            )
        if WORKER_TURN_BUDGET_NOTICE not in rendered:
            errors.append(f"worker regression: {name} profile must carry the turn-budget wrap-up notice")
        for clause in (
            "NEEDS INPUT",
            ".b-agentic",
            "git history",
            "no `b-state.mjs` or `b_run.py` command",
            "`b-state` or `b-run` wrapper",
        ):
            if clause not in rendered:
                errors.append(f"worker regression: {name} profile must state {clause!r}")
        if name in MANAGED_SUBAGENT_NAMES:
            errors.append(f"worker regression: {name} must not be a read-only specialist")
    return errors


PI_SKILL_DESCRIPTION_LIMIT = 1024


def render_runtime_kernel(
    skills: list[dict[str, Any]], policy: dict[str, Any], runtime: str, hits: set[str] | None = None
) -> str:
    """The kernel for a non-Claude runtime: its overrides, then its glossary."""
    return apply_glossary(apply_kernel_overrides(build_kernel(skills, policy, runtime), runtime), runtime, hits)


def render_pi_prompt(skill: dict[str, Any]) -> str:
    """A thin `/b-<name>` prompt template that points at the installed Pi skill."""
    name = skill["name"]
    first_sentence = skill["prompt"]["description"].split(". ")[0].rstrip(".") + "."
    lines = ["---", f"description: {json.dumps(first_sentence, ensure_ascii=False)}"]
    if skill.get("argument_hint"):
        lines.append(f"argument-hint: {json.dumps(skill['argument_hint'], ensure_ascii=False)}")
    lines.extend(
        [
            "---",
            "",
            f"Read the installed `{RUNTIMES['pi']['config_dir']}/skills/{name}/SKILL.md` and follow it for this request.",
            "",
            "Arguments: $ARGUMENTS",
            "",
            "<!-- Generated from skills/registry.yaml. Edit that source, not this file. -->",
            "",
        ]
    )
    return "\n".join(lines)


def pi_mcp_tool_ids(policy: dict[str, Any]) -> dict[str, str]:
    """Map each classified `mcp__<server>__<tool>` name to the `mcp:<server>/<tool>` form Pi agent tool lists use."""
    return {
        mcp_tool_name(server, tool): f"mcp:{server}/{tool}"
        for server, record in policy["servers"].items()
        for tool in record["tools"]
    }


def pi_agent_tool_list(agent: dict[str, Any], policy: dict[str, Any]) -> list[str]:
    """Pi's read tools plus the agent's own MCP allowlist (ADR-023), never an editing or prompting tool."""
    ids = pi_mcp_tool_ids(policy)
    names = [*agent_mcp_tools(agent, policy), *agent.get("conditional_tools", [])]
    return [*RUNTIMES["pi"]["read_only_tools"], *(ids[name] for name in names)]


def render_pi_agent_file(name: str, agent: dict[str, Any], skills: list[dict[str, Any]], policy: dict[str, Any]) -> str:
    pi = RUNTIMES["pi"]
    pi_agent = pi.get("agents", {}).get(name, {})
    bound_skills = [
        skill["name"]
        for skill in skills
        if skill["execution"]["mode"] == "subagent" and skill["execution"]["agent"] == name
    ]
    skill_list = " or ".join(f"`{skill}`" for skill in bound_skills)
    return "\n".join(
        [
            "---",
            f"name: {name}",
            f"description: {json.dumps(agent['description'])}",
            f"tools: {', '.join(pi_agent_tool_list(agent, policy))}",
            f"excludeTools: {', '.join(pi['excluded_agent_tools'])}",
            "systemPromptMode: replace",
            "inheritProjectContext: true",
            "inheritGlobalContext: true",
            "allowNestedSubagents: false",
            *([f"model: {pi_agent['model']}"] if "model" in pi_agent else []),
            *([f"thinking: {pi_agent['thinking']}"] if "thinking" in pi_agent else []),
            "---",
            "",
            f"You are the b-agentic `{name}` subagent. The main session delegates only {skill_list} to you and has already selected the exact skill; do not route again or launch a nested subagent.",
            "",
            f"Read and execute the named skill from the installed `{pi['config_dir']}/skills/<name>/SKILL.md` for the supplied bounded task. Return that skill's own Output format; do not substitute a profile-specific template. The skill's Delegation boundary directs the main session to delegate; you are the named child, so execute its steps.",
            "",
            "Remain read-only. Do not edit, write, commit, stage, run generators or fixers, or ask the user questions. Do not execute external/shared mutation, local upload, lifecycle, or authentication actions; report the required operation to the main session. A returned result is not authority to change files, commit, push, or report task completion. If a required tool is absent, tell the main session rather than bypassing the allowlist.",
            "",
            TURN_BUDGET_NOTICE,
            "",
            "<!-- Managed by b-agentic. Generated from skills/registry.yaml. Do not edit this file. -->",
            "",
        ]
    )


def pi_worker_tool_list(agents: dict[str, dict[str, Any]], policy: dict[str, Any]) -> list[str]:
    """Pi's worker tools (read + edit/write + bash) plus b-planner's read-only MCP allowlist."""
    ids = pi_mcp_tool_ids(policy)
    return [*RUNTIMES["pi"]["worker_tools"], *(ids[name] for name in agent_mcp_tools(agents["b-planner"], policy))]


def render_pi_worker_file(
    name: str, worker: dict[str, Any], agents: dict[str, dict[str, Any]], policy: dict[str, Any]
) -> str:
    pi = RUNTIMES["pi"]
    pi_worker = pi.get("workers", {}).get(name, {})
    return "\n".join(
        [
            "---",
            f"name: {name}",
            f"description: {json.dumps(worker['description'])}",
            f"tools: {', '.join(pi_worker_tool_list(agents, policy))}",
            f"excludeTools: {', '.join(pi['worker_excluded_tools'])}",
            "systemPromptMode: replace",
            "inheritProjectContext: true",
            "inheritGlobalContext: true",
            "allowNestedSubagents: false",
            *([f"model: {pi_worker['model']}"] if "model" in pi_worker else []),
            *([f"thinking: {pi_worker['thinking']}"] if "thinking" in pi_worker else []),
            "---",
            "",
            *render_worker_body(name, "pi"),
        ]
    )


PI_DEFAULT_TOOLS = ["+grep", "+find", "+ls"]
PI_MCP_TEMPLATE = CLAUDE_DIR / "configs" / "mcp.base.json"
PI_THEMES_DIR = ROOT / "pi" / "themes"


def render_pi_json(data: dict[str, Any]) -> str:
    return json.dumps(data, indent=2) + "\n"


def render_pi_settings() -> dict[str, Any]:
    """Settings the installer merges into Pi's settings.json: packages, search tools, and default theme."""
    return {
        "packages": list(RUNTIMES["pi"]["packages"]),
        "defaultTools": list(PI_DEFAULT_TOOLS),
        "theme": RUNTIMES["pi"]["theme"],
    }


def render_pi_subagent() -> dict[str, Any]:
    """Default pi-subagents extension configuration merged into extensions/subagent/config.json."""
    return dict(RUNTIMES["pi"]["subagent_config"])


def render_pi_permission(policy: dict[str, Any]) -> dict[str, Any]:
    """The permission-system config the installer merges: protected paths, shell asks and denies, MCP verdicts.

    The shell denies cover the model's own bash tool, which the guard extension does not see. Within a section a
    later rule wins, so every ask precedes every deny: a pattern that is both asked and denied (`git push`) is
    written once, as a deny, after all the asks, because a dict update would keep it at its first, earlier slot and
    the `git push *` ask would then win. `skill` and `codemode` have no shipped default in the permission system.
    """
    pi = RUNTIMES["pi"]
    ask, deny = shell_pattern_rules()
    bash: dict[str, str] = {"*": "allow"}
    denied = set(deny)
    bash.update({pattern: "ask" for pattern in ask if pattern not in denied})
    bash.update({pattern: "deny" for pattern in deny})
    mcp: dict[str, str] = {"*": "ask"}
    for server, record in policy["servers"].items():
        for tool, class_name in record["tools"].items():
            name = pi["mcp_tool_format"].format(server=server, tool=tool.replace("-", "_"))
            mcp[name] = policy["classes"][class_name]["native_permission"]
    permission: dict[str, Any] = {tool: "allow" for tool in ("read", "write", "edit", "find", "grep", "ls")}
    permission.update(
        {
            "bash": bash,
            "path": dict(PATH_RULES),
            "external_directory": "allow",
            "skill": "allow",
            "codemode": "ask",
            "mcp": mcp,
        }
    )
    permission.update({tool: "allow" for tool in pi["allowed_tools"]})
    config: dict[str, Any] = {}
    if PI_CLASSIFIER_PACKAGE in pi["packages"]:
        # The permission system consults only the links named here; the classifier package never enables itself.
        config["authorizerChain"] = [PI_CLASSIFIER_LINK]
    config["permission"] = permission
    return config


def render_pi_mcp() -> dict[str, Any]:
    """The MCP servers the installer merges into Pi's mcp.json, all with the runtime's default exposure."""
    servers = json.loads(PI_MCP_TEMPLATE.read_text())["mcpServers"]
    exposure = RUNTIMES["pi"]["mcp_exposure"]["default"]
    return {"mcpServers": {name: {**entry, "exposure": exposure} for name, entry in servers.items()}}


def render_pi_outputs(
    skills: list[dict[str, Any]],
    agents: dict[str, dict[str, Any]],
    policy: dict[str, Any],
    workers: dict[str, dict[str, Any]] | None = None,
) -> tuple[dict[str, str], set[str]]:
    """Every rendered Pi file keyed by its path under the target directory, and the glossary entries that matched."""
    workers = workers if workers is not None else load_workers()
    hits: set[str] = set()
    outputs = {"kernel.md": render_runtime_kernel(skills, policy, "pi", hits)}
    for skill in skills:
        outputs[f"skills/{skill['name']}/SKILL.md"] = render_skill_file(skill, "pi", hits)
        outputs[f"prompts/{skill['name']}.md"] = render_pi_prompt(skill)
    for name, agent in agents.items():
        outputs[f"agents/{name}.md"] = render_pi_agent_file(name, agent, skills, policy)
    for name, worker in workers.items():
        outputs[f"agents/{name}.md"] = render_pi_worker_file(name, worker, agents, policy)
    outputs["config/settings.json"] = render_pi_json(render_pi_settings())
    outputs["config/permission.json"] = render_pi_json(render_pi_permission(policy))
    outputs["config/mcp.json"] = render_pi_json(render_pi_mcp())
    outputs["config/subagent.json"] = render_pi_json(render_pi_subagent())
    return outputs, hits


def pi_output_errors(outputs: dict[str, str], hits: set[str]) -> list[str]:
    """What a rendered Pi tree must satisfy; the check never writes, so no Pi file lands in the checkout."""
    pi = RUNTIMES["pi"]
    errors: list[str] = []
    for path, text in sorted(outputs.items()):
        parts = PurePosixPath(path).parts
        if PurePosixPath(path).is_absolute() or ".." in parts or "." in parts or "\\" in path:
            errors.append(f"pi output {path!r}: the path must stay inside the target directory")
        for token in forbidden_hits(text, "pi"):
            errors.append(f"pi output {path}: forbidden token {token!r}")
        if "<!-- runtime" in text or "<!-- /runtime" in text:
            errors.append(f"pi output {path}: unresolved runtime marker")
    for entry in pi.get("glossary", []):
        if entry["from"] not in hits:
            errors.append(f"pi glossary entry matches nothing and has drifted from the prompts: {entry['from'][:70]!r}")
    kernel = outputs.get("kernel.md", "")
    if len(kernel.encode()) > MAX_KERNEL_BYTES:
        errors.append(f"pi kernel exceeds the {MAX_KERNEL_BYTES:,} byte kernel budget")
    if len(kernel.splitlines()) > MAX_KERNEL_LINES:
        errors.append(f"pi kernel exceeds the {MAX_KERNEL_LINES} line kernel budget")
    for path, text in sorted(outputs.items()):
        if path.startswith("skills/"):
            description = re.search(r"^description: (.*)$", text, re.M)
            if description is None or len(description.group(1)) > PI_SKILL_DESCRIPTION_LIMIT:
                errors.append(f"pi output {path}: description missing or over {PI_SKILL_DESCRIPTION_LIMIT} characters")
        if path.startswith("agents/"):
            agent_name = PurePosixPath(path).stem
            expected_names = MANAGED_SUBAGENT_NAMES | MANAGED_WORKER_NAMES
            if agent_name not in expected_names:
                errors.append(f"pi output {path}: unexpected Pi agent (expected only {sorted(expected_names)})")
            head, sep, _body = text.partition("\n---\n")
            frontmatter = (
                dict(line.split(": ", 1) for line in head.removeprefix("---\n").splitlines() if ": " in line)
                if sep
                else {}
            )
            listed = [item.strip() for item in frontmatter.get("tools", "").split(",") if item.strip()]
            listed_set = set(listed)
            if frontmatter.get("allowNestedSubagents") != "false":
                errors.append(f"pi output {path}: an agent must set allowNestedSubagents: false")
            if agent_name in MANAGED_WORKER_NAMES:
                excluded = pi["worker_excluded_tools"]
                if not listed or listed_set & set(excluded) or not set(pi["worker_tools"]) <= listed_set:
                    errors.append(f"pi output {path}: worker must list {pi['worker_tools']} and none of {excluded}")
                if frontmatter.get("excludeTools") != ", ".join(excluded):
                    errors.append(f"pi output {path}: worker must exclude {', '.join(excluded)}")
                cfg = pi.get("workers", {}).get(agent_name)
            else:
                excluded = pi["excluded_agent_tools"]
                if not listed or listed_set & set(excluded):
                    errors.append(f"pi output {path}: an agent must list tools and none of the excluded ones")
                if frontmatter.get("excludeTools") != ", ".join(excluded):
                    errors.append(f"pi output {path}: an agent must exclude {', '.join(excluded)}")
                cfg = pi.get("agents", {}).get(agent_name)
            if isinstance(cfg, dict):
                if frontmatter.get("model") != cfg.get("model"):
                    errors.append(f"pi output {path}: expected model {cfg.get('model')!r}")
                expected_thinking = cfg.get("thinking")
                if expected_thinking is not None and frontmatter.get("thinking") != expected_thinking:
                    errors.append(f"pi output {path}: expected thinking {expected_thinking!r}")
                if expected_thinking is None and "thinking" in frontmatter:
                    errors.append(f"pi output {path}: unexpected thinking field")
    for worker_name in MANAGED_WORKER_NAMES:
        if f"agents/{worker_name}.md" not in outputs:
            errors.append(f"pi output: missing worker agent agents/{worker_name}.md")
    flow = outputs.get("skills/b-flow/SKILL.md", "")
    if flow and "--gate reviewer" not in flow:
        errors.append("pi output skills/b-flow/SKILL.md: the review gate must be recorded as reviewer")
    if "`record step S-n --by main`" in flow:
        errors.append(
            "pi output skills/b-flow/SKILL.md: only a listed worker step takes --by, so an ordinary step is recorded bare"
        )
    if flow and ("b-worker" not in flow or "workflow" not in flow):
        errors.append("pi output skills/b-flow/SKILL.md: must include Pi b-worker and parallel workflow guidance")
    if flow and "one `bash` tool call per check" not in flow:
        errors.append("pi output skills/b-flow/SKILL.md: must include Pi parallel_checks guidance")
    plan_skill = outputs.get("skills/b-plan/SKILL.md", "")
    if plan_skill and ("worker_steps" not in plan_skill or "parallel_steps" not in plan_skill):
        errors.append("pi output skills/b-plan/SKILL.md: must include worker_steps and parallel_steps guidance")
    review = outputs.get("skills/b-review/SKILL.md", "")
    if review and "b-reviewer" not in review:
        errors.append("pi output skills/b-review/SKILL.md: the review gate must be the b-reviewer subagent")
    errors.extend(pi_config_errors(outputs))
    return errors


def pi_config_errors(outputs: dict[str, str]) -> list[str]:
    """What the rendered Pi config files must keep: the installer merges them without checking their meaning."""
    errors: list[str] = []
    parsed: dict[str, Any] = {}
    for name in ("settings", "permission", "mcp", "subagent"):
        try:
            value = json.loads(outputs[f"config/{name}.json"])
        except (KeyError, ValueError):
            value = None
        if isinstance(value, dict):
            parsed[name] = value
        else:
            errors.append(f"pi output config/{name}.json: missing or not a JSON object")
    settings, mcp, subagent = parsed.get("settings"), parsed.get("mcp"), parsed.get("subagent")
    if settings is not None:
        if settings.get("packages") != RUNTIMES["pi"]["packages"]:
            errors.append(
                "pi output config/settings.json: packages must be the unpinned runtime packages, classifier first"
            )
        if settings.get("theme") != RUNTIMES["pi"]["theme"]:
            errors.append(f"pi output config/settings.json: theme must be {RUNTIMES['pi']['theme']!r}")
    if subagent is not None and subagent != RUNTIMES["pi"]["subagent_config"]:
        errors.append("pi output config/subagent.json: must match runtimes.pi.subagent_config")
    if mcp is not None and any(
        entry.get("exposure") != RUNTIMES["pi"]["mcp_exposure"]["default"]
        for entry in mcp.get("mcpServers", {}).values()
    ):
        errors.append("pi output config/mcp.json: every server must carry the runtime's default exposure")
    permission = parsed.get("permission", {}).get("permission")
    if "permission" in parsed:
        expected_chain = [PI_CLASSIFIER_LINK] if PI_CLASSIFIER_PACKAGE in RUNTIMES["pi"]["packages"] else None
        if parsed["permission"].get("authorizerChain") != expected_chain:
            errors.append(
                f"pi output config/permission.json: authorizerChain must be {expected_chain} "
                "(the classifier judges asks only when the chain names it)"
            )
        if not isinstance(permission, dict):
            errors.append("pi output config/permission.json: expected a permission object")
        else:
            bash = permission.get("bash", {})
            verdicts = [verdict for pattern, verdict in bash.items() if pattern != "*"]
            if "deny" in verdicts and "ask" in verdicts[verdicts.index("deny") :]:
                errors.append(
                    "pi output config/permission.json: every bash ask must precede every deny (last match wins)"
                )
            if permission.get("skill") != "allow" or "codemode" not in permission:
                errors.append("pi output config/permission.json: skill must be allowed and codemode must carry a rule")
            if permission.get("path") != PATH_RULES:
                errors.append("pi output config/permission.json: path rules must equal the shared protected path rules")
            if any(bash.get(pattern) != "deny" for pattern in ("sudo", "git reset --hard", "git pull")):
                errors.append(
                    "pi output config/permission.json: the model's bash tool must deny sudo, reset --hard and pull"
                )
            for tool in RUNTIMES["pi"]["allowed_tools"]:
                if permission.get(tool) != "allow":
                    errors.append(f"pi output config/permission.json: {tool} must be allowed")
    return errors


def move_ask_after_denies(text: str) -> str:
    """The same permission config with the `git push *` ask moved behind every deny."""
    config = json.loads(text)
    bash = config["permission"]["bash"]
    bash["git push *"] = bash.pop("git push *")
    return json.dumps(config, indent=2) + "\n"


def validate_pi_regressions(
    skills: list[dict[str, Any]], agents: dict[str, dict[str, Any]], policy: dict[str, Any]
) -> list[str]:
    errors: list[str] = []
    if "pi" not in RUNTIMES:
        return errors
    outputs, hits = render_pi_outputs(skills, agents, policy)
    if pi_output_errors(outputs, hits):
        errors.append("pi regression: the shipped Pi render must pass its output checks")
    reviewer_cfg = RUNTIMES["pi"]["agents"]["b-reviewer"]
    reviewer_model = reviewer_cfg["model"]
    alt_model = "other/model" if reviewer_model != "other/model" else "another/model"
    mutations: list[tuple[Any, str]] = [
        (lambda o, h: o.update({"kernel.md": o["kernel.md"] + "\nsee ~/.claude/b-agentic"}), "a leaked Claude path"),
        (lambda o, h: o.update({"kernel.md": o["kernel.md"] + "\n<!-- runtime: pi -->"}), "an unresolved marker"),
        (lambda o, h: h.discard(RUNTIMES["pi"]["glossary"][0]["from"]), "a glossary entry that matches nothing"),
        (lambda o, h: o.update({"kernel.md": o["kernel.md"] + "x" * MAX_KERNEL_BYTES}), "an oversized kernel"),
        (
            lambda o, h: o.update(
                {"agents/b-reviewer.md": o["agents/b-reviewer.md"].replace("tools: ", "tools: edit, ")}
            ),
            "an editing agent",
        ),
        (
            lambda o, h: o.update(
                {"agents/b-reviewer.md": o["agents/b-reviewer.md"].replace(f"model: {reviewer_model}\n", "")}
            ),
            "an agent missing its model",
        ),
        (
            lambda o, h: o.update(
                {
                    "agents/b-reviewer.md": o["agents/b-reviewer.md"].replace(
                        f"model: {reviewer_model}", f"model: {alt_model}"
                    )
                }
            ),
            "an agent with a drifted model",
        ),
        (
            lambda o, h: o.update({"agents/unexpected.md": o["agents/b-planner.md"]}),
            "an unexpected agent rendered for Pi",
        ),
        (
            lambda o, h: o.pop("agents/b-worker.md"),
            "a missing Pi worker agent",
        ),
        (
            lambda o, h: o.update(
                {"agents/b-worker.md": o["agents/b-worker.md"].replace("tools: ", "tools: subagent, ")}
            ),
            "a Pi worker given subagent",
        ),
        (
            lambda o, h: o.update(
                {
                    "agents/b-worker.md": o["agents/b-worker.md"].replace(
                        "allowNestedSubagents: false", "allowNestedSubagents: true"
                    )
                }
            ),
            "a Pi worker allowing nested subagents",
        ),
        (
            lambda o, h: o.update(
                {
                    "agents/b-worker.md": o["agents/b-worker.md"].replace(
                        "excludeTools: subagent, ask_user_question", "excludeTools: ask_user_question"
                    )
                }
            ),
            "a Pi worker missing subagent exclusion",
        ),
        (
            lambda o, h: o.update({"agents/b-worker.md": o["agents/b-worker.md"].replace("model: ", "model: wrong-")}),
            "a Pi worker with a drifted model",
        ),
        (
            lambda o, h: o.update(
                {"skills/b-flow/SKILL.md": o["skills/b-flow/SKILL.md"].replace("b-worker", "implementer")}
            ),
            "Pi b-flow missing b-worker",
        ),
        (
            lambda o, h: o.update(
                {
                    "skills/b-flow/SKILL.md": o["skills/b-flow/SKILL.md"].replace(
                        "one `bash` tool call per check", "one check at a time"
                    )
                }
            ),
            "Pi b-flow missing parallel_checks guidance",
        ),
        (
            lambda o, h: o.update(
                {"skills/b-plan/SKILL.md": o["skills/b-plan/SKILL.md"].replace("worker_steps", "steps")}
            ),
            "Pi b-plan missing worker_steps",
        ),
        (
            lambda o, h: o.update(
                {
                    "config/permission.json": o["config/permission.json"].replace(
                        '"subagent_launch": "allow"', '"subagent_launch": "ask"'
                    )
                }
            ),
            "a permission config that asks for subagent_launch",
        ),
        (
            lambda o, h: o.update(
                {
                    "config/permission.json": o["config/permission.json"].replace(
                        '"subagents_enable": "allow"', '"subagents_enable": "ask"'
                    )
                }
            ),
            "a permission config that asks for subagents_enable",
        ),
        (
            lambda o, h: o.update(
                {"skills/b-flow/SKILL.md": o["skills/b-flow/SKILL.md"].replace("--gate reviewer", "")}
            ),
            "a review gate that is not reviewer",
        ),
        (
            lambda o, h: o.update(
                {"skills/b-flow/SKILL.md": o["skills/b-flow/SKILL.md"] + "`record step S-n --by main`"}
            ),
            "an ordinary step recorded with --by",
        ),
        (lambda o, h: o.update({"config/permission.json": "{}"}), "a permission config without its rules"),
        (
            lambda o, h: o.update(
                {"config/permission.json": o["config/permission.json"].replace('"skill": "allow"', '"skill": "ask"')}
            ),
            "a permission config that does not allow skills",
        ),
        (
            lambda o, h: o.update(
                {"config/mcp.json": o["config/mcp.json"].replace('"exposure": "direct"', '"exposure": "deferred"', 1)}
            ),
            "an MCP server with another exposure",
        ),
        (lambda o, h: o.update({"config/settings.json": "[]"}), "a settings fragment that is not an object"),
        (
            lambda o, h: o.update(
                {"config/settings.json": o["config/settings.json"].replace('"theme": "dracula"', '"theme": "other"')}
            ),
            "a settings fragment with a drifted theme",
        ),
        (lambda o, h: o.pop("config/subagent.json", None), "a missing subagent config fragment"),
        (lambda o, h: o.update({"config/subagent.json": "[]"}), "a subagent config fragment that is not an object"),
        (lambda o, h: o.update({"config/subagent.json": "{}"}), "a subagent config fragment missing its keys"),
        (
            lambda o, h: o.update({"config/permission.json": move_ask_after_denies(o["config/permission.json"])}),
            "a bash ask placed after the denies",
        ),
        (
            lambda o, h: o.update(
                {
                    "config/permission.json": o["config/permission.json"].replace(
                        f'"authorizerChain": [\n    "{PI_CLASSIFIER_LINK}"\n  ],\n  ', ""
                    )
                }
            ),
            "a permission config without the classifier chain",
        ),
        (lambda o, h: o.update({"../escape.md": "x"}), "a path that leaves the target"),
        (lambda o, h: o.update({"/abs.md": "x"}), "an absolute path"),
        (
            lambda o, h: o.update(
                {"skills/b-review/SKILL.md": o["skills/b-review/SKILL.md"].replace("b-reviewer", "reviewer")}
            ),
            "no reviewer subagent",
        ),
    ]
    reviewer_thinking = reviewer_cfg.get("thinking")
    if reviewer_thinking is not None:
        alt_thinking = "low" if reviewer_thinking != "low" else "high"
        mutations.extend(
            [
                (
                    lambda o, h: o.update(
                        {
                            "agents/b-reviewer.md": o["agents/b-reviewer.md"].replace(
                                f"thinking: {reviewer_thinking}\n", ""
                            )
                        }
                    ),
                    "an agent missing its thinking level",
                ),
                (
                    lambda o, h: o.update(
                        {
                            "agents/b-reviewer.md": o["agents/b-reviewer.md"].replace(
                                f"thinking: {reviewer_thinking}", f"thinking: {alt_thinking}"
                            )
                        }
                    ),
                    "an agent with a drifted thinking level",
                ),
            ]
        )
    for mutate, why in mutations:
        broken, broken_hits = dict(outputs), set(hits)
        mutate(broken, broken_hits)
        if not pi_output_errors(broken, broken_hits):
            errors.append(f"pi regression: {why} must fail the output checks")
    saved_agents = RUNTIMES["pi"]["agents"]
    try:
        RUNTIMES["pi"]["agents"] = {**saved_agents, "b-reviewer": {"model": "wrong/model"}}
        no_thinking = render_pi_agent_file("b-reviewer", agents["b-reviewer"], skills, policy)
        if "\nthinking: " in no_thinking:
            errors.append("pi regression: omitted thinking must not emit a thinking line")
        if pi_output_errors({**outputs, "agents/b-reviewer.md": no_thinking}, hits):
            errors.append("pi regression: an agent with omitted thinking must pass output checks")
        injected = no_thinking.replace("\n---\n", "\nthinking: low\n---\n", 1)
        if not pi_output_errors({**outputs, "agents/b-reviewer.md": injected}, hits):
            errors.append("pi regression: an unexpected thinking line must fail output checks")

        RUNTIMES["pi"]["agents"] = {**saved_agents, "b-reviewer": {"model": "wrong/model", "thinking": "low"}}
        low_thinking = render_pi_agent_file("b-reviewer", agents["b-reviewer"], skills, policy)
        if "\nmodel: wrong/model\n" not in low_thinking or "\nthinking: low\n" not in low_thinking:
            errors.append("pi regression: low thinking fixture must emit model and thinking lines")
        if pi_output_errors({**outputs, "agents/b-reviewer.md": low_thinking}, hits):
            errors.append("pi regression: an agent with model wrong/model and thinking low must pass output checks")
        if not pi_output_errors(
            {**outputs, "agents/b-reviewer.md": low_thinking.replace("model: wrong/model", "model: other/model")}, hits
        ):
            errors.append("pi regression: drifted model on fixture must fail output checks")
        if not pi_output_errors(
            {**outputs, "agents/b-reviewer.md": low_thinking.replace("thinking: low", "thinking: high")}, hits
        ):
            errors.append("pi regression: drifted thinking on fixture must fail output checks")
    finally:
        RUNTIMES["pi"]["agents"] = saved_agents
    errors.extend(validate_pi_write_path(outputs))
    return errors


def validate_pi_write_path(outputs: dict[str, str]) -> list[str]:
    """The --render entry point writes exactly the rendered file set, and refuses a checkout, non-empty, or Claude target."""
    import contextlib
    import io
    from unittest import mock

    errors: list[str] = []
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "pi"
            if write_runtime_tree("pi", target) != 0:
                errors.append("pi regression: rendering into a new directory must succeed")
            written = {path.relative_to(target).as_posix() for path in target.rglob("*") if path.is_file()}
            if written != set(outputs):
                errors.append("pi regression: the rendered directory must hold exactly the rendered file set")
            if write_runtime_tree("pi", target) != 2:
                errors.append("pi regression: a non-empty target directory must be refused")
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "pi"
            real_write = Path.write_text
            calls = {"count": 0}

            def failing_write(self: Path, *args: Any, **kwargs: Any) -> int:
                calls["count"] += 1
                if calls["count"] == 3:
                    raise OSError("simulated full disk")
                return real_write(self, *args, **kwargs)

            with mock.patch.object(Path, "write_text", failing_write):
                if write_runtime_tree("pi", target) != 1:
                    errors.append("pi regression: a failed write must fail the render")
            if target.exists() or any(Path(tmp).iterdir()):
                errors.append("pi regression: a failed write must leave neither the target nor a staging directory")
            if write_runtime_tree("pi", target) != 0:
                errors.append("pi regression: a render must succeed again after a failed one")
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "pi"
            target.mkdir()
            with mock.patch.object(os, "replace", side_effect=OSError("simulated rename failure")):
                if write_runtime_tree("pi", target) != 1:
                    errors.append("pi regression: a failed final rename must fail the render")
            if not target.is_dir() or any(target.iterdir()):
                errors.append("pi regression: a failed final rename must leave the empty target as it was")
            if {path.name for path in Path(tmp).iterdir()} != {"pi"}:
                errors.append("pi regression: a failed final rename must leave no staging directory")
            if write_runtime_tree("pi", target) != 0 or not (target / "kernel.md").is_file():
                errors.append("pi regression: a render must replace an existing empty target")
        inside = ROOT / "skills" / "pi-selftest-target"
        if write_runtime_tree("pi", inside) != 2 or inside.exists():
            errors.append("pi regression: a target inside the checkout must be refused and left uncreated")
        if write_runtime_tree("claude", Path(tempfile.gettempdir()) / "pi-selftest-claude") != 2:
            errors.append("pi regression: the claude runtime must be refused by --render")
    return errors


def write_runtime_tree(runtime: str, out: Path) -> int:
    """Render one non-Claude runtime into an empty or new directory outside the checkout.

    The files are written into a staging directory beside the target and moved into place with one replacing
    rename only after every write succeeded, so an error leaves the target exactly as it was.
    """
    if runtime == "claude" or runtime not in RUNTIMES:
        print(f"--render takes a non-Claude runtime: {sorted(set(RUNTIMES) - {'claude'})}", file=sys.stderr)
        return 2
    target = out.expanduser().resolve()
    if target == ROOT or ROOT in target.parents:
        print(f"--out must be outside the checkout: {target}", file=sys.stderr)
        return 2
    if target.exists() and (not target.is_dir() or any(target.iterdir())):
        print(f"--out must be a new or empty directory: {target}", file=sys.stderr)
        return 2
    if not target.parent.is_dir():
        print(f"--out needs an existing parent directory: {target.parent}", file=sys.stderr)
        return 2
    skills, agents, workers, policy, capabilities = (
        load_skills(),
        load_agents(),
        load_workers(),
        load_policy(),
        load_capabilities(),
    )
    errors = canonical_errors(skills, agents, workers, policy, capabilities)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    outputs, hits = render_pi_outputs(skills, agents, policy, workers)
    errors = pi_output_errors(outputs, hits)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    staging: Path | None = None
    try:
        staging = Path(tempfile.mkdtemp(prefix=f".{target.name}-render-", dir=target.parent))
        for relative, text in outputs.items():
            path = staging / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        # One rename replaces an empty target atomically, so a failure never leaves the target removed.
        os.replace(staging, target)
    except OSError as error:
        if staging is not None:
            shutil.rmtree(staging, ignore_errors=True)
        print(f"render failed and nothing was published: {error}", file=sys.stderr)
        return 1
    print(f"Rendered {len(outputs)} {runtime} files into {target}.")
    return 0


def validate_regressions(
    skills: list[dict[str, Any]],
    agents: dict[str, dict[str, Any]],
    capabilities: dict[str, Any],
    policy: dict[str, Any],
    workers: dict[str, dict[str, Any]],
) -> list[str]:
    errors: list[str] = []
    invalid_skill = json.loads(json.dumps(skills))
    invalid_skill[0]["execution"] = {"mode": "invalid"}
    if not validate_skills(invalid_skill, agents):
        errors.append("skill regression: invalid execution mode must fail")
    invalid_handoff = json.loads(json.dumps(skills))
    next(skill for skill in invalid_handoff if skill["name"] == "b-design")["handoff"] = ["parent evidence"]
    if not any("handoff: only subagent skills" in error for error in validate_skills(invalid_handoff, agents)):
        errors.append("skill regression: main skill cannot declare subagent handoff")
    invalid_handoff = json.loads(json.dumps(skills))
    next(skill for skill in invalid_handoff if skill["execution"]["mode"] == "subagent")["handoff"] = []
    if not any(
        "handoff: expected a non-empty string array" in error for error in validate_skills(invalid_handoff, agents)
    ):
        errors.append("skill regression: empty handoff must fail")

    def contract_errors(name: str, change: dict[str, Any]) -> list[str]:
        candidate = json.loads(json.dumps(skills))
        next(skill for skill in candidate if skill["name"] == name)["contract"].update(change)
        return validate_contracts(candidate)

    if validate_contracts(skills):
        errors.append("contract regression: the registry's own contracts must pass")
    for name, change, why in (
        ("b-plan", {"role": "worker"}, "an unknown role"),
        ("b-plan", {"phases": ["planning"]}, "a phase the run CLIs do not know"),
        ("b-plan", {"phases": []}, "a phase skill without phases"),
        ("b-review", {"phases": ["qa"]}, "a run phase left without a phase skill"),
        ("b-implement", {"parallel_safe": True}, "a tree-changing skill marked parallel-safe"),
        ("b-qa", {"evidence": ""}, "a phase skill without evidence"),
        ("b-pr", {"phases": ["commit"]}, "a utility that declares phases"),
        ("b-commit", {"role": "orchestrator"}, "a second orchestrator"),
    ):
        if not contract_errors(name, change):
            errors.append(f"contract regression: {why} must fail")
    for name, change, why in (
        (
            "b-flow",
            {"intent": "Changes that route to b-implement, b-frontend, or b-refactor"},
            "an entry line that omits one",
        ),
        (
            "b-flow",
            {"intent": "Changes that route to b-implement, b-frontend, b-refactor, b-test, or b-qa"},
            "an entry line that adds one",
        ),
        ("b-flow", {"entry": False, "triggers": ["run"]}, "an orchestrator that is not the entry"),
        ("b-plan", {"entry": True}, "a second routing entry"),
    ):
        candidate = json.loads(json.dumps(skills))
        next(skill for skill in candidate if skill["name"] == name)["routing"].update(change)
        if not validate_contracts(candidate):
            errors.append(f"routing regression: {why} must fail")
    candidate = json.loads(json.dumps(skills))
    next(skill for skill in candidate if skill["name"] == "b-flow")["routing"]["explicit_request"] = True
    if not any("not both" in error for error in validate_skills(candidate, agents)):
        errors.append("routing regression: an explicit-request routing entry must fail")
    if f"-> `b-flow`{ENTRY_ROUTING_SUFFIX}." not in render_routing(skills):
        errors.append("routing regression: the kernel must route changes through the b-flow entry line")
    flow = next(skill for skill in skills if skill["name"] == "b-flow")
    for runtime in RUNTIMES:
        rendered = render_skill_file(flow, runtime)
        if PHASE_CONTRACTS_PLACEHOLDER in rendered or any(f"| {phase} |" not in rendered for phase in packet_phases()):
            errors.append(f"contract regression: the {runtime} b-flow skill must carry the phase table")
    for skill in skills:
        if skill.get("handoff"):
            rendered = render_skill_file(skill)
            if any(item not in rendered for item in skill["handoff"]):
                errors.append(f"skill regression: {skill['name']} handoff missing from generated skill")
    for skill in skills:
        # The always-loaded kernel already carries routing and delegation, so a generated suffix only costs context.
        description_block = "\n".join(fold_yaml("description", skill["prompt"]["description"]))
        _, found, after = render_skill_file(skill).partition(f"\n{description_block}\n")
        if not found or after.startswith("  "):
            errors.append(
                f"skill regression: {skill['name']} description must be the registry description with no generated suffix"
            )
        if "\ndisable-model-invocation:" in render_skill_file(skill):
            errors.append(f"skill regression: {skill['name']} must not set disable-model-invocation")
        hint = skill.get("argument_hint")
        if bool(hint) != (f"\nargument-hint: {json.dumps(hint, ensure_ascii=False)}\n" in render_skill_file(skill)):
            errors.append(f"skill regression: {skill['name']} argument-hint must match the registry")
    for skill in skills:
        rendered = render_skill_file(skill)
        has_boundary = f"\n{DELEGATION_BOUNDARY_HEADING}\n" in rendered
        if skill["execution"]["mode"] == "subagent":
            agent_name = skill["execution"]["agent"]
            gate = primary_gate(skill, "claude")
            required = (
                f"`{skill['name']}` runs the {gate['label']} gate first, from the main session as the Steps direct;"
                if gate
                else f"`{skill['name']}` runs only in the `{agent_name}` subagent.",
                "even for a quick, small, or single-lookup request",
                "never fall back to self-execution",
                "$ARGUMENTS",
            )
            if not has_boundary or any(clause not in rendered for clause in required):
                errors.append(f"delegation regression: {skill['name']} SKILL.md must carry the strict boundary")
        elif has_boundary:
            errors.append(f"delegation regression: main skill {skill['name']} must not carry a delegation boundary")
    delegation = render_delegation(skills)
    if "even for a quick lookup" not in delegation or "report the gap and ask" not in delegation:
        errors.append("delegation regression: kernel delegation block must forbid main-session execution")

    def hint_errors(hint: str) -> list[str]:
        candidate = json.loads(json.dumps(skills))
        candidate[0]["argument_hint"] = hint
        return [error for error in validate_skills(candidate, agents) if "argument_hint" in error]

    def bracketed(length: int) -> str:
        return "[" + "x" * (length - 2) + "]"

    for bad in ("<required]", "[optional>", "", "no brackets", bracketed(ARGUMENT_HINT_MAX + 1)):
        if not hint_errors(bad):
            errors.append(f"skill regression: invalid argument_hint {bad!r} must fail")
    for good in ("<required>", "[optional]", "<a> [b]", bracketed(ARGUMENT_HINT_MAX)):
        if hint_errors(good):
            errors.append(f"skill regression: valid argument_hint {good!r} must pass")
    invalid_agents = json.loads(json.dumps(agents))
    invalid_agents["b-planner"].pop("model")
    if not validate_skills(skills, invalid_agents):
        errors.append("agent regression: missing model must fail")
    invalid_agents = json.loads(json.dumps(agents))
    invalid_agents["b-planner"]["model"] = "gpt-9"
    if not validate_skills(skills, invalid_agents):
        errors.append("agent regression: unknown model alias must fail")
    for bad_effort in (None, True, 42, "", "extreme", "XHIGH"):
        invalid_agents = json.loads(json.dumps(agents))
        invalid_agents["b-planner"]["effort"] = bad_effort
        if not any("effort" in error for error in validate_skills(skills, invalid_agents)):
            errors.append(f"agent regression: invalid effort {bad_effort!r} must fail")
    for effort in (None, "low", "medium", "high", "xhigh", "max"):
        candidate_agents = json.loads(json.dumps(agents))
        candidate = candidate_agents["b-planner"]
        candidate.pop("effort", None)
        if effort is not None:
            candidate["effort"] = effort
        if validate_skills(skills, candidate_agents):
            errors.append(f"agent regression: valid effort {effort!r} must pass")
        rendered = render_agent_file("b-planner", candidate, skills, policy)
        if re.findall(r"^effort: (.+)$", rendered, re.MULTILINE) != ([effort] if effort is not None else []):
            errors.append(f"agent regression: Claude must render effort {effort!r}, or omit it when unset")
    for name, agent in agents.items():
        rendered = render_agent_file(name, agent, skills, policy)
        if TURN_BUDGET_NOTICE not in rendered:
            errors.append(f"agent regression: {name} profile must carry the turn-budget wrap-up notice")
        tools = agent_tool_list(agent, policy)
        if any(tool in tools for tool in EDITING_TOOLS) or {"Agent", "Task", "AskUserQuestion"} & set(tools):
            errors.append(f"agent regression: {name} profile must stay read-only, non-delegating, and non-interactive")
        if any(tool.startswith("mcp__notion__") for tool in tools):
            errors.append(f"agent regression: {name} must not receive private Notion workspace tools")
    for bad_turns in (0, -1, True, "25"):
        invalid_turns = json.loads(json.dumps(agents))
        invalid_turns["b-researcher"]["max_turns"] = bad_turns
        if not validate_skills(skills, invalid_turns):
            errors.append(f"agent regression: invalid max_turns {bad_turns!r} must fail")
    errors.extend(validate_worker_regressions(agents, policy, workers))
    invalid_capabilities = json.loads(json.dumps(capabilities))
    invalid_capabilities["capabilities"][0].pop("status_signal", None)
    if not validate_capabilities(invalid_capabilities, policy):
        errors.append("capability regression: missing status signal must fail")
    for why, mutate in (
        ("missing tier", lambda c: c["capabilities"][0].pop("tier", None)),
        ("unknown tier", lambda c: c["capabilities"][0].update({"tier": "custom"})),
        (
            "exclusive without runtimes",
            lambda c: (c["capabilities"][1].update({"tier": "exclusive"}), c["capabilities"][1].pop("runtimes", None)),
        ),
        (
            "exclusive with all runtimes",
            lambda c: c["capabilities"][1].update({"tier": "exclusive", "runtimes": sorted(RUNTIMES)}),
        ),
        (
            "shared with runtimes",
            lambda c: c["capabilities"][2].update({"tier": "shared", "runtimes": ["claude"]}),
        ),
        (
            "shared with null runtimes",
            lambda c: c["capabilities"][2].update({"tier": "shared", "runtimes": None}),
        ),
        (
            "adapted with runtimes",
            lambda c: c["capabilities"][0].update({"tier": "adapted", "runtimes": ["claude"]}),
        ),
        (
            "adapted with null runtimes",
            lambda c: c["capabilities"][0].update({"tier": "adapted", "runtimes": None}),
        ),
        (
            "exclusive agent capability",
            lambda c: c["capabilities"][0].update({"tier": "exclusive", "runtimes": ["claude"]}),
        ),
    ):
        candidate_caps = json.loads(json.dumps(capabilities))
        mutate(candidate_caps)
        if not validate_capabilities(candidate_caps, policy):
            errors.append(f"capability regression: {why} must fail")
    invalid_agent_tools = json.loads(json.dumps(agents))
    invalid_agent_tools["b-researcher"]["conditional_tools"].append("mcp__playwright__browser_click")
    if not validate_agent_tools(invalid_agent_tools, policy):
        errors.append("agent regression: mutating conditional tool must fail")
    for change, why in (
        (lambda a: a["b-planner"].pop("mcp_tools"), "a missing mcp_tools"),
        (lambda a: a["b-planner"]["mcp_tools"].append("mcp__notion__notion-search"), "a non-read-only tool"),
        (lambda a: a["b-planner"]["mcp_tools"].append(a["b-planner"]["mcp_tools"][0]), "a duplicate tool"),
        (lambda a: a["b-planner"]["mcp_tools"].remove(CODEGRAPH_TOOL), "an allowlist without CodeGraph"),
        (lambda a: a["b-planner"]["mcp_tools"].append("mcp__firecrawl__firecrawl_search"), "a conditional tool"),
    ):
        candidate_agents = json.loads(json.dumps(agents))
        change(candidate_agents)
        if not validate_agent_tools(candidate_agents, policy):
            errors.append(f"agent regression: {why} in mcp_tools must fail")
    errors.extend(validate_snapshot_cli())
    errors.extend(validate_artifacts_schema())
    if ARTIFACTS_PATH.is_file():
        artifacts = json.loads(ARTIFACTS_PATH.read_text())
        for why, mutate in (
            ("a line field", lambda b: b["fields"].update({"note": {"type": "line"}})),
            ("a text field", lambda b: b["fields"]["review"]["fields"].update({"note": {"type": "text"}})),
            ("an id field", lambda b: b["fields"].update({"note": {"type": "id"}})),
            ("an unknown type", lambda b: b["fields"].update({"note": {"type": "blob"}})),
            ("a counts field without keys", lambda b: b["fields"]["ac"].pop("keys")),
            ("a counts field naming an unknown enum", lambda b: b["fields"]["escaped_from"].update({"enum": "nope"})),
            ("an enum without values", lambda b: b["fields"]["size"].pop("values")),
            ("a hash key without a length", lambda b: b["fields"]["repo"].pop("length")),
            ("a widened type list", lambda b: b["field_types"].append("text")),
            ("a store name with a path", lambda b: b.update({"store": "../run-stats.jsonl"})),
        ):
            candidate = json.loads(json.dumps(artifacts["run_stats"]))
            mutate(candidate)
            if not run_stats_errors(candidate, artifacts["enums"], "self-test"):
                errors.append(f"run_stats regression: {why} must fail")
    if B_REVIEW_PROMPT_PATH.is_file() and ARTIFACTS_PATH.is_file():
        review_prompt = B_REVIEW_PROMPT_PATH.read_text()
        class_enum = json.loads(ARTIFACTS_PATH.read_text()).get("enums", {}).get("blocker_class", [])
        for why, drifted_enum, drifted_prompt in (
            ("an enum missing a class", class_enum[1:], review_prompt),
            ("an enum with a reordered class", [*class_enum[1:], class_enum[0]], review_prompt),
            ("a prompt that drops a class", class_enum, review_prompt.replace("unexpected path, or ", "", 1)),
            ("a prompt with no class sentence", class_enum, review_prompt.replace("is one of:", "is any of:")),
            (
                "a prompt where only one sentence is reworded",
                class_enum,
                review_prompt.replace("is one of:", "is any of:", 1),
            ),
            (
                "a prompt where only one list drifts",
                class_enum,
                review_prompt.replace("unexpected path", "documentation gap", 1),
            ),
        ):
            if not blocker_class_errors(drifted_enum, drifted_prompt, "self-test"):
                errors.append(f"blocker class regression: {why} must fail")
    # Playwright's browser_find accepts a `filename` that writes results to disk, so it must
    # never be classed read-only (which makes it eligible for any specialist's mcp_tools allowlist).
    if policy["servers"]["playwright"]["tools"]["browser_find"] == "read-only":
        errors.append("MCP policy regression: file-writing browser_find must not be read-only")
    for agent_name, agent in agents.items():
        if "mcp__playwright__browser_find" in agent.get("conditional_tools", []):
            errors.append(f"agents.{agent_name}: file-writing browser_find must not be a specialist tool")
    invalid_policy = json.loads(json.dumps(policy))
    first_server = next(iter(invalid_policy["servers"].values()))
    first_server["tools"]["bad"] = "missing"
    if not validate_policy(invalid_policy):
        errors.append("MCP policy regression: unknown class must fail")
    invalid_policy = json.loads(json.dumps(policy))
    next(iter(invalid_policy["servers"].values()))["exposure"] = "eager"
    if not validate_policy(invalid_policy):
        errors.append("MCP policy regression: retired exposure field must fail")
    errors.extend(validate_runtime_regressions())
    errors.extend(validate_pi_regressions(skills, agents, policy))
    return errors


def validate_runtime_regressions() -> list[str]:
    errors: list[str] = []
    for bad in (
        "<!-- runtime: cluade --> text",
        "text <!-- runtime: claude -->",
        "<!-- runtime: claude,cluade --> text",
        "<!-- runtime: cluade -->\nx\n<!-- /runtime -->",
        "<!-- runtime: claude -->\nx",
        "<!-- runtime: claude -->\n<!-- runtime: claude -->\nx\n<!-- /runtime -->\n<!-- /runtime -->",
        "x\n<!-- /runtime -->",
        "<!-- runtime: claude -->\n<!-- runtime: claude --> x\n<!-- /runtime -->",
        "text <!-- /runtime -->",
    ):
        try:
            apply_markers(bad, "claude")
        except ValueError:
            continue
        errors.append(f"runtime regression: malformed marker {bad!r} must fail")
    if apply_markers("a\n<!-- runtime: claude --> c\nd", "claude") != "a\nc\nd":
        errors.append("runtime regression: Claude must keep shared and claude lines")
    indented = "- a\n  <!-- runtime: claude -->\n  - b\n  <!-- /runtime -->\n- d"
    if apply_markers(indented, "claude") != "- a\n  - b\n- d" or apply_markers(indented, "_other") != "- a\n- d":
        errors.append("runtime regression: an indented runtime block must work inside a list item")
    block = "a\n<!-- runtime: claude -->\nb\nc\n<!-- /runtime -->\nd"
    if apply_markers(block, "claude") != "a\nb\nc\nd":
        errors.append("runtime regression: Claude must keep a claude block and drop its marker lines")
    if apply_markers(block, "_other") != "a\nd":
        errors.append("runtime regression: another runtime must drop a claude block whole")
    pi = RUNTIMES.get("pi")
    if pi is not None:
        if validate_pi_runtime(pi, "runtimes.pi"):
            errors.append("runtime regression: the shipped pi entry must pass its shape checks")
        pinned = [*pi["packages"][:-1], pi["packages"][-1] + "@1.2.3"]
        swapped = [PI_PERMISSION_PACKAGE, PI_CLASSIFIER_PACKAGE]
        bad_entries = (
            {**pi, "packages": pinned},
            {**pi, "packages": swapped},
            {**pi, "mcp_exposure": {"default": "codemode"}},
            {**pi, "excluded_agent_tools": ["subagent"]},
            {key: value for key, value in pi.items() if key != "read_only_tools"},
            {key: value for key, value in pi.items() if key != "agents"},
            {key: value for key, value in pi.items() if key != "workers"},
            {**pi, "workers": {}},
            {**pi, "workers": {**pi["workers"], "b-worker": {"model": "sonnet", "thinking": "high"}}},
            {**pi, "workers": {**pi["workers"], "b-worker": {"model": "openai/gpt-6.1-terra", "thinking": "extreme"}}},
            {**pi, "worker_tools": [*pi["worker_tools"], "subagent"]},
            {**pi, "worker_excluded_tools": ["ask_user_question"]},
            {**pi, "allowed_tools": [t for t in pi["allowed_tools"] if t != "subagent_launch"]},
            {**pi, "allowed_tools": [t for t in pi["allowed_tools"] if t != "subagents_enable"]},
            {**pi, "agents": {k: v for k, v in pi["agents"].items() if k != "b-reviewer"}},
            {key: value for key, value in pi.items() if key != "theme"},
            {**pi, "theme": "a/b"},
            {**pi, "theme": "system"},
            {**pi, "theme": "missing-theme"},
            {key: value for key, value in pi.items() if key != "subagent_config"},
            {**pi, "subagent_config": []},
            {**pi, "subagent_config": {}},
            {**pi, "agents": {**pi["agents"], "b-worker": {"model": "openai/gpt-6.1-terra", "thinking": "high"}}},
            {**pi, "agents": {**pi["agents"], "b-planner": {"model": "opus", "thinking": "high"}}},
            {
                **pi,
                "agents": {**pi["agents"], "b-planner": {"model": "anthropic/claude-opus-5-5", "thinking": "extreme"}},
            },
            {
                **pi,
                "agents": {
                    **pi["agents"],
                    "b-planner": {"model": "anthropic/claude-opus-5-5", "thinking": "high", "effort": "high"},
                },
            },
        )
        for bad_pi in bad_entries:
            if not validate_pi_runtime(bad_pi, "runtimes.pi"):
                errors.append("runtime regression: a malformed pi entry must fail its shape checks")
        for valid_cfg in (
            {"model": "anthropic/claude-opus-5-5"},
            {"model": "wrong/model", "thinking": "low"},
        ):
            valid_pi = {**pi, "agents": {**pi["agents"], "b-reviewer": valid_cfg}}
            if validate_pi_runtime(valid_pi, "runtimes.pi"):
                errors.append(f"runtime regression: valid pi reviewer config {valid_cfg!r} must pass shape checks")
    # No runtime carries kernel overrides now, so drift is exercised through a synthetic entry.
    RUNTIMES["_probe"] = {"kernel_overrides": [{"from": "once", "to": "x"}], "forbidden_tokens": ["~/.claude"]}
    try:
        if not forbidden_hits("see ~/.claude/b-agentic", "_probe"):
            errors.append("runtime regression: a leaked Claude path must be detected in another runtime's output")
        for text in ("no match here", "once once"):
            try:
                apply_kernel_overrides(text, "_probe")
            except ValueError:
                continue
            errors.append(f"runtime regression: a drifted kernel override must fail on {text!r}")
    finally:
        del RUNTIMES["_probe"]
    return errors


PI_PACKAGE_NAME = re.compile(r"^npm:(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$")
PI_CLASSIFIER_PACKAGE = "npm:pi-permission-classifier"
PI_CLASSIFIER_LINK = "permission-judge"
PI_PERMISSION_PACKAGE = "npm:@gotgenes/pi-permission-system"
PI_AGENT_MODEL = re.compile(r"^[^\s/]+/\S+$")
PI_THINKING_LEVELS = {"off", "minimal", "low", "medium", "high", "xhigh", "max"}


def validate_pi_runtime(config: dict[str, Any], label: str) -> list[str]:
    """Shape checks for the pi entry: nothing is pinned, agents cannot edit, and the classifier loads first."""
    errors: list[str] = []
    for key in (
        "read_only_tools",
        "excluded_agent_tools",
        "worker_tools",
        "worker_excluded_tools",
        "allowed_tools",
        "packages",
    ):
        non_empty_string_list(config.get(key), f"{label}.{key}", errors)
    for required_tool in ("subagent_launch", "subagents_enable"):
        if required_tool not in (config.get("allowed_tools") or []):
            errors.append(f"{label}.allowed_tools: must include '{required_tool}'")
    exposure = config.get("mcp_exposure")
    if not isinstance(exposure, dict) or exposure.get("default") not in {"direct", "deferred"}:
        errors.append(f"{label}.mcp_exposure: expected {{default: direct or deferred}}")
    packages = config.get("packages")
    if isinstance(packages, list) and all(isinstance(item, str) for item in packages):
        for package in packages:
            if not PI_PACKAGE_NAME.fullmatch(package):
                errors.append(f"{label}.packages: {package!r} must be npm:NAME with no version pin")
        if PI_CLASSIFIER_PACKAGE in packages and PI_PERMISSION_PACKAGE in packages:
            if packages.index(PI_CLASSIFIER_PACKAGE) > packages.index(PI_PERMISSION_PACKAGE):
                errors.append(f"{label}.packages: {PI_CLASSIFIER_PACKAGE} must come before {PI_PERMISSION_PACKAGE}")
    editing, excluded = config.get("editing_tools"), config.get("excluded_agent_tools")
    if isinstance(editing, list) and isinstance(excluded, list) and not set(editing) <= set(excluded):
        errors.append(f"{label}.excluded_agent_tools: must include every editing tool")
    worker_tools = config.get("worker_tools")
    worker_excluded = config.get("worker_excluded_tools")
    if isinstance(editing, list) and isinstance(worker_tools, list) and not set(editing) <= set(worker_tools):
        errors.append(f"{label}.worker_tools: must include every editing tool")
    if isinstance(worker_excluded, list) and not {"subagent", "ask_user_question"} <= set(worker_excluded):
        errors.append(f"{label}.worker_excluded_tools: must include 'subagent' and 'ask_user_question'")
    if (
        isinstance(worker_tools, list)
        and isinstance(worker_excluded, list)
        and set(worker_tools) & set(worker_excluded)
    ):
        errors.append(f"{label}.worker_tools: must not include any tool in worker_excluded_tools")
    theme = ensure_string(config.get("theme"), f"{label}.theme", errors)
    if theme:
        if "/" in theme or theme == "system":
            errors.append(f"{label}.theme: {theme!r} must not contain '/' or equal 'system'")
        else:
            theme_path = PI_THEMES_DIR / f"{theme}.json"
            if not theme_path.is_file():
                errors.append(f"{label}.theme: missing theme file {theme_path.relative_to(ROOT)}")
            else:
                try:
                    theme_data = json.loads(theme_path.read_text())
                except ValueError as exc:
                    errors.append(f"{label}.theme: {theme_path.relative_to(ROOT)} is invalid JSON: {exc}")
                else:
                    if not isinstance(theme_data, dict) or theme_data.get("name") != theme:
                        errors.append(
                            f"{label}.theme: {theme_path.relative_to(ROOT)} must be an object with name {theme!r}"
                        )
    subagent_cfg = config.get("subagent_config")
    if not isinstance(subagent_cfg, dict) or not subagent_cfg:
        errors.append(f"{label}.subagent_config: expected a non-empty JSON object")
    else:
        for cfg_key, cfg_val in subagent_cfg.items():
            if not isinstance(cfg_key, str) or not cfg_key:
                errors.append(f"{label}.subagent_config: keys must be non-empty strings")
            if isinstance(cfg_val, bool):
                continue
            if not isinstance(cfg_val, (str, int, float)):
                errors.append(f"{label}.subagent_config.{cfg_key}: expected a scalar JSON value")
    for field_name, expected_names in (("agents", MANAGED_SUBAGENT_NAMES), ("workers", MANAGED_WORKER_NAMES)):
        pi_entries = config.get(field_name)
        if not isinstance(pi_entries, dict):
            errors.append(f"{label}.{field_name}: expected an object mapping {sorted(expected_names)}")
        else:
            if set(pi_entries) != expected_names:
                errors.append(f"{label}.{field_name}: keys must be exactly {sorted(expected_names)}")
            for entry_name, entry in pi_entries.items():
                entry_label = f"{label}.{field_name}.{entry_name}"
                if not isinstance(entry, dict):
                    errors.append(f"{entry_label}: expected an object")
                    continue
                extra = set(entry) - {"model", "thinking"}
                if extra:
                    errors.append(f"{entry_label}: unknown field(s) {sorted(extra)}")
                model = ensure_string(entry.get("model"), f"{entry_label}.model", errors)
                if model and not PI_AGENT_MODEL.fullmatch(model):
                    errors.append(f"{entry_label}.model: {model!r} must be provider/model")
                if "thinking" in entry:
                    thinking = ensure_string(entry.get("thinking"), f"{entry_label}.thinking", errors)
                    if thinking and thinking not in PI_THINKING_LEVELS:
                        errors.append(f"{entry_label}.thinking: expected one of {sorted(PI_THINKING_LEVELS)}")
    return errors


def validate_runtimes() -> list[str]:
    errors: list[str] = []
    for name, config in RUNTIMES.items():
        label = f"{RUNTIMES_PATH.relative_to(ROOT)}: runtimes.{name}"
        for key in (
            "config_dir",
            "state_dir",
            "hook_dir",
            "mcp_tool_format",
            "delegation_unavailable",
            "profile_check",
        ):
            ensure_string(config.get(key), f"{label}.{key}", errors)
        for key in ("agent_models", "editing_tools"):
            if not isinstance(config.get(key), list) or not all(isinstance(item, str) and item for item in config[key]):
                errors.append(f"{label}.{key}: expected a string array")
        for key in ("glossary", "kernel_overrides"):
            for index, entry in enumerate(config.get(key, []), start=1):
                if (
                    not isinstance(entry, dict)
                    or set(entry) != {"from", "to"}
                    or not isinstance(entry["from"], str)
                    or not entry["from"]
                    or not isinstance(entry["to"], str)
                ):
                    errors.append(f"{label}.{key}[{index}]: expected {{from: non-empty string, to: string}}")
        if "forbidden_tokens" in config:
            non_empty_string_list(config["forbidden_tokens"], f"{label}.forbidden_tokens", errors)
        template = config.get("mcp_tool_format")
        if isinstance(template, str) and not ("{server}" in template and "{tool}" in template):
            errors.append(f"{label}.mcp_tool_format: must contain {{server}} and {{tool}}")
        if name == "pi":
            errors.extend(validate_pi_runtime(config, label))
    claude = RUNTIMES["claude"]
    if claude.get("mcp_tool_format") != "mcp__{server}__{tool}":
        errors.append("runtimes.claude: MCP format must be mcp__{server}__{tool}")
    return errors


def canonical_errors(
    skills: list[dict[str, Any]],
    agents: dict[str, dict[str, Any]],
    workers: dict[str, dict[str, Any]],
    policy: dict[str, Any],
    capabilities: dict[str, Any],
) -> list[str]:
    """Every validator over the canonical sources; --check and --render both run it before they render."""
    return [
        *validate_skills(skills, agents),
        *validate_workers(workers, agents),
        *validate_contracts(skills),
        *validate_policy(policy),
        *validate_agent_tools(agents, policy),
        *validate_optional_components(skills, policy),
        *validate_capabilities(capabilities, policy),
        *validate_snapshot_cli(),
        *validate_artifacts_schema(),
        *validate_runtimes(),
    ]


def sync_outputs(check: bool) -> int:
    skills = load_skills()
    agents = load_agents()
    workers = load_workers()
    policy = load_policy()
    capabilities = load_capabilities()
    errors = canonical_errors(skills, agents, workers, policy, capabilities)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    if "pi" in RUNTIMES:
        pi_outputs, pi_hits = render_pi_outputs(skills, agents, policy, workers)
        pi_errors = pi_output_errors(pi_outputs, pi_hits)
        if pi_errors:
            print("\n".join(pi_errors), file=sys.stderr)
            return 1
    outputs = render_outputs(skills, agents, policy, workers)
    stale = [path for path, content in outputs.items() if not path.exists() or path.read_text() != content]
    if check and stale:
        print("\n".join(f"generated output out of date: {path.relative_to(ROOT)}" for path in stale), file=sys.stderr)
        return 1
    if not check:
        for path in stale:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(outputs[path])
        print("Generated Claude Code delivery assets refreshed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Render Claude Code assets from canonical b-agentic sources.")
    parser.add_argument("--check", action="store_true", help="fail when generated outputs are stale")
    parser.add_argument("--self-test", action="store_true", help="verify invalid canonical contracts fail validation")
    parser.add_argument(
        "--render", metavar="RUNTIME", help="render a non-Claude runtime (pi) into --out, never the checkout"
    )
    parser.add_argument("--out", metavar="DIR", help="new or empty directory outside the checkout for --render")
    args = parser.parse_args()
    if args.render:
        if not args.out:
            parser.error("--render needs --out DIR")
        if args.check or args.self_test:
            parser.error("--render cannot be combined with --check or --self-test")
        return write_runtime_tree(args.render, Path(args.out))
    if args.out:
        parser.error("--out is only used with --render")
    if args.self_test:
        errors = validate_regressions(load_skills(), load_agents(), load_capabilities(), load_policy(), load_workers())
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        print("Skill, capability, and MCP policy regression checks passed.")
    return sync_outputs(args.check)


if __name__ == "__main__":
    raise SystemExit(main())
