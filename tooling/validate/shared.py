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
    "cursor-json",
    "opencode-json",
    "pi-json",
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

expected_capabilities = {"skills", "permissions", "rules", "command_wrappers", "mcp"}
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
    config_install_path = runtime.get("config_install_path")
    if not isinstance(config_install_path, str) or not config_install_path.startswith("~/"):
        errors.append(f"runtimes/registry.yaml: {name} config_install_path must use a ~/ path")
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
    for forbidden in [
        "Optional runtime subagent",
        "Subagents are optional",
        "verify subagent claims independently",
        "[status]",
        "state-machine",
        "strict mode",
        "B_AGENTIC_STRICT",
    ]:
        if forbidden in text:
            errors.append(f"{rel(prompt)}: removed ceremony remains: {forbidden!r}")

# Prompt behavior regression contracts. These markers encode observed failure
# modes and their intended correction:
# - b-debug previously treated diagnosis-only requests as fix authorization.
# - b-test previously let TDD cross into production edits without b-implement.
# - b-review previously allowed structural audit output to imply full readiness.
# - b-summary previously forced substantial PR ceremony onto small changes.
# - b-research previously failed to pinpoint exact dependency versions by checking
#   loose ranges in manifests or using go.sum instead of go.mod.
# - b-browser previously ran E2E automation in headless/CI environments without
#   verifying display server (xvfb) presence or configuration.
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
    ],
    "b-debug": [
        "Build a feedback loop",
        "If no trustworthy feedback loop can be built",
        "asked only to diagnose, explain, or investigate",
    ],
    "b-test": [
        "public interface",
        "vertical tracer bullets",
        "implementation-coupled tests",
        "Keep production-code changes in **b-implement**",
    ],
    "b-browser": [
        "requested UI state",
        "generic page load",
        "headless or CI environments",
    ],
    "b-research": [
        "resolved lockfiles",
        "fallback",
        "go.mod",
    ],
    "b-refactor": [
        "deletion test",
        "Stop if the work becomes redesign",
    ],
    "b-review": [
        "real problem statement",
        "ceremony creep",
        "prompt-change evidence",
        "structural checks only",
    ],
    "b-summary": [
        "Use the staged diff for the commit message, PR title, and PR description.",
        "Commit message:",
        "PR title:",
        "PR description:",
        "Use a compact PR description for a small cohesive change.",
        "## <problem-or-capability heading>",
        "## <cause-or-decision heading>",
        "## <implementation heading>",
        "For the full structure, choose `Issue`, `Root Cause`, and `Fix` for defect repairs or regressions",
        "## Impact Analysis",
        "BLOCKED: split unrelated staged changes",
        "Not established from available evidence.",
        "Always return the commit message, PR title, and a complete proportional PR description when a cohesive staged change set exists.",
    ],
}
for skill_name, markers in required_prompt_markers.items():
    prompt = ROOT / "skills" / skill_name / "prompt.md"
    text = read_text(prompt)
    for marker in markers:
        if marker not in text:
            errors.append(f"{rel(prompt)}: missing behavior marker {marker!r}")

# Registry metadata is user-facing routing evidence. It must preserve the
# diagnosis/fix authorization boundary enforced by the b-debug prompt.
b_debug = next(
    (skill for skill in skills if isinstance(skill, dict) and skill.get("name") == "b-debug"),
    {},
)
b_debug_metadata = " ".join(
    str(value)
    for value in (
        b_debug.get("use", ""),
        (b_debug.get("command") or {}).get("description", ""),
        (b_debug.get("prompt") or {}).get("description", ""),
    )
)
for required in ["authorized", "Diagnosis-only requests stop"]:
    if required not in b_debug_metadata:
        errors.append(
            "skills/registry.yaml: b-debug metadata must preserve diagnosis/fix "
            f"authorization marker {required!r}"
        )

MCP_SERVERS = {"serena", "codegraph", "context7", "brave-search", "firecrawl", "playwright"}
LOCAL_TOOLS = {"bash"}
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


TOKEN_TO_DISPLAY_NAME = {
    "serena": "Serena",
    "codegraph": "CodeGraph",
    "context7": "Context7",
    "brave-search": "Brave",
    "firecrawl": "Firecrawl",
    "playwright": "Playwright",
    "bash": "Bash",
}

referenced_servers: set[str] = set()
for skill_name in sorted(prompt_dirs):
    prompt = ROOT / "skills" / skill_name / "prompt.md"
    prompt_content = read_text(prompt)
    tokens = tools_required_tokens(prompt_content)
    
    # Check for tool references outside of Tools required
    lines = prompt_content.splitlines()
    outside_lines = []
    in_tools_required = False
    for line in lines:
        if line.startswith("## "):
            in_tools_required = (line.strip() == "## Tools required")
            if not in_tools_required:
                outside_lines.append(line)
            continue
        if not in_tools_required:
            outside_lines.append(line)
    outside_text = "\n".join(outside_lines)

    for token in tokens:
        if token not in KNOWN_TOOLS:
            errors.append(
                f"{rel(prompt)}: unknown tool {token!r} in Tools required; "
                f"expected one of {sorted(KNOWN_TOOLS)}"
            )
        else:
            if token in MCP_SERVERS:
                referenced_servers.add(token)
            
            display_name = TOKEN_TO_DISPLAY_NAME.get(token, token)
            if (token not in outside_text) and (display_name not in outside_text):
                errors.append(
                    f"{rel(prompt)}: tool {token!r} is declared in Tools required but never referenced outside that section"
                )

unreferenced_servers = sorted(MCP_SERVERS - referenced_servers)
if unreferenced_servers:
    errors.append(
        "skills/: configured MCP servers not referenced by any skill Tools required: "
        f"{unreferenced_servers}"
    )

if list((ROOT / "skills").glob("*/reference.md")):
    errors.append("skills/: skill-local reference.md files were removed from the slim product")

contract_dir = ROOT / "references" / "contract"
expected_contract_mds = {"runtime.md", "safety-tools.md", "kernel.template.md"}
actual_contract_mds = {path.name for path in contract_dir.glob("*.md")}
if actual_contract_mds != expected_contract_mds:
    errors.append(
        f"references/contract/: expected markdown {sorted(expected_contract_mds)}, "
        f"found {sorted(actual_contract_mds)}"
    )
if not (contract_dir / "mcp_operations.yaml").exists():
    errors.append("references/contract/mcp_operations.yaml: missing canonical MCP operation policy")
safety_tools = read_text(contract_dir / "safety-tools.md")
if "mcp_operations.yaml" not in safety_tools:
    errors.append("references/contract/safety-tools.md: must point at mcp_operations.yaml as canonical source")
if "<!-- generated:mcp-operations:start -->" not in safety_tools:
    errors.append("references/contract/safety-tools.md: missing generated MCP operations block markers")

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

# Missing preferred shell tools previously forced an installation prompt even
# when a reliable local fallback existed. Preserve automatic degraded operation.
if "use the closest available local fallback" not in kernel_template:
    errors.append(
        "references/contract/kernel.template.md: missing automatic shell-tool fallback"
    )
if "prompt the user to install the shell tooling before falling back" in kernel_template:
    errors.append(
        "references/contract/kernel.template.md: blocking shell-tool install prompt remains"
    )

# The kernel's terse "Routing" list and runtime.md's detailed "Precedence" list
# are independent hand-written copies with no generator tying them together.
# Catch a skill silently missing from either one.
runtime_contract = read_text(ROOT / "references" / "contract" / "runtime.md")
kernel_routing_section = kernel_template.split("## Routing", 1)[-1].split("## Shell commands", 1)[0]
runtime_precedence_section = runtime_contract.split("Precedence:", 1)[-1].split(
    "<!-- generated:routing-triggers:start -->", 1
)[0]
for skill in skills:
    if not isinstance(skill.get("routing"), dict):
        continue
    name_token = f"`{skill['name']}`"
    if name_token not in kernel_routing_section:
        errors.append(
            f"references/contract/kernel.template.md: Routing list is missing {name_token}"
        )
    if name_token not in runtime_precedence_section:
        errors.append(
            f"references/contract/runtime.md: Precedence list is missing {name_token}"
        )

# Firecrawl is external research infrastructure, not browser evidence. Keeping
# it out of b-browser prevents overlapping tool ownership with b-research.
browser_prompt = read_text(ROOT / "skills" / "b-browser" / "prompt.md")
if "`firecrawl`" in browser_prompt:
    errors.append("skills/b-browser/prompt.md: firecrawl ownership must remain in b-research")

readme = read_text(ROOT / "README.md")
for forbidden in ["hooks", "subagent", "strict", "state-machine", "conformance"]:
    if re.search(rf"\b{re.escape(forbidden)}\b", readme, re.IGNORECASE):
        errors.append(f"README.md: removed product concept remains: {forbidden!r}")

claude_settings_path = ROOT / "runtimes" / "claude-code" / "configs" / "settings.template.json"
claude_settings = read_text(claude_settings_path)
claude_settings_json = load_json(claude_settings_path)
claude_allow = claude_settings_json.get("permissions", {}).get("allow", []) if isinstance(claude_settings_json, dict) else []
for forbidden in ["hooks", "statusLine", "check-runtime.py"]:
    if forbidden in claude_settings:
        errors.append(f"runtimes/claude-code/configs/settings.template.json: forbidden default permission/config {forbidden!r}")
if any("firecrawl_monitor" in str(item) for item in claude_allow):
    errors.append(
        "runtimes/claude-code/configs/settings.template.json: Firecrawl monitor tools must not be allowlisted"
    )

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


def cursor_gate_severity(tokens: list[str], settings: dict) -> int:
    # Cursor is allowlist-based: deny rules take precedence, unlisted commands are asked/approved, allowed are allowed.
    permissions = settings.get("permissions", {})
    # Check deny rules first
    for raw in permissions.get("deny", []):
        match = re.fullmatch(r"Shell\((.*?)\s*\*?\)", raw)
        if not match:
            continue
        entry_tokens = match.group(1).split()
        if entry_tokens and entry_tokens[0] == "rtk":
            entry_tokens = entry_tokens[1:]
        if entry_tokens[: len(tokens)] == tokens:
            return 2  # Deny
    # Check allow rules
    for raw in permissions.get("allow", []):
        match = re.fullmatch(r"Shell\((.*?)\s*\*?\)", raw)
        if not match:
            continue
        entry_tokens = match.group(1).split()
        if entry_tokens and entry_tokens[0] == "rtk":
            entry_tokens = entry_tokens[1:]
        if entry_tokens[: len(tokens)] == tokens:
            return 0  # Allow (not gated)
    # Default to ask (severity 1) because of allowlist approvalMode
    return 1


def pi_gate_severity(tokens: list[str], extension_text: str) -> int:
    # Pi gates live in the first-party TypeScript extension as token patterns.
    # DENY patterns are checked first; ASK/SERVICE patterns require confirmation.
    # Runtime normalizes a leading rtk token before matching.
    def patterns_from(const_name: str) -> list[list[str]]:
        match = re.search(rf"const {const_name}: string\[\]\[\] = \[(.*?)\];", extension_text, re.DOTALL)
        if not match:
            return []
        patterns: list[list[str]] = []
        for raw in re.findall(r"\[([^\]]*)\]", match.group(1)):
            entry = re.findall(r'"([^"]+)"', raw)
            if entry:
                patterns.append(entry)
        return patterns

    for pattern in patterns_from("DENY_COMMANDS"):
        if tokens[: len(pattern)] == pattern:
            return 2
    for pattern in patterns_from("ASK_COMMANDS") + patterns_from("SERVICE_COMMANDS"):
        if tokens[: len(pattern)] == pattern:
            return 1
    return 0


claude_config = load_json(ROOT / "runtimes" / "claude-code" / "configs" / "settings.template.json")
opencode_config = load_json(ROOT / "runtimes" / "opencode" / "configs" / "mcp.user.template.json")
codex_rules = read_text(ROOT / "runtimes" / "codex" / "rules" / "b-agentic.rules")
cursor_config = load_json(ROOT / "runtimes" / "cursor" / "configs" / "settings.template.json")
pi_extension = read_text(ROOT / "runtimes" / "pi" / "extensions" / "b-agentic-permissions.ts")
gate_runtimes = [
    ("runtimes/claude-code/configs/settings.template.json", lambda tokens: claude_gate_severity(tokens, claude_config)),
    ("runtimes/opencode/configs/mcp.user.template.json", lambda tokens: opencode_gate_severity(tokens, opencode_config)),
    ("runtimes/codex/rules/b-agentic.rules", lambda tokens: codex_gate_severity(tokens, codex_rules)),
    ("runtimes/cursor/configs/settings.template.json", lambda tokens: cursor_gate_severity(tokens, cursor_config)),
    ("runtimes/pi/extensions/b-agentic-permissions.ts", lambda tokens: pi_gate_severity(tokens, pi_extension)),
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
