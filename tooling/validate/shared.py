#!/usr/bin/env python3

from pathlib import Path
import json
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tooling.policy.load import (
    load_output_policy,
    validate_mode_policy_contract,
    validate_output_policy_contract,
)

errors = []


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def read_text(path: Path) -> str:
    return path.read_text() if path.exists() else ""


def load_runtime_registry():
    registry_path = ROOT / "runtimes" / "registry.yaml"
    if not registry_path.exists():
        errors.append(f"{rel(registry_path)}: missing runtime registry")
        return []

    try:
        registry = json.loads(registry_path.read_text())
    except Exception as exc:
        errors.append(f"{rel(registry_path)}: invalid JSON-compatible YAML registry: {exc}")
        return []

    runtimes = registry.get("runtimes")
    if not isinstance(runtimes, list) or not runtimes:
        errors.append(f"{rel(registry_path)}: runtimes must be a non-empty array")
        return []

    runtime_names = []
    for index, runtime in enumerate(runtimes):
        if not isinstance(runtime, dict):
            errors.append(f"{rel(registry_path)}: runtime entry {index} must be an object")
            continue
        name = runtime.get("name")
        if not isinstance(name, str) or not name:
            errors.append(f"{rel(registry_path)}: runtime entry {index} missing non-empty name")
            continue
        runtime_names.append(name)

    return runtime_names


def load_skill_registry():
    registry_path = ROOT / "skills" / "registry.yaml"
    if not registry_path.exists():
        errors.append(f"{rel(registry_path)}: missing skill registry")
        return []

    try:
        registry = json.loads(registry_path.read_text())
    except Exception as exc:
        errors.append(f"{rel(registry_path)}: invalid JSON-compatible YAML registry: {exc}")
        return []

    skills = registry.get("skills")
    if not isinstance(skills, list) or not skills:
        errors.append(f"{rel(registry_path)}: skills must be a non-empty array")
        return []

    return skills


def frontmatter_parts(path: Path):
    text = path.read_text()
    if not text.startswith("---\n"):
        errors.append(f"{rel(path)}: missing YAML frontmatter start")
        return "", text
    parts = text.split("---", 2)
    if len(parts) < 3:
        errors.append(f"{rel(path)}: missing YAML frontmatter close")
        return "", text
    return parts[1], parts[2]


def top_level_keys(frontmatter: str):
    return re.findall(r"^([A-Za-z0-9_-]+):", frontmatter, re.MULTILINE)


def tracked_existing_root_markdown_docs():
    docs = set()
    for path in ROOT.glob("*.md"):
        result = subprocess.run(
            ["git", "ls-files", "--error-unmatch", path.name],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            docs.add(path.name)
    return docs


def tool_model_bundle_names(text: str):
    return set(re.findall(r"^#### `([^`]+)`", text, re.MULTILINE))


def prompt_tool_tokens(text: str):
    match = re.search(r"^## Tools required\n(.*?)(?=^## )", text, re.MULTILINE | re.DOTALL)
    if not match:
        return set()
    tool_refs = set()
    for line in match.group(1).splitlines():
        if not re.match(r"^- `", line):
            continue
        tool_refs.update(re.findall(r"`([^`]+)`", line))
    return tool_refs


def require_contains(path: Path, text: str, needles, label: str):
    for needle in needles:
        if needle not in text:
            errors.append(f"{rel(path)}: missing {label} {needle!r}")


runtime_names = load_runtime_registry()
registry_skills = load_skill_registry()

skill_paths = sorted((ROOT / "skills").glob("*/SKILL.md"))
skill_names = [path.parent.name for path in skill_paths]
allowed_frontmatter = {
    "name",
    "description",
    "when_to_use",
    "argument-hint",
    "arguments",
    "user-invocable",
    "model",
    "effort",
    "context",
    "agent",
    "hooks",
    "paths",
    "shell",
}
required_sections = [
    "## When to use",
    "## When NOT to use",
    "## Tools required",
    "## Steps",
    "## Rules",
]

if not skill_paths:
    errors.append("skills/: no SKILL.md files found")

registry_skill_map = {}
for skill in registry_skills:
    if not isinstance(skill, dict):
        continue
    name = skill.get("name")
    if isinstance(name, str) and name:
        registry_skill_map[name] = skill

if (ROOT / "commands").exists() and any((ROOT / "commands").glob("*.md")):
    errors.append("commands/: Claude-native runtime should not ship command wrappers; skills create /b-* commands")

for path in skill_paths:
    name = path.parent.name
    text = path.read_text()
    frontmatter, body = frontmatter_parts(path)

    for key in top_level_keys(frontmatter):
        if key not in allowed_frontmatter:
            errors.append(f"{rel(path)}: unsupported skill frontmatter key {key!r}")

    name_match = re.search(r"^name:\s*(\S+)\s*$", frontmatter, re.MULTILINE)
    if not name_match:
        errors.append(f"{rel(path)}: missing frontmatter name")
    elif name_match.group(1) != name:
        errors.append(f"{rel(path)}: frontmatter name {name_match.group(1)!r} does not match directory {name!r}")

    desc_match = re.search(
        r"^description:\s*>\s*\n(?P<desc>(?:\s+.*\n)+?)(?=^[A-Za-z0-9_-]+:|^---)",
        frontmatter + "---",
        re.MULTILINE,
    )
    if not desc_match:
        errors.append(f"{rel(path)}: missing block description")
    else:
        desc = " ".join(line.strip() for line in desc_match.group("desc").splitlines())
        word_count = len(desc.split())
        if word_count > 80:
            errors.append(f"{rel(path)}: description has {word_count} words, expected <=80")

    if "allowed-tools:" in frontmatter:
        errors.append(f"{rel(path)}: allowed-tools grants permissions and requires explicit maintainer review before use")

    for section in required_sections:
        if section not in body:
            errors.append(f"{rel(path)}: missing required section {section!r}")

    # Per kernel §9 ("Skills do not restate this rule"), the status/handoff read-gate is
    # kernel-global: every runtime installs the kernel into its memory file, which carries
    # the contract/09-output read-gate. A per-skill 09-reference assertion is intentionally
    # NOT enforced here — most skills correctly defer to the kernel gate rather than
    # embedding their own (b-review keeps one by point-of-use need).

    if "## Output format" in body:
        output_fmt_start = body.index("## Output format")
        next_heading = body.find("\n## ", output_fmt_start + 1)
        output_section = body[output_fmt_start:next_heading] if next_heading != -1 else body[output_fmt_start:]
        output_lines = [line.strip() for line in output_section.splitlines()[1:] if line.strip()]
        if len(output_lines) < 2:
            errors.append(f"{rel(path)}: Output format section has fewer than 2 non-empty lines")
    else:
        errors.append(f"{rel(path)}: missing ## Output format section")

    forbidden = [
        "compatibility: opencode",
        "metadata:",
        "suite: b-agentic",
        "active `AGENTS.md` runtime kernel",
        "global/AGENTS.md",
    ]
    for needle in forbidden:
        if needle in text:
            errors.append(f"{rel(path)}: stale pattern {needle!r}")

    for runtime_doc in ["CLAUDE.md", "AGENTS.md"]:
        if runtime_doc in text:
            errors.append(f"{rel(path)}: shared skills must stay runtime-neutral and must not mention {runtime_doc}")

    if "${B_AGENTIC_RUNTIME_REFERENCES}" in text or "${B_AGENTIC_SKILL_DIR}" in text:
        errors.append(f"{rel(path)}: generated skills must not ship unresolved support-path placeholders")

    if "references/contract/" in text and "../../b-agentic/references/contract/" not in text:
        errors.append(f"{rel(path)}: contract read gates must use the installed shared reference path ../../b-agentic/references/contract/")

    if "performance-checklist.md" in text and "../../b-agentic/references/performance-checklist.md" not in text:
        errors.append(f"{rel(path)}: performance checklist read gates must use the installed shared reference path ../../b-agentic/references/performance-checklist.md")

    if "Read `reference.md` before" in text or re.search(r"Read\s+`?reference\.md`?", text):
        if "./reference.md" not in text:
            errors.append(f"{rel(path)}: local reference.md read gates must use the installed skill-local path ./reference.md")

    if re.search(r"Read §\d+", text):
        errors.append(f"{rel(path)}: read gates must name the reference file, not only a section number")

    if "Graceful degradation:" in text:
        errors.append(f"{rel(path)}: graceful degradation rules are centralized in the kernel; skills must not restate them")

    skill_reference = path.parent / "reference.md"
    if skill_reference.exists() and "reference.md" not in text:
        errors.append(f"{rel(path)}: existing reference.md is not discoverable from SKILL.md")

support_doc_paths = sorted(
    path
    for path in (ROOT / "skills").glob("*/*.md")
    if path.name not in {"prompt.md", "SKILL.md"}
)
for path in support_doc_paths:
    text = path.read_text()
    if any(token in text for token in ["${CLAUDE_SKILL_DIR}", "${B_AGENTIC_RUNTIME_REFERENCES}", "${B_AGENTIC_SKILL_DIR}"]):
        errors.append(f"{rel(path)}: support docs must not ship unresolved support-path placeholders")

routing_path = ROOT / "references" / "contract" / "01-routing.md"
if not routing_path.exists():
    errors.append("references/contract/01-routing.md: missing contract routing source")
else:
    routing_text = routing_path.read_text()
    referenced_skills = set(re.findall(r"`/(b-[a-z][a-z0-9-]*)`", routing_text))
    skill_dirs = set(skill_names)
    for name in sorted(referenced_skills - skill_dirs):
        errors.append(f"references/contract/01-routing.md: references /{name} but no skills/{name}/ directory exists")
    if "Bare mentions like `PR`, `ship`, or `lint` are ambiguous." not in routing_text:
        errors.append("references/contract/01-routing.md: missing ambiguous PR/ship/lint clarification rule")
    if "b-agentic suite self-audits use `b-review --audit-suite` or explicit suite-audit prose" not in routing_text:
        errors.append("references/contract/01-routing.md: suite-audit routing must allow explicit prose intent, not only --audit-suite")

normalized_routing_triggers = {}
command_only_terms = {}
for name, skill in registry_skill_map.items():
    routing = skill.get("routing")
    triggers = []
    if isinstance(routing, dict):
        trigger_values = routing.get("triggers", [])
        if isinstance(trigger_values, list):
            triggers = [trigger.strip().lower() for trigger in trigger_values if isinstance(trigger, str)]
    normalized_routing_triggers[name] = triggers

    command = skill.get("command")
    if isinstance(command, dict) and command.get("exposed") is True and routing is None:
        alias = command.get("alias")
        if isinstance(alias, str) and alias.startswith("b-"):
            command_only_terms[name] = alias[2:].strip().lower()

for command_skill, command_term in command_only_terms.items():
    for routing_skill, triggers in normalized_routing_triggers.items():
        if command_term and command_term in triggers:
            errors.append(
                f"skills/registry.yaml: command-only skill {command_skill!r} must not leak natural-language trigger {command_term!r} into routable skill {routing_skill!r}"
            )

simulated_dom_terms = {"component test", "jsdom", "happy-dom", "react testing library"}
browser_triggers = set(normalized_routing_triggers.get("b-browser", []))
test_triggers = set(normalized_routing_triggers.get("b-test", []))
browser_conflicts = sorted(browser_triggers & simulated_dom_terms)
if browser_conflicts:
    errors.append(
        f"skills/registry.yaml: b-browser routing must not include simulated-DOM/component-test triggers {browser_conflicts}"
    )

missing_test_terms = sorted(simulated_dom_terms - test_triggers)
if missing_test_terms:
    errors.append(
        f"skills/registry.yaml: b-test routing must include simulated-DOM/component-test triggers {missing_test_terms}"
    )

research_triggers = set(normalized_routing_triggers.get("b-research", []))
if '"what is"' in research_triggers:
    errors.append('skills/registry.yaml: b-research routing must not include the low-signal trigger \'"what is"\'')

refactor_triggers = set(normalized_routing_triggers.get("b-refactor", []))
if "cleanup" in refactor_triggers:
    errors.append("skills/registry.yaml: b-refactor routing must not include the vague trigger 'cleanup'")

review_triggers = set(normalized_routing_triggers.get("b-review", []))
for forbidden_trigger in ["pr", "lint"]:
    if forbidden_trigger in review_triggers:
        errors.append(
            f"skills/registry.yaml: b-review routing must not include the ambiguous trigger {forbidden_trigger!r}"
        )

review_skill = registry_skill_map.get("b-review", {})
review_routing = review_skill.get("routing") if isinstance(review_skill, dict) else None
review_prompt_meta = review_skill.get("prompt") if isinstance(review_skill, dict) else None
review_routing_text = ""
if isinstance(review_routing, dict):
    review_routing_text = " ".join(
        str(value)
        for value in [
            review_routing.get("intent", ""),
            *review_routing.get("triggers", []),
        ]
    ).lower()
review_prompt_description = ""
if isinstance(review_prompt_meta, dict):
    review_prompt_description = str(review_prompt_meta.get("description", ""))
review_prompt_source = read_text(ROOT / "skills" / "b-review" / "prompt.md")
review_audit_surface = " ".join(
    [review_routing_text, review_prompt_description, review_prompt_source]
).lower()
if "suite audit" in review_routing_text or "b-agentic audit" in review_routing_text:
    required_audit_markers = ["--audit-suite", "b-agentic suite self-audit"]
    for marker in required_audit_markers:
        if marker not in review_audit_surface:
            errors.append(
                f"skills/registry.yaml and skills/b-review/prompt.md: b-review suite-audit routing must mention {marker!r}"
            )
    forbidden_audit_patterns = [
        r"do not invoke for (?:repo/)?suite audits",
    ]
    for pattern in forbidden_audit_patterns:
        if re.search(pattern, review_audit_surface):
            errors.append(
                "skills/registry.yaml and skills/b-review/prompt.md: "
                "b-review suite-audit routing contradicts prompt text that forbids suite audits"
            )

if not re.search(r'--audit-suite.*\{\{skill_support_path\}\}/reference\.md', review_prompt_source):
    errors.append(
        "skills/b-review/prompt.md: missing --audit-suite read-gate to "
        "{{skill_support_path}}/reference.md (Audit-suite checklists); "
        "add an explicit read instruction scoped to --audit-suite distinct from the changed-code security-checklist gate"
    )
if "suite self-audit without `--audit-suite` -> ask" in review_prompt_source:
    errors.append(
        "skills/b-review/prompt.md: explicit suite-audit intent must route directly to audit mode; "
        "do not ask for --audit-suite when prose already names a b-agentic suite self-audit"
    )
if "with or without `--audit-suite`" not in review_prompt_source:
    errors.append(
        "skills/b-review/prompt.md: suite-audit routing must accept explicit prose intent with or without --audit-suite"
    )

b_implement_prompt_source = read_text(ROOT / "skills" / "b-implement" / "prompt.md")
if "missing frontmatter, non-executable `status`" in b_implement_prompt_source:
    errors.append(
        "skills/b-implement/prompt.md: missing frontmatter must not be a hard validation failure; "
        "contract/02 allows legacy no-frontmatter plans with current-chat approval"
    )
for required_line in [
    "Legacy saved plans without frontmatter may execute only when the current conversation contains explicit approval.",
    "Use the current-chat approval time for staleness checks",
]:
    if required_line not in b_implement_prompt_source:
        errors.append(f"skills/b-implement/prompt.md: missing legacy-plan guard {required_line!r}")

readme = read_text(ROOT / "README.md")
maintainer = read_text(ROOT / "CLAUDE.md")
tool_model_path = ROOT / "references" / "contract" / "04-tool-model.md"
tool_model_text = read_text(tool_model_path)
shared_contract_paths = sorted(
    p for p in (ROOT / "references" / "contract").glob("*.md")
    if re.match(r"[0-9]{2}-", p.name)
)
kernel_path = ROOT / "runtimes" / "claude-code" / "kernel.md"
kernel = read_text(kernel_path)
contract_index_path = ROOT / "references" / "contract" / "index.md"
contract_index = read_text(contract_index_path)
output_contract_path = ROOT / "references" / "contract" / "09-output.md"
output_contract = read_text(output_contract_path)
definitions_contract_path = ROOT / "references" / "contract" / "03-definitions.md"
definitions_contract = read_text(definitions_contract_path)
session_contract_path = ROOT / "references" / "contract" / "11-session.md"
session_contract = read_text(session_contract_path)
install_sh = read_text(ROOT / "install.sh")
registry_sync = ROOT / "tooling" / "generate" / "registry_sync.py"
validate_wrapper_path = ROOT / "scripts" / "validate-skills.sh"
validate_runner_path = ROOT / "tooling" / "validate" / "run.sh"
smoke_wrapper_path = ROOT / "scripts" / "smoke-install.sh"
smoke_runner_path = ROOT / "tests" / "smoke" / "install.sh"
smoke_lib_path = ROOT / "tests" / "smoke" / "lib.sh"
runtime_template_root = ROOT / "runtimes" / "runtime-template"
shared_kernel_template_path = ROOT / "references" / "contract" / "kernel.template.md"
shared_kernel_template = read_text(shared_kernel_template_path)

if shared_kernel_template and "09-output" not in shared_kernel_template:
    errors.append(f"{rel(shared_kernel_template_path)}: kernel template must reference contract/09-output for the shared status-block schema")

_policy_schema, _output_policy = load_output_policy(errors)
validate_output_policy_contract(_output_policy, output_contract, errors)
validate_mode_policy_contract(
    _output_policy,
    definitions_contract,
    shared_kernel_template,
    readme,
    errors,
)

# Decision cards removed in slim-down refactor; no card checks needed.
# Internal conformance/scenario self-tests run only in --release mode.

browser_evidence_row = (
    "| Browser/DOM/visual/e2e evidence | Supplied/CI evidence or existing repo scripts "
    "when they answer the question | `playwright-browser-operator` when live-browser evidence is needed "
    "and safety-gated; `firecrawl-extraction` only for static known remote pages |"
)
if browser_evidence_row not in tool_model_text:
    errors.append(
        f"{rel(tool_model_path)}: browser evidence priority must prefer supplied/CI evidence or existing repo scripts before live-browser operation"
    )

# --- Read-gate resolvability guard (locks the M1/n1 broken-pointer class) ---
# Every contract read-gate path shipped in a kernel or SKILL must resolve to a real
# source under references/contract/, and the kernel template must never carry a bare
# unanchored `contract/<f>.md` gate path (the M1 defect class). Scoped to explicit
# references/contract/<f>.md citations and skill-local ./reference.md gates so ordinary
# prose ("runtime contract §N", the `references/contract/*.md` glob) is not flagged.
_contract_dir = ROOT / "references" / "contract"
_contract_ref_re = re.compile(r"references/contract/([0-9A-Za-z][0-9A-Za-z._-]*\.md)")
_bare_contract_re = re.compile(r"(?<![\w/])contract/([0-9][0-9A-Za-z._-]*\.md)")

_read_gate_sources = [shared_kernel_template_path]
_read_gate_sources += [ROOT / "runtimes" / _rn / "kernel.md" for _rn in runtime_names]
_read_gate_sources += list(skill_paths)
for _gate_path in _read_gate_sources:
    _gate_text = read_text(_gate_path)
    for _contract_file in sorted(set(_contract_ref_re.findall(_gate_text))):
        if not (_contract_dir / _contract_file).exists():
            errors.append(
                f"{rel(_gate_path)}: read-gate cites references/contract/{_contract_file} but no such contract source exists"
            )

for _bare_file in sorted(set(_bare_contract_re.findall(shared_kernel_template))):
    errors.append(
        f"{rel(shared_kernel_template_path)}: unanchored read-gate path contract/{_bare_file}; "
        f"use {{{{runtime_metadata_root}}}}/references/contract/{_bare_file}"
    )

for _skill_path in skill_paths:
    _skill_name = _skill_path.parent.name
    if "./reference.md" in read_text(_skill_path) and not (ROOT / "skills" / _skill_name / "reference.md").exists():
        errors.append(
            f"{rel(_skill_path)}: read-gate cites ./reference.md but skills/{_skill_name}/reference.md does not exist"
        )

kernel_contract_version_match = re.search(r"This runtime contract version is `([0-9]{4}-[0-9]{2}-[0-9]{2})`", kernel)
kernel_contract_version = kernel_contract_version_match.group(1) if kernel_contract_version_match else None

# Extract canonical contract version from kernel template (00-kernel.md removed in slim-down)
canonical_version_match = re.search(r"This runtime contract version is `([0-9]{4}-[0-9]{2}-[0-9]{2})`", shared_kernel_template)
canonical_contract_version = canonical_version_match.group(1) if canonical_version_match else None

if not canonical_contract_version:
    errors.append("references/contract/kernel.template.md: unable to extract canonical contract version")

if not kernel_path.exists():
    errors.append("runtimes/claude-code/kernel.md: missing Claude Code kernel source")

# Check generated runtime kernels for contract version consistency with canonical source
if canonical_contract_version:
    for runtime_name in runtime_names:
        runtime_kernel_path = ROOT / "runtimes" / runtime_name / "kernel.md"
        if not runtime_kernel_path.exists():
            continue
        runtime_kernel_text = read_text(runtime_kernel_path)
        runtime_version_match = re.search(r"This runtime contract version is `([0-9]{4}-[0-9]{2}-[0-9]{2})`", runtime_kernel_text)
        if runtime_version_match:
            runtime_version = runtime_version_match.group(1)
            if runtime_version != canonical_contract_version:
                errors.append(f"{rel(runtime_kernel_path)}: contract version {runtime_version!r} does not match canonical version {canonical_contract_version!r}")

    # Check kernel template consistency with canonical source
    if shared_kernel_template:
        template_version_match = re.search(r"This runtime contract version is `([0-9]{4}-[0-9]{2}-[0-9]{2})`", shared_kernel_template)
        if template_version_match:
            template_version = template_version_match.group(1)
            if template_version != canonical_contract_version:
                errors.append(f"{rel(shared_kernel_template_path)}: contract version {template_version!r} does not match canonical version {canonical_contract_version!r}")

contract_version = canonical_contract_version or kernel_contract_version

for runtime_name in runtime_names:
    runtime_dir = ROOT / "runtimes" / runtime_name
    if not (runtime_dir / "kernel.md").exists():
        errors.append(f"runtimes/{runtime_name}/kernel.md: missing registered runtime kernel")
    if not (runtime_dir / "scripts" / "install.sh").exists():
        errors.append(f"runtimes/{runtime_name}/scripts/install.sh: missing registered runtime installer")
    if not (runtime_dir / "scripts" / "validate.sh").exists():
        errors.append(f"runtimes/{runtime_name}/scripts/validate.sh: missing registered runtime validator")
    if not (runtime_dir / "tests" / "smoke.sh").exists():
        errors.append(f"runtimes/{runtime_name}/tests/smoke.sh: missing registered runtime smoke suite")

# --- SKILL.md sibling-layout invariant ---
# Renderer hardcodes RENDERED_RUNTIME_REFERENCE_ROOT = "../../b-agentic/references".
# For a SKILL.md at skills_install_root/<skill>/SKILL.md this path resolves to
# <parent>/b-agentic/references, so skills_install_root and metadata_root must share
# a parent and metadata_root must be named "b-agentic".
_runtimes_registry_path = ROOT / "runtimes" / "registry.yaml"
try:
    _runtimes_full = json.loads(_runtimes_registry_path.read_text())
    for _rt in _runtimes_full.get("runtimes", []):
        _rt_name = _rt.get("name", "?")
        _skills_root_str = _rt.get("skills_install_root", "")
        _meta_root_str = _rt.get("metadata_root", "")
        if not _skills_root_str or not _meta_root_str:
            continue
        _skills_root = Path(_skills_root_str)
        _meta_root = Path(_meta_root_str)
        if _skills_root.parent != _meta_root.parent:
            errors.append(
                f"runtimes/registry.yaml: runtime {_rt_name!r} skills_install_root "
                f"({_skills_root_str}) and metadata_root ({_meta_root_str}) do not share "
                f"a parent directory; the rendered SKILL.md read-gate path "
                f"'../../b-agentic/references' would resolve incorrectly at install time"
            )
        elif _meta_root.name != "b-agentic":
            errors.append(
                f"runtimes/registry.yaml: runtime {_rt_name!r} metadata_root "
                f"({_meta_root_str}) must be named 'b-agentic'; the rendered SKILL.md "
                f"read-gate path '../../b-agentic/references' expects a sibling named 'b-agentic'"
            )
except Exception:
    pass  # registry parse errors already reported by load_runtime_registry()

# Keep registered runtime reference and artifact examples aligned with the shared
# contract so agents do not invent per-runtime paths from partial examples.
_RUNTIME_CONTRACT_EXAMPLES = {
    "claude-code": {
        "reference": "~/.claude/b-agentic/references/contract/",
        "temp_root": "/tmp/claude-code/b-agentic/",
        "sensitive": "~/.claude/b-agentic/<skill>/<run-id>/",
        "temp_run": "/tmp/claude-code/b-agentic/<skill>/<run-id>/",
        "temp_log": "/tmp/claude-code/b-agentic/<skill>/<slug>.log",
    },
    "opencode": {
        "reference": "~/.config/opencode/b-agentic/references/contract/",
        "temp_root": "/tmp/opencode/b-agentic/",
        "sensitive": "~/.config/opencode/b-agentic/<skill>/<run-id>/",
        "temp_run": "/tmp/opencode/b-agentic/<skill>/<run-id>/",
        "temp_log": "/tmp/opencode/b-agentic/<skill>/<slug>.log",
    },
    "codex-cli": {
        "reference": "~/.codex/b-agentic/references/contract/",
        "temp_root": "/tmp/codex-cli/b-agentic/",
        "sensitive": "~/.codex/b-agentic/<skill>/<run-id>/",
        "temp_run": "/tmp/codex-cli/b-agentic/<skill>/<run-id>/",
        "temp_log": "/tmp/codex-cli/b-agentic/<skill>/<slug>.log",
    },
    "antigravity-cli": {
        "reference": "~/.gemini/antigravity-cli/b-agentic/references/contract/",
        "temp_root": "/tmp/antigravity-cli/b-agentic/",
        "sensitive": "~/.gemini/antigravity-cli/b-agentic/<skill>/<run-id>/",
        "temp_run": "/tmp/antigravity-cli/b-agentic/<skill>/<run-id>/",
        "temp_log": "/tmp/antigravity-cli/b-agentic/<skill>/<slug>.log",
    },
    "zed": {
        "reference": "~/.agents/b-agentic/references/contract/",
        "temp_root": "/tmp/zed/b-agentic/",
        "sensitive": "~/.agents/b-agentic/<skill>/<run-id>/",
        "temp_run": "/tmp/zed/b-agentic/<skill>/<run-id>/",
        "temp_log": "/tmp/zed/b-agentic/<skill>/<slug>.log",
    },
}
artifact_contract_path = ROOT / "references" / "contract" / "08-artifacts.md"
artifact_contract = read_text(artifact_contract_path)
for _runtime_name in runtime_names:
    _examples = _RUNTIME_CONTRACT_EXAMPLES.get(_runtime_name)
    if not _examples:
        continue
    for _key in ["reference", "temp_root"]:
        if _examples[_key] not in contract_index:
            errors.append(
                f"{rel(contract_index_path)}: missing {_runtime_name} {_key} example {_examples[_key]!r}"
            )
    for _key in ["sensitive", "temp_run", "temp_log"]:
        if _examples[_key] not in artifact_contract:
            errors.append(
                f"{rel(artifact_contract_path)}: missing {_runtime_name} {_key} example {_examples[_key]!r}"
            )

if not readme:
    errors.append("README.md: missing or empty")
else:
    for name in skill_names:
        if name not in readme:
            errors.append(f"README.md: missing skill name {name}")
    for required in ["tooling/validate/", "tests/smoke/", "runtimes/runtime-template/"]:
        if required not in readme:
            errors.append(f"README.md: missing phase-4 architecture path {required!r}")
    if "scripts/validate-skills.sh --release" not in readme:
        errors.append("README.md: missing release-critical validation entrypoint scripts/validate-skills.sh --release")

for required in ["tooling/validate/", "tests/smoke/", "runtimes/runtime-template/"]:
    if required not in maintainer:
        errors.append(f"CLAUDE.md: missing phase-4 maintainer path {required!r}")
if "scripts/validate-skills.sh --release" not in maintainer:
    errors.append("CLAUDE.md: missing release-critical validation entrypoint scripts/validate-skills.sh --release")

root_markdown_docs = tracked_existing_root_markdown_docs()
allowed_root_markdown_docs = {"README.md", "CLAUDE.md"}
unexpected_root_docs = sorted(root_markdown_docs - allowed_root_markdown_docs)
if unexpected_root_docs:
    errors.append(
        "root docs: unexpected top-level Markdown docs "
        f"{unexpected_root_docs}; keep root docs targeted and move skill detail or support material under skills/, references/, or runtimes/"
    )

bundle_names = tool_model_bundle_names(tool_model_text)
if not bundle_names:
    errors.append(f"{rel(tool_model_path)}: missing MCP bundle definitions")
else:
    allowed_native_tool_refs = {"bash", "glob", "grep", "read"}
    for prompt_path in sorted((ROOT / "skills").glob("*/prompt.md")):
        tool_refs = prompt_tool_tokens(prompt_path.read_text())
        unknown_refs = sorted(tool_refs - allowed_native_tool_refs - bundle_names)
        if unknown_refs:
            errors.append(
                f"{rel(prompt_path)}: tool references {unknown_refs} are not defined MCP bundles in {rel(tool_model_path)}"
            )

runtime_readiness_install_lines = [
    'print_install_report_readiness',
    "print_shell_tool_recommendations",
    'print_install_report_next_steps',
]
release_validation_lines = [
    "run_release=0",
    "--release)",
    'bash "$ROOT_DIR/tests/smoke/install.sh"',
]
shared_shell_install_lines = [
    "recommended_shell_commands() {",
    "printf 'rg, fd/fdfind, jq'",
    "optional_shell_commands() {",
    "printf 'bat/batcat, yq, git-delta, gh, tmux, fzf'",
    "optional_shell_tool_workflows() {",
    "printf 'readable file previews, YAML-heavy work, better git diffs, GitHub-heavy workflows, long-running jobs, and non-interactive scoring'",
    'report_section "Shell tooling"',
    'report_item "installer" "suggestions only; no packages were installed automatically"',
]
runtime_readiness_doc_lines = [
    "## MCP readiness after install",
    "`playwright` is immediately available once `pnpm` is on `PATH`; no extra suite-owned setup runs.",
    "`serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.",
]
runtime_shell_doc_lines = [
    "## Optional shell tooling recommendations",
    "Install reports print a default shell-tooling tier for `rg`, `fd`/`fdfind`, and `jq`, plus a separate optional tier for `bat`/`batcat`, `yq`, `git-delta`, `gh`, `tmux`, and `fzf`.",
    "The tier-2 block is aimed at readable file previews, YAML-heavy work, better git diffs, GitHub-heavy workflows, long-running jobs, and non-interactive scoring.",
    "When the installer can detect Homebrew, `apt`, or `dnf`, it prints matching package commands for both tiers; otherwise it falls back to manual-install notes.",
    "The installer never auto-installs these packages.",
]
for runtime_name, api_key_line in [
    ("claude-code", "`context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.claude.json`."),
    ("opencode", "`context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.config/opencode/opencode.json`."),
    ("codex-cli", "`context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.codex/config.toml` or matching shell environment variables."),
    ("antigravity-cli", "`context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.gemini/antigravity-cli/mcp_config.json` or matching shell environment variables."),
]:
    install_path = ROOT / "runtimes" / runtime_name / "scripts" / "install.sh"
    readme_path = ROOT / "runtimes" / runtime_name / "configs" / "README.md"
    require_contains(install_path, read_text(install_path), runtime_readiness_install_lines, "runtime readiness install line")
    require_contains(readme_path, read_text(readme_path), runtime_readiness_doc_lines + runtime_shell_doc_lines + [api_key_line], "runtime readiness doc line")
require_contains(ROOT / "tooling" / "install" / "common.sh", read_text(ROOT / "tooling" / "install" / "common.sh"), shared_shell_install_lines, "shared shell tooling install line")
require_contains(validate_runner_path, read_text(validate_runner_path), release_validation_lines, "release validation line")

for contract_path in shared_contract_paths:
    if not contract_path.exists():
        errors.append(f"{rel(contract_path)}: missing shared contract file")
        continue

    contract_text = contract_path.read_text()
    if "CLAUDE.md" in contract_text or "AGENTS.md" in contract_text:
        errors.append(f"{rel(contract_path)}: shared contract files must refer to the active runtime kernel, not a runtime-specific memory filename")

    if "runtimes/claude-code/kernel.md" in contract_text and "runtimes/<name>/kernel.md" not in contract_text:
        errors.append(f"{rel(contract_path)}: shared contract files must not hardcode the Claude runtime kernel path")

    if "~/.claude/b-agentic" in contract_text and "~/.config/opencode/b-agentic" not in contract_text and "active runtime" not in contract_text:
        errors.append(f"{rel(contract_path)}: Claude-only user-scope artifact paths in shared contract files must be runtime-neutral or dual-runtime")

    if "/tmp/claude-code/b-agentic" in contract_text and "/tmp/opencode/b-agentic" not in contract_text and "active runtime" not in contract_text:
        errors.append(f"{rel(contract_path)}: Claude-only temp artifact paths in shared contract files must be runtime-neutral or dual-runtime")

for shared_doc_path, shared_doc_text in [
    (contract_index_path, contract_index),
    (ROOT / "references" / "contract" / "00-kernel.md", read_text(ROOT / "references" / "contract" / "00-kernel.md")),
    (shared_kernel_template_path, shared_kernel_template),
]:
    if "${CLAUDE_SKILL_DIR}" in shared_doc_text or "${B_AGENTIC_RUNTIME_REFERENCES}" in shared_doc_text or "${B_AGENTIC_SKILL_DIR}" in shared_doc_text:
        errors.append(f"{rel(shared_doc_path)}: shared contract docs must not use unresolved support-path placeholders")

if "bridge marker" in maintainer.lower() or "delivery bridge" in maintainer.lower():
    errors.append("CLAUDE.md: maintainer guidance should no longer rely on bridge-marker exceptions")

for path in sorted((ROOT / "skills").glob("*/prompt.md")):
    text = path.read_text()
    if "Skill tool" in text:
        errors.append(f"{rel(path)}: unsupported Skill tool claim; use handoff/status semantics instead")

if "Skill tool" in read_text(ROOT / "skills" / "registry.yaml"):
    errors.append("skills/registry.yaml: unsupported Skill tool claim; registry descriptions must use handoff/status semantics")

b_ship_prompt = read_text(ROOT / "skills" / "b-ship" / "prompt.md")
if "reviewed plan" in b_ship_prompt:
    errors.append("skills/b-ship/prompt.md: reviewed plans must not count as review evidence")
if "`b-review` status block" not in b_ship_prompt or "explicit current-session user override" not in b_ship_prompt:
    errors.append("skills/b-ship/prompt.md: missing explicit b-review or current-session override shipping gate")
if "explicit ship intent" not in b_ship_prompt or "recommendation, not an implicit shipping handoff" not in b_ship_prompt:
    errors.append("skills/b-ship/prompt.md: missing explicit-request-only shipping wording")

for required_line in [
    "verdict: <skill-defined terminal label>",
    "cause: <cause-class>   (required when state is 'blocked' or 'needs-input'; omit otherwise)",
    "`state` reports execution flow; `verdict` reports the skill-specific outcome.",
]:
    if required_line not in output_contract:
        errors.append(f"{rel(output_contract_path)}: missing status-schema line {required_line!r}")

for verdict_prompt_path in [
    ROOT / "skills" / "b-review" / "prompt.md",
]:
    verdict_prompt = read_text(verdict_prompt_path)
    if "verdict:" not in verdict_prompt:
        errors.append(f"{rel(verdict_prompt_path)}: verdict-owning prompt must reference the verdict field explicitly")

required_b_test_intent = "| Unit/integration/component tests, coverage, failing tests | `b-test` |"
if required_b_test_intent not in shared_kernel_template and required_b_test_intent not in read_text(ROOT / 'references' / 'contract' / '01-routing.md'):
    errors.append(
        f"{rel(shared_kernel_template_path)} and references/contract/01-routing.md: missing updated b-test routing intent for component-test ownership"
    )

# b-orchestrate removed in slim-down refactor; no orchestrate-specific checks needed

if contract_version:
    for plan_path in sorted((ROOT / ".b-agentic" / "b-plan").glob("*.md")):
        plan_text = plan_path.read_text()
        plan_version_match = re.search(r"^contract_version:\s*(\S+)", plan_text, re.MULTILINE)
        if plan_version_match:
            plan_version = plan_version_match.group(1).strip('"')
            if plan_version != contract_version:
                errors.append(f"{rel(plan_path)}: contract_version {plan_version!r} does not match kernel contract version {contract_version!r}")
else:
    errors.append("runtimes/claude-code/kernel.md: unable to extract contract version")

if not registry_sync.exists():
    errors.append("tooling/generate/registry_sync.py: missing registry generator")
else:
    registry_sync_check = subprocess.run(
        ["python3", str(registry_sync), "--check"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if registry_sync_check.returncode != 0:
        output = registry_sync_check.stderr.strip() or registry_sync_check.stdout.strip()
        if output:
            errors.extend(line for line in output.splitlines() if line.strip())
        else:
            errors.append("tooling/generate/registry_sync.py --check failed")

secret_literal_patterns = [
    re.compile(r"fc-[A-Za-z0-9_-]{8,}"),
    re.compile(r"YOUR[_-]?API[_-]?KEY", re.IGNORECASE),
    re.compile(r"your-api-key", re.IGNORECASE),
]

for json_path in sorted((ROOT / "runtimes").glob("*/configs/*.json")):
    try:
        data = json.loads(json_path.read_text())
    except Exception as exc:
        errors.append(f"{rel(json_path)}: invalid JSON: {exc}")
        continue

    text = json_path.read_text()
    for pattern in secret_literal_patterns:
        if pattern.search(text):
            errors.append(f"{rel(json_path)}: contains secret-looking placeholder/literal {pattern.pattern!r}")

    if json_path.name.startswith("mcp.") or ("antigravity-cli" in json_path.parts and json_path.name == "mcp_config.template.json"):
        is_opencode = "opencode" in json_path.parts
        is_antigravity = "antigravity-cli" in json_path.parts
        is_zed = "zed" in json_path.parts
        if is_opencode:
            mcp_key = "mcp"
        elif is_zed:
            mcp_key = "context_servers"
        else:
            mcp_key = "mcpServers"
        servers = data.get(mcp_key)
        if not isinstance(servers, dict) or not servers:
            errors.append(f"{rel(json_path)}: missing non-empty {mcp_key} object")
            continue

        expected_user = {"serena", "context7", "brave-search", "firecrawl", "playwright"}

        if is_opencode:
            if "serena" in servers:
                if servers["serena"].get("command") != ["serena", "start-mcp-server", "--context", "ide", "--project-from-cwd"]:
                    errors.append(f"{rel(json_path)}: serena must use serena start-mcp-server --context ide --project-from-cwd")

            if "brave-search" in servers:
                env = servers["brave-search"].get("environment", {})
                if env.get("BRAVE_API_KEY") != "{env:BRAVE_API_KEY}":
                    errors.append(f"{rel(json_path)}: brave-search must use {{env:BRAVE_API_KEY}} placeholder")
                cmd = servers["brave-search"].get("command", [])
                if cmd[:2] != ["pnpm", "dlx"]:
                    errors.append(f"{rel(json_path)}: brave-search must use pnpm dlx")
                if "@brave/brave-search-mcp-server" not in cmd:
                    errors.append(f"{rel(json_path)}: brave-search must use @brave/brave-search-mcp-server")

            if "firecrawl" in servers:
                env = servers["firecrawl"].get("environment", {})
                if env.get("FIRECRAWL_API_KEY") != "{env:FIRECRAWL_API_KEY}":
                    errors.append(f"{rel(json_path)}: firecrawl must use {{env:FIRECRAWL_API_KEY}} placeholder")
                cmd = servers["firecrawl"].get("command", [])
                if cmd[:2] != ["pnpm", "dlx"]:
                    errors.append(f"{rel(json_path)}: firecrawl must use pnpm dlx")
                if "firecrawl-mcp" not in cmd:
                    errors.append(f"{rel(json_path)}: firecrawl must use firecrawl-mcp")

            if "playwright" in servers:
                cmd = servers["playwright"].get("command", [])
                if cmd[:2] != ["pnpm", "dlx"]:
                    errors.append(f"{rel(json_path)}: playwright must use pnpm dlx")
                if "@playwright/mcp@latest" not in cmd:
                    errors.append(f"{rel(json_path)}: playwright must use @playwright/mcp@latest")
                if "--isolated" not in cmd:
                    errors.append(f"{rel(json_path)}: playwright must use --isolated by default")

            if "context7" in servers:
                server = servers["context7"]
                if server.get("type") != "remote" or server.get("url") != "https://mcp.context7.com/mcp":
                    errors.append(f"{rel(json_path)}: context7 must use the official MCP remote endpoint")
                headers = server.get("headers", {})
                if headers.get("CONTEXT7_API_KEY") != "{env:CONTEXT7_API_KEY}":
                    errors.append(f"{rel(json_path)}: context7 must use {{env:CONTEXT7_API_KEY}} header placeholder")

        elif is_antigravity:
            if "brave-search" in servers:
                env = servers["brave-search"].get("env", {})
                if env.get("BRAVE_API_KEY") != "$BRAVE_API_KEY":
                    errors.append(f"{rel(json_path)}: brave-search must use $BRAVE_API_KEY placeholder")
                if servers["brave-search"].get("command") != "pnpm":
                    errors.append(f"{rel(json_path)}: brave-search must use pnpm dlx")
                args = servers["brave-search"].get("args", [])
                if not args or args[0] != "dlx":
                    errors.append(f"{rel(json_path)}: brave-search must use pnpm dlx")
                if "@brave/brave-search-mcp-server" not in args:
                    errors.append(f"{rel(json_path)}: brave-search must use @brave/brave-search-mcp-server")

            if "firecrawl" in servers:
                env = servers["firecrawl"].get("env", {})
                if env.get("FIRECRAWL_API_KEY") != "$FIRECRAWL_API_KEY":
                    errors.append(f"{rel(json_path)}: firecrawl must use $FIRECRAWL_API_KEY placeholder")
                if servers["firecrawl"].get("command") != "pnpm":
                    errors.append(f"{rel(json_path)}: firecrawl must use pnpm dlx")
                firecrawl_args = servers["firecrawl"].get("args", [])
                if not firecrawl_args or firecrawl_args[0] != "dlx":
                    errors.append(f"{rel(json_path)}: firecrawl must use pnpm dlx")
                if "firecrawl-mcp" not in firecrawl_args:
                    errors.append(f"{rel(json_path)}: firecrawl must use firecrawl-mcp")

            if "playwright" in servers:
                if servers["playwright"].get("command") != "pnpm":
                    errors.append(f"{rel(json_path)}: playwright must use pnpm dlx")
                args = servers["playwright"].get("args", [])
                if not args or args[0] != "dlx":
                    errors.append(f"{rel(json_path)}: playwright must use pnpm dlx")
                if "@playwright/mcp@latest" not in args:
                    errors.append(f"{rel(json_path)}: playwright must use @playwright/mcp@latest")
                if "--isolated" not in args:
                    errors.append(f"{rel(json_path)}: playwright must use --isolated by default")

            if "context7" in servers:
                server = servers["context7"]
                if server.get("serverUrl") != "https://mcp.context7.com/mcp" or "httpUrl" in server:
                    errors.append(f"{rel(json_path)}: context7 must use the official MCP serverUrl endpoint")
                headers = server.get("headers", {})
                if headers.get("CONTEXT7_API_KEY") != "$CONTEXT7_API_KEY":
                    errors.append(f"{rel(json_path)}: context7 must use $CONTEXT7_API_KEY header placeholder")

        elif is_zed:
            if "brave-search" in servers:
                env = servers["brave-search"].get("env", {})
                if env.get("BRAVE_API_KEY") != "$BRAVE_API_KEY":
                    errors.append(f"{rel(json_path)}: brave-search must use $BRAVE_API_KEY placeholder")
                if servers["brave-search"].get("command") != "pnpm":
                    errors.append(f"{rel(json_path)}: brave-search must use pnpm dlx")
                args = servers["brave-search"].get("args", [])
                if not args or args[0] != "dlx":
                    errors.append(f"{rel(json_path)}: brave-search must use pnpm dlx")
                if "@brave/brave-search-mcp-server" not in args:
                    errors.append(f"{rel(json_path)}: brave-search must use @brave/brave-search-mcp-server")

            if "firecrawl" in servers:
                env = servers["firecrawl"].get("env", {})
                if env.get("FIRECRAWL_API_KEY") != "$FIRECRAWL_API_KEY":
                    errors.append(f"{rel(json_path)}: firecrawl must use $FIRECRAWL_API_KEY placeholder")
                if servers["firecrawl"].get("command") != "pnpm":
                    errors.append(f"{rel(json_path)}: firecrawl must use pnpm dlx")
                firecrawl_args = servers["firecrawl"].get("args", [])
                if not firecrawl_args or firecrawl_args[0] != "dlx":
                    errors.append(f"{rel(json_path)}: firecrawl must use pnpm dlx")
                if "firecrawl-mcp" not in firecrawl_args:
                    errors.append(f"{rel(json_path)}: firecrawl must use firecrawl-mcp")

            if "playwright" in servers:
                if servers["playwright"].get("command") != "pnpm":
                    errors.append(f"{rel(json_path)}: playwright must use pnpm dlx")
                args = servers["playwright"].get("args", [])
                if not args or args[0] != "dlx":
                    errors.append(f"{rel(json_path)}: playwright must use pnpm dlx")
                if "@playwright/mcp@latest" not in args:
                    errors.append(f"{rel(json_path)}: playwright must use @playwright/mcp@latest")
                if "--isolated" not in args:
                    errors.append(f"{rel(json_path)}: playwright must use --isolated by default")

            if "context7" in servers:
                server = servers["context7"]
                if server.get("url") != "https://mcp.context7.com/mcp":
                    errors.append(f"{rel(json_path)}: context7 must use the official MCP url endpoint")
                if "serverUrl" in server:
                    errors.append(f"{rel(json_path)}: context7 must not use serverUrl")
                headers = server.get("headers", {})
                if headers.get("CONTEXT7_API_KEY") != "$CONTEXT7_API_KEY":
                    errors.append(f"{rel(json_path)}: context7 must use $CONTEXT7_API_KEY header placeholder")

        else:
            if "brave-search" in servers:
                env = servers["brave-search"].get("env", {})
                if env.get("BRAVE_API_KEY") != "${BRAVE_API_KEY}":
                    errors.append(f"{rel(json_path)}: brave-search must use ${{BRAVE_API_KEY}} placeholder")
                if servers["brave-search"].get("command") != "pnpm":
                    errors.append(f"{rel(json_path)}: brave-search must use pnpm dlx")
                args = servers["brave-search"].get("args", [])
                if not args or args[0] != "dlx":
                    errors.append(f"{rel(json_path)}: brave-search must use pnpm dlx")
                if "@brave/brave-search-mcp-server" not in args:
                    errors.append(f"{rel(json_path)}: brave-search must use @brave/brave-search-mcp-server")

            if "firecrawl" in servers:
                env = servers["firecrawl"].get("env", {})
                if env.get("FIRECRAWL_API_KEY") != "${FIRECRAWL_API_KEY}":
                    errors.append(f"{rel(json_path)}: firecrawl must use ${{FIRECRAWL_API_KEY}} placeholder")
                if servers["firecrawl"].get("command") != "pnpm":
                    errors.append(f"{rel(json_path)}: firecrawl must use pnpm dlx")
                firecrawl_args = servers["firecrawl"].get("args", [])
                if not firecrawl_args or firecrawl_args[0] != "dlx":
                    errors.append(f"{rel(json_path)}: firecrawl must use pnpm dlx")
                if "firecrawl-mcp" not in firecrawl_args:
                    errors.append(f"{rel(json_path)}: firecrawl must use firecrawl-mcp")

            if "playwright" in servers:
                if servers["playwright"].get("command") != "pnpm":
                    errors.append(f"{rel(json_path)}: playwright must use pnpm dlx")
                args = servers["playwright"].get("args", [])
                if not args or args[0] != "dlx":
                    errors.append(f"{rel(json_path)}: playwright must use pnpm dlx")
                if "@playwright/mcp@latest" not in args:
                    errors.append(f"{rel(json_path)}: playwright must use @playwright/mcp@latest")
                if "--isolated" not in args:
                    errors.append(f"{rel(json_path)}: playwright must use --isolated by default")

            if "context7" in servers:
                server = servers["context7"]
                if server.get("type") != "http" or server.get("url") != "https://mcp.context7.com/mcp":
                    errors.append(f"{rel(json_path)}: context7 must use the official MCP HTTP endpoint")
                headers = server.get("headers", {})
                if headers.get("CONTEXT7_API_KEY") != "${CONTEXT7_API_KEY:-}":
                    errors.append(f"{rel(json_path)}: context7 must use ${{CONTEXT7_API_KEY:-}} optional header placeholder")

        if json_path.name == "mcp.user.template.json" or (is_antigravity and json_path.name == "mcp_config.template.json") or is_zed:
            actual_user = set(servers)
            if actual_user != expected_user:
                errors.append(f"{rel(json_path)}: user MCP template must contain all default global servers {sorted(expected_user)}, found {sorted(actual_user)}")

if not validate_runner_path.exists():
    errors.append("tooling/validate/run.sh: missing shared validation runner")
else:
    validate_wrapper = read_text(validate_wrapper_path)
    if "tooling/validate/run.sh" not in validate_wrapper:
        errors.append("scripts/validate-skills.sh: must delegate to tooling/validate/run.sh")
    if validate_wrapper_path.stat().st_mode & 0o111 == 0:
        errors.append("scripts/validate-skills.sh: wrapper must be executable")

if not smoke_runner_path.exists():
    errors.append("tests/smoke/install.sh: missing shared smoke runner")
else:
    smoke_wrapper = read_text(smoke_wrapper_path)
    if "tests/smoke/install.sh" not in smoke_wrapper:
        errors.append("scripts/smoke-install.sh: must delegate to tests/smoke/install.sh")
    if smoke_wrapper_path.stat().st_mode & 0o111 == 0:
        errors.append("scripts/smoke-install.sh: wrapper must be executable")

if not smoke_lib_path.exists():
    errors.append("tests/smoke/lib.sh: missing shared smoke helpers")

for scaffold_path in [
    runtime_template_root / "README.md",
    runtime_template_root / "configs" / "README.md",
    runtime_template_root / "scripts" / "install.sh",
    runtime_template_root / "scripts" / "validate.sh",
    runtime_template_root / "tests" / "smoke.sh",
]:
    if not scaffold_path.exists():
        errors.append(f"{rel(scaffold_path)}: missing runtime scaffold asset")

runtime_template_readme = read_text(runtime_template_root / "README.md")
for forbidden_wrapper in ["bash scripts/validate-skills.sh", "bash scripts/smoke-install.sh"]:
    if forbidden_wrapper in runtime_template_readme:
        errors.append(f"{rel(runtime_template_root / 'README.md')}: wrapper usage should rely on executable entrypoints, not {forbidden_wrapper!r}")

for forbidden in ["--install-project-mcp", "--replace-project-mcp", "--mcp-profile", "--with-playwright", ".mcp.json"]:
    if forbidden in readme:
        errors.append(f"README.md: should not document per-project/options installer path {forbidden!r}")

for forbidden in ["--install-project-mcp", "--replace-project-mcp", "--mcp-profile", "--with-playwright", "PROJECT_MCP_DST", "mcpProfile"]:
    if forbidden in install_sh:
        errors.append(f"install.sh: should not expose per-project/options installer path {forbidden!r}")

_known_non_skill_b_names = {"b-agentic", "b-debug-probe"}
_skill_name_ref_re = re.compile(r'`(b-[a-z][a-z0-9-]+)`|\*\*(b-[a-z][a-z0-9-]+)\*\*')
_skill_ref_scan_paths = [
    *sorted((ROOT / "references" / "contract").glob("*.md")),
    *sorted((ROOT / "skills").glob("*/prompt.md")),
    *sorted((ROOT / "skills").glob("*/SKILL.md")),
    ROOT / "README.md",
]
_registry_skill_names = set(registry_skill_map)
for _scan_path in _skill_ref_scan_paths:
    if not _scan_path.exists():
        continue
    _scan_text = _scan_path.read_text()
    for _m in _skill_name_ref_re.finditer(_scan_text):
        _name = _m.group(1) or _m.group(2)
        if _name in _registry_skill_names or _name in _known_non_skill_b_names:
            continue
        errors.append(f"{rel(_scan_path)}: references unresolved skill name {_name!r} (not in skills/registry.yaml)")

_rr_gate_re = re.compile(r'\{\{runtime_reference_root\}\}/contract/([a-z0-9-]+\.md)')
_sp_gate_re = re.compile(r'\{\{skill_support_path\}\}/([a-zA-Z0-9_.-]+)')
for _prompt_path in sorted((ROOT / "skills").glob("*/prompt.md")):
    _prompt_text = _prompt_path.read_text()
    _skill_dir = _prompt_path.parent
    for _m in _rr_gate_re.finditer(_prompt_text):
        _target = ROOT / "references" / "contract" / _m.group(1)
        if not _target.exists():
            errors.append(f"{rel(_prompt_path)}: read gate references non-existent contract file references/contract/{_m.group(1)}")
    for _m in _sp_gate_re.finditer(_prompt_text):
        _target = _skill_dir / _m.group(1)
        if not _target.exists():
            errors.append(f"{rel(_prompt_path)}: read gate references non-existent skill support file {rel(_target)}")

# Examples removed in slim-down refactor; no examples checks needed

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print(f"Shared skill validation passed ({len(skill_paths)} skills).")
