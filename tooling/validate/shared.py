#!/usr/bin/env python3

from pathlib import Path
import json
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
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

    if "handoff envelope" in text.lower() or "[handoff]" in text:
        if "contract/09-output" not in text:
            errors.append(f"{rel(path)}: emits handoff envelope but missing contract/09-output reference")

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

    if "references/b-agentic/contract/" in text and "${CLAUDE_SKILL_DIR}/references/b-agentic/contract/" not in text:
        errors.append(f"{rel(path)}: contract read gates must use ${{CLAUDE_SKILL_DIR}} support path")

    if "performance-checklist.md" in text and "${CLAUDE_SKILL_DIR}/references/b-agentic/performance-checklist.md" not in text:
        errors.append(f"{rel(path)}: performance checklist read gates must use ${{CLAUDE_SKILL_DIR}} support path")

    if "Read `reference.md` before" in text or re.search(r"Read\s+`?reference\.md`?", text):
        errors.append(f"{rel(path)}: local reference.md read gates must use ${{CLAUDE_SKILL_DIR}}/reference.md")

    if re.search(r"Read §\d+", text):
        errors.append(f"{rel(path)}: read gates must name the reference file, not only a section number")

    if "Graceful degradation:" in text:
        errors.append(f"{rel(path)}: graceful degradation rules are centralized in the kernel; skills must not restate them")

    skill_reference = path.parent / "reference.md"
    if skill_reference.exists() and "reference.md" not in text:
        errors.append(f"{rel(path)}: existing reference.md is not discoverable from SKILL.md")

routing_path = ROOT / "references" / "contract" / "01-routing.md"
if not routing_path.exists():
    errors.append("references/contract/01-routing.md: missing contract routing source")
else:
    routing_text = routing_path.read_text()
    referenced_skills = set(re.findall(r"`/(b-[a-z][a-z0-9-]*)`", routing_text))
    skill_dirs = set(skill_names)
    for name in sorted(referenced_skills - skill_dirs):
        errors.append(f"references/contract/01-routing.md: references /{name} but no skills/{name}/ directory exists")

readme = read_text(ROOT / "README.md")
maintainer = read_text(ROOT / "CLAUDE.md")
tool_model_path = ROOT / "references" / "contract" / "04-tool-model.md"
tool_model_text = read_text(tool_model_path)
shared_contract_paths = [
    ROOT / "references" / "contract" / "00-kernel.md",
    tool_model_path,
    ROOT / "references" / "contract" / "05-evidence.md",
    ROOT / "references" / "contract" / "06-safety.md",
    ROOT / "references" / "contract" / "07-execution.md",
    ROOT / "references" / "contract" / "08-artifacts.md",
    ROOT / "references" / "contract" / "10-decisions.md",
]
kernel_path = ROOT / "runtimes" / "claude-code" / "kernel.md"
kernel = read_text(kernel_path)
contract_index_path = ROOT / "references" / "contract" / "index.md"
contract_index = read_text(contract_index_path)
install_sh = read_text(ROOT / "install.sh")
registry_sync = ROOT / "tooling" / "generate" / "registry_sync.py"
validate_wrapper_path = ROOT / "scripts" / "validate-skills.sh"
validate_runner_path = ROOT / "tooling" / "validate" / "run.sh"
smoke_wrapper_path = ROOT / "scripts" / "smoke-install.sh"
smoke_runner_path = ROOT / "tests" / "smoke" / "install.sh"
smoke_lib_path = ROOT / "tests" / "smoke" / "lib.sh"
runtime_template_root = ROOT / "runtimes" / "runtime-template"

contract_version_match = re.search(r"This runtime contract version is `([0-9]{4}-[0-9]{2}-[0-9]{2})`", kernel)
contract_version = contract_version_match.group(1) if contract_version_match else None

if not kernel_path.exists():
    errors.append("runtimes/claude-code/kernel.md: missing Claude Code kernel source")

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

if not readme:
    errors.append("README.md: missing or empty")
else:
    for name in skill_names:
        if name not in readme:
            errors.append(f"README.md: missing skill name {name}")
    for required in ["tooling/validate/", "tests/smoke/", "runtimes/runtime-template/"]:
        if required not in readme:
            errors.append(f"README.md: missing phase-4 architecture path {required!r}")

for required in ["tooling/validate/", "tests/smoke/", "runtimes/runtime-template/"]:
    if required not in maintainer:
        errors.append(f"CLAUDE.md: missing phase-4 maintainer path {required!r}")

root_markdown_docs = tracked_existing_root_markdown_docs()
allowed_root_markdown_docs = {"README.md", "CLAUDE.md"}
unexpected_root_docs = sorted(root_markdown_docs - allowed_root_markdown_docs)
if unexpected_root_docs:
    errors.append(
        "root docs: unexpected top-level Markdown docs "
        f"{unexpected_root_docs}; keep root docs targeted and move skill detail or support material under skills/, references/, or runtimes/"
    )

if "One Command" not in readme or "skillsSynced" not in readme:
    errors.append("README.md: missing one-command install/output documentation")

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
    "mcpReadiness:",
    "serena: install/init separately; installer never runs onboarding",
    "gitnexus: install/index separately if you want graph radar",
    "api-keys: Context7, Brave Search, and Firecrawl need user-scope keys",
]
runtime_readiness_doc_lines = [
    "## MCP readiness after install",
    "`playwright` is immediately available once Bun is on `PATH`; no extra suite-owned setup runs.",
    "`serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.",
    "`gitnexus` entry is installed, but graph radar depends on the user having GitNexus installed and running their own indexing/analyze flow. The installer never runs GitNexus setup or indexing.",
]
for runtime_name, api_key_line in [
    ("claude-code", "`context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.claude.json`."),
    ("opencode", "`context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.config/opencode/opencode.json`."),
]:
    install_path = ROOT / "runtimes" / runtime_name / "scripts" / "install.sh"
    readme_path = ROOT / "runtimes" / runtime_name / "configs" / "README.md"
    require_contains(install_path, read_text(install_path), runtime_readiness_install_lines, "runtime readiness install line")
    require_contains(readme_path, read_text(readme_path), runtime_readiness_doc_lines + [api_key_line], "runtime readiness doc line")

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

if contract_version:
    for plan_path in sorted((ROOT / ".b-agentic" / "b-plan").glob("*.md")):
        plan_text = plan_path.read_text()
        plan_version_match = re.search(r"^contract_version:\s*(\S+)", plan_text, re.MULTILINE)
        if plan_version_match:
            plan_version = plan_version_match.group(1)
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

    if json_path.name.startswith("mcp."):
        is_opencode = "opencode" in json_path.parts
        mcp_key = "mcp" if is_opencode else "mcpServers"
        servers = data.get(mcp_key)
        if not isinstance(servers, dict) or not servers:
            errors.append(f"{rel(json_path)}: missing non-empty {mcp_key} object")
            continue

        expected_user = {"serena", "context7", "brave-search", "firecrawl", "playwright", "gitnexus"}

        if is_opencode:
            if "serena" in servers:
                if servers["serena"].get("command") != ["serena", "start-mcp-server", "--context", "ide", "--project-from-cwd"]:
                    errors.append(f"{rel(json_path)}: serena must use serena start-mcp-server --context ide --project-from-cwd")

            if "brave-search" in servers:
                env = servers["brave-search"].get("environment", {})
                if env.get("BRAVE_API_KEY") != "{env:BRAVE_API_KEY}":
                    errors.append(f"{rel(json_path)}: brave-search must use {{env:BRAVE_API_KEY}} placeholder")
                cmd = servers["brave-search"].get("command", [])
                if not cmd or cmd[0] != "bunx":
                    errors.append(f"{rel(json_path)}: brave-search must use bunx")
                if "@brave/brave-search-mcp-server" not in cmd:
                    errors.append(f"{rel(json_path)}: brave-search must use @brave/brave-search-mcp-server")

            if "firecrawl" in servers:
                env = servers["firecrawl"].get("environment", {})
                if env.get("FIRECRAWL_API_KEY") != "{env:FIRECRAWL_API_KEY}":
                    errors.append(f"{rel(json_path)}: firecrawl must use {{env:FIRECRAWL_API_KEY}} placeholder")
                cmd = servers["firecrawl"].get("command", [])
                if not cmd or cmd[0] != "bunx":
                    errors.append(f"{rel(json_path)}: firecrawl must use bunx")
                if "firecrawl-mcp" not in cmd:
                    errors.append(f"{rel(json_path)}: firecrawl must use firecrawl-mcp")

            if "playwright" in servers:
                cmd = servers["playwright"].get("command", [])
                if not cmd or cmd[0] != "bunx":
                    errors.append(f"{rel(json_path)}: playwright must use bunx")
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

            if "gitnexus" in servers and json_path.name != "mcp.user.template.json":
                errors.append(f"{rel(json_path)}: gitnexus belongs only in the global user config")
            if "gitnexus" in servers:
                if servers["gitnexus"].get("command") != ["gitnexus", "mcp"]:
                    errors.append(f"{rel(json_path)}: gitnexus must use installed gitnexus mcp command")

        else:
            if "brave-search" in servers:
                env = servers["brave-search"].get("env", {})
                if env.get("BRAVE_API_KEY") != "${BRAVE_API_KEY}":
                    errors.append(f"{rel(json_path)}: brave-search must use ${{BRAVE_API_KEY}} placeholder")
                if servers["brave-search"].get("command") != "bunx":
                    errors.append(f"{rel(json_path)}: brave-search must use bunx")
                args = servers["brave-search"].get("args", [])
                if "@brave/brave-search-mcp-server" not in args:
                    errors.append(f"{rel(json_path)}: brave-search must use @brave/brave-search-mcp-server")

            if "firecrawl" in servers:
                env = servers["firecrawl"].get("env", {})
                if env.get("FIRECRAWL_API_KEY") != "${FIRECRAWL_API_KEY}":
                    errors.append(f"{rel(json_path)}: firecrawl must use ${{FIRECRAWL_API_KEY}} placeholder")
                if servers["firecrawl"].get("command") != "bunx":
                    errors.append(f"{rel(json_path)}: firecrawl must use bunx")
                if "firecrawl-mcp" not in servers["firecrawl"].get("args", []):
                    errors.append(f"{rel(json_path)}: firecrawl must use firecrawl-mcp")

            if "playwright" in servers:
                if servers["playwright"].get("command") != "bunx":
                    errors.append(f"{rel(json_path)}: playwright must use bunx")
                args = servers["playwright"].get("args", [])
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

            if "gitnexus" in servers and json_path.name != "mcp.user.template.json":
                errors.append(f"{rel(json_path)}: gitnexus belongs only in the global user config")
            if "gitnexus" in servers:
                gitnexus = servers["gitnexus"]
                if gitnexus.get("command") != "gitnexus" or gitnexus.get("args") != ["mcp"]:
                    errors.append(f"{rel(json_path)}: gitnexus must use installed gitnexus mcp command")

        if json_path.name == "mcp.user.template.json":
            actual_user = set(servers)
            if actual_user != expected_user:
                errors.append(f"{rel(json_path)}: user MCP template must contain all default global servers {sorted(expected_user)}, found {sorted(actual_user)}")

if not validate_runner_path.exists():
    errors.append("tooling/validate/run.sh: missing shared validation runner")
else:
    validate_wrapper = read_text(validate_wrapper_path)
    if "tooling/validate/run.sh" not in validate_wrapper:
        errors.append("scripts/validate-skills.sh: must delegate to tooling/validate/run.sh")

if not smoke_runner_path.exists():
    errors.append("tests/smoke/install.sh: missing shared smoke runner")
else:
    smoke_wrapper = read_text(smoke_wrapper_path)
    if "tests/smoke/install.sh" not in smoke_wrapper:
        errors.append("scripts/smoke-install.sh: must delegate to tests/smoke/install.sh")

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

for forbidden in ["--install-project-mcp", "--replace-project-mcp", "--mcp-profile", "--with-playwright", "--with-gitnexus", ".mcp.json"]:
    if forbidden in readme:
        errors.append(f"README.md: should not document per-project/options installer path {forbidden!r}")

for forbidden in ["--install-project-mcp", "--replace-project-mcp", "--mcp-profile", "--with-playwright", "--with-gitnexus", "PROJECT_MCP_DST", "mcpProfile"]:
    if forbidden in install_sh:
        errors.append(f"install.sh: should not expose per-project/options installer path {forbidden!r}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print(f"Shared skill validation passed ({len(skill_paths)} skills).")
