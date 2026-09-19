# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "error: this script is sourced by tests/smoke/install.sh" >&2
	exit 1
fi

run_pi_permission_behavioral_fixture() {
	local sandbox="$1"
	# Behavioral permission coverage via node --experimental-strip-types (no Pi runtime).
	# Prefer the repository's pinned Pi dependency for resolver-contract assertions.
	local pi_package_root="$ROOT_DIR/pi/node_modules/@earendil-works/pi-coding-agent"
	local pi_package_source="repo-local pinned dependency"
	if [ ! -f "$pi_package_root/package.json" ]; then
		pi_package_root=""
		pi_package_source="global Pi fallback"
	fi
	if [ -z "$pi_package_root" ] && command -v pi >/dev/null 2>&1; then
		local pi_path
		pi_path="$(command -v pi)"
		# Resolve the CLI symlink and walk to the package manifest instead of
		# assuming a fixed dist/ layout or relying on GNU readlink -f.
		pi_package_root="$(node --input-type=module -e '
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";

let directory = dirname(realpathSync(process.argv[1]));
while (true) {
  const packagePath = join(directory, "package.json");
  if (existsSync(packagePath)) {
    try {
      if (JSON.parse(readFileSync(packagePath, "utf8")).name === "@earendil-works/pi-coding-agent") {
        process.stdout.write(directory);
        break;
      }
    } catch {}
  }
  const parent = dirname(directory);
  if (parent === directory) break;
  directory = parent;
}
' "$pi_path" 2>/dev/null || true)"
	fi
	if [ -z "$pi_package_root" ]; then
		pi_package_source="no Pi package anchor"
	fi

	local pi_server_loader="$sandbox/pi-server-loader.mjs"
	local pi_server_marker="$sandbox/pi-server-shim.marker"
	local pi_server_probe="$sandbox/pi-server-shim-probe.log"
	local pi_server_resolver="$sandbox/pi-server-resolver.mjs"
	local pi_server_fixture="$sandbox/pi-server-resolver-fixture"
	local pi_server_fixture_log="$sandbox/pi-server-resolver-fixture.log"
	local -a node_loader_args=()
	cat >"$pi_server_resolver" <<'RESOLVER'
import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const packageRoot = process.argv[2];
const requireFromPackage = createRequire(pathToFileURL(join(packageRoot, "package.json")));
try {
  requireFromPackage.resolve("@earendil-works/pi-tui");
} catch {
  process.exit(2);
}
for (const specifier of ["@earendil-works/pi-server", "@earendil-works/pi-server/unix"]) {
  try {
    requireFromPackage.resolve(specifier);
  } catch {
    process.exit(1);
  }
}
console.log("pi-server dependencies resolvable");
RESOLVER
	mkdir -p "$pi_server_fixture/node_modules/@earendil-works/pi-server" "$pi_server_fixture/node_modules/@earendil-works/pi-tui"
	printf '{"name":"smoke-pi-anchor"}\n' >"$pi_server_fixture/package.json"
	printf '{"name":"@earendil-works/pi-tui","exports":"./index.js"}\n' >"$pi_server_fixture/node_modules/@earendil-works/pi-tui/package.json"
	printf '{"name":"@earendil-works/pi-server","exports":{".":"./index.js","./unix":"./unix.js"}}\n' >"$pi_server_fixture/node_modules/@earendil-works/pi-server/package.json"
	: >"$pi_server_fixture/node_modules/@earendil-works/pi-tui/index.js"
	: >"$pi_server_fixture/node_modules/@earendil-works/pi-server/index.js"
	: >"$pi_server_fixture/node_modules/@earendil-works/pi-server/unix.js"
	if ! node "$pi_server_resolver" "$pi_server_fixture" >"$pi_server_fixture_log"; then
		fail "pi-server resolver fixture did not recognize valid root and /unix exports"
	fi
	assert_contains "$pi_server_fixture_log" 'pi-server dependencies resolvable'
	assert_no_path "$pi_server_loader"
	assert_no_path "$pi_server_marker"
	assert_no_path "$pi_server_probe"

	local pi_server_resolution_status=0
	if [ -n "$pi_package_root" ]; then
		if node "$pi_server_resolver" "$pi_package_root" >/dev/null; then
			:
		else
			pi_server_resolution_status=$?
		fi
	fi
	if [ "$pi_server_resolution_status" -eq 1 ]; then
		cat >"$pi_server_loader" <<'LOADER'
const shim = `
export class ServerError extends Error {}
export class SessionAmbiguousError extends Error {}
export class SessionNotFoundError extends Error {}
const unavailable = () => { throw new Error("pi-server smoke shim invoked"); };
export const createUnixServer = unavailable;
export const getUnixSocketPath = unavailable;
`;
const shimUrl = `data:text/javascript,${encodeURIComponent(shim)}`;

export async function resolve(specifier, context, defaultResolve) {
  if (specifier === "@earendil-works/pi-server" || specifier === "@earendil-works/pi-server/unix") {
    return { format: "module", shortCircuit: true, url: shimUrl };
  }
  return defaultResolve(specifier, context, defaultResolve);
}
LOADER
		printf 'fallback activated because pi-server resolution failed\n' >"$pi_server_marker"
		node_loader_args=(--experimental-loader="$pi_server_loader")
		if ! node "${node_loader_args[@]}" --input-type=module -e '
const shim = await import("@earendil-works/pi-server");
const unixShim = await import("@earendil-works/pi-server/unix");
for (const [name, module] of [["createUnixServer", shim], ["getUnixSocketPath", unixShim]]) {
  try {
    module[name]();
  } catch (error) {
    if (error instanceof Error && error.message === "pi-server smoke shim invoked") {
      console.error(error.message);
      continue;
    }
    throw error;
  }
  throw new Error(name + " did not throw");
}
' >"$pi_server_probe" 2>&1; then
			fail "pi-server shim exports did not fail closed when invoked"
		fi
	elif [ "$pi_server_resolution_status" -ne 0 ]; then
		fail "unable to resolve Pi package dependency anchor"
	fi
	ROOT_DIR="$ROOT_DIR" PI_TEST_HOME="$sandbox/home" PI_CODING_AGENT_DIR="$sandbox/home/.pi/agent" PI_PACKAGE_ROOT="$pi_package_root" PI_PACKAGE_SOURCE="$pi_package_source" node "${node_loader_args[@]}" --experimental-strip-types --input-type=module - <<'NODE'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.env.ROOT_DIR || process.cwd();
process.env.B_AGENTIC_DIR = path.join(root, '.b-agentic-test');
const installedRoot = path.join(process.env.PI_TEST_HOME || '', '.pi/agent/extensions');
const agentRoot = path.join(process.env.PI_CODING_AGENT_DIR || '', 'agents', 'b-agentic');
const subagentGuardPath = path.join(process.env.PI_CODING_AGENT_DIR || '', 'b-agentic', 'subagent-read-only-guard.ts');
const packageLinks = path.join(process.env.PI_CODING_AGENT_DIR || '', 'node_modules', '@earendil-works');
const piPackageRoot = process.env.PI_PACKAGE_ROOT;
if (piPackageRoot) {
  mkdirSync(packageLinks, { recursive: true });
  for (const [name, target] of [
    ['pi-coding-agent', piPackageRoot],
    ['pi-tui', path.join(piPackageRoot, 'node_modules/@earendil-works/pi-tui')],
  ]) {
    const link = path.join(packageLinks, name);
    if (!existsSync(link)) await import('node:fs').then(({ symlinkSync }) => symlinkSync(target, link, 'junction'));
  }
  const { setCapabilities } = await import(pathToFileURL(path.join(process.env.PI_CODING_AGENT_DIR, 'node_modules/@earendil-works/pi-tui/dist/index.js')).href);
  setCapabilities({ images: null, trueColor: true, hyperlinks: true });
}

function expect(condition, message) {
  if (!condition) throw new Error(message);
}

const extensionNames = [
  'b-agentic-permissions.ts', 'b-agentic-mcp-permissions.ts',
  'b-agentic-auto-mode.ts', 'b-agentic-sync.ts',
  'b-agentic-preview-markdown.ts', 'b-agentic-status.ts',
];
const modules = await Promise.all(extensionNames.map((name) =>
  import(pathToFileURL(path.join(installedRoot, name)).href),
));
const childGuard = await import(pathToFileURL(subagentGuardPath).href);
for (const name of ['shell.ts', 'mcp.ts', 'auto.ts', 'capabilities.ts', 'status.ts']) {
  await import(pathToFileURL(path.join(installedRoot, 'b-agentic-support', name)).href);
}

const handlers = new Map();
const childHandlers = new Map();
const commands = {};
const flags = {};
const flagDefinitions = {};
const persistedEntries = [];
const statusEntries = [];
let mcpApprovalHandler;
const host = {
  on(event, handler) {
    const registered = handlers.get(event) || [];
    registered.push(handler);
    handlers.set(event, registered);
  },
  events: { on(event, handler) { if (event === 'pi-mcp-adapter:tool-approval-request') mcpApprovalHandler = handler; } },
  registerFlag(name, definition) { flagDefinitions[name] = definition; },
  getFlag(name) { return flags[name]; },
  registerCommand(name, definition) { commands[name] = definition; },
  registerShortcut() {},
  registerTool() {},
  appendEntry(type, data) { persistedEntries.push({ type, data }); },
  sendMessage() {},
  async exec() { return { code: 0, stdout: '', stderr: '' }; },
};
for (const module of modules) module.default(host);

async function invoke(event, payload, context) {
  for (const handler of handlers.get(event) || []) {
    const result = await handler(payload, context);
    if (result) return result;
  }
  return undefined;
}

async function invokeChildGuard(payload) {
  for (const handler of childHandlers.get('tool_call') || []) {
    const result = await handler(payload, {});
    if (result) return result;
  }
  return undefined;
}

const context = {
  cwd: root,
  hasUI: true,
  ui: {
    async confirm() { return true; },
    notify() {},
    setStatus(key, value) { statusEntries.push({ key, value }); },
    theme: { fg(_color, text) { return text; } },
  },
  sessionManager: { getBranch() { return []; } },
};
const noUiContext = { ...context, hasUI: false };
const permissions = modules[0].__test__;
const auto = modules[2].__test__;
const status = modules[5].__test__;
expect(permissions && auto && status, 'managed safety and status extensions must expose their test surfaces');
expect(existsSync(subagentGuardPath) && typeof childGuard.default === 'function', 'managed child-only read-only guard must be installed');
await childGuard.default({
  on(event, handler) {
    const registered = childHandlers.get(event) || [];
    registered.push(handler);
    childHandlers.set(event, registered);
  },
});
expect((await invokeChildGuard({ toolName: 'bash', input: { command: 'touch child-write.txt' } }))?.block === true, 'child guard must block Bash even if it becomes available');
expect((await invokeChildGuard({ toolName: 'powershell', input: { command: 'Set-Content child-write.txt unsafe' } }))?.block === true, 'child guard must block PowerShell even if it becomes available');
expect((await invokeChildGuard({ toolName: 'arbitrary_custom_tool', input: {} }))?.block === true, 'child guard must block unexpected child tools');
expect((await invokeChildGuard({ toolName: 'edit', input: { path: 'src/example.ts', edits: [] } }))?.block === true, 'child guard must block native edits');
expect((await invokeChildGuard({ toolName: 'mcpScript', input: { code: 'emit({})' } }))?.block === true, 'child guard must block nested MCP scripts');
expect((await invokeChildGuard({ toolName: 'mcp__firecrawl__firecrawl_search', input: { query: 'docs' } }))?.block === true, 'child guard must block direct MCP tools');
expect((await invokeChildGuard({ toolName: 'mcp', input: { server: 'firecrawl', tool: 'firecrawl_crawl', args: { url: 'https://example.test' } } }))?.block === true, 'child guard must block unclassified gateway operations');
expect(await invokeChildGuard({ toolName: 'mcp', input: { server: 'codegraph', tool: 'codegraph_codegraph_explore', args: { query: 'callers' } } }) === undefined, 'child guard must allow a classified read-only gateway operation');
expect(await invokeChildGuard({ toolName: 'read', input: { path: 'README.md' } }) === undefined, 'child guard must preserve native read access');
expect(typeof mcpApprovalHandler === 'function', 'MCP approval extension must register the package approval broker');
expect(commands['b-auto-mode'] && commands['b-status'] && commands['b-sync'] && commands['b-update'], 'single-session runtime must retain auto, status, sync, and update commands');
expect(!commands['b-role'], 'single-session runtime must not register the legacy role command');
expect(flagDefinitions['b-auto-mode']?.type === 'boolean', 'auto-mode must retain its boolean startup flag');

expect(permissions.commandDecision('git reset --hard').decision === 'deny', 'prohibited destructive Git commands must remain denied');
expect(permissions.nativePathDecision('read', '.env', root).decision === 'ask', 'likely secret paths must remain approval-gated');
expect(permissions.isTrustedPreviewMarkdownCall({ markdown: '# Preview' }) === true, 'trusted preview calls retain their narrow argument shape');
expect(permissions.isTrustedPreviewMarkdownCall({ markdown: '# Preview', extra: true }) === false, 'preview calls with extra arguments remain untrusted');
expect((await invoke('tool_call', { toolName: 'bash', input: { command: 'git reset --hard' } }, noUiContext))?.block === true, 'headless destructive shell commands must fail closed');
expect((await invoke('tool_call', { toolName: 'mcp', input: { server: 'firecrawl' } }, noUiContext))?.block === true, 'headless MCP calls must fail closed without auto-mode');
await invoke('turn_start', {}, context);
expect(await invoke('tool_call', { toolName: 'edit', input: { path: 'src/example.ts' } }, context) === undefined, 'the first ordinary edit may proceed');
expect((await invoke('tool_call', { toolName: 'edit', input: { path: 'src/example.ts' } }, context))?.block === true, 'duplicate native edits in one turn remain blocked');

expect(auto.parseAutoMode(true) === true && auto.parseAutoMode('off') === false && auto.parseAutoMode('invalid') === undefined, 'auto-mode input parsing must fail closed');
await commands['b-auto-mode'].handler('on', context);
expect(persistedEntries.at(-1)?.type === auto.AUTO_MODE_ENTRY_TYPE && statusEntries.at(-1)?.key === 'b-auto-mode', 'enabling auto-mode must persist session state and update status');
await commands['b-auto-mode'].handler('off', context);

const snapshot = await status.buildCapabilitySnapshot(host, {
  packageListing: ['pi-mcp-adapter', 'pi-subagents', '@juicesharp/rpiv-todo'].join('\n'),
  extensionRoot: installedRoot,
  agentRoot,
  guardPath: subagentGuardPath,
  settingsPath: path.join(process.env.PI_CODING_AGENT_DIR, 'settings.json'),
  mcpConfigPresent: true,
  commandAvailable: () => true,
});
expect(snapshot.includes('Capability contract v1') && snapshot.includes('pi-subagents: installed'), 'status must report the pi-subagents package from local evidence');
expect(snapshot.includes('b-agentic-subagent-profiles: installed'), 'status must report installed managed subagent profiles');
expect(snapshot.includes('b-agentic-subagent-settings: configured'), 'status must report the local subagent settings file without inspecting its values');
const missingSubagentSnapshot = await status.buildCapabilitySnapshot(host, {
  packageListing: 'pi-subagents',
  extensionRoot: installedRoot,
  agentRoot: path.join(agentRoot, 'missing'),
  guardPath: path.join(agentRoot, 'missing-subagent-guard.ts'),
  settingsPath: path.join(agentRoot, 'missing-settings.json'),
  mcpConfigPresent: true,
  commandAvailable: () => true,
});
expect(missingSubagentSnapshot.includes('b-agentic-subagent-profiles: missing'), 'status must report missing managed subagent profiles');
expect(missingSubagentSnapshot.includes('b-agentic-subagent-settings: missing'), 'status must report a missing local subagent settings file');
const missingGuardSnapshot = await status.buildCapabilitySnapshot(host, {
  packageListing: 'pi-subagents',
  extensionRoot: installedRoot,
  agentRoot,
  guardPath: path.join(agentRoot, 'missing-subagent-guard.ts'),
  settingsPath: path.join(process.env.PI_CODING_AGENT_DIR, 'settings.json'),
  mcpConfigPresent: true,
  commandAvailable: () => true,
});
expect(missingGuardSnapshot.includes('b-agentic-subagent-profiles: missing'), 'status must report a missing managed child-only guard');
expect(!snapshot.includes('pi-intercom'), 'status must not advertise the retired two-role coordinator');
expect(snapshot.includes('local, read-only; no MCP/auth/browser probes'), 'status must describe its bounded local observation');

for (const name of ['b-planner.md', 'b-researcher.md', 'b-debugger.md', 'b-reviewer.md']) {
  const profile = path.join(agentRoot, name);
  expect(existsSync(profile), `managed custom subagent profile missing: ${name}`);
  const text = readFileSync(profile, 'utf8');
  const frontmatter = text.startsWith('---') ? text.split('---', 3)[1] : text;
  expect(text.includes('read-only') && text.includes('subagentOnlyExtensions: ../../b-agentic/subagent-read-only-guard.ts'), `${name} must load the child-only guard`);
  for (const forbidden of ['- bash', '- edit', '- write', '- mcpScript', '- intercom']) {
    expect(!frontmatter.includes(forbidden), `${name} must not grant ${forbidden.slice(2)}`);
  }
}
const settings = JSON.parse(readFileSync(path.join(process.env.PI_CODING_AGENT_DIR, 'settings.json'), 'utf8'));
expect(settings.subagents?.disableBuiltins === true, 'managed Pi settings must disable bundled subagents');
for (const name of ['b-planner', 'b-researcher', 'b-debugger', 'b-reviewer']) {
  expect(settings.subagents.agentOverrides?.[name]?.model === 'inherit', `${name} must inherit the parent model by default`);
}

console.log('single-session Pi permission and subagent smoke checks passed');
NODE
	if [ -f "$pi_server_marker" ]; then
		assert_contains "$pi_server_marker" 'fallback activated because pi-server resolution failed'
		assert_contains "$pi_server_probe" 'pi-server smoke shim invoked'
	else
		assert_no_path "$pi_server_loader"
		assert_no_path "$pi_server_marker"
		assert_no_path "$pi_server_probe"
	fi
}

run_pi_smoke_cases() {
	# This function runs in a background subshell from tests/smoke/install.sh.
	# Do not let the parent's EXIT trap remove the shared WORK_DIR while the
	# installer smoke workers are still running.
	trap - EXIT
	local snapshot_repo="$1"
	local sandbox="$WORK_DIR/pi"
	local sandbox_adapter="$WORK_DIR/pi-adapter"
	local sandbox_preserve="$WORK_DIR/pi-preserve"
	local sandbox_replace="$WORK_DIR/pi-replace"
	local sandbox_mcp_merge="$WORK_DIR/pi-mcp-merge"
	local sandbox_extension_restore="$WORK_DIR/pi-extension-restore"
	local sandbox_extension_modified="$WORK_DIR/pi-extension-modified"
	local sandbox_extension_symlink="$WORK_DIR/pi-extension-symlink"
	local sandbox_agent_modified="$WORK_DIR/pi-agent-modified"
	local sandbox_agent_symlink="$WORK_DIR/pi-agent-symlink"
	local sandbox_guard_modified="$WORK_DIR/pi-guard-modified"
	local sandbox_guard_symlink="$WORK_DIR/pi-guard-symlink"
	local sandbox_skill_modified="$WORK_DIR/pi-skill-modified"
	local sandbox_skill_reinstall="$WORK_DIR/pi-skill-reinstall"
	local sandbox_skill_stale="$WORK_DIR/pi-skill-stale"
	local sandbox_skill_symlink="$WORK_DIR/pi-skill-symlink"
	mkdir -p \
		"$sandbox/home" \
		"$sandbox_adapter/home" \
		"$sandbox_preserve/home" \
		"$sandbox_replace/home" \
		"$sandbox_mcp_merge/home" \
		"$sandbox_extension_restore/home/.pi/agent/extensions" \
		"$sandbox_extension_modified/home" \
		"$sandbox_extension_symlink/home/.pi/agent/extensions" \
		"$sandbox_agent_modified/home" \
		"$sandbox_agent_symlink/home" \
		"$sandbox_guard_modified/home" \
		"$sandbox_guard_symlink/home" \
		"$sandbox_skill_modified/home" \
		"$sandbox_skill_reinstall/home" \
		"$sandbox_skill_stale/home" \
		"$sandbox_skill_symlink/home"

	# Core install layout without adapter package.
	expect_install_status 0 "$sandbox" "$snapshot_repo"
	assert_file "$sandbox/home/.pi/agent/AGENTS.md"
	assert_file "$sandbox/home/.pi/agent/skills/b-plan/SKILL.md"
	assert_no_path "$sandbox/home/.pi/agent/skills/b-plan/prompt.md"
	assert_file "$sandbox/home/.pi/agent/b-agentic/references/kernel.template.md"
	assert_file "$sandbox/home/.pi/agent/b-agentic/references/mcp_operations.yaml"
	assert_file "$sandbox/home/.pi/agent/b-agentic/references/capabilities.yaml"
	assert_no_path "$sandbox/home/.pi/agent/b-agentic/references/contract"
	assert_file "$sandbox/home/.pi/agent/mcp.json"
	for extension in b-agentic-preview-markdown.ts b-agentic-permissions.ts b-agentic-mcp-permissions.ts b-agentic-auto-mode.ts b-agentic-sync.ts b-agentic-status.ts; do
		assert_file "$sandbox/home/.pi/agent/extensions/$extension"
		assert_file "$sandbox/home/.pi/agent/b-agentic/extensions/$extension"
	done
	for support in shell.ts mcp.ts auto.ts capabilities.ts status.ts; do
		assert_file "$sandbox/home/.pi/agent/extensions/b-agentic-support/$support"
		assert_file "$sandbox/home/.pi/agent/b-agentic/extensions/b-agentic-support/$support"
	done
	for agent in b-planner.md b-researcher.md b-debugger.md b-reviewer.md; do
		assert_file "$sandbox/home/.pi/agent/agents/b-agentic/$agent"
		assert_file "$sandbox/home/.pi/agent/b-agentic/agents/$agent"
	done
	assert_file "$sandbox/home/.pi/agent/settings.json"
	assert_file "$sandbox/home/.pi/agent/b-agentic/subagent-read-only-guard.ts"
	assert_file "$sandbox/home/.pi/agent/b-agentic/subagent-read-only-guard.snapshot.ts"
	assert_equal_files "$sandbox/home/.pi/agent/b-agentic/subagent-read-only-guard.ts" "$sandbox/source/pi/subagent-read-only-guard.ts"
	assert_equal_files "$sandbox/home/.pi/agent/b-agentic/subagent-read-only-guard.snapshot.ts" "$sandbox/source/pi/subagent-read-only-guard.ts"
	assert_contains "$sandbox/home/.pi/agent/settings.json" '"disableBuiltins": true'
	assert_file "$sandbox/home/.pi/agent/b-agentic/install.json"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilityContractVersion'] == 1"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['contractVersion'] == 1"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "len(data['capabilities']['states']) == 20"
	assert_not_contains "$sandbox/home/.pi/agent/b-agentic/install.json" 'extension.b-agentic-consult'
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['states']['package.pi-mcp-adapter']['state'] == 'ready'"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['states']['package.pi-todo']['state'] == 'ready'"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['states']['agent.b-agentic-subagent-profiles']['state'] == 'ready'"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['states']['agent.b-agentic-subagent-settings']['state'] == 'ready'"
	assert_not_contains "$sandbox/home/.pi/agent/b-agentic/install.json" 'package.pi-lsp'
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['states']['extension.b-agentic-status']['state'] == 'ready'"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['paths']['capabilityContract'].endswith('/references/capabilities.yaml')"
	assert_contains "$sandbox/home/.pi/agent/mcp.json" '"codegraph"'
	assert_contains "$sandbox/home/.pi/agent/mcp.json" '"lifecycle": "lazy"'
	assert_contains "$sandbox/home/.pi/agent/extensions/b-agentic-permissions.ts" 'tool_call'
	assert_equal_files "$sandbox/home/.pi/agent/extensions/b-agentic-preview-markdown.ts" "$sandbox/source/pi/packages/preview-markdown/extensions/b-agentic-preview-markdown.ts"
	assert_contains "$sandbox/home/.pi/agent/extensions/b-agentic-preview-markdown.ts" 'preview_markdown'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"mcpAdapterState": "ready"'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"extensions"'
	assert_contains "$sandbox/home/.pi/agent/AGENTS.md" 'b-agentic-managed'
	assert_file "$sandbox/smoke-bin/pi-install.log"
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:pi-mcp-adapter'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:pi-observational-memory'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@sreetej510/pi-usage'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@gotgenes/pi-anthropic-auth'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:pi-subagents'
	assert_not_contains "$sandbox/smoke-bin/pi-install.log" 'npm:pi-intercom'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@juicesharp/rpiv-ask-user-question'
	assert_not_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@narumitw/pi-lsp'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@juicesharp/rpiv-todo'
	assert_not_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@juicesharp/rpiv-ask-user-question@'
	assert_not_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@juicesharp/rpiv-todo@'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piSubagentsState": "ready"'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"subagentProfilesState": "active"'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"subagentGuardState": "active"'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"subagentSettingsState": "active"'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piAskUserQuestionState": "ready"'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piAnthropicAuthState": "ready"'
	assert_not_contains "$sandbox/home/.pi/agent/b-agentic/install.json" 'piLsp'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piTodoState": "ready"'
	local initial_anthropic_auth_install_count initial_todo_install_count
	initial_anthropic_auth_install_count="$(grep -Fc 'npm:@gotgenes/pi-anthropic-auth' "$sandbox/smoke-bin/pi-install.log")"
	initial_todo_install_count="$(grep -Fc 'npm:@juicesharp/rpiv-todo' "$sandbox/smoke-bin/pi-install.log")"

	# Split in-session modes: sync pulls/assets only; update uses installed source without Git.
	# Exercise sync with the default environment so package, Pi CLI, and MCP setup
	# cannot be hidden by opt-out flags.
	local sync_mcp_snapshot="$sandbox/sync-mcp.json"
	local sync_manifest_snapshot="$sandbox/sync-manifest.json"
	local sync_helper_snapshot="$sandbox/sync-helper.py"
	cp "$sandbox/home/.pi/agent/mcp.json" "$sync_mcp_snapshot"
	cp "$sandbox/home/.pi/agent/b-agentic/install.json" "$sync_manifest_snapshot"
	cp "$sandbox/home/.pi/agent/b-agentic/tooling/install/manifest_uninstall.py" "$sync_helper_snapshot"
	rm -rf "$sandbox/home/.pi/agent/skills/b-plan"
	printf '\n<!-- stale sync fixture -->\n' >>"$sandbox/home/.pi/agent/AGENTS.md"
	printf '\n// stale sync fixture\n' >>"$sandbox/home/.pi/agent/extensions/b-agentic-sync.ts"
	env \
		-u B_AGENTIC_PROMPT_API_KEYS \
		HOME="$sandbox/home" \
		PATH="$(smoke_runtime_cli_path "$sandbox")" \
		B_AGENTIC_REPO="$snapshot_repo" \
		B_AGENTIC_DIR="$sandbox/source" \
		bash "$ROOT_DIR/install.sh" --sync >/dev/null 2>&1
	assert_equal_files "$sandbox/home/.pi/agent/mcp.json" "$sync_mcp_snapshot"
	assert_equal_files "$sandbox/home/.pi/agent/b-agentic/install.json" "$sync_manifest_snapshot"
	assert_equal_files "$sandbox/home/.pi/agent/b-agentic/tooling/install/manifest_uninstall.py" "$sync_helper_snapshot"
	assert_equal_files "$sandbox/home/.pi/agent/skills/b-plan/SKILL.md" "$sandbox/source/skills/b-plan/SKILL.md"
	assert_equal_files "$sandbox/home/.pi/agent/AGENTS.md" "$sandbox/source/references/kernel.template.md"
	assert_equal_files "$sandbox/home/.pi/agent/extensions/b-agentic-sync.ts" "$sandbox/source/pi/extensions/b-agentic-sync.ts"
	assert_equal_files "$sandbox/home/.pi/agent/agents/b-agentic/b-reviewer.md" "$sandbox/source/pi/agents/b-reviewer.md"
	assert_equal_files "$sandbox/home/.pi/agent/b-agentic/subagent-read-only-guard.ts" "$sandbox/source/pi/subagent-read-only-guard.ts"
	assert_file "$sandbox/home/.pi/agent/b-agentic/themes/dracula.json"
	[ -L "$sandbox/home/.pi/agent/themes/dracula.json" ] || fail "expected dracula.json to be a symlink"
	assert_equal_files "$sandbox/home/.pi/agent/themes/dracula.json" "$sandbox/home/.pi/agent/b-agentic/themes/dracula.json"
	# Mark an existing package only for the update-mode proof below.
	: >"$sandbox/smoke-bin/pi-adapter-installed"
	cat >"$sandbox/smoke-bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "$sandbox/smoke-bin/curl"
	mv "$sandbox/source/.git" "$sandbox/source/.git-without-pull"
	HOME="$sandbox/home" \
		PATH="$(smoke_runtime_cli_path "$sandbox")" \
		B_AGENTIC_REPO="$snapshot_repo" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --update >/dev/null 2>&1
	mv "$sandbox/source/.git-without-pull" "$sandbox/source/.git"
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'update'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'update --extensions'
	[ "$(grep -Fc 'npm:@gotgenes/pi-anthropic-auth' "$sandbox/smoke-bin/pi-install.log")" -eq "$initial_anthropic_auth_install_count" ] || fail "Pi update reinstalled pi-anthropic-auth despite package being present"
	[ "$(grep -Fc 'npm:@juicesharp/rpiv-todo' "$sandbox/smoke-bin/pi-install.log")" -eq "$initial_todo_install_count" ] || fail "Pi update reinstalled pi-todo despite package being present"
	assert_not_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@narumitw/pi-lsp'
	assert_not_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@juicesharp/rpiv-todo@'

	local behavioral_pid
	run_pi_permission_behavioral_fixture "$sandbox" &
	behavioral_pid=$!

	(

	# Optional Pi packages via env opt-in (mock pi records installs).
	# expect_install_status hardcodes env; invoke installer directly for package opt-ins.
	local smoke_path
	smoke_path="$(smoke_runtime_cli_path "$sandbox_adapter")"
	HOME="$sandbox_adapter/home" \
		PATH="$smoke_path" \
		B_AGENTIC_REPO="$snapshot_repo" \
		B_AGENTIC_DIR="$sandbox_adapter/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" >/dev/null 2>&1
	assert_file "$sandbox_adapter/home/.pi/agent/b-agentic/install.json"
	assert_contains "$sandbox_adapter/home/.pi/agent/b-agentic/install.json" '"mcpAdapterState": "ready"'
	assert_contains "$sandbox_adapter/home/.pi/agent/b-agentic/install.json" '"piObservationalMemoryState": "ready"'
	assert_contains "$sandbox_adapter/home/.pi/agent/b-agentic/install.json" '"piUsageState": "ready"'
	assert_contains "$sandbox_adapter/home/.pi/agent/b-agentic/install.json" '"piAnthropicAuthState": "ready"'
	assert_file "$sandbox_adapter/smoke-bin/pi-install.log"
	assert_contains "$sandbox_adapter/smoke-bin/pi-install.log" 'npm:pi-mcp-adapter'
	assert_contains "$sandbox_adapter/smoke-bin/pi-install.log" 'npm:pi-observational-memory'
	assert_contains "$sandbox_adapter/smoke-bin/pi-install.log" 'npm:@sreetej510/pi-usage'
	assert_contains "$sandbox_adapter/smoke-bin/pi-install.log" 'npm:@gotgenes/pi-anthropic-auth'
	assert_contains "$sandbox_adapter/smoke-bin/pi-install.log" 'npm:@juicesharp/rpiv-ask-user-question'
	assert_not_contains "$sandbox_adapter/smoke-bin/pi-install.log" 'npm:@narumitw/pi-lsp'
	assert_contains "$sandbox_adapter/smoke-bin/pi-install.log" 'npm:@juicesharp/rpiv-todo'
	assert_not_contains "$sandbox_adapter/smoke-bin/pi-install.log" 'npm:@juicesharp/rpiv-ask-user-question@'
	assert_not_contains "$sandbox_adapter/smoke-bin/pi-install.log" 'npm:@juicesharp/rpiv-todo@'
	assert_contains "$sandbox_adapter/home/.pi/agent/b-agentic/install.json" '"piAskUserQuestionState": "ready"'
	assert_not_contains "$sandbox_adapter/home/.pi/agent/b-agentic/install.json" 'piLsp'
	assert_contains "$sandbox_adapter/home/.pi/agent/b-agentic/install.json" '"piTodoState": "ready"'
	assert_contains "$sandbox_adapter/smoke-bin/pi-install.log" 'update --extensions'

	# Preserve user-owned kernel.
	mkdir -p "$sandbox_preserve/home/.pi/agent"
	printf 'user-owned pi kernel\n' >"$sandbox_preserve/home/.pi/agent/AGENTS.md"
	expect_install_status 1 "$sandbox_preserve" "$snapshot_repo"
	assert_file "$sandbox_preserve/home/.pi/agent/AGENTS.md"
	assert_contains "$sandbox_preserve/home/.pi/agent/AGENTS.md" 'user-owned pi kernel'
	assert_file "$sandbox_preserve/home/.pi/agent/b-agentic/install.json"
	assert_contains "$sandbox_preserve/home/.pi/agent/b-agentic/install.json" '"activationState": "pending"'

	# --replace-memory overwrites user kernel.
	mkdir -p "$sandbox_replace/home/.pi/agent"
	printf 'user-owned pi kernel\n' >"$sandbox_replace/home/.pi/agent/AGENTS.md"
	expect_install_status 0 "$sandbox_replace" "$snapshot_repo" --replace-memory
	assert_contains "$sandbox_replace/home/.pi/agent/AGENTS.md" 'b-agentic-managed'
	assert_not_contains "$sandbox_replace/home/.pi/agent/AGENTS.md" 'user-owned pi kernel'

	# MCP merge preserves unrelated servers.
	mkdir -p "$sandbox_mcp_merge/home/.pi/agent"
	cat >"$sandbox_mcp_merge/home/.pi/agent/mcp.json" <<'EOF'
{
  "mcpServers": {
    "user-server": {
      "command": "echo",
      "args": ["user"]
    },
    "serena": {
      "command": "user-owned-serena",
      "args": ["--custom"],
      "env": {"USER_SETTING": "keep-me"},
      "lifecycle": "eager"
    }
  },
  "settings": {"serenaPreference": "keep-me"}
}
EOF
	expect_install_status 0 "$sandbox_mcp_merge" "$snapshot_repo"
	assert_contains "$sandbox_mcp_merge/home/.pi/agent/mcp.json" '"user-server"'
	assert_json_value "$sandbox_mcp_merge/home/.pi/agent/mcp.json" "data['mcpServers']['serena'] == {'command': 'user-owned-serena', 'args': ['--custom'], 'env': {'USER_SETTING': 'keep-me'}, 'lifecycle': 'eager'}"
	assert_json_value "$sandbox_mcp_merge/home/.pi/agent/mcp.json" "data['settings']['serenaPreference'] == 'keep-me'"

	# Uninstall restores pre-existing entrypoint and support files after reinstall and managed-file deletion.
	mkdir -p "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-support"
	printf 'user-owned permission extension\n' >"$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-permissions.ts"
	printf 'user-owned status extension\n' >"$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-status.ts"
	printf 'user-owned shell support\n' >"$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-support/shell.ts"
	expect_install_status 0 "$sandbox_extension_restore" "$snapshot_repo"
	assert_not_contains "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-permissions.ts" 'user-owned permission extension'
	expect_install_status 0 "$sandbox_extension_restore" "$snapshot_repo"
	rm "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-permissions.ts"
	rm "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-status.ts"
	rm "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-support/shell.ts"
	expect_install_status 0 "$sandbox_extension_restore" "$snapshot_repo"
	expect_install_status 0 "$sandbox_extension_restore" "$snapshot_repo" --uninstall
	assert_contains "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-permissions.ts" 'user-owned permission extension'
	assert_contains "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-status.ts" 'user-owned status extension'
	assert_contains "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-support/shell.ts" 'user-owned shell support'

	# Uninstall preserves symlink destinations instead of restoring through them.
	printf 'user-owned permission extension\n' >"$sandbox_extension_symlink/home/.pi/agent/extensions/b-agentic-permissions.ts"
	expect_install_status 0 "$sandbox_extension_symlink" "$snapshot_repo"
	cp "$sandbox_extension_symlink/home/.pi/agent/extensions/b-agentic-permissions.ts" "$sandbox_extension_symlink/target.ts"
	rm "$sandbox_extension_symlink/home/.pi/agent/extensions/b-agentic-permissions.ts"
	ln -s "$sandbox_extension_symlink/target.ts" "$sandbox_extension_symlink/home/.pi/agent/extensions/b-agentic-permissions.ts"
	expect_install_status 0 "$sandbox_extension_symlink" "$snapshot_repo" --uninstall
	[ -L "$sandbox_extension_symlink/home/.pi/agent/extensions/b-agentic-permissions.ts" ] || fail "expected symlinked extension to be preserved"
	assert_contains "$sandbox_extension_symlink/target.ts" 'tool_call'
	assert_not_contains "$sandbox_extension_symlink/target.ts" 'user-owned permission extension'

	# Uninstall preserves an extension modified after installation.
	expect_install_status 0 "$sandbox_extension_modified" "$snapshot_repo"
	printf 'post-install user modification\n' >"$sandbox_extension_modified/home/.pi/agent/extensions/b-agentic-permissions.ts"
	expect_install_status 0 "$sandbox_extension_modified" "$snapshot_repo" --uninstall
	assert_contains "$sandbox_extension_modified/home/.pi/agent/extensions/b-agentic-permissions.ts" 'post-install user modification'

	# Reinstall and uninstall preserve a user-modified custom-agent profile, while unchanged profiles are removed.
	expect_install_status 0 "$sandbox_agent_modified" "$snapshot_repo"
	printf '\nuser profile modification\n' >>"$sandbox_agent_modified/home/.pi/agent/agents/b-agentic/b-planner.md"
	expect_install_status 0 "$sandbox_agent_modified" "$snapshot_repo"
	assert_contains "$sandbox_agent_modified/home/.pi/agent/agents/b-agentic/b-planner.md" 'user profile modification'
	expect_install_status 0 "$sandbox_agent_modified" "$snapshot_repo" --uninstall
	assert_contains "$sandbox_agent_modified/home/.pi/agent/agents/b-agentic/b-planner.md" 'user profile modification'
	assert_no_path "$sandbox_agent_modified/home/.pi/agent/agents/b-agentic/b-researcher.md"
	assert_no_path "$sandbox_agent_modified/home/.pi/agent/settings.json"

	# A symlinked custom-agent profile remains user-owned on reinstall and uninstall.
	expect_install_status 0 "$sandbox_agent_symlink" "$snapshot_repo"
	cp "$sandbox_agent_symlink/home/.pi/agent/agents/b-agentic/b-planner.md" "$sandbox_agent_symlink/profile-target.md"
	rm "$sandbox_agent_symlink/home/.pi/agent/agents/b-agentic/b-planner.md"
	ln -s "$sandbox_agent_symlink/profile-target.md" "$sandbox_agent_symlink/home/.pi/agent/agents/b-agentic/b-planner.md"
	expect_install_status 0 "$sandbox_agent_symlink" "$snapshot_repo"
	expect_install_status 0 "$sandbox_agent_symlink" "$snapshot_repo" --uninstall
	[ -L "$sandbox_agent_symlink/home/.pi/agent/agents/b-agentic/b-planner.md" ] || fail "expected symlinked subagent profile to be preserved"

	# Reinstall and uninstall preserve a user-modified child-only guard.
	expect_install_status 0 "$sandbox_guard_modified" "$snapshot_repo"
	printf '\nuser guard modification\n' >>"$sandbox_guard_modified/home/.pi/agent/b-agentic/subagent-read-only-guard.ts"
	expect_install_status 0 "$sandbox_guard_modified" "$snapshot_repo"
	assert_contains "$sandbox_guard_modified/home/.pi/agent/b-agentic/subagent-read-only-guard.ts" 'user guard modification'
	expect_install_status 0 "$sandbox_guard_modified" "$snapshot_repo" --uninstall
	assert_contains "$sandbox_guard_modified/home/.pi/agent/b-agentic/subagent-read-only-guard.ts" 'user guard modification'
	assert_file "$sandbox_guard_modified/home/.pi/agent/b-agentic/install.json"

	# A symlinked child-only guard remains user-owned on reinstall and uninstall.
	expect_install_status 0 "$sandbox_guard_symlink" "$snapshot_repo"
	cp "$sandbox_guard_symlink/home/.pi/agent/b-agentic/subagent-read-only-guard.ts" "$sandbox_guard_symlink/guard-target.ts"
	rm "$sandbox_guard_symlink/home/.pi/agent/b-agentic/subagent-read-only-guard.ts"
	ln -s "$sandbox_guard_symlink/guard-target.ts" "$sandbox_guard_symlink/home/.pi/agent/b-agentic/subagent-read-only-guard.ts"
	expect_install_status 0 "$sandbox_guard_symlink" "$snapshot_repo"
	expect_install_status 0 "$sandbox_guard_symlink" "$snapshot_repo" --uninstall
	[ -L "$sandbox_guard_symlink/home/.pi/agent/b-agentic/subagent-read-only-guard.ts" ] || fail "expected symlinked subagent read-only guard to be preserved"
	assert_file "$sandbox_guard_symlink/home/.pi/agent/b-agentic/install.json"

	# Reinstall preserves a modified managed skill.
	expect_install_status 0 "$sandbox_skill_reinstall" "$snapshot_repo"
	printf '\npost-install skill modification\n' >>"$sandbox_skill_reinstall/home/.pi/agent/skills/b-plan/SKILL.md"
	expect_install_status 0 "$sandbox_skill_reinstall" "$snapshot_repo"
	assert_contains "$sandbox_skill_reinstall/home/.pi/agent/skills/b-plan/SKILL.md" 'post-install skill modification'

	# Stale modified and symlinked skills survive reinstall pruning.
	expect_install_status 0 "$sandbox_skill_stale" "$snapshot_repo"
	mkdir -p \
		"$sandbox_skill_stale/home/.pi/agent/skills/stale-skill" \
		"$sandbox_skill_stale/home/.pi/agent/b-agentic/skills/stale-skill"
	printf 'Generated from skills/registry.yaml\n' >"$sandbox_skill_stale/home/.pi/agent/skills/stale-skill/SKILL.md"
	cp "$sandbox_skill_stale/home/.pi/agent/skills/stale-skill/SKILL.md" \
		"$sandbox_skill_stale/home/.pi/agent/b-agentic/skills/stale-skill/SKILL.md"
	mkdir -p "$sandbox_skill_stale/stale-target"
	printf 'Generated from skills/registry.yaml\n' >"$sandbox_skill_stale/stale-target/SKILL.md"
	ln -s "$sandbox_skill_stale/stale-target" \
		"$sandbox_skill_stale/home/.pi/agent/skills/stale-link"
	python3 - "$sandbox_skill_stale/home/.pi/agent/b-agentic/install.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['skills'].extend(['stale-skill', 'stale-link'])
path.write_text(json.dumps(data, indent=2) + '\n')
PY
	printf '\nuser stale-skill edit\n' >>"$sandbox_skill_stale/home/.pi/agent/skills/stale-skill/SKILL.md"
	expect_install_status 0 "$sandbox_skill_stale" "$snapshot_repo"
	assert_contains "$sandbox_skill_stale/home/.pi/agent/skills/stale-skill/SKILL.md" 'user stale-skill edit'
	[ -L "$sandbox_skill_stale/home/.pi/agent/skills/stale-link" ] || fail "expected stale skill symlink to be preserved"

	# Source-backed uninstall preserves a modified skill.
	expect_install_status 0 "$sandbox_skill_modified" "$snapshot_repo"
	printf '\npost-install skill modification\n' >>"$sandbox_skill_modified/home/.pi/agent/skills/b-plan/SKILL.md"
	expect_install_status 0 "$sandbox_skill_modified" "$snapshot_repo" --uninstall
	assert_contains "$sandbox_skill_modified/home/.pi/agent/skills/b-plan/SKILL.md" 'post-install skill modification'

	# Source-backed uninstall preserves a symlinked skill.
	expect_install_status 0 "$sandbox_skill_symlink" "$snapshot_repo"
	cp -R "$sandbox_skill_symlink/home/.pi/agent/skills/b-plan" "$sandbox_skill_symlink/target-skill"
	rm -rf "$sandbox_skill_symlink/home/.pi/agent/skills/b-plan"
	ln -s "$sandbox_skill_symlink/target-skill" "$sandbox_skill_symlink/home/.pi/agent/skills/b-plan"
	expect_install_status 0 "$sandbox_skill_symlink" "$snapshot_repo" --uninstall
	[ -L "$sandbox_skill_symlink/home/.pi/agent/skills/b-plan" ] || fail "expected symlinked skill to be preserved"
	assert_file "$sandbox_skill_symlink/target-skill/SKILL.md"

	) &
	local base_pid=$!

	local base_status
	if wait "$base_pid"; then
		:
	else
		base_status=$?
		wait "$behavioral_pid" 2>/dev/null || true
		return "$base_status"
	fi

	if wait "$behavioral_pid"; then
		:
	else
		local behavioral_status=$?
		return "$behavioral_status"
	fi

	# Source-backed uninstall removes managed content only.
	expect_install_status 0 "$sandbox" "$snapshot_repo" --uninstall
	assert_no_path "$sandbox/home/.pi/agent/skills/b-plan"
	assert_no_path "$sandbox/home/.pi/agent/b-agentic/install.json"
	assert_no_path "$sandbox/home/.pi/agent/extensions/b-agentic-permissions.ts"
	assert_no_path "$sandbox/home/.pi/agent/themes/dracula.json"
	# User MCP entries would be preserved by merge cleanup; managed-only install removes mcp.json entirely.
}
