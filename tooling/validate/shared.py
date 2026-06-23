#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
errors: list[str] = []
RUNTIME_CONFIG_SCHEMA_FAMILIES = {
    "claude-user-config",
    "codex-toml",
    "opencode-json",
}


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def read_text(path: Path) -> str:
    return path.read_text() if path.exists() else ""


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        errors.append(f"{rel(path)}: invalid JSON-compatible YAML: {exc}")
        return {}


def validate_runtime_reference_layout(runtime: dict, label: str) -> None:
    skills_root = runtime.get("skills_install_root")
    metadata_root = runtime.get("metadata_root")
    if not isinstance(skills_root, str) or not isinstance(metadata_root, str):
        return
    if not skills_root.startswith("~/") or not metadata_root.startswith("~/"):
        errors.append(f"{label}: skills_install_root and metadata_root must use ~/ paths")
        return
    skills_path = Path(skills_root[2:])
    metadata_path = Path(metadata_root[2:])
    if metadata_path.name != "b-agentic":
        errors.append(f"{label}.metadata_root: must end with b-agentic")
    if skills_path.parent != metadata_path.parent:
        errors.append(
            f"{label}: skills_install_root and metadata_root must share a parent "
            "because generated skills reference ../../b-agentic/references"
        )


def require_contains(path: Path, text: str, needles: list[str], label: str) -> None:
    for needle in needles:
        if needle not in text:
            errors.append(f"{rel(path)}: missing {label} {needle!r}")


def frontmatter_parts(path: Path) -> tuple[str, str]:
    text = path.read_text()
    if not text.startswith("---\n"):
        errors.append(f"{rel(path)}: missing YAML frontmatter")
        return "", text
    parts = text.split("---", 2)
    if len(parts) < 3:
        errors.append(f"{rel(path)}: missing YAML frontmatter close")
        return "", text
    return parts[1], parts[2]


skills_registry = load_json(ROOT / "skills" / "registry.yaml")
runtimes_registry = load_json(ROOT / "runtimes" / "registry.yaml")
skills = skills_registry.get("skills", [])
runtimes = runtimes_registry.get("runtimes", [])

if not isinstance(skills, list) or not skills:
    errors.append("skills/registry.yaml: skills must be a non-empty array")
    skills = []
if not isinstance(runtimes, list) or not runtimes:
    errors.append("runtimes/registry.yaml: runtimes must be a non-empty array")
    runtimes = []

skill_names = [skill.get("name") for skill in skills if isinstance(skill, dict)]
runtime_names = [runtime.get("name") for runtime in runtimes if isinstance(runtime, dict)]

if len(skill_names) != len(set(skill_names)):
    errors.append("skills/registry.yaml: duplicate skill names")
if len(runtime_names) != len(set(runtime_names)):
    errors.append("runtimes/registry.yaml: duplicate runtime names")

prompt_dirs = {path.parent.name for path in (ROOT / "skills").glob("*/prompt.md")}
if prompt_dirs != set(skill_names):
    errors.append(
        "skills/registry.yaml: registry must match prompt directories "
        f"(registry={sorted(skill_names)}, dirs={sorted(prompt_dirs)})"
    )

runtime_dirs = {path.name for path in (ROOT / "runtimes").iterdir() if path.is_dir() and path.name != "runtime-template"}
if runtime_dirs != set(runtime_names):
    errors.append(
        "runtimes/registry.yaml: registry must match runtime directories "
        f"(registry={sorted(runtime_names)}, dirs={sorted(runtime_dirs)})"
    )

expected_capabilities = {"skills", "permissions", "rules", "command_wrappers"}
for runtime in runtimes:
    if not isinstance(runtime, dict):
        continue
    name = runtime.get("name", "<unknown>")
    capabilities = runtime.get("capabilities")
    if not isinstance(capabilities, dict):
        errors.append(f"runtimes/registry.yaml: {name} missing capabilities object")
        continue
    config_schema_family = runtime.get("config_schema_family")
    if config_schema_family not in RUNTIME_CONFIG_SCHEMA_FAMILIES:
        errors.append(
            f"runtimes/registry.yaml: {name} config_schema_family must be one of "
            f"{sorted(RUNTIME_CONFIG_SCHEMA_FAMILIES)}"
        )
    validate_runtime_reference_layout(runtime, f"runtimes/registry.yaml: {name}")
    actual = set(capabilities)
    if actual != expected_capabilities:
        errors.append(
            f"runtimes/registry.yaml: {name} capabilities must be {sorted(expected_capabilities)}, found {sorted(actual)}"
        )
    for removed in ["hooks", "subagents", "plugins", "custom_tools"]:
        if removed in capabilities:
            errors.append(f"runtimes/registry.yaml: {name} must not declare removed capability {removed!r}")

reference_count = sum(1 for runtime in runtimes if isinstance(runtime, dict) and runtime.get("reference_runtime") is True)
if reference_count != 1:
    errors.append("runtimes/registry.yaml: expected exactly one reference runtime")

for skill_name in sorted(prompt_dirs):
    prompt = ROOT / "skills" / skill_name / "prompt.md"
    skill_file = ROOT / "skills" / skill_name / "SKILL.md"
    if not skill_file.exists():
        errors.append(f"{rel(skill_file)}: missing generated skill file")
        continue
    frontmatter, body = frontmatter_parts(skill_file)
    if f"name: {skill_name}" not in frontmatter:
        errors.append(f"{rel(skill_file)}: frontmatter name must match directory")
    for section in ["## When to use", "## When NOT to use", "## Tools required", "## Steps", "## Output format", "## Rules"]:
        if section not in body:
            errors.append(f"{rel(skill_file)}: missing section {section!r}")
    text = prompt.read_text()
    for forbidden in ["Optional runtime subagent", "Subagents are optional", "[status]", "state-machine", "strict mode", "B_AGENTIC_STRICT"]:
        if forbidden in text:
            errors.append(f"{rel(prompt)}: removed ceremony remains: {forbidden!r}")

required_prompt_markers = {
    "b-plan": [
        "CONTEXT.md",
        "intended observable outcome",
        "AFK",
        "HITL",
    ],
    "b-implement": [
        "CONTEXT.md",
        "requested observable outcome",
        "verify subagent claims independently",
    ],
    "b-debug": [
        "Build a feedback loop",
        "If no trustworthy feedback loop can be built",
    ],
    "b-test": [
        "public interface",
        "vertical tracer bullets",
        "implementation-coupled tests",
    ],
    "b-browser": [
        "requested UI state",
        "generic page load",
    ],
    "b-refactor": [
        "deletion test",
        "Stop if the work becomes redesign",
    ],
    "b-review": [
        "real problem statement",
        "ceremony creep",
        "prompt-change evidence",
    ],
    "b-summary": [
        "Use the staged diff for the commit message, PR title, and PR description.",
        "Commit message:",
        "PR title:",
        "PR description:",
        "## Issue/Feature",
        "## Root Cause/Decision",
        "## Fix/Change",
        "## Impact Analysis",
        "BLOCKED: split unrelated staged changes",
        "Not established from available evidence.",
        "Always return the commit message, PR title, and complete PR description when a cohesive staged change set exists.",
    ],
}
for skill_name, markers in required_prompt_markers.items():
    prompt = ROOT / "skills" / skill_name / "prompt.md"
    text = read_text(prompt)
    for marker in markers:
        if marker not in text:
            errors.append(f"{rel(prompt)}: missing behavior marker {marker!r}")

MCP_SERVERS = {"serena", "codegraph", "context7", "brave-search", "firecrawl", "playwright"}
LOCAL_TOOLS = {"bash", "gh"}
KNOWN_TOOLS = MCP_SERVERS | LOCAL_TOOLS


def tools_required_tokens(prompt_text: str) -> list[str]:
    tokens: list[str] = []
    in_section = False
    for line in prompt_text.splitlines():
        if line.startswith("## "):
            in_section = line.strip() == "## Tools required"
            continue
        if in_section and line.lstrip().startswith("- "):
            match = re.match(r"\s*-\s+`([^`]+)`", line)
            if match:
                tokens.append(match.group(1))
    return tokens


referenced_servers: set[str] = set()
for skill_name in sorted(prompt_dirs):
    prompt = ROOT / "skills" / skill_name / "prompt.md"
    tokens = tools_required_tokens(read_text(prompt))
    for token in tokens:
        if token not in KNOWN_TOOLS:
            errors.append(
                f"{rel(prompt)}: unknown tool {token!r} in Tools required; "
                f"expected one of {sorted(KNOWN_TOOLS)}"
            )
        elif token in MCP_SERVERS:
            referenced_servers.add(token)

unreferenced_servers = sorted(MCP_SERVERS - referenced_servers)
if unreferenced_servers:
    errors.append(
        "skills/: configured MCP servers not referenced by any skill Tools required: "
        f"{unreferenced_servers}"
    )

if list((ROOT / "skills").glob("*/reference.md")):
    errors.append("skills/: skill-local reference.md files were removed from the slim product")

contract_dir = ROOT / "references" / "contract"
expected_contracts = {"runtime.md", "safety-tools.md", "kernel.template.md"}
actual_contracts = {path.name for path in contract_dir.glob("*.md")}
if actual_contracts != expected_contracts:
    errors.append(
        f"references/contract/: expected {sorted(expected_contracts)}, found {sorted(actual_contracts)}"
    )

for path in [ROOT / "references" / "contract" / "kernel.template.md", *(ROOT / "runtimes" / name / "kernel.md" for name in runtime_names)]:
    text = read_text(path)
    for required in ["Core Rules", "Routing", "runtime.md", "safety-tools.md"]:
        if required not in text:
            errors.append(f"{rel(path)}: missing kernel marker {required!r}")
    for forbidden in ["state-machine.md", "decisions.md", "index.md", "Strict governance", "Advisory-only runtime"]:
        if forbidden in text:
            errors.append(f"{rel(path)}: removed kernel concept remains: {forbidden!r}")

kernel_template = read_text(ROOT / "references" / "contract" / "kernel.template.md")
for forbidden in ["route every shell command through", "always prefix shell commands"]:
    if forbidden in kernel_template:
        errors.append(
            "references/contract/kernel.template.md: unsupported RTK routing remains: "
            f"{forbidden!r}"
        )

readme = read_text(ROOT / "README.md")
for forbidden in ["hooks", "subagent", "strict", "state-machine", "conformance"]:
    if re.search(rf"\b{re.escape(forbidden)}\b", readme, re.IGNORECASE):
        errors.append(f"README.md: removed product concept remains: {forbidden!r}")

claude_settings = read_text(ROOT / "runtimes" / "claude-code" / "configs" / "settings.template.json")
for forbidden in ["firecrawl_monitor", "hooks", "statusLine", "check-runtime.py"]:
    if forbidden in claude_settings:
        errors.append(f"runtimes/claude-code/configs/settings.template.json: forbidden default permission/config {forbidden!r}")

# Safety-gate parity: every runtime must gate the command families the runtime
# contract (references/contract/safety-tools.md) requires, at no weaker than the
# canonical severity. "ask" = must prompt for approval; "deny" = must be refused.
# Each family is checked through the runtime's own permission model.
SAFETY_GATES = [
    # (command tokens, minimum severity)
    (["git", "commit"], "ask"),
    (["git", "push"], "ask"),
    (["git", "pull"], "ask"),
    (["git", "revert"], "ask"),
    (["npm", "install"], "ask"),
    (["pnpm", "install"], "ask"),
    (["yarn", "install"], "ask"),
    (["bun", "install"], "ask"),
    (["cargo", "install"], "ask"),
    (["go", "install"], "ask"),
    (["pip", "install"], "ask"),
    (["poetry", "add"], "ask"),
    (["cargo", "add"], "ask"),
    (["go", "get"], "ask"),
    (["rm", "-rf"], "ask"),
    (["git", "reset", "--hard"], "deny"),
    (["git", "clean", "-f"], "deny"),
    (["git", "push", "--force"], "deny"),
    (["git", "push", "--force-with-lease"], "deny"),
    (["git", "branch", "-D"], "deny"),
    (["docker", "system", "prune"], "deny"),
    (["docker", "volume", "rm"], "deny"),
]
SEVERITY_RANK = {"ask": 1, "deny": 2}


def claude_gate_severity(tokens: list[str], settings: dict) -> int:
    # Claude is not default-deny: only explicitly listed prefixes are gated.
    # An entry gates a family when its longer-or-equal token prefix is covered.
    permissions = settings.get("permissions", {})
    best = 0
    for level, rank in (("ask", 1), ("deny", 2)):
        for raw in permissions.get(level, []):
            match = re.fullmatch(r"Bash\((.*?)\s*\*?\)", raw)
            if not match:
                continue
            entry_tokens = match.group(1).split()
            if entry_tokens and entry_tokens[0] == "rtk":
                entry_tokens = entry_tokens[1:]
            if entry_tokens[: len(tokens)] == tokens:
                best = max(best, rank)
    return best


def opencode_gate_severity(tokens: list[str], config: dict) -> int:
    bash = config.get("permission", {}).get("bash", {})
    # OpenCode defaults unlisted commands to the "*" decision.
    default_rank = SEVERITY_RANK.get(bash.get("*"), 0)
    best = default_rank
    for pattern, decision in bash.items():
        if pattern == "*":
            continue
        entry_tokens = pattern.replace("*", "").split()
        if entry_tokens and entry_tokens[0] == "rtk":
            entry_tokens = entry_tokens[1:]
        if entry_tokens[: len(tokens)] == tokens:
            best = max(best, SEVERITY_RANK.get(decision, 0))
    return best


def codex_gate_severity(tokens: list[str], rules_text: str) -> int:
    # Codex prefix_rule decisions: "prompt" ~= ask, "forbidden" ~= deny.
    decision_rank = {"prompt": 1, "forbidden": 2}
    best = 0
    for block in re.findall(r"prefix_rule\((.*?)\)", rules_text, re.DOTALL):
        pattern_match = re.search(r"pattern\s*=\s*\[(.*?)\]", block, re.DOTALL)
        decision_match = re.search(r'decision\s*=\s*"(\w+)"', block)
        if not pattern_match or not decision_match:
            continue
        entry_tokens = re.findall(r'"([^"]+)"', pattern_match.group(1))
        if entry_tokens and entry_tokens[0] == "rtk":
            entry_tokens = entry_tokens[1:]
        if entry_tokens[: len(tokens)] == tokens:
            best = max(best, decision_rank.get(decision_match.group(1), 0))
    return best


claude_config = load_json(ROOT / "runtimes" / "claude-code" / "configs" / "settings.template.json")
opencode_config = load_json(ROOT / "runtimes" / "opencode" / "configs" / "mcp.user.template.json")
codex_rules = read_text(ROOT / "runtimes" / "codex-cli" / "rules" / "b-agentic.rules")
gate_runtimes = [
    ("runtimes/claude-code/configs/settings.template.json", lambda tokens: claude_gate_severity(tokens, claude_config)),
    ("runtimes/opencode/configs/mcp.user.template.json", lambda tokens: opencode_gate_severity(tokens, opencode_config)),
    ("runtimes/codex-cli/rules/b-agentic.rules", lambda tokens: codex_gate_severity(tokens, codex_rules)),
]
for tokens, min_severity in SAFETY_GATES:
    required_rank = SEVERITY_RANK[min_severity]
    family = " ".join(tokens)
    for label, severity_fn in gate_runtimes:
        if severity_fn(tokens) < required_rank:
            errors.append(
                f"{label}: safety gate {family!r} weaker than required {min_severity!r}; "
                "align with references/contract/safety-tools.md"
            )

for deleted_path in ["tooling/policy", "tooling/state", "tooling/hooks", "tooling/conformance", "tooling/scenarios"]:
    leftovers = [
        path for path in (ROOT / deleted_path).glob("**/*")
        if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc"
    ]
    if leftovers:
        errors.append(f"{deleted_path}: removed-governance files remain in the worktree")

generated_paths = [
    ROOT / "README.md",
    ROOT / "references" / "contract" / "runtime.md",
    *(ROOT / "skills" / name / "SKILL.md" for name in skill_names),
    *(ROOT / "runtimes" / name / "kernel.md" for name in runtime_names),
    *(ROOT / "runtimes" / "opencode" / "commands" / f"{name}.md" for name in skill_names),
]
for path in generated_paths:
    if path.exists() and "{{" in path.read_text():
        errors.append(f"{rel(path)}: unresolved template token")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print(f"Shared skill validation passed ({len(skill_names)} skills).")
