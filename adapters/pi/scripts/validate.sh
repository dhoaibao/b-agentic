#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

bash -n "$ROOT_DIR/adapters/pi/scripts/install-preview-markdown.sh"
bash -n "$ROOT_DIR/adapters/pi/scripts/typecheck.sh"
bash -n "$ROOT_DIR/adapters/pi/scripts/typecheck-preview-markdown.sh"

python3 - <<'PY'
from pathlib import Path
import json
import re
import sys

root = Path('.')
errors = []
kernel = root / 'references/kernel.template.md'
mcp = root / 'adapters/pi/configs/mcp.user.template.json'
capabilities = root / 'references/capabilities.yaml'
capabilities_module = root / 'adapters/pi/extensions/b-agentic-support/capabilities.ts'
extension = root / 'adapters/pi/extensions/b-agentic-permissions.ts'
rule_guard_source = root / 'adapters/pi/extensions/b-agentic-rule-guard.ts'
consult_source = root / 'adapters/pi/extensions/b-agentic-consult.ts'
consult_support_source = root / 'adapters/pi/extensions/b-agentic-support/consult.ts'
status_extension = root / 'adapters/pi/extensions/b-agentic-status.ts'
preview_extension = root / 'adapters/pi/packages/preview-markdown/extensions/b-agentic-preview-markdown.ts'
preview_package = root / 'adapters/pi/packages/preview-markdown/package.json'
public_readme = root / 'README.md'
preview_tag_sections = [
    (
        root / 'REFERENCE.md',
        'After the public immutable',
        'After the package is published',
    ),
    (
        root / 'adapters/pi/packages/preview-markdown/README.md',
        'For a version-pinned GitHub install',
        '## Scope',
    ),
]
extension_files = [
    extension,
    preview_extension,
    root / 'adapters/pi/extensions/b-agentic-mcp-permissions.ts',
    root / 'adapters/pi/extensions/b-agentic-auto-mode.ts',
    root / 'adapters/pi/extensions/b-agentic-sync.ts',
    root / 'adapters/pi/extensions/b-agentic-support/shell.ts',
    root / 'adapters/pi/extensions/b-agentic-support/mcp.ts',
    root / 'adapters/pi/extensions/b-agentic-support/worker.ts',
    root / 'adapters/pi/extensions/b-agentic-support/auto.ts',
    status_extension,
    root / 'adapters/pi/extensions/b-agentic-support/capabilities.ts',
    root / 'adapters/pi/extensions/b-agentic-support/status.ts',
]
config_readme = root / 'adapters/pi/configs/README.md'
standalone_preview_installer = root / 'adapters/pi/scripts/install-preview-markdown.sh'

for path in [kernel, mcp, capabilities, capabilities_module, *extension_files, config_readme, standalone_preview_installer, preview_package]:
    if not path.exists():
        errors.append(f'{path}: missing')

if kernel.exists():
    text = kernel.read_text()
    for marker in [
        'Workflow Kernel',
        'ask_user_question', '2–4 concrete options', 'automatic custom-answer row',
        '`references/capabilities.yaml` is canonical',
        'never parse MCP configuration or inspect credential/API-key values',
    ]:
        if marker not in text:
            errors.append(f'{kernel}: missing {marker!r}')

if rule_guard_source.exists():
    errors.append(f'{rule_guard_source}: retired managed rule-guard source must be absent')
if consult_source.exists():
    errors.append(f'{consult_source}: retired managed consult source must be absent')
if consult_support_source.exists():
    errors.append(f'{consult_support_source}: retired managed consult support source must be absent')

if capabilities.exists():
    capabilities_text = capabilities.read_text()
    if 'b-agentic-rule-guard' in capabilities_text:
        errors.append(f'{capabilities}: retired managed rule-guard capability must be absent')
    contract = json.loads(capabilities_text)
    contract_entries = contract.get('capabilities', [])
    if contract.get('schema_version') != 2 or not isinstance(contract_entries, list) or not contract_entries:
        errors.append(f'{capabilities}: must contain schema_version 1 and a non-empty capabilities array')
    if len({entry.get('id') for entry in contract_entries if isinstance(entry, dict)}) != len(contract_entries):
        errors.append(f'{capabilities}: capability ids must be unique')
    if any(name in capabilities_text for name in ['pi-lens', 'pi-subagents', 'background-task', 'pi-lsp', '@narumitw/pi-lsp', 'piLspAction', 'piLspState', 'b-agentic-consult']):
        errors.append(f'{capabilities}: retired or forbidden packages/integrations must not be managed')
if capabilities_module.exists():
    text = capabilities_module.read_text()
    if 'b-agentic-rule-guard' in text:
        errors.append(f'{capabilities_module}: retired managed rule-guard capability must be absent')
    for marker in ['Generated from references/capabilities.yaml', 'CAPABILITY_CONTRACT_VERSION', 'CAPABILITIES', 'package.pi-mcp-adapter', 'mcp.playwright', 'extension.b-agentic-status']:
        if marker not in text:
            errors.append(f'{capabilities_module}: missing generated capability marker {marker!r}')
installer = root / 'adapters/pi/scripts/install.sh'
if installer.exists():
    installer_text = installer.read_text()
    installer_match = re.search(r'EXTENSION_NAMES=\(\n(.*?)\n\)', installer_text, re.DOTALL)
    if installer_match:
        for retired_name in ['b-agentic-rule-guard.ts', 'b-agentic-consult.ts', 'b-agentic-support/consult.ts']:
            if retired_name in installer_match.group(1):
                errors.append(f'{installer}: retired managed extension {retired_name} must not remain in EXTENSION_NAMES')
if status_extension.exists():
    text = status_extension.read_text()
    for marker in ['registerCommand("b-status"', 'buildCapabilitySnapshot', 'read-only local capability', 'no MCP/auth/browser probes', 'pi.exec("pi", ["list"]']:
        if marker not in text:
            errors.append(f'{status_extension}: missing status marker {marker!r}')
    if 'writeFile' in text or 'appendEntry' in text:
        errors.append(f'{status_extension}: status snapshot must not persist session content')
status_support = root / 'adapters/pi/extensions/b-agentic-support/status.ts'
if status_support.exists():
    text = status_support.read_text()
    for marker in ['mcpConfigPresent', 'MCP configuration contents and credential/key readiness are intentionally unverified']:
        if marker not in text:
            errors.append(f'{status_support}: missing privacy/readiness marker {marker!r}')
    for forbidden in ['readFileSync', 'readLocalJsonConfig', 'hasConfiguredValue', 'process.env[']:
        if forbidden in text:
            errors.append(f'{status_support}: status snapshot must not inspect MCP content or credential environment values ({forbidden!r})')

if mcp.exists():
    data = json.loads(mcp.read_text())
    servers = data.get('mcpServers', {})
    for server in ['context7', 'codegraph', 'brave-search', 'firecrawl', 'playwright']:
        if server not in servers:
            errors.append(f'{mcp}: missing MCP server {server!r}')
        elif servers[server].get('lifecycle') != 'lazy':
            errors.append(f'{mcp}: {server} must use lifecycle lazy by default')
    settings = data.get('settings', {})
    if settings.get('directTools') not in (False, None):
        errors.append(f'{mcp}: default directTools must be false (proxy tool default)')
    if settings.get('requestTimeoutMs') != 30000:
        errors.append(f'{mcp}: default requestTimeoutMs must be 30000 milliseconds')

if extension.exists():
    text = '\n'.join(path.read_text() for path in extension_files if path.exists())
    if preview_extension.exists():
        preview_text = preview_extension.read_text()
        for marker in [
            'preview_markdown', 'promptSnippet', 'promptGuidelines', 'ctx.mode', 'renderResult',
            'registerShortcut', 'ctrl+shift+m', 'copyToClipboard',
            'PALETTE', '#1e2030', '#222436', '#191b29', '#2f334d', '#c8d3f5', '#828bb8', '#636da6',
            '#3b4261', '#82aaff', '#86e1fc', '#ffc777', '#c3e88d', '#c099ff', '#65bcff',
            '#d5d6db', '#e1e2e7', '#c4c8da', '#dcdfe4', '#3760bf', '#6172b0', '#848cb5',
            '#8990b3', '#2e7de9', '#007197', '#8c6c3e', '#587539', '#9854f1',
            'getAgentDir', 'preview-markdown:render', 'preview-markdown:theme', 'preview-markdown:list', 'MAX_PREVIEW_HISTORY', 'currentPreviewTheme', 'previewRowInvalidators', 'clearPreviewRowInvalidators', 'loadCurrentPreviewTheme', 'session_shutdown', 'Tokyo Night Day', 'preview-theme.json',
            'FIXED_PAGE_BACKGROUND',
            'FIXED_CARD_BACKGROUND', 'PreviewCard', 'Ctrl+Shift+M  Copy source', 'Markdown preview rendered inline',
        ]:
            if marker not in preview_text:
                errors.append(f'{preview_extension}: missing preview marker {marker!r}')
    for marker in [
        'tool_call', 'ask_user_question', 'isAutoApprovedIntercomCall',
        'isDirectClassifiedManagedTool', 'CODEGRAPH_TRUSTED_TOOLS', 'mcpScript',
    ]:
        if marker not in text:
            errors.append(f'{extension}: missing policy marker {marker!r}')
    if 'return { block: true' not in text and 'block: true' not in text:
        errors.append(f'{extension}: must be able to block tool calls')
    if 'custom/MCP tool' not in text and 'MCP' not in text:
        errors.append(f'{extension}: must gate MCP/custom tools')
    for server in ['codegraph', 'context7', 'brave-search', 'firecrawl', 'playwright']:
        if f'"{server}"' not in text:
            errors.append(f'{extension}: missing managed MCP server {server!r}')
    firecrawl_trusted = re.search(r'FIRECRAWL_TRUSTED_TOOLS = new Set\(\[(.*?)\]\)', text, re.DOTALL)
    if firecrawl_trusted:
        # Exact quoted ids only so firecrawl_agent_status / firecrawl_interact_stop remain allowed.
        for forbidden in [
            '"firecrawl_interact"',
            '"firecrawl_parse"',
            '"firecrawl_search_feedback"',
            '"firecrawl_feedback"',
            '"firecrawl_agent"',
            '"firecrawl_crawl"',
        ]:
            if forbidden in firecrawl_trusted.group(1):
                errors.append(f'{extension}: {forbidden} must not be in FIRECRAWL_TRUSTED_TOOLS')
    playwright_trusted = re.search(r'PLAYWRIGHT_TRUSTED_TOOLS = new Set\(\[(.*?)\]\)', text, re.DOTALL)
    if playwright_trusted and re.search(r'"browser_click"', playwright_trusted.group(1)):
        errors.append(f'{extension}: browser_click must not be in PLAYWRIGHT_TRUSTED_TOOLS')
    if 'isTrustedManagedGatewayCall' not in text or 'isMcpProxyToolExecution' not in text or 'isTrustedPreviewMarkdownCall' not in text or 'if (toolName === "mcp") return !isMcpProxyToolExecution(input);' not in text:
        errors.append(f'{extension}: must route only explicit MCP proxy executions through the adapter broker')
    if any(marker in text for marker in ['LSP_DIAGNOSTICS_FIELDS', 'isTrustedLspPath', 'isTrustedLspDiagnosticsCall']):
        errors.append(f'{extension}: retired LSP-specific trust paths must be absent')
    if 'Blocked' not in text or 'protected path' not in text:
        errors.append(f'{extension}: must block protected paths')
    # read must share protected-path handling with write/edit
    if 'event.toolName === "read"' not in text and 'toolName === "read"' not in text:
        # Accept combined write/edit/read branch
        if not re.search(r'toolName === "write".*toolName === "edit".*toolName === "read"', text, re.DOTALL):
            if 'read' not in text or 'isProtectedPath' not in text:
                errors.append(f'{extension}: must apply protected-path policy to read')

if standalone_preview_installer.exists():
    text = standalone_preview_installer.read_text()
    for marker in [
        'dhoaibao/b-agentic', 'VERSION', 'invalid version',
        'adapters/pi/packages/preview-markdown/extensions/b-agentic-preview-markdown.ts',
        'PI_CODING_AGENT_DIR', 'registerShortcut("ctrl+shift+m"',
        'name: "preview_markdown"', 'export default function',
        'Run /reload', 'AGENTS.md',
    ]:
        if marker not in text:
            errors.append(f'{standalone_preview_installer}: missing installer marker {marker!r}')

if preview_package.exists():
    manifest = json.loads(preview_package.read_text())
    package_version = manifest.get('version')
    version_pattern = r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'
    if not isinstance(package_version, str) or not re.fullmatch(version_pattern, package_version):
        errors.append(f'{preview_package}: version must be a numeric semver string')
    else:
        expected_tag = f'v{package_version}'
        tag_pattern = re.compile(r'\bv' + version_pattern + r'\b')
        command_pattern = re.compile(
            r'https://raw\.githubusercontent\.com/dhoaibao/b-agentic/'
            r'(v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))'
            r'/adapters/pi/scripts/install-preview-markdown\.sh\s*\|\s*bash\s+-s\s+--\s+'
            r'(v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))'
        )
        for doc, start_marker, end_marker in preview_tag_sections:
            if not doc.exists():
                errors.append(f'{doc}: missing preview install documentation')
                continue
            text = doc.read_text()
            start = text.find(start_marker)
            end = text.find(end_marker, start + len(start_marker)) if start >= 0 else -1
            if start < 0 or end < 0:
                errors.append(f'{doc}: cannot locate the bounded preview tag section')
                continue
            section = text[start:end]
            tags = tag_pattern.findall(section)
            if not tags:
                errors.append(f'{doc}: missing documented preview release tag')
            mismatches = sorted({tag for tag in tags if tag != expected_tag})
            if mismatches:
                errors.append(
                    f'{doc}: documented preview tag(s) {", ".join(mismatches)} '
                    f'do not match package version {package_version!r}; expected {expected_tag}'
                )
            commands = command_pattern.findall(section)
            if not commands:
                errors.append(f'{doc}: missing preview bootstrap URL and trailing installer argument')
            for url_tag, argument_tag in commands:
                if url_tag != expected_tag or argument_tag != expected_tag or url_tag != argument_tag:
                    errors.append(
                        f'{doc}: preview bootstrap tag {url_tag} and installer argument {argument_tag} '
                        f'must both match package version {package_version!r} (expected {expected_tag})'
                    )

if public_readme.exists():
    text = public_readme.read_text()
    for marker in [
        '[Read the operational reference](REFERENCE.md)',
        'the standalone\nMarkdown preview install',
        'preview package route',
        '[package-facing guide](adapters/pi/packages/preview-markdown/README.md)',
    ]:
        if marker not in text:
            errors.append(f'{public_readme}: missing public-entrypoint marker {marker!r}')

if config_readme.exists():
    text = config_readme.read_text()
    for marker in [
        '# Pi Configuration Layout',
        '## Install Layout',
        '`~/.pi/agent/AGENTS.md`',
        '`~/.pi/agent/skills/<skill-name>/SKILL.md`',
        '`~/.pi/agent/mcp.json`',
        '`~/.pi/agent/extensions/`',
        '`~/.pi/agent/b-agentic/`',
        'ownership boundary',
        '[operational reference](../../REFERENCE.md)',
    ]:
        if marker not in text:
            errors.append(f'{config_readme}: missing layout/boundary marker {marker!r}')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Pi integration validation passed.')
PY
