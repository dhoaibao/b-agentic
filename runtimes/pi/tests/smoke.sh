# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/pi"
  local sandbox_adapter="$WORK_DIR/pi-adapter"
  local sandbox_preserve="$WORK_DIR/pi-preserve"
  local sandbox_replace="$WORK_DIR/pi-replace"
  local sandbox_mcp_merge="$WORK_DIR/pi-mcp-merge"
  mkdir -p "$sandbox/home" "$sandbox_adapter/home" "$sandbox_preserve/home" "$sandbox_replace/home" "$sandbox_mcp_merge/home"

  # Core install layout without adapter package.
  expect_install_status 0 "$sandbox" "$snapshot_repo" --runtime=pi
  assert_file "$sandbox/home/.pi/agent/AGENTS.md"
  assert_file "$sandbox/home/.pi/agent/skills/b-plan/SKILL.md"
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

  # Adapter-installed path via env opt-in (mock pi records install).
  # expect_install_status hardcodes env; invoke installer directly for adapter opt-in.
  local smoke_path
  smoke_path="$(smoke_runtime_cli_path "$sandbox_adapter")"
  HOME="$sandbox_adapter/home" \
  PATH="$smoke_path" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_adapter/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RUNTIME_CLI=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  B_AGENTIC_INSTALL_PI_MCP_ADAPTER=Y \
  bash "$ROOT_DIR/install.sh" --runtime=pi >/dev/null 2>&1
  assert_file "$sandbox_adapter/home/.pi/agent/b-agentic/install.json"
  assert_contains "$sandbox_adapter/home/.pi/agent/b-agentic/install.json" '"mcpAdapterState": "ready"'
  assert_file "$sandbox_adapter/smoke-bin/pi-install.log"
  assert_contains "$sandbox_adapter/smoke-bin/pi-install.log" 'npm:pi-mcp-adapter'

  # Preserve user-owned kernel.
  mkdir -p "$sandbox_preserve/home/.pi/agent"
  printf 'user-owned pi kernel\n' > "$sandbox_preserve/home/.pi/agent/AGENTS.md"
  expect_install_status 2 "$sandbox_preserve" "$snapshot_repo" --runtime=pi
  assert_file "$sandbox_preserve/home/.pi/agent/AGENTS.md"
  assert_contains "$sandbox_preserve/home/.pi/agent/AGENTS.md" 'user-owned pi kernel'
  assert_file "$sandbox_preserve/home/.pi/agent/b-agentic/install.json"
  assert_contains "$sandbox_preserve/home/.pi/agent/b-agentic/install.json" '"activationState": "pending"'

  # --replace-memory overwrites user kernel.
  mkdir -p "$sandbox_replace/home/.pi/agent"
  printf 'user-owned pi kernel\n' > "$sandbox_replace/home/.pi/agent/AGENTS.md"
  expect_install_status 0 "$sandbox_replace" "$snapshot_repo" --runtime=pi --replace-memory
  assert_contains "$sandbox_replace/home/.pi/agent/AGENTS.md" 'b-agentic-managed'
  assert_not_contains "$sandbox_replace/home/.pi/agent/AGENTS.md" 'user-owned pi kernel'

  # MCP merge preserves unrelated servers.
  mkdir -p "$sandbox_mcp_merge/home/.pi/agent"
  cat > "$sandbox_mcp_merge/home/.pi/agent/mcp.json" <<'EOF'
{
  "mcpServers": {
    "user-server": {
      "command": "echo",
      "args": ["user"]
    }
  }
}
EOF
  expect_install_status 0 "$sandbox_mcp_merge" "$snapshot_repo" --runtime=pi
  assert_contains "$sandbox_mcp_merge/home/.pi/agent/mcp.json" '"user-server"'
  assert_contains "$sandbox_mcp_merge/home/.pi/agent/mcp.json" '"serena"'

  # Behavioral permission coverage via node --experimental-strip-types (no Pi runtime).
  if command -v node >/dev/null 2>&1; then
    ROOT_DIR="$ROOT_DIR" node --experimental-strip-types --input-type=module - <<'NODE'
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.env.ROOT_DIR || process.cwd();
const modPath = path.join(root, 'runtimes/pi/extensions/b-agentic-permissions.ts');
const mod = await import(pathToFileURL(modPath).href);
const t = mod.__test__;
if (!t) {
  console.error('permission extension missing __test__ exports');
  process.exit(1);
}

function expect(cond, msg) {
  if (!cond) {
    console.error(msg);
    process.exit(1);
  }
}

// Compound commands and wrappers
expect(t.commandDecision('cd repo && git reset --hard').decision === 'deny', 'compound reset --hard must deny');
expect(t.commandDecision('git -C repo reset --hard').decision === 'deny', 'git -C reset --hard must deny');
expect(t.commandDecision('/usr/bin/git reset --hard').decision === 'deny', 'path-qualified git reset --hard must deny');
expect(t.commandDecision('/usr/bin/npm install lodash').decision === 'ask', 'path-qualified npm install must ask');
expect(t.commandDecision('/bin/rm -rf /tmp/x').decision === 'ask', 'path-qualified rm -rf must ask');
expect(t.commandDecision('/usr/bin/printf x').decision === 'allow', 'benign path-qualified command must allow');
expect(t.commandDecision("git -c alias.wipe='reset --hard' wipe").decision === 'ask', 'inline Git alias invocation must ask');
expect(t.commandDecision('env X=1 npm install lodash').decision === 'ask', 'env-wrapped npm install must ask');
for (const command of ['env', 'env -i', 'env X=1']) {
  expect(t.commandDecision(command).decision === 'ask', `${command} must require rtk env`);
}
expect(t.commandDecision('rtk env').decision === 'allow', 'rtk env must allow');
expect(t.commandDecision('rtk git commit -m x').decision === 'ask', 'rtk git commit must ask');
expect(t.commandDecision('rtk proxy git reset --hard').decision === 'deny', 'rtk proxy must preserve deny decisions');
expect(t.commandDecision('rtk proxy grep needle src/main.ts').decision === 'allow', 'rtk proxy must satisfy RTK requirement');
expect(t.commandDecision('sudo git push --force origin main').decision === 'deny', 'sudo force push must deny');
expect(t.commandDecision('/usr/bin/env X=1 git reset --hard').decision === 'deny', 'path-qualified env must not bypass reset denial');
expect(t.commandDecision('/usr/bin/sudo git push --force origin main').decision === 'deny', 'path-qualified sudo must not bypass force-push denial');
expect(t.commandDecision('/opt/bin/rtk git reset --hard').decision === 'deny', 'path-qualified RTK must not bypass reset denial');
expect(t.commandDecision('rtk git --git-dir repo/.git reset --hard').decision === 'deny', 'Git option value must not hide reset denial');
expect(t.commandDecision('rtk git --git-dir repo/.git --config-env=alias.wipe=ALIAS wipe').decision === 'ask', 'Git config-env alias after option value must ask');
expect(t.commandDecision('git push -f origin main').decision === 'deny', 'git push -f must deny');
expect(t.commandDecision('rm -rf /tmp/x').decision === 'ask', 'rm -rf must ask');
expect(t.commandDecision('ls -la').decision === 'ask', 'direct ls must require approval to use RTK or eza/exa');
expect(t.commandDecision('rtk ls -la').decision === 'allow', 'rtk ls must allow');
expect(t.commandDecision('env X=1 rtk ls -la').decision === 'allow', 'env-wrapped rtk ls must allow');
expect(t.commandDecision('command rtk ls -la').decision === 'allow', 'command-wrapped rtk ls must allow');
expect(t.commandDecision('sudo rtk ls -la').decision === 'allow', 'sudo-wrapped rtk ls must allow');
expect(t.commandDecision('env -u FOO rtk ls -la').decision === 'allow', 'env -u wrapped rtk ls must allow');
expect(t.commandDecision('env -S ls').decision === 'ask', 'env -S legacy command must be approval-gated');
expect(t.commandDecision('env -S "grep needle src/main.ts"').decision === 'ask', 'env -S command string must be approval-gated');
expect(t.commandDecision('grep needle src/main.ts').decision === 'ask', 'direct grep must require approval to use RTK or rg');
expect(t.commandDecision('python3 -m json.tool package.json').decision === 'ask', 'python json.tool must require approval to use jq');
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
for (const command of ['npm view lodash', 'pnpm list', 'yarn why lodash', 'bun --version', 'cargo search serde']) {
  expect(t.commandDecision(command).decision === 'ask', `${command} must require RTK`);
}
for (const command of ['rtk npm view lodash', 'rtk pnpm list', 'rtk yarn why lodash', 'rtk bun --version', 'rtk cargo search serde', 'rtk pytest -q']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} must preserve supported RTK use`);
}
const rtkSupportedCommands = [
  'ls', 'tree', 'git', 'gh', 'glab', 'aws', 'psql', 'pnpm', 'find', 'diff',
  'dotnet', 'docker', 'kubectl', 'oc', 'grep', 'rg', 'wget', 'wc',
  'jest', 'vitest', 'prisma', 'tsc', 'next', 'lint', 'prettier', 'format',
  'playwright', 'cargo', 'npm', 'npx', 'yarn', 'bun', 'curl', 'ruff', 'pytest', 'mypy',
  'rake', 'rubocop', 'rspec', 'pip', 'go', 'gt', 'golangci-lint', 'gradlew', 'mvn',
];
for (const command of rtkSupportedCommands) {
  expect(t.RTK_REQUIRED_COMMANDS.has(command), `${command} must be covered by the RTK policy`);
  expect(t.commandDecision(`${command} --version`).decision === 'ask', `${command} must require RTK`);
}
expect(t.commandDecision('pip show requests').decision === 'ask', 'pip must require RTK');
for (const command of ['poetry show', 'uv --version']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} remains allowed because RTK does not support it`);
}
expect(t.commandDecision('printf x').decision === 'allow', 'unrelated shell command must allow');
expect(t.commandDecision('printf x\ngit reset --hard').decision === 'deny', 'newline-separated reset --hard must deny');
expect(t.commandDecision('printf x\r\ngit reset --hard').decision === 'deny', 'CRLF-separated reset --hard must deny');
expect(t.commandDecision('printf x\ncat .env').decision === 'ask', 'newline-separated protected path must ask');
expect(t.commandDecision('printf x\nprintf y').decision === 'allow', 'benign multiline commands must allow');
expect(t.commandDecision('cat .env').decision === 'ask', 'bare protected shell path must ask');
expect(t.commandDecision('cat .env.local').decision === 'ask', 'root-relative protected shell path variant must ask');
expect(t.commandDecision('cat /tmp/.env.production').decision === 'ask', 'absolute protected shell path variant must ask');
expect(t.commandDecision('rtk cat ./config/../.env.local').decision === 'ask', 'rtk-wrapped protected shell path variant must ask');
expect(t.commandDecision('ls src && cat credentials.json').decision === 'ask', 'compound protected shell path must ask');
expect(t.commandDecision('cat src/main.ts').decision === 'ask', 'direct cat must require approval to use bat/batcat');
expect(t.commandDecision('cat "$SECRET_FILE"').decision === 'ask', 'variable shell paths must fail closed');
expect(t.commandDecision("cat '.env").decision === 'ask', 'unbalanced shell quotes must fail closed');

// Ambiguous shell
expect(t.commandDecision('eval "$(echo git reset --hard)"').decision === 'ask', 'eval must ask');
expect(t.hasAmbiguousShellSyntax('$(git reset --hard)') === true, 'subshell must be ambiguous');
expect(t.hasUnbalancedQuotes("cat '.env") === true, 'unbalanced quotes must be ambiguous');

// Interpreter/eval-style wrappers (opaque body) must ask
expect(t.commandDecision("bash -c 'git reset --hard'").decision === 'ask', 'bash -c must ask');
expect(t.commandDecision("sh -c 'git push --force'").decision === 'ask', 'sh -c must ask');
expect(t.commandDecision("node -e \"require('fs').rmSync('.')\"").decision === 'ask', 'node -e must ask');
expect(t.commandDecision('python3 -c "import os; os.system(\'git reset --hard\')"').decision === 'ask', 'python -c must ask');
expect(t.isInterpreterOpaque(['bash', '-c', 'git reset --hard']) === true, 'isInterpreterOpaque bash -c');
expect(t.commandDecision('bash --version').decision === 'allow', 'bash without -c may allow');

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
expect(t.isMcpOrCustomTool('mcp', { server: 'serena' }) === false, 'managed MCP server listing is autonomous');
expect(t.isMcpOrCustomTool('mcp', { connect: 'codegraph' }) === false, 'managed MCP connect is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'serena_find_symbol' }) === false, 'classified Serena read is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'serena_replace_content' }) === true, 'Serena local mutation requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_search' }) === false, 'firecrawl search is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_scrape' }) === false, 'firecrawl scrape is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'brave_search_brave_web_search' }) === false, 'brave search tools are autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_navigate' }) === false, 'playwright navigate is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'playwright_browser_snapshot' }) === false, 'playwright snapshot is autonomous');
expect(t.isMcpOrCustomTool('mcp', { tool: 'context7_query-docs' }) === false, 'context7 tools are autonomous');
expect(t.isMcpOrCustomTool('serena_find_symbol') === false, 'direct managed MCP tool is autonomous');
expect(t.isMcpOrCustomTool('firecrawl_firecrawl_search') === false, 'adapter-prefixed firecrawl tool is autonomous');
expect(t.isMcpOrCustomTool('codegraph_codegraph_explore') === false, 'direct codegraph tool is autonomous');
// External-mutation Firecrawl/Playwright tools stay gated.
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_agent' }) === true, 'firecrawl agent requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_crawl' }) === true, 'firecrawl crawl requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'firecrawl_interact' }) === true, 'firecrawl interact requires approval');
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
expect(t.isMcpOrCustomTool('mcp', { server: 'firecrawl', tool: 'firecrawl_search' }) === false, 'matching server/tool remains trusted');
// connect must not short-circuit past a sensitive tool selector.
expect(t.isMcpOrCustomTool('mcp', { connect: 'firecrawl', tool: 'firecrawl_agent' }) === true, 'connect+tool mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { connect: 'serena', tool: 'firecrawl_agent' }) === true, 'connect cannot launder foreign tool');
expect(t.isMcpOrCustomTool('mcp', { connect: 'firecrawl', action: 'auth-start' }) === true, 'connect+auth mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { connect: 'firecrawl', server: 'user-server' }) === true, 'connect+server mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { connect: 'firecrawl', search: 'x' }) === true, 'connect+search mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { connect: 'firecrawl', describe: 'firecrawl_agent' }) === true, 'connect+describe mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { connect: 'firecrawl' }) === false, 'pure managed connect remains autonomous');
expect(t.isMcpOrCustomTool('mcp', { search: 'x', tool: 'firecrawl_agent' }) === true, 'metadata+tool mixed selector fails closed');
expect(t.isMcpOrCustomTool('mcp', { action: 'auth-start', server: 'context7' }) === true, 'MCP auth action requires approval');
expect(t.isMcpOrCustomTool('mcp', { server: 'user-server' }) === true, 'user MCP server requires approval');
expect(t.isMcpOrCustomTool('mcp', { connect: 'user-server' }) === true, 'user MCP connect requires approval');
expect(t.isMcpOrCustomTool('mcp', { tool: 'user_tool', server: 'user-server' }) === true, 'user MCP tool requires approval');
expect(t.isMcpOrCustomTool('mcp') === true, 'unscoped MCP proxy call requires approval');
expect(t.isMcpOrCustomTool('some-extension-tool') === true, 'unknown tool is custom');
expect(t.isTrustedManagedMcpCall('mcp', { tool: 'serena_find_symbol' }) === true, 'trusted managed helper');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_search') === true, 'firecrawl search trusted helper');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_interact') === false, 'firecrawl interact not trusted helper');
expect(t.isTrustedManagedTool('playwright', 'browser_click') === false, 'playwright click not trusted helper');
expect(t.SPECIALIZED_TOOLS.has('grep') && t.SPECIALIZED_TOOLS.has('find') && t.SPECIALIZED_TOOLS.has('ls'), 'discovery tools specialized');
expect(t.SERENA_TRUSTED_TOOLS.has('serena_find_symbol') && t.MANAGED_MCP_SERVERS.has('playwright'), 'managed MCP sets present');
expect(t.isTrustedManagedTool('serena', 'serena_replace_content') === false, 'Serena local mutation not trusted helper');
expect(t.FIRECRAWL_TRUSTED_TOOLS.has('firecrawl_search'), 'firecrawl allowlist present');
expect(t.PLAYWRIGHT_TRUSTED_TOOLS.has('browser_snapshot'), 'playwright allowlist present');

console.log('pi permission behavioral fixtures ok');
NODE
  fi

  # Source-backed uninstall removes managed content only.
  expect_install_status 0 "$sandbox" "$snapshot_repo" --runtime=pi --uninstall
  assert_no_path "$sandbox/home/.pi/agent/skills/b-plan"
  assert_no_path "$sandbox/home/.pi/agent/b-agentic/install.json"
  assert_no_path "$sandbox/home/.pi/agent/extensions/b-agentic-permissions.ts"
  # User MCP entries would be preserved by merge cleanup; managed-only install removes mcp.json entirely.
}
