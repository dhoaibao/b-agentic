#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import subprocess
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


def changed_by_generator() -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


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

if list((ROOT / "skills").glob("*/reference.md")):
    errors.append("skills/: skill-local reference.md files were removed from the slim product")

contract_dir = ROOT / "references" / "contract"
expected_contracts = {"runtime.md", "safety-tools.md", "output.md", "kernel.template.md"}
actual_contracts = {path.name for path in contract_dir.glob("*.md")}
if actual_contracts != expected_contracts:
    errors.append(
        f"references/contract/: expected {sorted(expected_contracts)}, found {sorted(actual_contracts)}"
    )

for path in [ROOT / "references" / "contract" / "kernel.template.md", *(ROOT / "runtimes" / name / "kernel.md" for name in runtime_names)]:
    text = read_text(path)
    for required in ["Core Rules", "Routing", "safety-tools.md", "output.md"]:
        if required not in text:
            errors.append(f"{rel(path)}: missing kernel marker {required!r}")
    for forbidden in ["state-machine.md", "decisions.md", "index.md", "Strict governance", "Advisory-only runtime"]:
        if forbidden in text:
            errors.append(f"{rel(path)}: removed kernel concept remains: {forbidden!r}")

readme = read_text(ROOT / "README.md")
for forbidden in ["hooks", "subagent", "strict", "state-machine", "conformance"]:
    if re.search(rf"\b{re.escape(forbidden)}\b", readme, re.IGNORECASE):
        errors.append(f"README.md: removed product concept remains: {forbidden!r}")

claude_settings = read_text(ROOT / "runtimes" / "claude-code" / "configs" / "settings.template.json")
for forbidden in ["firecrawl_monitor", "hooks", "statusLine", "check-runtime.py"]:
    if forbidden in claude_settings:
        errors.append(f"runtimes/claude-code/configs/settings.template.json: forbidden default permission/config {forbidden!r}")

for deleted_path in ["tooling/state", "tooling/hooks", "tooling/conformance", "tooling/scenarios"]:
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
    *(ROOT / "runtimes" / "opencode" / "commands" / f"{name}.md" for name in skill_names if name != "b-ship" or True),
]
for path in generated_paths:
    if path.exists() and "{{" in path.read_text():
        errors.append(f"{rel(path)}: unresolved template token")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print(f"Shared skill validation passed ({len(skill_names)} skills).")
