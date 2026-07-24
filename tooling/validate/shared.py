#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
errors: list[str] = []

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
skills = skills_registry.get("skills", [])
if not isinstance(skills, list) or not skills:
    errors.append("skills/registry.yaml: skills must be a non-empty array")
    skills = []

skill_names = [skill["name"] for skill in skills if isinstance(skill, dict) and isinstance(skill.get("name"), str)]
if len(skill_names) != len(set(skill_names)):
    errors.append("skills/registry.yaml: duplicate skill names")

prompt_dirs = {path.parent.name for path in (ROOT / "skills").glob("*/prompt.md")}
if prompt_dirs != set(skill_names):
    errors.append(
        "skills/registry.yaml: registry must match prompt directories "
        f"(registry={sorted(skill_names)}, dirs={sorted(prompt_dirs)})"
    )

for skill_name in sorted(prompt_dirs):
    prompt = ROOT / "skills" / skill_name / "prompt.md"
    skill_file = ROOT / "skills" / skill_name / "SKILL.md"
    if not skill_file.exists():
        errors.append(f"{rel(skill_file)}: missing generated skill file")
        continue
    frontmatter, body = frontmatter_parts(skill_file)
    if f"name: {skill_name}" not in frontmatter:
        errors.append(f"{rel(skill_file)}: frontmatter name must match directory")
    for section in ["## When to use", "## When NOT to use", "## Tool guidance", "## Steps", "## Output format", "## Rules"]:
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
# - b-test previously forced explicit TDD loops to bounce through b-implement.
# - b-review previously allowed structural audit output to imply full readiness.
# - b-pr-summary must distinguish a combined PR summary from commit creation.
# - b-research previously failed to pinpoint exact dependency versions by checking
#   loose ranges in manifests or using go.sum instead of go.mod.
# - b-browser previously ran E2E automation in headless/CI environments without
#   verifying display server (xvfb) presence or configuration.
required_prompt_markers = {
    "b-plan": [
        "intended observable outcome",
        "AFK",
        "HITL",
    ],
    "b-implement": [
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
        "explicitly requested a tightly scoped TDD red-green loop",
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
    "b-commit": [
        "BLOCKED: commit staged changes before generating PR copy",
        "If the user asks only for a commit message, inspect only the existing staged diff.",
        "Commit message:",
        "CONFIRM: stage and create these commits",
        "Never use `git add -A`, `git add .`, `git commit --amend`, reset, or history-rewriting commands.",
        "Ask before staging or committing; do not push or create a PR.",
    ],
    "b-pr-summary": [
        "PR title:",
        "PR description:",
        "BLOCKED: invalid commit count",
        "BLOCKED: not enough commits to summarize",
        "BLOCKED: origin branch not found",
        "BLOCKED: no commits ahead of cached origin to summarize",
        "Not established from available evidence.",
        "Do not contact remotes, fetch, push, inspect merge bases, or open PR state.",
    ],
    "b-design": [
        "adaptable checklist",
        "Do not scaffold unused section headings when repo evidence is sparse.",
        "Do not invent a design system when evidence is thin.",
    ],
}
for skill_name, markers in required_prompt_markers.items():
    prompt = ROOT / "skills" / skill_name / "prompt.md"
    text = read_text(prompt)
    for marker in markers:
        if marker not in text:
            errors.append(f"{rel(prompt)}: missing behavior marker {marker!r}")

principles_path = ROOT / "tests" / "behavior" / "principles.json"
principles_fixture = load_json(principles_path)
principle_names = {
    "think-before-coding",
    "simplicity-first",
    "surgical-changes",
    "goal-driven-execution",
}
if principles_fixture.get("version") != 1:
    errors.append(f"{rel(principles_path)}: expected fixture version 1")
if not isinstance(principles_fixture.get("source"), str) or not principles_fixture["source"]:
    errors.append(f"{rel(principles_path)}: source must be a non-empty string")
scenarios = principles_fixture.get("scenarios")
if not isinstance(scenarios, list) or not scenarios:
    errors.append(f"{rel(principles_path)}: scenarios must be a non-empty array")
    scenarios = []
scenario_ids: list[str] = []
covered_principles: set[str] = set()
for index, scenario in enumerate(scenarios, start=1):
    label = f"{rel(principles_path)}: scenario {index}"
    if not isinstance(scenario, dict):
        errors.append(f"{label} must be an object")
        continue
    scenario_id = scenario.get("id")
    if not isinstance(scenario_id, str) or not scenario_id:
        errors.append(f"{label} must have a non-empty id")
    else:
        scenario_ids.append(scenario_id)
    principle = scenario.get("principle")
    if principle not in principle_names:
        errors.append(f"{label} has unknown principle {principle!r}")
    else:
        covered_principles.add(principle)
    if scenario.get("skill", "b-implement") not in skill_names:
        errors.append(f"{label} has unknown skill {scenario.get('skill')!r}")
    if not isinstance(scenario.get("prompt"), str) or not scenario["prompt"]:
        errors.append(f"{label} must have a non-empty prompt")
    for field in ("must", "avoid"):
        values = scenario.get(field)
        if not isinstance(values, list) or not values or not all(isinstance(value, str) and value for value in values):
            errors.append(f"{label} {field} must be a non-empty string array")
    regression_fields = ("observed_failure", "intended_behavior")
    if any(field in scenario for field in regression_fields):
        for field in regression_fields:
            if not isinstance(scenario.get(field), str) or not scenario[field]:
                errors.append(f"{label} {field} must be a non-empty string")
if len(scenario_ids) != len(set(scenario_ids)):
    errors.append(f"{rel(principles_path)}: scenario ids must be unique")
if covered_principles != principle_names:
    errors.append(f"{rel(principles_path)}: scenarios must cover all four principles")

routing_path = ROOT / "tests" / "behavior" / "routing.json"
routing_fixture = load_json(routing_path)
routing_scenarios = routing_fixture.get("scenarios", [])
if routing_fixture.get("version") != 1 or not isinstance(routing_scenarios, list) or not routing_scenarios:
    errors.append(f"{rel(routing_path)}: expected version 1 with non-empty scenarios")
else:
    routing_ids: list[str] = []
    for index, scenario in enumerate(routing_scenarios, start=1):
        label = f"{rel(routing_path)}: scenario {index}"
        if not isinstance(scenario, dict):
            errors.append(f"{label} must be an object")
            continue
        scenario_id = scenario.get("id")
        if not isinstance(scenario_id, str) or not scenario_id:
            errors.append(f"{label} must have a non-empty id")
        else:
            routing_ids.append(scenario_id)
        if scenario.get("expected_skill") not in skill_names:
            errors.append(f"{label} has unknown expected_skill {scenario.get('expected_skill')!r}")
        forbidden = scenario.get("forbidden_skills")
        if not isinstance(forbidden, list) or not all(value in skill_names for value in forbidden):
            errors.append(f"{label} forbidden_skills must contain only registered skills")
        if not isinstance(scenario.get("prompt"), str) or not scenario["prompt"]:
            errors.append(f"{label} must have a non-empty prompt")
    if len(routing_ids) != len(set(routing_ids)):
        errors.append(f"{rel(routing_path)}: scenario ids must be unique")

prompt_runner_path = ROOT / "pi" / "tests" / "prompt_effectiveness.py"
prompt_runner = read_text(prompt_runner_path)
require_contains(
    prompt_runner_path,
    prompt_runner,
    ["--allow-model-calls", '"--no-session"', '"--no-tools"', '"--routing"', 'environment["PI_TELEMETRY"] = "0"'],
    "prompt-effectiveness safety marker",
)

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


def tool_guidance_tokens(prompt_text: str) -> list[str]:
    tokens: list[str] = []
    in_section = False
    for line in prompt_text.splitlines():
        if line.startswith("## "):
            in_section = line.strip() == "## Tool guidance"
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
    tokens = tool_guidance_tokens(prompt_content)

    # Check for tool references outside of Tool guidance.
    lines = prompt_content.splitlines()
    outside_lines = []
    in_tool_guidance = False
    for line in lines:
        if line.startswith("## "):
            in_tool_guidance = (line.strip() == "## Tool guidance")
            if not in_tool_guidance:
                outside_lines.append(line)
            continue
        if not in_tool_guidance:
            outside_lines.append(line)
    outside_text = "\n".join(outside_lines)

    for token in tokens:
        if token not in KNOWN_TOOLS:
            errors.append(
                f"{rel(prompt)}: unknown tool {token!r} in Tool guidance; "
                f"expected one of {sorted(KNOWN_TOOLS)}"
            )
        else:
            if token in MCP_SERVERS:
                referenced_servers.add(token)
            
            display_name = TOKEN_TO_DISPLAY_NAME.get(token, token)
            if (token not in outside_text) and (display_name not in outside_text):
                errors.append(
                    f"{rel(prompt)}: tool {token!r} is declared in Tool guidance but never referenced outside that section"
                )

unreferenced_servers = sorted(MCP_SERVERS - referenced_servers)
if unreferenced_servers:
    errors.append(
        "skills/: configured MCP servers not referenced by any skill Tool guidance: "
        f"{unreferenced_servers}"
    )

if list((ROOT / "skills").glob("*/reference.md")):
    errors.append("skills/: skill-local reference.md files were removed from the slim product")

references_dir = ROOT / "references"
expected_reference_mds = {"kernel.template.md"}
actual_reference_mds = {path.name for path in references_dir.glob("*.md")}
if actual_reference_mds != expected_reference_mds:
    errors.append(
        f"references/: expected markdown {sorted(expected_reference_mds)}, "
        f"found {sorted(actual_reference_mds)}"
    )
if (references_dir / "contract").exists():
    errors.append("references/contract/: removed contract directory remains")
if not (references_dir / "mcp_operations.yaml").exists():
    errors.append("references/mcp_operations.yaml: missing canonical MCP operation policy")

kernel_template = read_text(references_dir / "kernel.template.md")
for required in ["Core Rules", "Routing", "Safety and tools", "Managed MCP operations"]:
    if required not in kernel_template:
        errors.append(f"references/kernel.template.md: missing kernel marker {required!r}")
for forbidden in ["state-machine.md", "decisions.md", "index.md", "Strict governance", "Advisory-only runtime"]:
    if forbidden in kernel_template:
        errors.append(f"references/kernel.template.md: removed kernel concept remains: {forbidden!r}")

if "Use `rtk` for command families it supports; run unsupported commands directly." not in kernel_template:
    errors.append(
        "references/kernel.template.md: RTK must cover only command families it supports"
    )

# The kernel owns the RTK requirement and modern shell-tool preferences.
for required_tool in ["`rtk`", "`rg`", "`fd`", "`bat`", "`eza`", "`sd`", "`jq`"]:
    if required_tool not in kernel_template:
        errors.append(
            f"references/kernel.template.md: missing shell-tool guidance for {required_tool!r}"
        )
if "prompt the user to install the shell tooling before falling back" in kernel_template:
    errors.append(
        "references/kernel.template.md: blocking shell-tool install prompt remains"
    )

for marker in [
    "<!-- generated:kernel-routing:start -->",
    "<!-- generated:kernel-routing:end -->",
    "<!-- generated:mcp-operations:start -->",
    "<!-- generated:mcp-operations:end -->",
]:
    if marker not in kernel_template:
        errors.append(f"references/kernel.template.md: missing generated marker {marker!r}")
for skill in skills:
    if not isinstance(skill.get("routing"), dict):
        continue
    name_token = f"`{skill['name']}`"
    if name_token not in kernel_template:
        errors.append(
            f"references/kernel.template.md: routing is missing {name_token}"
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

# Safety-gate parity: every runtime that ships a permission model must gate the
# command families the kernel (references/kernel.template.md)
# requires, at no weaker than the canonical severity. "ask" = must prompt for
# approval; "deny" = must be refused. Each family is checked through the
# runtime's own permission model. Runtimes without a managed permission gate
# (e.g. Pi's adapter-only model) are checked against their shipped extension.
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


pi_extension = read_text(ROOT / "pi" / "extensions" / "b-agentic-permissions.ts")
for tokens, min_severity in SAFETY_GATES:
    if pi_gate_severity(tokens, pi_extension) < SEVERITY_RANK[min_severity]:
        errors.append(
            f"pi/extensions/b-agentic-permissions.ts: safety gate {' '.join(tokens)!r} weaker than required {min_severity!r}; "
            "align with references/kernel.template.md"
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
    ROOT / "references" / "kernel.template.md",
    *(ROOT / "skills" / name / "SKILL.md" for name in skill_names),
]
for path in generated_paths:
    if path.exists() and "{{" in path.read_text():
        errors.append(f"{rel(path)}: unresolved template token")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print(f"Shared skill validation passed ({len(skill_names)} skills).")
