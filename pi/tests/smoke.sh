# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "error: this script is sourced by tests/smoke/install.sh" >&2
	exit 1
fi

run_pi_smoke_cases() {
	local snapshot_repo="$1"
	local sandbox="$WORK_DIR/pi"
	local sandbox_adapter="$WORK_DIR/pi-adapter"
	local sandbox_preserve="$WORK_DIR/pi-preserve"
	local sandbox_replace="$WORK_DIR/pi-replace"
	local sandbox_mcp_merge="$WORK_DIR/pi-mcp-merge"
	local sandbox_extension_restore="$WORK_DIR/pi-extension-restore"
	local sandbox_extension_modified="$WORK_DIR/pi-extension-modified"
	local sandbox_extension_symlink="$WORK_DIR/pi-extension-symlink"
	mkdir -p \
		"$sandbox/home" \
		"$sandbox_adapter/home" \
		"$sandbox_preserve/home" \
		"$sandbox_replace/home" \
		"$sandbox_mcp_merge/home" \
		"$sandbox_extension_restore/home/.pi/agent/extensions" \
		"$sandbox_extension_modified/home" \
		"$sandbox_extension_symlink/home/.pi/agent/extensions"

	# Core install layout without adapter package.
	expect_install_status 0 "$sandbox" "$snapshot_repo"
	assert_file "$sandbox/home/.pi/agent/AGENTS.md"
	assert_file "$sandbox/home/.pi/agent/skills/b-plan/SKILL.md"
	assert_no_path "$sandbox/home/.pi/agent/skills/b-plan/prompt.md"
	assert_file "$sandbox/home/.pi/agent/b-agentic/references/kernel.template.md"
	assert_file "$sandbox/home/.pi/agent/b-agentic/references/mcp_operations.yaml"
	assert_no_path "$sandbox/home/.pi/agent/b-agentic/references/contract"
	assert_file "$sandbox/home/.pi/agent/mcp.json"
	assert_file "$sandbox/home/.pi/agent/extensions/b-agentic-permissions.ts"
	assert_file "$sandbox/home/.pi/agent/b-agentic/extensions/b-agentic-permissions.ts"
	assert_file "$sandbox/home/.pi/agent/b-agentic/install.json"
	assert_contains "$sandbox/home/.pi/agent/mcp.json" '"codegraph"'
	assert_contains "$sandbox/home/.pi/agent/mcp.json" '"lifecycle": "lazy"'
	assert_contains "$sandbox/home/.pi/agent/extensions/b-agentic-permissions.ts" 'tool_call'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"mcpAdapterState": "missing"'
	assert_contains "$sandbox/home/.pi/agent/AGENTS.md" 'b-agentic-managed'

	# Optional Pi packages via env opt-in (mock pi records installs).
	# expect_install_status hardcodes env; invoke installer directly for package opt-ins.
	local smoke_path
	smoke_path="$(smoke_runtime_cli_path "$sandbox_adapter")"
	HOME="$sandbox_adapter/home" \
		PATH="$smoke_path" \
		B_AGENTIC_REPO="$snapshot_repo" \
		B_AGENTIC_DIR="$sandbox_adapter/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		B_AGENTIC_INSTALL_PI_CLI=N \
		B_AGENTIC_INSTALL_RTK=N \
		B_AGENTIC_INSTALL_SERENA=N \
		B_AGENTIC_INSTALL_CODEGRAPH=N \
		B_AGENTIC_INSTALL_PI_MCP_ADAPTER=Y \
		B_AGENTIC_INSTALL_PI_OBSERVATIONAL_MEMORY=Y \
		bash "$ROOT_DIR/install.sh" >/dev/null 2>&1
	assert_file "$sandbox_adapter/home/.pi/agent/b-agentic/install.json"
	assert_contains "$sandbox_adapter/home/.pi/agent/b-agentic/install.json" '"mcpAdapterState": "ready"'
	assert_contains "$sandbox_adapter/home/.pi/agent/b-agentic/install.json" '"piObservationalMemoryState": "ready"'
	assert_file "$sandbox_adapter/smoke-bin/pi-install.log"
	assert_contains "$sandbox_adapter/smoke-bin/pi-install.log" 'npm:pi-mcp-adapter'
	assert_contains "$sandbox_adapter/smoke-bin/pi-install.log" 'npm:pi-observational-memory'

	# Preserve user-owned kernel.
	mkdir -p "$sandbox_preserve/home/.pi/agent"
	printf 'user-owned pi kernel\n' >"$sandbox_preserve/home/.pi/agent/AGENTS.md"
	expect_install_status 2 "$sandbox_preserve" "$snapshot_repo"
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
    }
  }
}
EOF
	expect_install_status 0 "$sandbox_mcp_merge" "$snapshot_repo"
	assert_contains "$sandbox_mcp_merge/home/.pi/agent/mcp.json" '"user-server"'
	assert_contains "$sandbox_mcp_merge/home/.pi/agent/mcp.json" '"serena"'

	# Uninstall restores a pre-existing extension after no-op reinstall and managed-file deletion.
	printf 'user-owned permission extension\n' >"$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-permissions.ts"
	expect_install_status 0 "$sandbox_extension_restore" "$snapshot_repo"
	assert_not_contains "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-permissions.ts" 'user-owned permission extension'
	expect_install_status 0 "$sandbox_extension_restore" "$snapshot_repo"
	rm "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-permissions.ts"
	expect_install_status 0 "$sandbox_extension_restore" "$snapshot_repo"
	expect_install_status 0 "$sandbox_extension_restore" "$snapshot_repo" --uninstall
	assert_contains "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-permissions.ts" 'user-owned permission extension'

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

	# Behavioral permission coverage via node --experimental-strip-types (no Pi runtime).
	ROOT_DIR="$ROOT_DIR" node --experimental-strip-types --input-type=module - <<'NODE'
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.env.ROOT_DIR || process.cwd();
const modPath = path.join(root, 'pi/extensions/b-agentic-permissions.ts');
const mod = await import(pathToFileURL(modPath).href);
const t = mod.__test__;
if (!t) {
  console.error('permission extension missing __test__ exports');
  process.exit(1);
}
let toolCallHandler;
mod.default({
  on(eventName, handler) {
    if (eventName === 'tool_call') toolCallHandler = handler;
  },
});

function expect(cond, msg) {
  if (!cond) {
    console.error(msg);
    process.exit(1);
  }
}

expect(typeof toolCallHandler === 'function', 'permission extension must register a tool_call handler');
const noUiContext = { hasUI: false, ui: { confirm: async () => true } };
expect(await toolCallHandler({ toolName: 'bash', input: { command: 'rtk git status --short' } }, noUiContext) === undefined, 'registered handler must allow safe RTK command');
expect((await toolCallHandler({ toolName: 'bash', input: { command: 'rtk git commit -m x' } }, noUiContext))?.block === true, 'registered handler must fail closed for approval-required shell command');
expect((await toolCallHandler({ toolName: 'mcp', input: { connect: 'serena' } }, noUiContext))?.block === true, 'registered handler must fail closed for MCP connect');
expect((await toolCallHandler({ toolName: 'read', input: { path: '.env' } }, noUiContext))?.block === true, 'registered handler must fail closed for protected read');

// Compound commands and wrappers
expect(t.commandDecision('cd repo && git reset --hard').decision === 'deny', 'compound reset --hard must deny');
expect(t.commandDecision('git -C repo reset --hard').decision === 'deny', 'git -C reset --hard must deny');
expect(t.commandDecision('/usr/bin/git reset --hard').decision === 'deny', 'path-qualified git reset --hard must deny');
expect(t.commandDecision('/usr/bin/npm install lodash').decision === 'ask', 'path-qualified npm install must ask');
expect(t.commandDecision('/bin/rm -rf /tmp/x').decision === 'ask', 'path-qualified rm -rf must ask');
expect(t.commandDecision('/usr/bin/printf x').decision === 'allow', 'unsupported raw command must allow');
expect(t.commandDecision("git -c alias.wipe='reset --hard' wipe").decision === 'ask', 'inline Git alias invocation must ask');
expect(t.commandDecision('env X=1 npm install lodash').decision === 'ask', 'env-wrapped npm install must ask');
for (const command of ['env', 'env -i', 'env X=1']) {
  expect(t.commandDecision(command).decision === 'ask', `${command} must require rtk env`);
}
expect(t.commandDecision('rtk env').decision === 'allow', 'rtk env must allow');
expect(t.commandDecision('rtk git commit -m x').decision === 'ask', 'rtk git commit must ask');
expect(t.commandDecision('rtk proxy git reset --hard').decision === 'deny', 'rtk proxy must preserve deny decisions');
expect(t.commandDecision('rtk g\\it reset --hard').decision === 'deny', 'escaped command name must not bypass reset denial');
expect(t.commandDecision(['rtk g', '\\', '\n', 'it reset --hard'].join('')).decision === 'deny', 'line-continuation command name must not bypass reset denial');
expect(t.commandDecision('rtk proxy c\\at src/main.ts').decision === 'allow', 'modern shell-tool alternatives remain optional');
expect(t.commandDecision('rtk proxy grep needle src/main.ts').decision === 'allow', 'rtk proxy must satisfy RTK requirement');
expect(t.commandDecision('sudo git push --force origin main').decision === 'deny', 'sudo force push must deny');
expect(t.commandDecision('/usr/bin/env X=1 git reset --hard').decision === 'deny', 'path-qualified env must not bypass reset denial');
expect(t.commandDecision('/usr/bin/sudo git push --force origin main').decision === 'deny', 'path-qualified sudo must not bypass force-push denial');
expect(t.commandDecision('/opt/bin/rtk git reset --hard').decision === 'deny', 'path-qualified RTK must not bypass reset denial');
expect(t.commandDecision('rtk git --git-dir repo/.git reset --hard').decision === 'deny', 'Git option value must not hide reset denial');
expect(t.commandDecision('rtk git --git-dir repo/.git --config-env=alias.wipe=ALIAS wipe').decision === 'ask', 'Git config-env alias after option value must ask');
expect(t.commandDecision('git push -f origin main').decision === 'deny', 'git push -f must deny');
expect(t.commandDecision('rm -rf /tmp/x').decision === 'ask', 'rm -rf must ask');
expect(t.commandDecision('ls -la').decision === 'ask', 'direct supported command must require RTK');
expect(t.commandDecision('rtk ls -la').decision === 'allow', 'rtk ls must allow');
expect(t.commandDecision('env X=1 rtk ls -la').decision === 'allow', 'env-wrapped rtk ls must allow');
expect(t.commandDecision('command rtk ls -la').decision === 'allow', 'command-wrapped rtk ls must allow');
expect(t.commandDecision('sudo rtk ls -la').decision === 'allow', 'sudo-wrapped rtk ls must allow');
expect(t.commandDecision('env -u FOO rtk ls -la').decision === 'allow', 'env -u wrapped rtk ls must allow');
expect(t.commandDecision('env -S ls').decision === 'ask', 'env -S legacy command must be approval-gated');
expect(t.commandDecision('env -S "grep needle src/main.ts"').decision === 'ask', 'env -S command string must be approval-gated');
expect(t.commandDecision('grep needle src/main.ts').decision === 'ask', 'direct supported command must require RTK');
for (const command of [
  'cat src/main.ts',
  'sed -n 1p src/main.ts',
  'awk {print} src/main.ts',
  'python3 -m json.tool package.json',
]) expect(t.commandDecision(command).decision === 'allow', `${command} must allow; modern shell-tool alternatives are optional`);
for (const [command, label] of [
  ['npm add lodash', 'npm add'], ['npm remove lodash', 'npm remove'], ['npm --silent install lodash', 'npm option install'], ['npm ci', 'npm ci'],
  ['/usr/bin/npm --silent install lodash', 'path-qualified npm option install'], ['rtk npm --prefix ./app install lodash', 'npm option-value install'],
  ['pnpm update', 'pnpm update'], ['pnpm up lodash', 'pnpm up'], ['rtk pnpm --dir ./app add lodash', 'pnpm option-value add'],
  ['yarn remove lodash', 'yarn remove'], ['yarn up lodash', 'yarn up'], ['bun uninstall lodash', 'bun uninstall'],
  ['cargo remove serde', 'cargo remove'], ['rtk cargo --manifest-path app/Cargo.toml update', 'cargo option-value update'],
  ['npm --unknown-option install lodash', 'unknown package option'], ['pip uninstall requests', 'pip uninstall'],
  ['pip3 uninstall requests', 'pip3 uninstall'], ['poetry update', 'poetry update'],
  ['uv pip uninstall requests', 'uv pip uninstall'], ['uv pip sync requirements.txt', 'uv pip sync'],
]) expect(t.commandDecision(command).decision === 'ask', `${label} must gate dependency writes`);
expect(t.commandDecision('git --config-env=alias.wipe=ALIAS wipe').decision === 'ask', 'inline Git config-env alias invocation must ask');
for (const command of ['npm view lodash', 'pnpm list', 'cargo search serde']) {
  expect(t.commandDecision(command).decision === 'ask', `${command} must require RTK`);
}
for (const command of ['rtk npm view lodash', 'rtk pnpm list', 'rtk cargo search serde', 'rtk pytest -q']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} must preserve supported RTK use`);
}
for (const command of ['yarn why lodash', 'bun --version']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} must allow when RTK does not support it`);
  expect(t.commandDecision(`rtk proxy ${command}`).decision === 'allow', `rtk proxy ${command} must preserve safety classification`);
}
const rtkSupportedCommands = [
  'ls', 'tree', 'git', 'gh', 'glab', 'aws', 'psql', 'pnpm', 'find', 'diff',
  'dotnet', 'docker', 'kubectl', 'oc', 'grep', 'rg', 'wget', 'wc',
  'jest', 'vitest', 'prisma', 'tsc', 'next', 'lint', 'prettier', 'format',
  'playwright', 'cargo', 'npm', 'npx', 'curl', 'ruff', 'pytest', 'mypy',
  'rake', 'rubocop', 'rspec', 'pip', 'go', 'gt', 'golangci-lint', 'gradlew', 'mvn',
];
for (const command of rtkSupportedCommands) {
  expect(t.RTK_REQUIRED_COMMANDS.has(command), `${command} must be covered by the RTK policy`);
  expect(t.commandDecision(`${command} --version`).decision === 'ask', `${command} must require RTK`);
}
expect(t.commandDecision('pip show requests').decision === 'ask', 'pip must require RTK');
for (const command of ['poetry show', 'uv --version', 'printf x']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} must allow when RTK does not support it`);
}
for (const command of ['rtk proxy poetry show', 'rtk proxy uv --version', 'rtk proxy printf x']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} must preserve safety classification`);
}
expect(t.commandDecision('printf x\ngit reset --hard').decision === 'deny', 'newline-separated reset --hard must deny');
expect(t.commandDecision('printf x\r\ngit reset --hard').decision === 'deny', 'CRLF-separated reset --hard must deny');
expect(t.commandDecision('rtk proxy printf x\ncat .env').decision === 'ask', 'newline-separated protected-path read must ask');
expect(t.commandDecision('printf x\nprintf y').decision === 'allow', 'unsupported multiline raw commands must allow when safe');
expect(t.commandDecision('cat .env').decision === 'ask', 'bare protected-path read must ask');
expect(t.commandDecision('cat .env.local').decision === 'ask', 'root-relative protected-path read must ask');
expect(t.commandDecision('cat /tmp/.env.production').decision === 'ask', 'absolute protected-path read must ask');
expect(t.commandDecision('rtk cat ./config/../.env.local').decision === 'ask', 'rtk-wrapped protected-path read must ask');
expect(t.commandDecision('ls src && cat credentials.json').decision === 'ask', 'compound protected-path read must ask');
expect(t.commandDecision('cat src/main.ts').decision === 'allow', 'direct cat must allow when appropriate');
expect(t.commandDecision('cat "$SECRET_FILE"').decision === 'ask', 'variable shell paths must fail closed as ambiguous');
expect(t.commandDecision('rtk proxy bat .e?v').decision === 'ask', 'unquoted protected-path glob must fail closed');
expect(t.commandDecision("rtk rg 'src/*.ts'").decision === 'allow', 'quoted glob argument must remain usable');
expect(t.commandDecision("rtk rg '\\d+' src/main.ts").decision === 'allow', 'quoted regex escape must remain usable');
expect(t.commandDecision("cat '.env").decision === 'ask', 'unbalanced shell quotes must fail closed');

// Ambiguous shell
expect(t.commandDecision('eval "$(echo git reset --hard)"').decision === 'ask', 'eval must ask');
expect(t.hasAmbiguousShellSyntax('$(git reset --hard)') === true, 'subshell must be ambiguous');
expect(t.hasUnbalancedQuotes("cat '.env") === true, 'unbalanced quotes must be ambiguous');
expect(t.commandDecision('bash <(printf "git reset --hard")').decision === 'ask', 'process substitution must ask');
expect(t.commandDecision('rtk proxy find . -exec git reset --hard \\;').decision === 'ask', 'find execution proxy must ask');
expect(t.commandDecision('rtk proxy printf "git reset --hard" | rtk proxy xargs sh').decision === 'ask', 'xargs execution proxy must ask');
expect(t.commandDecision('if rtk ls .; then rtk proxy echo ok; fi').decision === 'ask', 'if control structure must ask');
expect(t.commandDecision('while rtk ls .; do rtk proxy echo ok; break; done').decision === 'ask', 'while control structure must ask');
expect(t.hasShellControlSyntax('for item in one; do rtk proxy echo "$item"; done') === true, 'for control structure must be recognized');

// Interpreter/eval-style wrappers (opaque body) must ask
expect(t.commandDecision("bash -c 'git reset --hard'").decision === 'ask', 'bash -c must ask');
expect(t.commandDecision("sh -c 'git push --force'").decision === 'ask', 'sh -c must ask');
expect(t.commandDecision("node -e \"require('fs').rmSync('.')\"").decision === 'ask', 'node -e must ask');
expect(t.commandDecision('python3 -c "import os; os.system(\'git reset --hard\')"').decision === 'ask', 'python -c must ask');
expect(t.isInterpreterOpaque(['bash', '-c', 'git reset --hard']) === true, 'isInterpreterOpaque bash -c');
expect(t.commandDecision('bash --version').decision === 'allow', 'unsupported raw shell executable may allow');
expect(t.commandDecision('rtk proxy bash --version').decision === 'allow', 'rtk proxy shell executable may allow');

// Protected paths
expect(t.isProtectedPath('.env') === true, '.env protected');
expect(t.isProtectedPath('.env.local') === true, 'root-relative .env variant protected');
expect(t.isProtectedPath('/tmp/.env.production') === true, 'absolute .env variant protected');
expect(t.isProtectedPath('src/app.env') === true, 'app.env protected');
expect(t.isProtectedPath('secrets.json') === true, 'secrets. marker');
expect(t.isProtectedPath('.git/config') === true, '.git path protected');
expect(t.isProtectedPath('src/main.ts') === false, 'normal path not protected');
expect(t.nativePathDecision('read', '.env').decision === 'ask', 'protected native read must ask for approval');
expect(t.nativePathDecision('write', '.env').decision === 'deny', 'protected native write must remain blocked');
expect(t.nativePathDecision('edit', '.env').decision === 'deny', 'protected native edit must remain blocked');
expect(t.nativePathDecision('read', 'src/main.ts').decision === 'allow', 'normal native read must allow');
const protectedReadReason = t.nativePathDecision('read', '.env').reason;
expect(await t.confirmOrBlock({ hasUI: false, ui: { confirm: async () => true } }, 'test', 'test', protectedReadReason), 'protected native read must fail closed without UI');
expect((await t.confirmOrBlock({ hasUI: true, ui: { confirm: async () => true } }, 'test', 'test', protectedReadReason)) === undefined, 'approved protected native read must allow');
expect(await t.confirmOrBlock({ hasUI: true, ui: { confirm: async () => false } }, 'test', 'test', protectedReadReason), 'denied protected native read must block');

// MCP metadata discovery and operation-level trusted managed MCP tools are autonomous;
// Firecrawl/Playwright external mutations, auth, user MCP, and unknown tools still ask.
expect(t.isMcpOrCustomTool('bash') === false, 'bash is specialized');
expect(t.isMcpOrCustomTool('write') === false, 'write is specialized');
expect(t.isMcpOrCustomTool('read') === false, 'read is specialized');
expect(t.isMcpOrCustomTool('grep') === false, 'grep is specialized discovery');
expect(t.isMcpOrCustomTool('find') === false, 'find is specialized discovery');
expect(t.isMcpOrCustomTool('ls') === false, 'ls is specialized discovery');
expect(t.isMcpOrCustomTool('mcp', { search: 'symbol' }) === false, 'MCP metadata search is autonomous');
expect(t.isMcpOrCustomTool('mcp', { describe: 'serena_find_symbol' }) === false, 'MCP metadata describe is autonomous');
expect(t.isMcpOrCustomTool('mcp', { action: 'ui-messages' }) === false, 'MCP UI messages are autonomous');
expect(t.isMcpOrCustomTool('mcp', { server: 'serena' }) === true, 'managed MCP server listing requires approval');
expect(t.isMcpOrCustomTool('mcp', { connect: 'codegraph' }) === true, 'managed MCP connect requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'serena_find_symbol', args: '{"name_path_pattern":"Thing","relative_path":"src/main.ts"}' }) === false, 'safe Serena read is autonomous');
for (const tool of [
  'serena_search_for_pattern', 'serena_get_symbols_overview', 'serena_find_symbol',
  'serena_find_referencing_symbols', 'serena_find_implementations',
  'serena_find_declaration', 'serena_get_diagnostics_for_file',
]) {
  expect(t.isMcpOrCustomTool('mcp', { tool, args: '{"relative_path":".env"}' }) === true, `${tool} protected path requires approval`);
  expect(t.isMcpOrCustomTool(tool, { relative_path: 'credentials.json' }) === true, `${tool} direct protected path requires approval`);
}
expect(t.isMcpOrCustomTool('mcp', { tool: 'serena_search_for_pattern', args: '{"substring_pattern":".+"}' }) === true, 'unrestricted Serena pattern search requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'serena_search_for_pattern', args: '{"substring_pattern":".+","paths_include_glob":"**/*"}' }) === true, 'broad-glob Serena pattern search requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'serena_search_for_pattern', args: '{"substring_pattern":"x","relative_path":"","restrict_search_to_code_files":true}' }) === true, 'empty-scope Serena pattern search requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'serena_search_for_pattern', args: '{"substring_pattern":"isSafeSerenaPatternSearch","relative_path":"pi/extensions/b-agentic-permissions.ts","restrict_search_to_code_files":true}' }) === false, 'single-file code-only Serena pattern search is autonomous');
expect(t.isMcpOrCustomTool('serena_search_for_pattern', { substring_pattern: 'x', relative_path: 'pi/extensions/b-agentic-permissions.ts', restrict_search_to_code_files: true }) === false, 'direct single-file Serena pattern search is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'serena_search_for_pattern', args: '{"substring_pattern":"x","paths_include_glob":"**/.env*"}' }) === true, 'Serena protected glob requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'serena_find_symbol', args: '{"name_path_pattern":"Thing","relative_path":"src/main.ts","newUpstreamField":true}' }) === true, 'unknown Serena arguments fail closed');
expect(t.isMcpOrCustomTool('mcp', { tool: 'serena_replace_content' }) === true, 'Serena local mutation requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'serena_replace_in_files' }) === true, 'Serena bulk replacement requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_search', args: '{"query":"safe search"}' }) === false, 'bounded firecrawl search is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_search', args: '{"query":"safe search","scrapeOptions":{"formats":["markdown"]}}' }) === false, 'bounded firecrawl search extraction is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_search', args: '{"query":"unsafe search","scrapeOptions":{"actions":[{"type":"click"}]}}' }) === true, 'firecrawl search actions require approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_search', args: '{"query":"unsafe search","scrapeOptions":{"profile":{"name":"saved","saveChanges":true}}}' }) === true, 'firecrawl search saved profile requires approval');
expect(t.isMcpOrCustomTool('firecrawl_firecrawl_search', { query: 'unsafe search', scrapeOptions: { actions: [{ type: 'click' }] } }) === true, 'direct firecrawl search actions require approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_search', args: '{"query":"unsafe search","scrapeOptions":{"newUpstreamField":true}}' }) === true, 'unknown firecrawl search extraction arguments fail closed');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_scrape', args: '{"url":"https://example.com"}' }) === false, 'bounded firecrawl scrape is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_scrape', args: '{"url":"https://example.com","actions":[{"type":"click"}]}' }) === true, 'firecrawl scrape actions require approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_scrape', args: '{"url":"https://example.com","profile":{"name":"saved","saveChanges":true}}' }) === true, 'firecrawl saved profile requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_scrape', args: '{"url":"https://example.com","newUpstreamField":true}' }) === true, 'unknown firecrawl scrape arguments fail closed');
expect(t.isMcpOrCustomTool('mcp', { tool: 'brave_search_brave_web_search' }) === false, 'brave search tools are autonomous');
for (const url of [
  'https://example.com', 'https://[2606:4700:4700::1111]/',
  'file:///tmp/.env', 'http://localhost', 'http://service.internal', 'http://devserver',
  'http://127.0.0.1', 'http://10.0.0.1', 'http://169.254.1.1', 'http://192.168.1.1',
  'http://[::1]', 'http://[fc00::1]', 'http://[fe80::1]', 'http://[::ffff:127.0.0.1]',
]) expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_navigate', args: JSON.stringify({ url }) }) === true, `${url} playwright navigate requires approval`);
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_tabs', args: '{"action":"list"}' }) === false, 'playwright tab listing is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_tabs', args: '{"action":"new","url":"https://example.com"}' }) === true, 'playwright tab creation requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_take_screenshot', args: '{"type":"png","scale":"css"}' }) === true, 'default screenshot file requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_take_screenshot', args: '{"type":"png","scale":"css","filename":"repo.png"}' }) === true, 'explicit screenshot filename requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_snapshot', args: '{}' }) === false, 'playwright snapshot response is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_snapshot', args: '{"filename":"snapshot.md"}' }) === true, 'playwright snapshot file requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_console_messages', args: '{"level":"info"}' }) === false, 'playwright console response is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_console_messages', args: '{"level":"info","filename":"console.txt"}' }) === true, 'playwright console file requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_network_requests', args: '{"static":false}' }) === false, 'playwright network response is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_network_requests', args: '{"static":false,"filename":"network.txt"}' }) === true, 'playwright network file requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_network_request', args: '{"index":1}' }) === false, 'playwright network detail response is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_network_request', args: '{"index":1,"filename":"request.txt"}' }) === true, 'playwright network detail file requires approval');
expect(t.isMcpOrCustomTool('playwright_browser_snapshot', { filename: 'snapshot.md' }) === true, 'direct playwright snapshot file requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_find' }) === false, 'playwright find is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'context7_query-docs' }) === false, 'context7 tools are autonomous');
expect(t.isMcpOrCustomTool('serena_find_symbol', { name_path_pattern: 'Thing', relative_path: 'src/main.ts' }) === false, 'direct managed MCP tool is autonomous');
expect(t.isMcpOrCustomTool('firecrawl_firecrawl_search', { query: 'safe search' }) === false, 'adapter-prefixed firecrawl tool is autonomous');
expect(t.isMcpOrCustomTool('codegraph_codegraph_explore') === false, 'direct codegraph tool is autonomous');
// External-mutation Firecrawl/Playwright tools stay gated.
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_agent' }) === true, 'firecrawl agent requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_crawl' }) === true, 'firecrawl crawl requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_interact' }) === true, 'firecrawl interact requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_interact_stop' }) === true, 'firecrawl interact stop requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_parse' }) === true, 'firecrawl parse (local upload) requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_search_feedback' }) === true, 'firecrawl search feedback requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_feedback' }) === true, 'firecrawl feedback requires approval');
expect(t.isMcpOrCustomTool('firecrawl_firecrawl_agent') === true, 'direct firecrawl agent requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_monitor_create' }) === true, 'firecrawl monitor requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_click' }) === true, 'playwright click requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_type' }) === true, 'playwright type requires approval');
expect(t.isMcpOrCustomTool('browser_click') === true, 'direct browser_click requires approval');
// Explicit managed server must not override a sensitive tool origin.
expect(t.isMcpOrCustomTool('mcp', { server: 'serena', tool: 'firecrawl_agent' }) === true, 'mismatched server/tool fails closed');
expect(t.isMcpOrCustomTool('mcp', { server: 'serena', tool: 'user_tool' }) === true, 'managed server cannot launder unknown tool');
expect(t.isMcpOrCustomTool('mcp', { server: 'firecrawl', tool: 'firecrawl_search', args: '{"query":"safe search"}' }) === false, 'matching server/tool remains trusted');
// connect must not short-circuit past a sensitive tool selector.
expect(t.isMcpOrCustomTool('mcp', { connect: 'firecrawl', tool: 'firecrawl_agent' }) === true, 'connect+tool mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { connect: 'serena', tool: 'firecrawl_agent' }) === true, 'connect cannot launder foreign tool');
expect(t.isMcpOrCustomTool('mcp', { connect: 'firecrawl', action: 'auth-start' }) === true, 'connect+auth mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { connect: 'firecrawl', server: 'user-server' }) === true, 'connect+server mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { connect: 'firecrawl', search: 'x' }) === true, 'connect+search mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { connect: 'firecrawl', describe: 'firecrawl_agent' }) === true, 'connect+describe mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { connect: 'firecrawl' }) === true, 'pure managed connect follows gateway lifecycle policy');
expect(t.isMcpOrCustomTool('mcp', { search: 'x', tool: 'firecrawl_agent' }) === true, 'metadata+tool mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { search: 'x', action: 'auth-start' }) === true, 'search+auth mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { describe: 'firecrawl_search', action: 'auth-complete' }) === true, 'describe+auth mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { search: 'x', describe: 'firecrawl_search' }) === true, 'multiple metadata selectors fail closed');
expect(t.isMcpOrCustomTool('mcp', { action: 'ui-messages', search: 'x' }) === true, 'UI action+search mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { action: 'auth-start', server: 'context7' }) === true, 'MCP auth action requires approval');
expect(t.isMcpOrCustomTool('mcp', { server: 'user-server' }) === true, 'user MCP server requires approval');
expect(t.isMcpOrCustomTool('mcp', { connect: 'user-server' }) === true, 'user MCP connect requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'user_tool', server: 'user-server' }) === true, 'user MCP tool requires approval');
expect(t.isMcpOrCustomTool('mcp') === true, 'unscoped MCP proxy call requires approval');
expect(t.isMcpOrCustomTool('some-extension-tool') === true, 'unknown tool is custom');
expect(t.isTrustedManagedMcpCall('mcp', { tool: 'serena_find_symbol', args: '{"name_path_pattern":"Thing","relative_path":"src/main.ts"}' }) === true, 'trusted managed helper');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_search', { query: 'safe search' }) === true, 'firecrawl search trusted helper');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_interact') === false, 'firecrawl interact not trusted helper');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_interact_stop') === false, 'firecrawl interact stop not trusted helper');
expect(t.isTrustedManagedTool('playwright', 'browser_click') === false, 'playwright click not trusted helper');
expect(t.SPECIALIZED_TOOLS.has('grep') && t.SPECIALIZED_TOOLS.has('find') && t.SPECIALIZED_TOOLS.has('ls'), 'discovery tools specialized');
expect(t.SERENA_TRUSTED_TOOLS.has('serena_find_symbol') && t.MANAGED_MCP_SERVERS.has('playwright'), 'managed MCP sets present');
expect(t.MCP_TRUSTED_GATEWAY_OPERATIONS.has('search') && !t.MCP_TRUSTED_GATEWAY_OPERATIONS.has('connect'), 'gateway policy allowlist present');
expect(t.isTrustedManagedTool('serena', 'serena_replace_content') === false, 'Serena local mutation not trusted helper');
expect(t.FIRECRAWL_TRUSTED_TOOLS.has('firecrawl_search'), 'firecrawl allowlist present');
expect(t.PLAYWRIGHT_TRUSTED_TOOLS.has('browser_snapshot'), 'playwright allowlist present');

console.log('pi permission behavioral fixtures ok');
NODE

	# Source-backed uninstall removes managed content only.
	expect_install_status 0 "$sandbox" "$snapshot_repo" --uninstall
	assert_no_path "$sandbox/home/.pi/agent/skills/b-plan"
	assert_no_path "$sandbox/home/.pi/agent/b-agentic/install.json"
	assert_no_path "$sandbox/home/.pi/agent/extensions/b-agentic-permissions.ts"
	# User MCP entries would be preserved by merge cleanup; managed-only install removes mcp.json entirely.
}
