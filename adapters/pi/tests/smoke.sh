# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "error: this script is sourced by tests/smoke/install.sh" >&2
	exit 1
fi

run_pi_permission_behavioral_fixture() {
	local sandbox="$1"
	# Behavioral permission coverage via node --experimental-strip-types (no Pi runtime).
	# Prefer the repository's pinned Pi dependency for resolver-contract assertions.
	local pi_package_root="$ROOT_DIR/adapters/pi/node_modules/@earendil-works/pi-coding-agent"
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
import { spawn } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.env.ROOT_DIR || process.cwd();
process.env.B_AGENTIC_DIR = path.join(root, '.b-agentic-test');
const installedRoot = path.join(process.env.PI_TEST_HOME || '', '.pi/agent/extensions');
const packageLinks = path.join(process.env.PI_CODING_AGENT_DIR || '', 'node_modules', '@earendil-works');
const piPackageRoot = process.env.PI_PACKAGE_ROOT;
const piPathUtils = piPackageRoot
  ? await import(pathToFileURL(path.join(piPackageRoot, 'dist/core/tools/path-utils.js')).href)
  : null;
if (piPathUtils) {
  const piVersion = JSON.parse(readFileSync(path.join(piPackageRoot, 'package.json'), 'utf8')).version;
  const source = process.env.PI_PACKAGE_SOURCE;
  const label = source === 'repo-local pinned dependency'
    ? 'native resolver contract'
    : 'native resolver fallback gap (not pinned parity)';
  console.log(`${label}: ${source} Pi ${piVersion}`);
} else {
  console.warn('native resolver contract skipped: no Pi package anchor');
}
if (process.env.PI_PACKAGE_ROOT) {
  mkdirSync(packageLinks, { recursive: true });
  for (const [name, target] of [
    ['pi-coding-agent', process.env.PI_PACKAGE_ROOT],
    ['pi-tui', path.join(process.env.PI_PACKAGE_ROOT, 'node_modules/@earendil-works/pi-tui')],
  ]) {
    const link = path.join(packageLinks, name);
    if (!existsSync(link)) symlinkSync(target, link, 'junction');
  }
  const { setCapabilities } = await import(pathToFileURL(path.join(process.env.PI_CODING_AGENT_DIR, 'node_modules/@earendil-works/pi-tui/dist/index.js')).href);
  setCapabilities({ images: null, trueColor: true, hyperlinks: true });
}
const extensionModules = await Promise.all([
  'b-agentic-permissions.ts', 'b-agentic-mcp-permissions.ts', 'b-agentic-auto-mode.ts', 'b-agentic-sync.ts',
  'b-agentic-preview-markdown.ts', 'b-agentic-status.ts',
].map((name) => import(pathToFileURL(path.join(installedRoot, name)).href)));
for (const name of ['shell.ts', 'mcp.ts', 'permissions-data.ts', 'worker.ts', 'state.ts', 'auto.ts', 'capabilities.ts', 'status.ts']) {
  await import(pathToFileURL(path.join(installedRoot, 'b-agentic-support', name)).href);
}
const autoStateTest = await import(pathToFileURL(path.join(installedRoot, 'b-agentic-support', 'state.ts')).href);
if (process.env.PI_PACKAGE_ROOT) {
  const { initTheme } = await import(pathToFileURL(path.join(process.env.PI_PACKAGE_ROOT, 'dist/index.js')).href);
  initTheme('dark');
}
const mod = extensionModules[0];
const t = mod.__test__;
const statusTest = extensionModules[5].__test__;
if (!t || !statusTest) {
  console.error('permission or status extension missing __test__ exports');
  process.exit(1);
}
const handlers = {};
const registrations = {};
const commands = {};
const tools = {};
const shortcuts = {};
const flags = {};
const flagDefinitions = {};
const persistedEntries = [];
const branchEntries = [];
let activeTools = ['read', 'bash', 'edit', 'write', 'recall', 'intercom', 'mcp', 'mcpScript'];
let activeModel = { provider: 'anthropic', id: 'claude-sonnet-4-5' };
let activeThinkingLevel = 'high';
const statuses = [];
const notifications = [];
const terminalTitles = [];
const sentMessages = [];
const sentUserMessages = [];
let mcpApprovalHandler;
let intercomChannelRegistration;
const executedCommands = [];
const extensionHost = {
  on(eventName, handler) {
    (registrations[eventName] ||= []).push(handler);
    handlers[eventName] = async (...args) => {
      let result;
      for (const registered of registrations[eventName] || []) {
        const next = await registered(...args);
        if (eventName === 'before_agent_start' && next) result = { ...result, ...next };
        else if (next) return next;
      }
      return result;
    };
  },
  registerFlag(name, definition) { flagDefinitions[name] = definition; },
  getFlag(name) { return flags[name]; },
  registerCommand(name, definition) { commands[name] = definition; },
  registerShortcut(name, definition) { shortcuts[name] = definition; },
  registerTool(definition) { tools[definition.name] = definition; },
  async exec(command, args, options) {
    executedCommands.push({ command, args, options });
    return { code: 0, stdout: '', stderr: '', killed: false };
  },
  getActiveTools() { return [...activeTools]; },
  setActiveTools(names) { activeTools = [...names]; },
  async setModel(model) { activeModel = model; return true; },
  getThinkingLevel() { return activeThinkingLevel; },
  setThinkingLevel(level) { activeThinkingLevel = level; },
  sendMessage(message, options) { sentMessages.push({ message, options }); },
  sendUserMessage(content, options) { sentUserMessages.push({ content, options }); },
  appendEntry(customType, data) {
    const entry = { type: 'custom', customType, data };
    persistedEntries.push(entry);
    branchEntries.push(entry);
  },
  events: {
    on(channel, handler) {
      if (channel === 'pi-mcp-adapter:tool-approval-request') mcpApprovalHandler = handler;
      return () => {};
    },
    emit(channel, value) {
      if (channel === 'intercom:extension-register') intercomChannelRegistration = value;
    },
  },
};
for (const extension of extensionModules) extension.default(extensionHost);
expect(!tools.b_consult && !commands['b-consult-model'], 'retired consult tool and model command must not register');
const previewModule = extensionModules[4];
const previewTest = previewModule.__test__;
const previewTool = tools.preview_markdown;
const previewShortcut = shortcuts['ctrl+shift+m'];
const previewRenderCommand = commands['preview-markdown:render'];
const previewThemeCommand = commands['preview-markdown:theme'];
const previewListCommand = commands['preview-markdown:list'];
if (!previewTool || !previewTest || !previewShortcut || !previewRenderCommand || !previewThemeCommand || !previewListCommand || commands['preview-markdown-theme']) throw new Error('preview_markdown extension must register its tool, shortcut, direct command family, and test surface');
expect(previewShortcut.description.includes('latest Markdown preview source'), 'preview shortcut must describe latest source copying');
expect(previewTool.promptSnippet.includes('inline'), 'preview_markdown must advertise inline Markdown previews');
expect(previewTool.promptGuidelines.some((line) => line.includes('ctrl+shift+m')), 'preview_markdown prompt metadata must describe the source-copy shortcut');
expect(previewTool.parameters.type === 'object' && previewTool.parameters.properties.markdown, 'preview_markdown schema must require Markdown');
const nonTuiResult = await previewTool.execute('preview-1', { markdown: '# Hello' }, undefined, undefined, {
  mode: 'print',
  ui: { custom: async () => { throw new Error('non-TUI preview must not open custom UI'); } },
});
expect(nonTuiResult.details.interactive === false && nonTuiResult.content[0].text.includes('only available in Pi TUI'), 'preview_markdown must return a concise non-TUI fallback');
const shortcutNotifications = [];
const shortcutContext = {
  ui: { notify(message, level) { shortcutNotifications.push({ message, level }); } },
};
await previewShortcut.handler(shortcutContext);
expect(shortcutNotifications.at(-1)?.message === 'No Markdown preview source is available to copy' && shortcutNotifications.at(-1)?.level === 'warning', 'shortcut must guard when no TUI preview exists');
const previewAgentDir = process.env.PI_CODING_AGENT_DIR;
const previewThemePath = path.join(previewAgentDir, 'b-agentic/preview-theme.json');
const previewThemeNotifications = [];
let previewThemeSelection;
let previewThemeMenuOptions = [];
const previewThemeContext = {
  hasUI: true,
  ui: {
    async select(title, options) {
      expect(title === 'Select preview theme', 'preview-markdown:theme must use a native selection title');
      previewThemeMenuOptions = [...options];
      return previewThemeSelection;
    },
    notify(message, level) { previewThemeNotifications.push({ message, level }); },
  },
};
const previewSource = readFileSync(path.join(root, 'adapters/pi/packages/preview-markdown/extensions/b-agentic-preview-markdown.ts'), 'utf8');
for (const marker of ['renderResult', 'new Markdown', 'preserveOrderedListMarkers', 'registerShortcut', 'ctrl+shift+m', 'copyToClipboard', 'PreviewCard', 'PALETTE', '#1e2030', '#222436', '#191b29', '#2f334d', '#c8d3f5', '#828bb8', '#636da6', '#3b4261', '#82aaff', '#86e1fc', '#ffc777', '#c3e88d', '#c099ff', '#65bcff', '#d5d6db', '#e1e2e7', '#c4c8da', '#dcdfe4', '#3760bf', '#6172b0', '#848cb5', '#8990b3', '#2e7de9', '#007197', '#8c6c3e', '#587539', 'getAgentDir', 'preview-markdown:render', 'preview-markdown:theme', 'preview-markdown:list', 'MAX_PREVIEW_HISTORY', 'currentPreviewTheme', 'previewRowInvalidators', 'clearPreviewRowInvalidators', 'loadCurrentPreviewTheme', 'session_shutdown', 'Tokyo Night Day', 'preview-theme.json', 'FIXED_PAGE_BACKGROUND', 'FIXED_CARD_BACKGROUND', 'fixedCodeSurface', 'fixedCodeBlockBorder', 'Ctrl+Shift+M  Copy source', 'Markdown preview rendered inline']) {
  expect(previewSource.includes(marker), `preview inline source must include ${marker}`);
}
for (const obsolete of ['ctx.ui.custom', 'onKey', 'handleInput', 'MarkdownPreviewComponent', 'createMarkdownPreviewComponent', 'Original Markdown source', 'preview-markdown-theme']) {
  expect(!previewSource.includes(obsolete), `preview inline source must not include ${obsolete}`);
}
const inlineMarkdown = '# Original Markdown\n\n**exact source**\n\n## Syntax coverage\n\n_emphasis_, **strong**, and ~~strike~~.\n\n- item\n  - nested item\n1. ordered item\n\n[docs](https://example.com) and https://example.org with `inline code`.\n\n> quoted line\n\n---\n\n| Col A | Col B |\n| --- | --- |\n| cell one | cell two |\n\nThis deliberately long paragraph exercises wrapping across narrow and normal preview widths without changing the original source.\n\n```js\nconst value = 1;\nsecond line\n```';
let customCalls = 0;
const inlineResult = await previewTool.execute('preview-2', { markdown: inlineMarkdown, title: 'Inline example' }, undefined, undefined, {
  mode: 'tui',
  ui: { custom: async () => { customCalls += 1; throw new Error('inline preview must not open custom UI'); } },
});
expect(customCalls === 0, 'inline preview must not open custom UI');
expect(inlineResult.content[0].text === 'Markdown preview rendered inline.', 'inline preview result must keep LLM content concise');
expect(inlineResult.details.markdown === inlineMarkdown && inlineResult.details.title === 'Inline example' && inlineResult.details.theme === 'moon', 'inline preview result must retain source, title, and default Moon theme details');
expect(!existsSync(previewThemePath), 'missing preview theme config must default to Moon without creating a file');
const copiedSources = [];
await previewTest.copyLatestPreviewSource(shortcutContext, async (source) => { copiedSources.push(source); });
expect(copiedSources.length === 1 && copiedSources[0] === inlineMarkdown, 'shortcut copy must use the exact latest preview source');
expect(shortcutNotifications.at(-1)?.message === 'Latest Markdown preview source copied to clipboard' && shortcutNotifications.at(-1)?.level === 'info', 'shortcut copy success must notify');
await previewTest.copyLatestPreviewSource(shortcutContext, async () => { throw new Error('clipboard unavailable'); });
expect(shortcutNotifications.at(-1)?.message === 'Failed to copy latest Markdown preview source to clipboard' && shortcutNotifications.at(-1)?.level === 'error', 'shortcut copy failure must notify without throwing');
const previewRenderNotifications = [];
const previewRenderContext = {
  ui: { notify(message, level) { previewRenderNotifications.push({ message, level }); } },
};
const sentUserMessageCount = sentUserMessages.length;
await previewRenderCommand.handler('build a release preview', previewRenderContext);
const renderMessage = sentUserMessages.at(-1);
expect(sentUserMessages.length === sentUserMessageCount + 1 && renderMessage?.content.includes('build a release preview') && renderMessage?.content.includes('preview_markdown') && renderMessage?.options?.deliverAs === 'followUp', 'render command must forward the prompt with safe follow-up delivery and preview instructions');
await previewRenderCommand.handler('   ', previewRenderContext);
expect(sentUserMessages.length === sentUserMessageCount + 1 && previewRenderNotifications.at(-1)?.message === 'Usage: /preview-markdown:render <prompt>' && previewRenderNotifications.at(-1)?.level === 'error', 'render command must reject empty prompts with concise usage');
const previewBranch = [
  {
    type: 'message',
    message: { role: 'toolResult', toolName: 'preview_markdown', isError: true, details: { markdown: '# Failed preview', title: 'Failed preview', theme: 'moon' } },
  },
  ...Array.from({ length: previewTest.MAX_PREVIEW_HISTORY + 1 }, (_, index) => ({
    type: 'message',
    message: { role: 'toolResult', toolName: 'preview_markdown', isError: false, details: { markdown: `# Preview ${index}`, title: `Preview ${index}`, theme: 'moon' } },
  })),
];
const previewListNotifications = [];
let previewListTitle;
let previewListOptions;
let selectPreview = false;
const previewListContext = {
  hasUI: true,
  sessionManager: { getBranch: () => [...previewBranch] },
  ui: {
    async select(title, options) {
      previewListTitle = title;
      previewListOptions = [...options];
      return selectPreview ? options.at(-1) : undefined;
    },
    notify(message, level) { previewListNotifications.push({ message, level }); },
  },
};
await previewListCommand.handler('', previewListContext);
expect(previewTest.MAX_PREVIEW_HISTORY === 20 && previewListTitle === 'Select Markdown preview' && previewListOptions.length === 20 && previewListOptions[0] === '1. Preview 1' && previewListOptions.at(-1) === '20. Preview 20' && !previewListOptions.some((option) => option.includes('Preview 0') || option.includes('Failed preview')), 'list command must cap active-branch history to the 20 most recent successful previews');
selectPreview = true;
let selectedListSource;
await previewTest.listPreviewSources(previewListContext, async (source) => { selectedListSource = source; });
expect(selectedListSource === '# Preview 20' && previewListNotifications.at(-1)?.message === 'Markdown preview source copied to clipboard' && previewListNotifications.at(-1)?.level === 'info', 'newest list selection must copy the exact original Markdown and report success');
await previewTest.listPreviewSources(previewListContext, async () => { throw new Error('clipboard unavailable'); });
expect(previewListNotifications.at(-1)?.message === 'Failed to copy Markdown preview source to clipboard' && previewListNotifications.at(-1)?.level === 'error', 'list copy failure must report an error');
previewBranch.length = 0;
await previewListCommand.handler('', previewListContext);
expect(previewListNotifications.at(-1)?.message === 'No Markdown previews found on this branch' && previewListNotifications.at(-1)?.level === 'warning', 'list command must report an empty active branch');
const fakeTheme = {
  fg: (_color, text) => text,
  bold: (text) => text,
};
let inlineInvalidationCount = 0;
const inlineRenderContext = { toolCallId: 'preview-2', invalidate() { inlineInvalidationCount += 1; } };
const renderedPreview = previewTool.renderResult(inlineResult, { expanded: true, isPartial: false }, fakeTheme, inlineRenderContext);
expect(renderedPreview && typeof renderedPreview.render === 'function', 'inline renderer must return a Component');
const renderedLines = renderedPreview.render(120);
const renderedText = renderedLines.join('\n');
const stripTerminalSequences = (line) => line
  .replace(/\u001b\[[0-9;]*m/g, '')
  .replace(/\u001b\]8;;.*?\u001b\\/g, '');
const expectFooterSeparator = (lines, label) => {
  const plainLines = lines.map(stripTerminalSequences);
  const footerLine = plainLines.findIndex((line) => line.includes('Ctrl+Shift+M'));
  expect(footerLine > 0 && plainLines[footerLine - 1].replace(/[│]/g, '').trim() === '', `${label} must show a blank line before the copy footer`);
};
const normalizedRenderedText = renderedLines
  .map((line) => stripTerminalSequences(line).trimEnd())
  .join('\n');
expect(renderedText.includes('╭') && renderedText.includes('╮') && renderedText.includes('╰') && renderedText.includes('╯'), 'inline renderer must show a complete elevated card border');
expect(!renderedText.includes('MARKDOWN PREVIEW') && !renderedText.includes('Inline example') && renderedText.includes('Ctrl+Shift+M  Copy source'), 'inline renderer must omit the header and supplied title while keeping the copy footer');
expect(renderedText.includes('Original Markdown'), 'inline renderer must show rendered Markdown content');
expect(renderedText.includes('exact source') && renderedText.includes('item'), 'inline renderer must render Markdown syntax content');
for (const fragment of ['Syntax coverage', 'emphasis', 'strong', 'strike', 'nested item', 'ordered item', 'docs', 'https://example.org', 'quoted line', 'cell one', 'cell two', 'deliberately long paragraph']) {
  expect(normalizedRenderedText.includes(fragment), `inline renderer must visibly render ${fragment}`);
}
expect(renderedText.includes('\u001b]8;;https://example.com'), 'inline renderer must preserve the link URL in terminal hyperlink metadata');
expect(renderedText.includes('Ctrl+Shift+M  Copy source'), 'inline renderer must show the copy shortcut hint');
expectFooterSeparator(renderedLines, 'Moon renderer at normal width');
expectFooterSeparator(renderedPreview.render(28), 'Moon renderer at narrow width');
expect(renderedText.includes('\u001b[48;2;30;32;48m'), 'inline renderer must use the Tokyo Night page-dark frame palette');
expect(renderedText.includes('\u001b[48;2;34;36;54m'), 'inline renderer must use the Tokyo Night card surface palette');
expect(renderedText.includes('\u001b[38;2;59;66;97m'), 'inline renderer must use the Tokyo Night border palette');
expect(renderedText.includes('\u001b[38;2;255;199;119m'), 'inline renderer must use the Tokyo Night heading palette');
expect(renderedText.includes('\u001b[38;2;101;188;255m'), 'inline renderer must use the Tokyo Night link palette');
expect(renderedText.includes('\u001b[38;2;134;225;252m'), 'inline renderer must use the Tokyo Night cyan palette');
expect(renderedText.includes('\u001b[38;2;195;232;141m'), 'inline renderer must use the Tokyo Night code-block palette');
expect(renderedText.includes('\u001b[38;2;192;153;255m'), 'inline renderer must use the Tokyo Night inline-code palette');
expect(renderedText.includes('\u001b[48;2;25;27;41m'), 'inline renderer must use the Tokyo Night deepest code-block background');
expect(renderedText.includes('\u001b[48;2;25;27;41m\u001b[38;2;99;109;166m'), 'inline renderer must keep the code-block border on the deepest surface');
expect(renderedText.includes('\u001b[48;2;47;51;77m'), 'inline renderer must use the Tokyo Night inline-code highlight background');
const lineLengths = renderedLines.map((line) => line
  .replace(/\u001b\[[0-9;]*m/g, '')
  .replace(/\u001b\]8;;.*?\u001b\\/g, '')
  .length);
expect(Math.max(...lineLengths) <= 120, 'inline renderer must keep every line within the component width');
expect(!normalizedRenderedText.includes(inlineMarkdown) && !normalizedRenderedText.includes('**exact source**'), 'inline renderer must not show raw Markdown source');
const syntaxFragments = ['Syntax coverage', 'emphasis', 'strong', 'strike', 'nested item', 'ordered item', 'docs', 'https://example.org', 'quoted line', 'cell one', 'cell two', 'deliberately', 'paragraph'];
for (const [width, lines] of [[28, renderedPreview.render(28)], [120, renderedLines]]) {
  const plainLines = lines.map((line) => stripTerminalSequences(line));
  const plainText = plainLines.join('\n');
  for (const fragment of syntaxFragments) {
    expect(plainText.includes(fragment), `inline renderer must visibly render ${fragment} at width ${width}`);
  }
  const codeLines = plainLines.filter((line) => /```|const value = 1;|second line/.test(line));
  expect(codeLines.length >= 3, `inline renderer must preserve all fenced code lines at width ${width}`);
  expect(codeLines.some((line) => line.includes('```js')), `inline renderer must preserve the opening fence at width ${width}`);
  expect(codeLines.some((line) => line.includes('const value = 1;')), `inline renderer must preserve code content at width ${width}`);
  expect(codeLines.some((line) => line.includes('second line')), `inline renderer must preserve the second code line at width ${width}`);
  expect(codeLines.some((line) => line.replace(/[│]/g, '').trim() === '```'), `inline renderer must preserve the closing fence at width ${width}`);
  expect(lines.every((line) => stripTerminalSequences(line).length <= width), `inline renderer must keep code layout within width ${width}`);
  expect(lines.every((line) => !stripTerminalSequences(line).includes('\u001b')), `inline renderer must keep ANSI sequences well-formed at width ${width}`);
  const surfaceLines = lines.filter((line) => /\u001b\[48;2;(25;27;41|47;51;77)m/.test(line));
  expect(surfaceLines.length > 0 && surfaceLines.every((line) => !line.includes('\u001b[0m') || line.includes('\u001b[0m\u001b[48;2;34;36;54m')), `inline renderer must keep code surfaces ANSI-safe at width ${width}`);
}
expect(renderedText.includes('\u001b[48;2;47;51;77m\u001b[38;2;192;153;255minline code\u001b[0m\u001b[48;2;34;36;54m'), 'inline code must restore the card surface after a full reset');
expect(renderedText.includes('\u001b[48;2;25;27;41m\u001b[38;2;195;232;141mconst value = 1;\u001b[0m\u001b[48;2;34;36;54m'), 'code blocks must restore the card surface after a full reset');
const gfmMarkdown = [
  '# GFM terminal parity',
  '',
  '## Supported syntax',
  '',
  '**bold**, _italic_, ~~strike~~, `inline code`, [link](https://example.com), <https://example.org>, <user@example.com>.',
  'Escaped \\*asterisk\\* and \\_underscore\\_.',
  '',
  '- [x] done',
  '- [ ] todo',
  '  3) nested ordered',
  '',
  '> quoted line',
  '',
  '---',
  '',
  '| H1 | H2 | H3 | H4 | H5 | H6 | H7 | H8 | H9 | H10 |',
  '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |',
  '| a | b | c | d | e | f | g | h | i | j |',
  '',
  'Inline math $x^2 + y^2$.',
  '',
  '<span class="literal">HTML stays literal</span>',
  '',
  '![image alt](https://example.com/image.png)',
  '',
  '[^note]',
  '',
  '[^note]: footnote text',
  '',
  '```mermaid',
  'graph TD',
  '  A --> B',
  '```',
].join('\n');
const gfmResult = await previewTool.execute('preview-gfm', { markdown: gfmMarkdown, title: 'GFM corpus' }, undefined, undefined, {
  mode: 'tui',
  ui: { custom: async () => { throw new Error('GFM preview must not open custom UI'); } },
});
const gfmRendered = previewTool.renderResult(gfmResult, { expanded: true, isPartial: false }, fakeTheme, { toolCallId: 'gfm-preview', invalidate() {} }).render(120);
const gfmNarrowRendered = previewTool.renderResult(gfmResult, { expanded: true, isPartial: false }, fakeTheme, { toolCallId: 'gfm-preview-narrow', invalidate() {} }).render(28);
const gfmRenderedText = gfmRendered.join('\n');
const gfmNarrowRenderedText = gfmNarrowRendered.join('\n');
const gfmPlain = gfmRendered.map(stripTerminalSequences).join('\n');
const gfmNarrowPlain = gfmNarrowRendered.map(stripTerminalSequences).join('\n');
for (const fragment of ['GFM terminal parity', 'Supported syntax', 'bold', 'italic', 'strike', 'inline code', 'link', 'https://example.org', 'user@example.com', '[x] done', '[ ] todo', '3) nested ordered', 'quoted line', 'Inline math x² + y²']) {
  expect(gfmPlain.includes(fragment), `GFM corpus must render ${fragment}`);
}
expect(gfmPlain.includes('*asterisk*') && gfmPlain.includes('_underscore_') && !gfmPlain.includes('\\*asterisk\\*') && !gfmPlain.includes('\\_underscore\\_'), 'GFM corpus must render escaped punctuation as literal punctuation');
expect(gfmRenderedText.includes('\u001b]8;;https://example.com') && gfmRenderedText.includes('\u001b]8;;mailto:user@example.com'), 'GFM corpus must render link and autolink metadata');
expect(gfmRenderedText.includes('┌') && gfmRenderedText.includes('H10'), 'GFM corpus must render a supported table at normal width');
expect(!gfmNarrowRenderedText.includes('┌') && gfmNarrowPlain.includes('| H1 | H2 | H3 | H4 | H5'), 'very narrow tables must fall back to raw Markdown');
expect(gfmPlain.includes('<span class="literal">HTML stays literal</span>'), 'raw HTML must remain literal in the terminal contract');
expect(gfmPlain.includes('image alt') && !gfmPlain.includes('image.png'), 'images must fall back to visible alt text');
expect(gfmPlain.includes('[^note]') && gfmPlain.includes('[^note]: footnote text'), 'footnote syntax must remain literal without a plugin renderer');
expect(gfmPlain.includes('```mermaid') && gfmPlain.includes('graph TD') && gfmPlain.includes('A --> B'), 'Mermaid fences must remain code');
for (const [width, lines] of [[120, gfmRendered], [28, gfmNarrowRendered]]) {
  expect(lines.every((line) => stripTerminalSequences(line).length <= width), `GFM corpus must keep every line within width ${width}`);
  expect(lines.every((line) => !stripTerminalSequences(line).includes('\u001b')), `GFM corpus must keep ANSI sequences well-formed at width ${width}`);
}
previewThemeNotifications.length = 0;
await previewThemeCommand.handler('unexpected', previewThemeContext);
expect(previewThemeNotifications.at(-1)?.message === 'Usage: /preview-markdown:theme' && previewThemeNotifications.at(-1)?.level === 'error', 'theme command must reject unexpected arguments with concise usage');
previewThemeSelection = 'Tokyo Night Day';
await previewThemeCommand.handler('', previewThemeContext);
expect(previewThemeMenuOptions[0] === 'Tokyo Night Moon (current)' && previewThemeMenuOptions[1] === 'Tokyo Night Day', 'preview-markdown:theme must indicate the current Moon selection');
expect(JSON.parse(readFileSync(previewThemePath, 'utf8')).theme === 'day', 'Day selection must persist globally in the b-agentic namespace');
expect(inlineInvalidationCount === 1, 'theme selection must invalidate previously rendered preview rows');
const rerenderedPreview = previewTool.renderResult(inlineResult, { expanded: true, isPartial: false }, fakeTheme, inlineRenderContext);
const rerenderedText = rerenderedPreview.render(120).join('\n');
expect(rerenderedText.includes('\u001b[48;2;213;214;219m') && !rerenderedText.includes('\u001b[48;2;30;32;48m'), 'previously rendered previews must re-render with the selected Day palette');
const restoredResult = {
  content: [{ type: 'text', text: 'Markdown preview rendered inline.' }],
  details: { markdown: '# Restored', title: 'Restored', theme: 'moon' },
};
const restoredRendered = previewTool.renderResult(restoredResult, { expanded: true, isPartial: false }, fakeTheme, { toolCallId: 'restored-preview', invalidate() {} });
const restoredRenderedText = restoredRendered.render(120).join('\n');
expect(restoredRenderedText.includes('\u001b[48;2;213;214;219m') && !restoredRenderedText.includes('\u001b[48;2;30;32;48m'), 'restored details must not override the persisted current theme');
const dayResult = await previewTool.execute('preview-day', { markdown: inlineMarkdown, title: 'Day example' }, undefined, undefined, {
  mode: 'tui',
  ui: { custom: async () => { throw new Error('inline preview must not open custom UI'); } },
});
expect(dayResult.details.theme === 'day', 'subsequent previews must use the persisted Day theme');
const renderedDay = previewTool.renderResult(dayResult, { expanded: true, isPartial: false }, fakeTheme, {});
const renderedDayLines = renderedDay.render(120);
const renderedDayText = renderedDayLines.join('\n');
const normalizedDayText = renderedDayLines.map((line) => stripTerminalSequences(line).trimEnd()).join('\n');
expect(renderedDayText.includes('\u001b[48;2;213;214;219m'), 'Day renderer must use the official Tokyo Night Day page palette');
expect(renderedDayText.includes('\u001b[48;2;225;226;231m'), 'Day renderer must use the official Tokyo Night Day card palette');
expect(renderedDayText.includes('\u001b[38;2;137;144;179m'), 'Day renderer must use the official Tokyo Night Day border palette');
expect(renderedDayText.includes('\u001b[38;2;140;108;62m'), 'Day renderer must use the official Tokyo Night Day heading palette');
expect(renderedDayText.includes('\u001b[38;2;46;125;233m'), 'Day renderer must use the official Tokyo Night Day accent/link palette');
expect(renderedDayText.includes('\u001b[38;2;0;113;151m'), 'Day renderer must use the official Tokyo Night Day cyan palette');
expect(renderedDayText.includes('\u001b[38;2;88;117;57m'), 'Day renderer must use the official Tokyo Night Day code-block palette');
expect(renderedDayText.includes('\u001b[38;2;152;84;241m'), 'Day renderer must use the official Tokyo Night Day inline-code palette');
expect(renderedDayText.includes('\u001b[48;2;196;200;218m'), 'Day renderer must use the official Tokyo Night Day deepest palette');
expect(renderedDayText.includes('\u001b[48;2;220;223;228m'), 'Day renderer must use the official Tokyo Night Day highlight palette');
expect(normalizedDayText.includes('Original Markdown') && normalizedDayText.includes('nested item'), 'Day renderer must preserve rendered Markdown content');
expect(!renderedDayText.includes('MARKDOWN PREVIEW') && !renderedDayText.includes('Day example') && renderedDayText.includes('Ctrl+Shift+M  Copy source'), 'Day renderer must omit the header and supplied title while keeping the copy footer');
expectFooterSeparator(renderedDayLines, 'Day renderer at normal width');
expectFooterSeparator(renderedDay.render(28), 'Day renderer at narrow width');
for (const [width, lines] of [[28, renderedDay.render(28)], [120, renderedDayLines]]) {
  const plainLines = lines.map((line) => stripTerminalSequences(line));
  const plainText = plainLines.join('\n');
  for (const fragment of syntaxFragments) {
    expect(plainText.includes(fragment), `Day renderer must visibly render ${fragment} at width ${width}`);
  }
  expect(lines.every((line) => stripTerminalSequences(line).length <= width), `Day renderer must keep every line within width ${width}`);
  expect(lines.every((line) => !stripTerminalSequences(line).includes('\u001b')), `Day renderer must keep ANSI sequences well-formed at width ${width}`);
}
let staleInvalidationCount = 0;
previewTool.renderResult(restoredResult, { expanded: true, isPartial: false }, fakeTheme, { toolCallId: 'stale-preview', invalidate() { staleInvalidationCount += 1; } });
expect(typeof handlers.session_shutdown === 'function', 'preview extension must register session shutdown cleanup');
await handlers.session_shutdown({ type: 'session_shutdown', reason: 'reload' }, {});
await handlers.session_shutdown({ type: 'session_shutdown', reason: 'reload' }, {});
const invalidationsBeforeShutdownTheme = inlineInvalidationCount;
previewThemeSelection = 'Tokyo Night Moon';
await previewThemeCommand.handler('', previewThemeContext);
previewThemeSelection = 'Tokyo Night Day';
await previewThemeCommand.handler('', previewThemeContext);
expect(staleInvalidationCount === 0 && inlineInvalidationCount === invalidationsBeforeShutdownTheme, 'session shutdown must clear prior preview invalidators idempotently');
const reloadedTools = {};
const reloadedCommands = {};
const reloadedHost = {
  on() {},
  registerShortcut() {},
  registerCommand(name, definition) { reloadedCommands[name] = definition; },
  registerTool(definition) { reloadedTools[definition.name] = definition; },
};
const reloadedPreviewModule = await import(`${pathToFileURL(path.join(installedRoot, 'b-agentic-preview-markdown.ts')).href}?reload=day`);
reloadedPreviewModule.default(reloadedHost);
const reloadedResult = await reloadedTools.preview_markdown.execute('preview-reload', { markdown: '# Reloaded' }, undefined, undefined, { mode: 'tui', ui: {} });
expect(reloadedResult.details.theme === 'day', 'a reloaded extension must read the persisted global Day theme');
writeFileSync(previewThemePath, '{malformed json');
const malformedResult = await previewTool.execute('preview-malformed', { markdown: '# Fallback' }, undefined, undefined, { mode: 'tui', ui: {} });
expect(malformedResult.details.theme === 'day', 'malformed preview theme config must not override the loaded current Day theme');
writeFileSync(previewThemePath, JSON.stringify({ theme: 'moon' }));
const invalidationsBeforeCancel = inlineInvalidationCount;
previewThemeSelection = undefined;
await previewThemeCommand.handler('', previewThemeContext);
expect(previewThemeMenuOptions[0] === 'Tokyo Night Moon' && previewThemeMenuOptions[1] === 'Tokyo Night Day (current)' && JSON.parse(readFileSync(previewThemePath, 'utf8')).theme === 'moon', 'Escape must cancel preview theme changes');
const canceledResult = await previewTool.execute('preview-cancel', { markdown: '# Canceled' }, undefined, undefined, { mode: 'tui', ui: {} });
const canceledRenderedText = previewTool.renderResult(inlineResult, { expanded: true, isPartial: false }, fakeTheme, inlineRenderContext).render(120).join('\n');
expect(canceledResult.details.theme === 'day' && inlineInvalidationCount === invalidationsBeforeCancel && canceledRenderedText.includes('\u001b[48;2;213;214;219m'), 'canceled theme selection must leave the current Day rendering unchanged');
const failureAgentDir = path.join(previewAgentDir, 'preview-theme-failure');
writeFileSync(failureAgentDir, 'not a directory');
process.env.PI_CODING_AGENT_DIR = failureAgentDir;
const invalidationsBeforeFailure = inlineInvalidationCount;
previewThemeSelection = 'Tokyo Night Moon';
previewThemeNotifications.length = 0;
await previewThemeCommand.handler('', previewThemeContext);
expect(previewThemeNotifications.at(-1)?.level === 'error' && previewThemeNotifications.at(-1)?.message.includes('Failed to save preview theme'), 'persistence failure must notify without changing behavior');
const failedSaveResult = await previewTool.execute('preview-failed-save', { markdown: '# Failed save' }, undefined, undefined, { mode: 'tui', ui: {} });
const failedRenderedText = previewTool.renderResult(inlineResult, { expanded: true, isPartial: false }, fakeTheme, inlineRenderContext).render(120).join('\n');
expect(failedSaveResult.details.theme === 'day' && inlineInvalidationCount === invalidationsBeforeFailure && failedRenderedText.includes('\u001b[48;2;213;214;219m'), 'persistence failure must retain the current Day rendering');
process.env.PI_CODING_AGENT_DIR = previewAgentDir;
rmSync(failureAgentDir, { force: true });
const [autoSessionStartHandler] = registrations.session_start;
const toolCallHandler = handlers.tool_call;
const statusCommand = commands['b-status'];
const statusSnapshot = await statusTest.buildCapabilitySnapshot(extensionHost, {
  packageListing: [
    'pi-mcp-adapter', 'pi-observational-memory', '@sreetej510/pi-usage',
    '@gotgenes/pi-anthropic-auth', 'pi-intercom', '@juicesharp/rpiv-ask-user-question', '@juicesharp/rpiv-todo',
  ].join('\n'),
  extensionRoot: installedRoot,
  mcpConfigPresent: true,
  commandAvailable: (command) => command !== 'missing-launcher',
});
expect(statusCommand && statusCommand.description.includes('read-only'), 'b-status must register a read-only command');
expect(statusSnapshot.includes('Capability contract v2'), 'b-status snapshot must include the contract version');
expect(statusSnapshot.includes('Overall: degraded'), 'b-status must remain degraded when MCP contents are unverified');
expect(statusSnapshot.includes('local, read-only; no MCP/auth/browser probes'), 'b-status snapshot must disclaim live probes');
expect(statusSnapshot.includes('pi-mcp-adapter: installed'), 'b-status must report installed package presence');
expect(!statusSnapshot.includes('linear') && !statusSnapshot.includes('mobbin'), 'b-status must not advertise retired MCP integrations');
expect(!statusSnapshot.includes('pi-lsp'), 'b-status must not advertise retired LSP integration');
expect(!statusSnapshot.includes('rule-guard'), 'b-status must not advertise retired rule-guard integration');
expect(!statusSnapshot.includes('b-agentic-consult'), 'b-status must not advertise retired consult integration');
expect(statusSnapshot.includes('b-agentic-status: installed'), 'b-status must report its managed extension presence');
expect(!statusSnapshot.includes('Bearer configured') && !statusSnapshot.includes('BRAVE_API_KEY'), 'status fixture should not expose configured secret values');

function expect(cond, msg) {
  if (!cond) throw new Error(msg);
}

const validIntercomCalls = [
  { action: 'list' },
  { action: 'list-cwd' },
  { action: 'list-cwd', cwd: '/workspace/b-agentic' },
  { action: 'status' },
  { action: 'pending' },
  { action: 'send', to: 'peer', message: 'bounded task', attachments: [{ type: 'snippet', name: 'note.md', content: 'context', language: 'markdown' }], replyTo: 'message-1', supersedes: 'message-0', retryOf: 'message-previous' },
  { action: 'ask', to: 'peer', message: 'question' },
  { action: 'reply', message: 'answer', replyTo: 'message-1' },
  { action: 'cancel', messageId: 'message-1' },
];
for (const input of validIntercomCalls) {
  expect(t.isAutoApprovedIntercomCall('intercom', input) === true, `valid Intercom call must be auto-approved: ${input.action}`);
}
expect(t.isAutoApprovedIntercomCall('intercom', { action: 'send', to: 'peer', message: 'attachment', attachments: [] }) === true, 'empty Intercom attachments remain auto-approved');
expect(t.isAutoApprovedIntercomCall('intercom', { action: 'send', to: 'peer', message: 'unknown', priority: 'high' }) === false, 'Intercom unknown fields remain approval-gated');
expect(t.isAutoApprovedIntercomCall('intercom', { action: 'send', to: 'peer', message: 'bad attachment', attachments: [{ type: 'snippet', name: 'note.md', content: 'context', extra: true }] }) === false, 'invalid Intercom attachments remain approval-gated');
expect(t.isAutoApprovedIntercomCall('intercom', { action: 'unknown' }) === false, 'unknown Intercom actions remain approval-gated');
expect(t.isAutoApprovedIntercomCall('intercom', { action: 'cancel', messageId: 1 }) === false, 'invalid Intercom optional field types remain approval-gated');
expect(t.isAutoApprovedIntercomCall('intercom', { action: 'reply', replyTo: 'message-1' }) === true, 'targetless schema-valid Intercom replies remain auto-approved');
expect(t.isAutoApprovedIntercomCall('intercom', { action: 'send', cwd: '/x', focus: true }) === true, 'focus:true on Intercom call must be auto-approved');
expect(t.isAutoApprovedIntercomCall('intercom', { action: 'send', cwd: '/x', focus: false }) === true, 'focus:false on Intercom call must be auto-approved');
expect(t.isAutoApprovedIntercomCall('intercom', { action: 'send', cwd: '/x', openProjectPaneIfMissing: false }) === true, 'openProjectPaneIfMissing:false on Intercom call must be auto-approved');
expect(t.isAutoApprovedIntercomCall('intercom', { action: 'send', cwd: '/x', openProjectPaneIfMissing: true }) === false, 'openProjectPaneIfMissing:true on Intercom call must remain approval-gated');

expect(typeof toolCallHandler === 'function', 'permission extension must register a tool_call handler');
expect(typeof mcpApprovalHandler === 'function', 'permission extension must register the MCP approval broker');
expect(t.isTrustedPreviewMarkdownCall({ markdown: '# Preview' }) === true, 'preview_markdown policy must trust the required Markdown-only shape');
expect(t.isTrustedPreviewMarkdownCall({ markdown: '# Preview', title: 'Example' }) === true, 'preview_markdown policy must trust an optional string title');
expect(t.isTrustedPreviewMarkdownCall({ markdown: '# Preview', extra: true }) === false, 'preview_markdown policy must reject extra fields');
expect(t.isTrustedPreviewMarkdownCall({ markdown: 42 }) === false, 'preview_markdown policy must reject non-string Markdown');
const noUiContext = { hasUI: false, ui: { select: async () => 'Approve' } };
let colorMode = 'truecolor';
const baseContext = {
  get model() { return activeModel; }, cwd: root, mode: 'rpc', hasUI: true,
  ui: {
    confirm: async () => true,
    select: async () => 'Allow once',
    notify(message, level) { notifications.push({ message, level }); },
    setTitle(title) { terminalTitles.push(title); },
    theme: { fg(color, text) { return `<${color}>${text}</${color}>`; }, getColorMode() { return colorMode; } },
    setStatus(key, value) { statuses.push({ key, value }); },
  },
  modelRegistry: { find: (provider, id) => provider === 'anthropic' && id === 'claude-sonnet-4-5' ? { provider, id } : undefined },
  sessionManager: { getBranch: () => [...branchEntries] },
};
expect(commands['b-sync'] && commands['b-update'], 'refresh extension must register /b-sync and /b-update');
let refreshConfirmations = 0;
let reloads = 0;
const refreshContext = { hasUI: true, ui: { confirm: async () => { refreshConfirmations += 1; return true; }, notify() {} }, async reload() { reloads += 1; } };
await commands['b-sync'].handler('', refreshContext);
await commands['b-update'].handler('', refreshContext);
expect(refreshConfirmations === 1 && reloads === 2, 'refresh lifecycle remains available');
expect(commands['b-auto-mode'], 'auto-mode extension must register /b-auto-mode');
expect(flagDefinitions['b-auto-mode']?.type === 'boolean', 'auto-mode must register a boolean startup flag');
const autoTest = extensionModules[2].__test__;
expect(autoTest.AUTO_MODE_ENTRY_TYPE === 'b-agentic-auto-mode', 'auto-mode state must use a dedicated persisted entry');
expect(autoTest.parseAutoMode(true) === true && autoTest.parseAutoMode('off') === false && autoTest.parseAutoMode('invalid') === undefined, 'auto-mode values must parse safely');
expect(autoTest.latestAutoModeState([{ type: 'custom', customType: 'b-agentic-auto-mode', data: { enabled: true } }]) === true, 'auto-mode state must restore from the session branch');
await commands['b-auto-mode'].handler('on', baseContext);
expect(statuses.at(-1)?.key === 'b-auto-mode' && statuses.at(-1)?.value === '<error>auto-mode</error>', 'enabled auto-mode must display red auto-mode status');
await commands['b-auto-mode'].handler('off', baseContext);
const isolatedAutoModeRoot = mkdtempSync(path.join(os.tmpdir(), 'b-agentic-isolated-auto-mode-'));
try {
  mkdirSync(path.join(isolatedAutoModeRoot, 'b-agentic-support'));
  cpSync(path.join(installedRoot, 'b-agentic-auto-mode.ts'), path.join(isolatedAutoModeRoot, 'b-agentic-auto-mode.ts'));
  for (const name of ['auto.ts', 'state.ts']) {
    cpSync(path.join(installedRoot, 'b-agentic-support', name), path.join(isolatedAutoModeRoot, 'b-agentic-support', name));
  }
  const isolatedCommands = {};
  const isolatedRegistrations = {};
  const isolatedAutoMode = (await import(pathToFileURL(path.join(isolatedAutoModeRoot, 'b-agentic-auto-mode.ts')).href)).default;
  isolatedAutoMode({
    on(eventName, handler) { isolatedRegistrations[eventName] = handler; },
    registerFlag() {},
    getFlag() {},
    registerCommand(name, definition) { isolatedCommands[name] = definition; },
    appendEntry: extensionHost.appendEntry,
  });
  expect((await toolCallHandler({ toolName: 'mcp', input: { server: 'firecrawl' } }, noUiContext))?.block === true, 'generic MCP selectors must require approval while auto-mode is off');
  await isolatedCommands['b-auto-mode'].handler('on', baseContext);
  expect(await toolCallHandler({ toolName: 'mcp', input: { server: 'firecrawl' } }, noUiContext) === undefined, 'auto-mode must share enabled state with the MCP permission extension across isolated module instances for generic MCP selectors');
  await isolatedCommands['b-auto-mode'].handler('off', baseContext);
  branchEntries.length = 0;
  autoTest.saveAutoModePreference(true);
  autoStateTest.setAutoModeEnabled(false);
  let isolatedStartupConfirmations = 0;
  await isolatedRegistrations.session_start({}, {
    ...baseContext,
    sessionManager: { getBranch: () => [] },
    ui: {
      ...baseContext.ui,
      confirm: async () => { isolatedStartupConfirmations += 1; return true; },
    },
  });
  expect(autoStateTest.isAutoModeEnabled() === true && isolatedStartupConfirmations === 0, 'a fresh auto-mode module must restore durable enabled state without confirmation');
  await isolatedCommands['b-auto-mode'].handler('off', baseContext);
  expect(autoTest.loadAutoModePreference() === false, 'disabling auto-mode must durably persist the disabled state');
  autoStateTest.setAutoModeEnabled(true);
  const secondRegistrations = {};
  isolatedAutoMode({
    on(eventName, handler) { secondRegistrations[eventName] = handler; },
    registerFlag() {},
    getFlag() {},
    registerCommand() {},
    appendEntry: extensionHost.appendEntry,
  });
  await secondRegistrations.session_start({}, { ...baseContext, sessionManager: { getBranch: () => [] } });
  expect(autoStateTest.isAutoModeEnabled() === false, 'a fresh auto-mode module must restore durable disabled state without a session entry');
  autoTest.saveAutoModePreference(false);
  autoStateTest.setAutoModeEnabled(true);
  await secondRegistrations.session_start({}, {
    ...baseContext,
    sessionManager: { getBranch: () => [{ type: 'custom', customType: 'b-agentic-auto-mode', data: { enabled: true } }] },
  });
  expect(autoStateTest.isAutoModeEnabled() === false && autoTest.loadAutoModePreference() === false, 'durable disabled state must override a conflicting legacy enabled session entry');
  autoTest.saveAutoModePreference(true);
  autoStateTest.setAutoModeEnabled(false);
  await secondRegistrations.session_start({}, {
    ...baseContext,
    sessionManager: { getBranch: () => [{ type: 'custom', customType: 'b-agentic-auto-mode', data: { enabled: false } }] },
  });
  expect(autoStateTest.isAutoModeEnabled() === true && autoTest.loadAutoModePreference() === true, 'durable enabled state must override a conflicting legacy disabled session entry');
  autoTest.saveAutoModePreference(false);
  autoStateTest.setAutoModeEnabled(false);
  branchEntries.length = 0;
  branchEntries.push({ type: 'custom', customType: 'b-agentic-auto-mode', data: { enabled: true } });
  flags['b-auto-mode'] = true;
  let startupFlagConfirmations = 0;
  const startupFlagContext = {
    ...baseContext,
    ui: {
      ...baseContext.ui,
      confirm: async () => { startupFlagConfirmations += 1; return true; },
    },
  };
  const entriesBeforeStartupFlagOn = branchEntries.length;
  expect(typeof autoSessionStartHandler === 'function', 'auto-mode extension must register session startup handling');
  await autoSessionStartHandler({}, startupFlagContext);
  expect(autoStateTest.isAutoModeEnabled() === true && autoTest.loadAutoModePreference() === false && startupFlagConfirmations === 1, 'explicit auto-mode on flag must confirm without changing durable state');
  expect(branchEntries.length === entriesBeforeStartupFlagOn, 'explicit auto-mode on flag must not append a session entry');
  autoTest.saveAutoModePreference(true);
  autoStateTest.setAutoModeEnabled(true);
  branchEntries.length = 0;
  branchEntries.push({ type: 'custom', customType: 'b-agentic-auto-mode', data: { enabled: false } });
  flags['b-auto-mode'] = false;
  const entriesBeforeStartupFlagOff = branchEntries.length;
  await autoSessionStartHandler({}, startupFlagContext);
  expect(autoStateTest.isAutoModeEnabled() === false && autoTest.loadAutoModePreference() === true, 'explicit auto-mode off flag must not change durable state');
  expect(branchEntries.length === entriesBeforeStartupFlagOff, 'explicit auto-mode off flag must not append a session entry');
  delete flags['b-auto-mode'];
  autoStateTest.setAutoModeEnabled(false);
} finally {
  rmSync(isolatedAutoModeRoot, { recursive: true, force: true });
}
await commands['b-auto-mode'].handler('on', baseContext);
const refreshConfirmationsBeforeAutoSync = refreshConfirmations;
const refreshExecutionsBeforeAutoSync = executedCommands.length;
await commands['b-sync'].handler('', refreshContext);
expect(refreshConfirmations === refreshConfirmationsBeforeAutoSync, 'b-sync must skip its confirmation when auto-mode is enabled');
expect(executedCommands.length === refreshExecutionsBeforeAutoSync + 1, 'auto-mode b-sync must still execute the refresh');
expect(persistedEntries.at(-1)?.customType === 'b-agentic-auto-mode' && persistedEntries.at(-1)?.data.enabled === true, 'enabling auto-mode must persist its state');
expect(await toolCallHandler({ toolName: 'bash', input: { command: 'rm -rf /tmp/auto-mode-ask' } }, noUiContext) === undefined, 'auto-mode must auto-allow shell ask decisions without UI');
expect((await toolCallHandler({ toolName: 'bash', input: { command: 'git push --force origin main' } }, noUiContext))?.block === true, 'auto-mode must retain explicit shell deny decisions');
expect(await toolCallHandler({ toolName: 'write', input: { path: '/tmp/auto-mode-write' } }, noUiContext) === undefined, 'auto-mode must auto-allow native path ask decisions without UI');
expect((await toolCallHandler({ toolName: 'write', input: { path: '.env' } }, noUiContext))?.block === true, 'auto-mode must retain explicit native path deny decisions');
expect(await toolCallHandler({ toolName: 'custom-tool', input: { value: 'external' } }, noUiContext) === undefined, 'auto-mode must auto-allow custom-tool asks without UI');
let autoModeBrokerClaim;
mcpApprovalHandler({
  serverName: 'firecrawl', originalToolName: 'firecrawl_agent', prefixedToolName: 'firecrawl_firecrawl_agent', args: {}, origin: 'proxy',
  claim(handler) { autoModeBrokerClaim = handler; return true; },
});
expect(await autoModeBrokerClaim() === 'allow_once', 'auto-mode must auto-allow broker ask decisions without UI');
await commands['b-auto-mode'].handler('off', baseContext);
expect(statuses.at(-1)?.value === undefined && persistedEntries.at(-1)?.data.enabled === false, 'disabling auto-mode must clear status and persist off');
expect((await toolCallHandler({ toolName: 'bash', input: { command: 'rm -rf /tmp/auto-mode-off' } }, noUiContext))?.block === true, 'off auto-mode must retain fail-closed no-UI shell asks');
let autoModeStartupConfirmations = 0;
branchEntries.length = 0;
rmSync(autoTest.autoModePath(), { force: true });
branchEntries.push({ type: 'custom', customType: 'b-agentic-auto-mode', data: { enabled: true } });
const autoModeStartupContext = {
  ...baseContext,
  ui: {
    ...baseContext.ui,
    confirm: async () => { autoModeStartupConfirmations += 1; return true; },
  },
};
await autoSessionStartHandler({}, autoModeStartupContext);
expect(autoModeStartupConfirmations === 0, 'persisted auto-mode must restore without reopening an approval prompt');
expect(await toolCallHandler({ toolName: 'bash', input: { command: 'rm -rf /tmp/auto-mode-restored' } }, noUiContext) === undefined, 'restored auto-mode must auto-allow shell ask decisions');
await commands['b-auto-mode'].handler('off', baseContext);

expect(await toolCallHandler({ toolName: 'mcpScript', input: { code: 'return 1;' } }, noUiContext) === undefined, 'trusted mcpScript container must auto-allow without UI');
expect(await toolCallHandler({
  toolName: 'mcpScript',
  input: { code: "const found = await tools.search({ query: 'symbol' }); return tools.describe({ path: found.items[0].path });" },
}, noUiContext) === undefined, 'trusted mcpScript must permit read-only tools.search/tools.describe metadata discovery');
let nestedScriptMutationClaim;
mcpApprovalHandler({
  serverName: 'firecrawl', originalToolName: 'firecrawl_agent', prefixedToolName: 'firecrawl_firecrawl_agent', args: {}, origin: 'script',
  claim(handler) { nestedScriptMutationClaim = handler; return true; },
});
expect(await nestedScriptMutationClaim() === 'deny', 'unsafe nested mcpScript operations must retain normal approval policy');
let nestedScriptLocalUploadClaim;
mcpApprovalHandler({
  serverName: 'firecrawl', originalToolName: 'firecrawl_parse', prefixedToolName: 'firecrawl_firecrawl_parse', args: { url: 'https://example.com' }, origin: 'script',
  claim(handler) { nestedScriptLocalUploadClaim = handler; return true; },
});
expect(await nestedScriptLocalUploadClaim() === 'deny', 'nested mcpScript local-upload operations must retain normal approval/auth policy');
expect(await toolCallHandler({ toolName: 'mcpScript', input: { code: "return tools.call('firecrawl_firecrawl_search', { query: 'bounded check', limit: 1 });" } }, noUiContext) === undefined, 'a single nested tools.call must remain inside the shared mcpScript policy');
expect(await toolCallHandler({ toolName: 'mcp', input: { server: 'firecrawl', tool: 'firecrawl_agent' } }, noUiContext) === undefined, 'top-level MCP mutations must reach the broker without generic blocking');
expect(await toolCallHandler({ toolName: 'mcp', input: { server: 'firecrawl', tool: 'firecrawl_search', args: { query: 'collision check', limit: 1 } } }, noUiContext) === undefined, 'valid top-level MCP proxy calls must not require generic UI approval');
for (const input of [
  { search: 'symbol' },
  { describe: 'tool' },
  { action: 'ui-messages' },
  { server: 'firecrawl', action: 'auth-start' },
  { tool: 'firecrawl_developer_search', args: { query: 'collision check' } },
  { server: 'firecrawl', tool: 'firecrawl_search', extra: true },
]) {
  expect((await toolCallHandler({ toolName: 'mcp', input }, noUiContext))?.block === true, 'non-execution MCP selectors must retain the generic approval gate');
}
expect((await toolCallHandler({ toolName: 'firecrawl_firecrawl_agent', input: {} }, noUiContext))?.block === true, 'direct managed-looking tools must retain the top-level approval gate');
for (const toolName of ['mcp__linear_get_issue', 'mcp__mobbin_mobbin_search_screens']) {
  expect((await toolCallHandler({ toolName, input: {} }, noUiContext))?.block === true, `${toolName} must fail closed through generic no-UI gating`);
}
let directClaim;
mcpApprovalHandler({
  serverName: 'firecrawl',
  originalToolName: 'firecrawl_agent',
  prefixedToolName: 'firecrawl_firecrawl_agent',
  args: {},
  origin: 'direct',
  claim(handler) { directClaim = handler; return true; },
});
expect(await directClaim() === 'abstain', 'top-level direct MCP approval must not prompt twice');
let directSafeClaim;
mcpApprovalHandler({
  serverName: 'firecrawl',
  originalToolName: 'firecrawl_search',
  prefixedToolName: 'firecrawl_firecrawl_search',
  args: { query: 'Pi', limit: 10 },
  origin: 'direct',
  claim(handler) { directSafeClaim = handler; return true; },
});
expect(await directSafeClaim() === 'allow_once', 'direct safe managed adapter calls must auto-allow');
await toolCallHandler({ toolName: 'bash', input: { command: 'rtk git status --short' } }, noUiContext);
let parallelProxyClaim;
mcpApprovalHandler({
  serverName: 'firecrawl',
  originalToolName: 'firecrawl_agent',
  prefixedToolName: 'firecrawl_firecrawl_agent',
  args: {},
  origin: 'proxy',
  claim(handler) { parallelProxyClaim = handler; return true; },
});
expect(await parallelProxyClaim() === 'deny', 'unsafe adapter-owned proxy calls must use the broker without UI');
let safeProxyClaim;
mcpApprovalHandler({
  serverName: 'firecrawl',
  originalToolName: 'firecrawl_search',
  prefixedToolName: 'firecrawl_firecrawl_search',
  args: { query: 'Pi', limit: 10 },
  origin: 'proxy',
  claim(handler) { safeProxyClaim = handler; return true; },
});
expect(await safeProxyClaim() === 'allow_once', 'safe managed proxy calls must auto-allow through the adapter broker');
let noUiClaim;
mcpApprovalHandler({
  serverName: 'firecrawl',
  originalToolName: 'firecrawl_agent',
  prefixedToolName: 'firecrawl_firecrawl_agent',
  args: {},
  origin: 'script',
  claim(handler) { noUiClaim = handler; return true; },
});
expect(typeof noUiClaim === 'function', 'MCP broker request must be claimed');
expect(await noUiClaim() === 'deny', 'MCP broker must fail closed without UI');
let safeClaim;
mcpApprovalHandler({
  serverName: 'firecrawl',
  originalToolName: 'firecrawl_search',
  prefixedToolName: 'firecrawl_firecrawl_search',
  args: { query: 'Pi', limit: 10 },
  origin: 'script',
  claim(handler) { safeClaim = handler; return true; },
});
expect(await safeClaim() === 'allow_once', 'MCP broker must auto-allow classified safe calls');
let sessionClaim;
const uiContext = { hasUI: true, ui: { confirm: async () => true, select: async () => 'Allow for session' } };
await toolCallHandler({ toolName: 'mcp', input: { server: 'firecrawl', tool: 'firecrawl_agent' } }, uiContext);
let approvedGatewayClaim;
mcpApprovalHandler({
  serverName: 'firecrawl',
  originalToolName: 'firecrawl_agent',
  prefixedToolName: 'firecrawl_firecrawl_agent',
  args: {},
  origin: 'proxy',
  claim(handler) { approvedGatewayClaim = handler; return true; },
});
expect(await approvedGatewayClaim() === 'allow_for_session', 'unsafe top-level MCP proxy calls must use the selected broker approval');
mcpApprovalHandler({
  serverName: 'firecrawl',
  originalToolName: 'firecrawl_agent',
  prefixedToolName: 'firecrawl_firecrawl_agent',
  args: {},
  origin: 'script',
  claim(handler) { sessionClaim = handler; return true; },
});
expect(await sessionClaim() === 'allow_for_session', 'MCP broker must support session-scoped approval');
expect(await toolCallHandler({ toolName: 'mcp', input: { server: 'user-server', tool: 'user_tool' } }, noUiContext) === undefined, 'unmanaged MCP gateway calls must reach the broker');
let userGatewayClaim;
mcpApprovalHandler({
  serverName: 'user-server',
  originalToolName: 'user_tool',
  prefixedToolName: 'user-server_user_tool',
  args: {},
  origin: 'proxy',
  claim(handler) { userGatewayClaim = handler; return true; },
});
expect(await userGatewayClaim() === 'deny', 'unmanaged MCP proxy calls must use the broker without UI');
for (const retired of [
  { serverName: 'linear', originalToolName: 'linear_get_issue' },
  { serverName: 'mobbin', originalToolName: 'mobbin_search_screens' },
]) {
  let retiredClaim;
  expect(await toolCallHandler({ toolName: 'mcp', input: { server: retired.serverName, tool: retired.originalToolName, args: {} } }, noUiContext) === undefined, 'retired MCP proxy calls must reach generic gating');
  mcpApprovalHandler({
    serverName: retired.serverName,
    originalToolName: retired.originalToolName,
    prefixedToolName: `${retired.serverName}_${retired.originalToolName}`,
    args: {},
    origin: 'proxy',
    claim(handler) { retiredClaim = handler; return true; },
  });
  expect(await retiredClaim() === 'deny', `${retired.serverName} must fail closed without UI`);
}
expect(await toolCallHandler({ toolName: 'bash', input: { command: 'rtk git status --short' } }, noUiContext) === undefined, 'registered handler must allow safe RTK command');
expect(await toolCallHandler({ toolName: 'bash', input: { command: 'git commit -m x' } }, noUiContext) === undefined, 'registered handler must allow regular project-local Git commands');
expect((await toolCallHandler({ toolName: 'mcp', input: { connect: 'codegraph' } }, noUiContext))?.block === true, 'managed MCP connect calls must retain the generic approval gate');
expect((await toolCallHandler({ toolName: 'read', input: { path: '.env' } }, noUiContext))?.block === true, 'registered handler must fail closed for protected read');

// Compound commands and wrappers
expect(t.commandDecision('cd repo && git reset --hard').decision === 'deny', 'compound reset --hard must deny');
expect(t.commandDecision('git -C repo reset --hard').decision === 'deny', 'git -C reset --hard must deny');
expect(t.commandDecision('/usr/bin/git reset --hard').decision === 'deny', 'path-qualified git reset --hard must deny');
expect(t.commandDecision('/usr/bin/npm install lodash').decision === 'allow', 'path-qualified npm install must allow local dependency automation');
expect(t.commandDecision('/bin/rm -rf /tmp/x').decision === 'ask', 'path-qualified rm -rf must ask');
expect(t.commandDecision('/usr/bin/printf x').decision === 'allow', 'unsupported raw command must allow');
const originalCwd = process.cwd();
const codegraphFixture = mkdtempSync(path.join(os.tmpdir(), 'b-agentic-codegraph-'));
const indexedCodegraphFixture = mkdtempSync(path.join(os.tmpdir(), 'b-agentic-codegraph-indexed-'));
try {
  process.chdir(codegraphFixture);
  expect(t.commandDecision('codegraph init').decision === 'allow', 'exact CodeGraph initialization must allow only while its index is absent');
  expect(t.commandDecision('./codegraph init').decision === 'ask', 'relative CodeGraph executable must require approval');
  expect(t.commandDecision('/tmp/codegraph init').decision === 'ask', 'path-qualified CodeGraph executable must require approval');
  expect(t.commandDecision('sudo codegraph init').decision === 'ask', 'sudo CodeGraph initialization must require approval');
  expect(t.commandDecision('PATH=./bin codegraph init').decision === 'ask', 'PATH-assigned CodeGraph initialization must require approval');
  expect(t.commandDecision('env PATH=./bin codegraph init').decision === 'ask', 'env PATH-assigned CodeGraph initialization must require approval');
  expect(t.commandDecision('LD_PRELOAD=/tmp/payload.so codegraph init').decision === 'ask', 'runtime-injected CodeGraph initialization must require approval');
  expect(t.commandDecision('env LD_PRELOAD=/tmp/payload.so codegraph init').decision === 'ask', 'env runtime-injected CodeGraph initialization must require approval');
  expect(t.commandDecision('env -i codegraph init').decision === 'ask', 'env-wrapped CodeGraph initialization must require approval');
  expect(t.commandDecision('PATH=./bin; codegraph init').decision === 'ask', 'compound PATH-modified CodeGraph initialization must require approval');
  mkdirSync(path.join(indexedCodegraphFixture, '.codegraph'));
  writeFileSync(path.join(indexedCodegraphFixture, '.codegraph', 'codegraph.db'), 'index');
  expect(t.commandDecision(`env -C ${indexedCodegraphFixture} codegraph init`).decision === 'ask', 'env -C CodeGraph initialization must require approval');
  mkdirSync(path.join(codegraphFixture, '.codegraph'));
  writeFileSync(path.join(codegraphFixture, '.codegraph', 'codegraph.db'), 'index');
  expect(t.commandDecision('codegraph init').decision === 'allow', 'project-local CodeGraph initialization must allow');
} finally {
  process.chdir(originalCwd);
  rmSync(codegraphFixture, { recursive: true, force: true });
  rmSync(indexedCodegraphFixture, { recursive: true, force: true });
}
expect(t.commandDecision('codegraph init --force').decision === 'allow', 'project-local CodeGraph commands must allow');
expect(t.commandDecision('codegraph status').decision === 'allow', 'project-local CodeGraph status must allow');
expect(t.commandDecision("git -c alias.wipe='reset --hard' wipe").decision === 'ask', 'inline Git alias invocation must ask');
expect(t.commandDecision('env X=1 npm install lodash').decision === 'allow', 'env-wrapped npm install must allow local dependency automation');
for (const command of ['env', 'env -i', 'env X=1']) {
  expect(t.commandDecision(command).decision === 'ask', `${command} must require rtk env`);
}
expect(t.commandDecision('rtk env').decision === 'allow', 'rtk env must allow');
for (const command of [
  'git config --global user.name agent',
  'git config --system user.name agent',
  'rtk git config --global user.name agent',
  'rtk git config --system user.name agent',
  'rtk proxy git config --global user.name agent',
]) {
  expect(t.commandDecision(command).decision === 'ask', `${command} must require shared-scope approval`);
  expect((await toolCallHandler({ toolName: 'bash', input: { command } }, noUiContext))?.block === true, `${command} must fail closed without approval UI`);
}
for (const command of [
  'git config user.name agent',
  'git config --local user.name agent',
  'rtk git config user.name agent',
  'rtk git config --local user.name agent',
  'rtk git commit -m x',
]) expect(t.commandDecision(command).decision === 'allow', `${command} must retain project-local Git behavior`);
expect(t.commandDecision('rtk proxy git reset --hard').decision === 'deny', 'rtk proxy must preserve deny decisions');
for (const wrapper of ['err', 'test', 'summary']) {
  expect(t.RTK_EXECUTION_WRAPPERS.has(wrapper), `rtk ${wrapper} must be classified as an execution wrapper`);
  expect(t.commandDecision(`rtk ${wrapper} git reset --hard`).decision === 'deny', `rtk ${wrapper} must preserve deny decisions`);
  expect(t.commandDecision(`rtk ${wrapper} -- git reset --hard`).decision === 'deny', `rtk ${wrapper} -- must preserve deny decisions`);
  expect(t.commandDecision(`rtk ${wrapper} --skip-env npm install lodash`).decision === 'allow', `rtk ${wrapper} options must allow local dependency automation`);
}
expect(t.commandDecision('rtk run git reset --hard').decision === 'deny', 'positional rtk run must preserve deny decisions');
expect(t.commandDecision('rtk --ultra-compact run git reset --hard').decision === 'deny', 'RTK global options must not hide deny decisions');
expect(t.commandDecision('rtk --skip-env git reset --hard').decision === 'deny', 'RTK global options must preserve direct command classification');
expect(t.commandDecision("rtk run -c 'git reset --hard'").decision === 'ask', 'rtk run -c must fail closed as opaque');
expect(t.commandDecision('rtk g\\it reset --hard').decision === 'deny', 'escaped command name must not bypass reset denial');
expect(t.commandDecision(['rtk g', '\\', '\n', 'it reset --hard'].join('')).decision === 'deny', 'line-continuation command name must not bypass reset denial');
const noModernTools = new Set();
const allModernTools = new Set(['rg', 'fd', 'bat', 'eza', 'sd', 'jq']);
const defaultModernDecision = t.commandDecision('rtk grep needle src/main.ts');
expect(defaultModernDecision.decision === t.commandDecision('rtk grep needle src/main.ts', noModernTools).decision &&
  defaultModernDecision.reason === t.commandDecision('rtk grep needle src/main.ts', allModernTools).reason,
'implicit modern-tool availability must not change shell policy decisions');
expect(t.segmentDecision('rtk grep needle src/main.ts').decision === 'allow', 'segment decisions must retain the availability-free default call shape');
expect(t.commandDecision('rtk proxy c\\at src/main.ts', noModernTools).decision === 'allow', 'baseline fallback remains allowed when the preferred modern tool is unavailable or inappropriate');
expect(t.commandDecision('rtk proxy grep needle src/main.ts', noModernTools).decision === 'allow', 'RTK-wrapped legacy discovery may fall back when rg is unavailable');
expect(t.commandDecision('grep needle src/main.ts', noModernTools).decision === 'allow', 'bare project-local grep must allow');
expect(t.commandDecision('rtk grep needle src/main.ts', allModernTools).decision === 'allow', 'RTK-wrapped grep must allow');
expect(t.commandDecision('rg needle src/main.ts', allModernTools).decision === 'allow', 'bare project-local rg must allow');
expect(t.commandDecision('rtk rg needle src/main.ts', allModernTools).decision === 'allow', 'RTK-wrapped rg must allow');
expect(t.commandDecision('rtk find . -name main.ts', noModernTools).decision === 'allow', 'RTK-wrapped find may fall back when fd is unavailable');
expect(t.commandDecision('rtk find . -name main.ts', allModernTools).decision === 'allow', 'RTK-wrapped find must allow when fd is available');
expect(t.commandDecision('fd -t f main.ts', allModernTools).decision === 'allow', 'unsupported modern fd discovery must allow directly');
expect(t.commandDecision('eza -la', allModernTools).decision === 'allow', 'unsupported modern eza discovery must allow directly');
expect(t.commandDecision('cat src/main.ts', allModernTools).decision === 'allow', 'project-local cat must allow when bat is available');
expect(t.commandDecision('python3 -m json.tool package.json', allModernTools).decision === 'allow', 'project-local JSON formatting must allow when jq is available');
expect(t.commandDecision('sudo git push --force origin main').decision === 'deny', 'sudo force push must deny');
expect(t.commandDecision('/usr/bin/env X=1 git reset --hard').decision === 'deny', 'path-qualified env must not bypass reset denial');
expect(t.commandDecision('/usr/bin/sudo git push --force origin main').decision === 'deny', 'path-qualified sudo must not bypass force-push denial');
expect(t.commandDecision('/opt/bin/rtk git reset --hard').decision === 'deny', 'path-qualified RTK must not bypass reset denial');
expect(t.commandDecision('rtk git --git-dir repo/.git reset --hard').decision === 'deny', 'Git option value must not hide reset denial');
expect(t.commandDecision('rtk git --git-dir repo/.git --config-env=alias.wipe=ALIAS wipe').decision === 'ask', 'RTK Git command with opaque options must ask');
expect(t.commandDecision('git push -f origin main').decision === 'deny', 'git push -f must deny');
for (const command of [
  'rtk git restore .',
  'rtk git checkout -- src/main.ts',
  'rtk git checkout -f main',
  'rtk git switch --discard-changes main',
  'rtk git stash clear',
  'rtk git stash drop',
  'rtk git stash pop',
  'rtk git stash --quiet clear',
  'rtk git stash --quiet drop',
  'rtk git stash --quiet pop',
]) {
  expect(t.commandDecision(command).decision === 'ask', `${command} can discard work and must ask`);
}
for (const command of [
  'git add .',
  'git branch feature',
  'git fetch origin',
  'git reset HEAD src/main.ts',
  'git stash push',
  'git tag v1',
]) expect(t.commandDecision(command).decision === 'allow', `${command} is a regular project-local Git command and must allow`);
expect(t.commandDecision('git worktree remove ../other').decision === 'ask', 'Git worktree removal outside the project must ask');
for (const command of [
  'rtk git branch',
  'rtk git branch -a',
  'rtk git branch --contains HEAD',
  'rtk git log -1',
  'rtk git remote -v',
  'rtk git stash list',
  'rtk git status --short',
  "rtk git tag --list 'v*'",
  'rtk git diff --name-only',
  'rtk git show --name-status --format= HEAD',
  'rtk git diff -- adapters/pi/tests/smoke.sh',
  'rtk git show HEAD -- adapters/pi/tests/smoke.sh',
]) expect(t.commandDecision(command).decision === 'allow', `${command} is a scoped or metadata-only Git read and may allow via RTK`);
for (const command of [
  'rtk git diff', 'rtk git diff --cached', 'rtk git show HEAD',
  'rtk git diff --name-only --patch', 'rtk git show --name-status --patch HEAD',
  'rtk git diff -- .', 'rtk git show HEAD -- pi',
]) {
  expect(t.commandDecision(command).decision === 'ask', `${command} must not automatically expose unscoped Git content`);
}
expect(t.commandDecision('rtk git diff -- .env').decision === 'ask', 'targeted protected Git content must require approval');
expect(t.commandDecision('rm -rf /tmp/x').decision === 'ask', 'rm -rf must ask');
expect(t.commandDecision('rm -r /tmp/x').decision === 'ask', 'recursive rm must ask');
for (const command of [
  'mkdir -p /etc/b-agentic-review',
  'tee /etc/hosts',
  'unlink /tmp/important',
  'shred /tmp/important',
  'cd /etc && cat passwd',
  'pushd /etc && cat passwd',
  'popd && cat passwd',
  'env --chdir=/etc cat passwd',
  'sudo -C /etc cat passwd',
  'tar -xf /tmp/a.tar -C /etc',
  'make -C /etc all',
  'rsync src /etc/',
  'rsync src user@example.com:/etc/',
  'scp src user@example.com:/etc/hosts',
  'ssh user@example.com cat /etc/passwd',
  'unzip a.zip -d /etc',
  'rtk curl --output=/etc/hosts https://example.com',
  'rtk wget -O /etc/hosts https://example.com',
]) expect(t.commandDecision(command).decision === 'ask', `${command} must ask for outside-project mutation or cwd change`);
expect(t.commandDecision('rm -f /tmp/important').decision === 'ask', 'local file removal must ask');
expect(t.commandDecision('cat /etc/passwd').decision === 'ask', 'outside-project reads must ask');
expect(t.commandDecision('cat ~/.bashrc').decision === 'ask', 'home reads must ask');
expect(t.commandDecision('printf x > /etc/hosts').decision === 'ask', 'outside-project redirections must ask');
expect(t.commandDecision('cp src/main.ts /etc/hosts').decision === 'ask', 'outside-project copies must ask');
expect(t.commandDecision('mv src/main.ts /etc/hosts').decision === 'ask', 'outside-project moves must ask');
expect(t.commandDecision('touch /etc/hosts').decision === 'ask', 'outside-project touches must ask');
expect(t.commandDecision('cat src/main.ts', noModernTools).decision === 'allow', 'project-local reads must remain autonomous when bat is unavailable');
expect(t.commandDecision('printf x > adapters/pi/tests/new-file.ts').decision === 'allow', 'project-local writes must remain autonomous');
for (const command of ['dd if=/dev/zero of=/dev/sda', 'mkfs.ext4 /dev/sda', 'chmod -R 777 .', 'chown -R root .', 'kill -9 1']) {
  expect(t.commandDecision(command).decision === 'ask', `${command} must ask`);
}
expect(t.commandDecision('ls -la', noModernTools).decision === 'allow', 'bare project-local ls must allow');
expect(t.commandDecision('find . -name "*.ts"', noModernTools).decision === 'allow', 'bare project-local find must allow');
expect(t.commandDecision('rtk ls -la', noModernTools).decision === 'allow', 'RTK-wrapped ls may allow');
expect(t.commandDecision('rtk ls -la', allModernTools).decision === 'allow', 'RTK-wrapped ls may allow when eza is available');
expect(t.commandDecision('env X=1 rtk ls -la', noModernTools).decision === 'allow', 'env-wrapped RTK ls must allow when eza is unavailable');
expect(t.commandDecision('command rtk ls -la', noModernTools).decision === 'allow', 'command-wrapped RTK ls must allow when eza is unavailable');
expect(t.commandDecision('sudo rtk ls -la', noModernTools).decision === 'ask', 'sudo-wrapped commands must require approval');
expect(t.commandDecision('env -u FOO rtk ls -la', noModernTools).decision === 'allow', 'env -u wrapped RTK ls must allow when eza is unavailable');
expect(t.commandDecision('env -S ls').decision === 'ask', 'env -S legacy command must be approval-gated');
expect(t.commandDecision('env -S "grep needle src/main.ts"').decision === 'ask', 'env -S command string must be approval-gated');
expect(t.hasDependencyPathRisk(['npx', '--prefix', '/tmp', 'tool']) === false, 'npx must remain outside dependency-target classification');
expect(t.commandDecision('npx --prefix /tmp tool').decision === 'allow', 'npx prefix options must retain their existing command decision');
for (const command of [
  'cat src/main.ts',
  'sed -n 1p src/main.ts',
  'awk {print} src/main.ts',
  'python3 -m json.tool package.json',
]) expect(t.commandDecision(command, noModernTools).decision === 'allow', `${command} must remain an allowed fallback when its replacement is unavailable`);
for (const [command, label] of [
  ['npm add lodash', 'npm add'], ['npm remove lodash', 'npm remove'], ['npm --silent install lodash', 'npm option install'], ['npm ci', 'npm ci'],
  ['/usr/bin/npm --silent install lodash', 'path-qualified npm option install'],
  ['pnpm update', 'pnpm update'], ['pnpm up lodash', 'pnpm up'],
  ['yarn remove lodash', 'yarn remove'], ['yarn up lodash', 'yarn up'], ['bun uninstall lodash', 'bun uninstall'],
  ['cargo remove serde', 'cargo remove'], ['pip uninstall requests', 'pip uninstall'],
  ['pip3 uninstall requests', 'pip3 uninstall'], ['poetry update', 'poetry update'],
  ['uv pip uninstall requests', 'uv pip uninstall'], ['uv pip sync requirements.txt', 'uv pip sync'],
]) expect(t.commandDecision(command).decision === 'allow', `${label} must allow repository-local dependency automation`);
expect(t.commandDecision('npm --unknown-option install lodash').decision === 'ask', 'unknown package options must remain opaque');
for (const command of ['rtk npm --prefix ./app install lodash', 'rtk pnpm --dir ./app add lodash', 'rtk cargo --manifest-path app/Cargo.toml update']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} must allow repository-confined dependency automation via RTK`);
}
for (const command of ['npm --prefix /tmp install lodash', 'pnpm --dir /tmp add lodash', 'cargo --manifest-path /tmp/Cargo.toml update', 'pip install --prefix /tmp requests', 'pip install --target /tmp requests']) {
  expect(t.commandDecision(command).decision === 'ask', `${command} must ask for an outside-project dependency target`);
}
for (const command of ['pip install --prefix ./venv requests', 'pip install --target ./vendor requests']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} must allow a repository-confined dependency target`);
}
for (const command of ['npm install -g lodash', 'npm install --location=global lodash', 'pnpm add --global lodash', 'yarn global add lodash', 'bun install --global lodash', 'pip install --user requests', 'pip install --break-system-packages requests']) {
  expect(t.commandDecision(command).decision === 'ask', `${command} must ask for a global dependency target`);
}
for (const command of ['cargo install ripgrep', 'go install example.com/tool@latest']) {
  expect(t.commandDecision(command).decision === 'ask', `${command} must ask for an external binary install`);
}
expect(t.commandDecision('git --config-env=alias.wipe=ALIAS wipe').decision === 'ask', 'inline Git alias invocation must ask');
for (const command of ['npm view lodash', 'pnpm list', 'cargo search serde']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} is a regular command and must not require RTK`);
}
for (const command of ['rtk npm view lodash', 'rtk pnpm list', 'rtk cargo search serde', 'rtk pytest -q']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} must preserve supported RTK use`);
}
for (const command of ['rtk npx eslint .', 'rtk npm test', 'rtk npm run build', 'rtk pnpm exec vite']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} is routine project-local automation and must allow`);
}
for (const command of ['rtk npm run deploy', 'rtk pnpm run release', 'rtk yarn publish']) {
  expect(t.commandDecision(command).decision === 'ask', `${command} may mutate external state and must ask`);
}
const automationFixture = mkdtempSync(path.join(root, 'adapters/pi/tests/', '.b-agentic-automation-'));
try {
  const projectScript = path.join(automationFixture, 'build.js');
  writeFileSync(projectScript, 'console.log("build");');
  const relativeProjectScript = path.relative(process.cwd(), projectScript);
  for (const command of [`node ${relativeProjectScript}`, `bash ${relativeProjectScript}`]) {
    expect(t.commandDecision(command).decision === 'allow', `${command} is a project-local script and must allow`);
  }
} finally {
  rmSync(automationFixture, { recursive: true, force: true });
}
for (const command of [
  'rtk gh pr create',
  'rtk gh pr checkout 42',
  'rtk gh workflow run ci.yml',
  'rtk glab mr merge 42',
  'rtk aws s3 rm s3://bucket/key',
  'rtk psql database',
  'rtk kubectl apply -f deployment.yaml',
  'rtk kubectl delete pods get',
  'rtk oc rollout restart deployment/app',
  'rtk docker run image',
  'rtk docker run image ps',
  'rtk curl -X POST https://example.com',
  'rtk wget --post-data=x https://example.com',
]) expect(t.commandDecision(command).decision === 'ask', `${command} may mutate external or shared state and must ask`);
for (const command of [
  'rtk gh pr view 42',
  'rtk gh run view 42',
  'rtk glab mr list',
  'rtk kubectl get pods',
  'rtk oc logs pod/app',
  'rtk docker ps',
  'rtk docker compose logs',
  'rtk curl https://example.com',
  'rtk wget https://example.com',
]) expect(t.commandDecision(command).decision === 'allow', `${command} is read-only and may allow via RTK`);
for (const command of ['yarn why lodash', 'bun --version']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} must allow when RTK does not support it`);
  expect(t.commandDecision(`rtk proxy ${command}`).decision === 'allow', `rtk proxy ${command} must preserve safety classification`);
}
const rtkRequiredCommands = [
  'git', 'gh', 'glab', 'aws', 'psql', 'pnpm',
  'dotnet', 'docker', 'kubectl', 'oc', 'wget',
  'jest', 'vitest', 'ctest', 'prisma', 'tsc', 'next', 'lint', 'prettier', 'format',
  'playwright', 'cargo', 'npm', 'npx', 'curl', 'ruff', 'pytest', 'mypy',
  'rake', 'rubocop', 'rspec', 'pip', 'go', 'gt', 'golangci-lint', 'gradlew', 'mvn', 'mvnd',
  'ecs', 'paratest', 'pest', 'phpt', 'php', 'phpstan', 'phpunit', 'pint', 'sbt', 'uv', 'bun', 'bunx', 'deno',
];
const rtkDiscoveryCommands = ['ls', 'tree', 'find', 'diff', 'grep', 'rg', 'wc'];
for (const command of [...rtkRequiredCommands, ...rtkDiscoveryCommands]) {
  expect(t.RTK_REQUIRED_COMMANDS.has(command), `${command} must remain documented as RTK-supported`);
  expect(t.commandDecision(`${command} --version`, noModernTools).decision === 'allow', `${command} version checks must not require RTK`);
}
expect(t.RTK_OPTIONAL_COMMANDS.size === 0, 'RTK-supported command families retain a single documentation list');
for (const command of ['bun', 'bunx', 'deno']) {
  expect(t.commandDecision(`${command} --version`, noModernTools).decision === 'allow', `${command} version checks must remain allowed`);
  expect(t.commandDecision(`rtk ${command} --version`, noModernTools).decision === 'allow', `rtk ${command} version checks must remain allowed`);
}
for (const command of ['bun run untrusted.ts', 'bunx untrusted-package', 'deno run untrusted.ts']) {
  expect(t.commandDecision(command, noModernTools).decision === 'ask', `${command} must retain opaque-execution approval`);
  expect(t.commandDecision(`rtk ${command}`, noModernTools).decision === 'ask', `rtk-wrapped ${command} must retain opaque-execution approval`);
}
expect(t.SPECIALIZED_TOOLS.has('recall'), 'recall must be a first-party specialized tool');
expect(t.SPECIALIZED_TOOLS.has('todo'), 'todo must be a first-party specialized tool');
expect(t.SPECIALIZED_TOOLS.has('ask_user_question'), 'ask_user_question must be a first-party specialized tool');
expect(t.SPECIALIZED_TOOLS.has('mcpScript'), 'mcpScript must be a trusted container whose nested calls retain policy');
expect(t.isMcpOrCustomTool('recall', { id: 'aaaaaaaaaaaa' }) === false, 'recall must not require custom-tool approval');
expect(t.isMcpOrCustomTool('todo', { action: 'list' }) === false, 'todo must not require custom-tool approval');
const genericApprovalToolCases = [
  { name: 'ask_user_question', input: { questions: [] }, gated: false },
  { name: 'contact_supervisor', input: { message: 'status' }, gated: true },
  { name: 'lsp_diagnostics', input: { paths: ['README.md'] }, gated: true },
  { name: 'lsp_diagnostics', input: {}, gated: true },
  { name: 'lsp_fix', input: { path: 'README.md' }, gated: true },
];
for (const { name, input, gated } of genericApprovalToolCases) {
  expect(t.isMcpOrCustomTool(name, input) === gated, `${name} must use generic custom-tool approval`);
  const result = await toolCallHandler({ toolName: name, input }, noUiContext);
  expect((result?.block === true) === gated, `${name} no-UI behavior must fail closed for generic approval`);
}
expect(t.commandDecision('pip show requests').decision === 'allow', 'regular package metadata reads must not require RTK');
for (const command of ['poetry show', 'printf x']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} must allow when RTK does not support it`);
}
for (const command of ['rtk proxy poetry show', 'rtk proxy printf x']) {
  expect(t.commandDecision(command).decision === 'allow', `${command} must preserve safety classification`);
}
expect(t.commandDecision('printf x\ngit reset --hard').decision === 'deny', 'newline-separated reset --hard must deny');
expect(t.commandDecision('printf x\r\ngit reset --hard').decision === 'deny', 'CRLF-separated reset --hard must deny');
expect(t.commandDecision('rtk proxy printf x\ncat .env').decision === 'ask', 'newline-separated protected-path read must ask');
expect(t.commandDecision('printf x\nprintf y').decision === 'allow', 'unsupported multiline raw commands must allow when safe');
expect(t.commandDecision('cat .env').decision === 'ask', 'bare protected-path read must ask');
expect(t.commandDecision('cat .env.local').decision === 'ask', 'root-relative protected-path read must ask');
expect(t.commandDecision('cat .envrc').decision === 'ask', '.envrc read must ask');
expect(t.commandDecision('cat /tmp/.env.production').decision === 'ask', 'absolute protected-path read must ask');
expect(t.commandDecision('printf EXAMPLE=value > .env.example').decision === 'allow', 'public env template writes must allow');
expect(t.commandDecision('rtk cat ./config/../.env.local').decision === 'ask', 'rtk-wrapped protected-path read must ask');
expect(t.commandDecision('rtk rg SECRET .env').decision === 'ask', 'RTK-supported command must gate protected paths');
expect(t.commandDecision("rtk rg -n 'CONFIRM:' skills pi tests tooling --glob '!**/.git/**'").decision === 'allow', 'negated glob exclusions must not be treated as protected-path reads');
expect(t.commandDecision('ls src && cat credentials.json').decision === 'ask', 'compound protected-path read must ask');
expect(t.commandDecision('cat src/main.ts', noModernTools).decision === 'allow', 'direct cat must allow when bat is unavailable');
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
expect(t.commandDecision('rtk proxy find . -exec git reset --hard \\;').decision === 'ask', 'RTK find execution proxy must ask');
expect(t.commandDecision('rtk proxy printf "git reset --hard" | rtk proxy xargs sh').decision === 'ask', 'xargs execution proxy must ask');
expect(t.commandDecision('if rtk ls .; then rtk proxy echo ok; fi').decision === 'ask', 'if control structure must ask');
expect(t.commandDecision('while rtk ls .; do rtk proxy echo ok; break; done').decision === 'ask', 'while control structure must ask');
expect(t.hasShellControlSyntax('for item in one; do rtk proxy echo "$item"; done') === true, 'for control structure must be recognized');

// Interpreter/eval-style wrappers (opaque body) must ask
expect(t.commandDecision("bash -c 'git reset --hard'").decision === 'ask', 'bash -c must ask');
expect(t.commandDecision("sh -c 'git push --force'").decision === 'ask', 'sh -c must ask');
expect(t.commandDecision("node -e \"require('fs').rmSync('.')\"").decision === 'ask', 'node -e must ask');
expect(t.commandDecision('python3 -c "import os; os.system(\'git reset --hard\')"').decision === 'ask', 'python -c must ask');
for (const command of ['bash ./untrusted.sh', 'python3 ./untrusted.py', 'node app.js', 'python3 -m untrusted_module', './untrusted.sh', '../untrusted.sh', '/tmp/untrusted', '/tmp/rtk git status', 'sudo /tmp/untrusted', 'rtk /usr/bin/../../tmp/untrusted', 'rtk ~/untrusted']) {
  expect(t.commandDecision(command).decision === 'ask', `${command} must gate opaque code execution`);
}
expect(t.commandDecision('/usr/bin/printf x').decision === 'allow', 'trusted absolute system executable may allow');
expect(t.isInterpreterOpaque(['bash', '-c', 'git reset --hard']) === true, 'isInterpreterOpaque bash -c');
expect(t.isInterpreterOpaque(['bash', './untrusted.sh']) === true, 'isInterpreterOpaque script file');
expect(t.commandDecision('bash --version').decision === 'allow', 'unsupported raw shell executable may allow');
expect(t.commandDecision('rtk proxy bash --version').decision === 'allow', 'rtk proxy shell executable may allow');

// Protected paths
expect(t.isProtectedPath('.env') === true, '.env protected');
expect(t.isProtectedPath('.env.local') === true, 'root-relative .env variant protected');
expect(t.isProtectedPath('.envrc') === true, '.envrc protected');
expect(t.isProtectedPath('.envrc.local') === true, '.envrc variant protected');
expect(t.isProtectedPath('/tmp/.env.production') === true, 'absolute .env variant protected');
expect(t.isProtectedPath('.env.example') === false, 'public env template must not be protected');
expect(t.isProtectedPath('.ssh/.env.example') === true, 'env template within SSH directory must remain protected');
expect(t.isProtectedPath('.aws/.env.example') === true, 'env template within AWS directory must remain protected');
expect(t.isProtectedPath('src/app.env') === true, 'app.env protected');
expect(t.isProtectedPath('secrets.json') === true, 'secrets. marker');
expect(t.isProtectedPath('apps/api/src/modules/provider-secrets/application/provider-secrets.service.ts') === false, 'secret words inside code path must not protect it');
expect(t.isProtectedPath('apps/api/src/modules/provider-credentials/application/provider-credentials.service.ts') === false, 'credential words inside code path must not protect it');
expect(t.isProtectedPath('apps/api/src/modules/secrets/application/secrets.service.ts') === false, 'secret-named source file must not protect it');
expect(t.isProtectedPath('apps/api/src/modules/credentials/application/credentials.service.ts') === false, 'credential-named source file must not protect it');
expect(t.isProtectedPath('credentials.types.ts') === false, 'credential-named compound source file must not protect it');
expect(t.isProtectedPath('secrets.fixture.ts') === false, 'secret-named compound source file must not protect it');
expect(t.isProtectedPath('credentials.ts') === true, 'literal credential source file protected');
expect(t.isProtectedPath('secrets.ts') === true, 'literal secret source file protected');
expect(t.isProtectedPath('credentials.json') === true, 'credential data file protected');
expect(t.isProtectedPath('.git/config') === true, '.git path protected');
expect(t.isProtectedPath('src/main.ts') === false, 'normal path not protected');
expect(t.nativePathDecision('write', 'apps/api/src/modules/provider-secrets/application/provider-secrets.service.ts').decision === 'allow', 'code path containing secret words must allow writes');
expect(t.nativePathDecision('write', 'apps/api/src/modules/provider-credentials/application/provider-credentials.service.ts').decision === 'allow', 'code path containing credential words must allow writes');
expect(t.nativePathDecision('write', 'apps/api/src/modules/secrets/application/secrets.service.ts').decision === 'allow', 'secret-named source file must allow writes');
expect(t.nativePathDecision('write', 'apps/api/src/modules/credentials/application/credentials.service.ts').decision === 'allow', 'credential-named source file must allow writes');
expect(t.nativePathDecision('write', 'credentials.types.ts').decision === 'allow', 'credential-named compound source file must allow writes');
expect(t.nativePathDecision('write', 'credentials.ts').decision === 'deny', 'literal credential source file must remain blocked');
expect(t.nativePathDecision('write', 'secrets.ts').decision === 'deny', 'literal secret source file must remain blocked');
expect(t.nativePathDecision('read', '.env').decision === 'ask', 'protected native read must ask for approval');
expect(t.nativePathDecision('read', '.envrc').decision === 'ask', '.envrc native read must ask for approval');
expect(t.nativePathDecision('write', '.env').decision === 'deny', 'protected native write must remain blocked');
expect(t.nativePathDecision('write', '.envrc').decision === 'deny', '.envrc native write must remain blocked');
expect(t.nativePathDecision('edit', '.env').decision === 'deny', 'protected native edit must remain blocked');
expect(t.nativePathDecision('edit', '.envrc').decision === 'deny', '.envrc native edit must remain blocked');
expect(t.nativePathDecision('write', '.env.example').decision === 'allow', 'public env template writes must allow');
expect(t.nativePathDecision('write', '.ssh/.env.example').decision === 'deny', 'SSH directory env template writes must remain blocked');
expect(t.nativePathDecision('write', '.aws/.env.example').decision === 'deny', 'AWS directory env template writes must remain blocked');
expect(t.nativePathDecision('read', 'src/main.ts').decision === 'allow', 'normal native read must allow');
expect(t.nativePathDecision('read', '/etc/passwd').decision === 'ask', 'outside-project native reads must ask');
expect(t.nativePathDecision('write', '/etc/hosts').decision === 'ask', 'outside-project native writes must ask');
expect(t.nativePathDecision('write', 'adapters/pi/tests/new-file.ts').decision === 'allow', 'project-local native writes must allow');
const nativeResolutionFixture = mkdtempSync(path.join(os.tmpdir(), 'b-agentic-native-resolution-'));
try {
  const project = path.join(nativeResolutionFixture, 'project');
  const protectedPath = path.join(project, 'credentials.ts');
  const outsidePath = path.join(nativeResolutionFixture, 'outside.txt');
  const ordinaryPath = path.join(project, 'ordinary.ts');
  mkdirSync(project, { recursive: true });
  writeFileSync(protectedPath, 'synthetic protected target');
  writeFileSync(outsidePath, 'synthetic outside target');
  writeFileSync(ordinaryPath, 'ordinary');
  const rawPaths = [
    ['@credentials.ts', 'protected'],
    ['@../outside.txt', 'outside'],
    [`file://${outsidePath}`, 'outside'],
    ['unicode\u202Fspace.txt', 'ordinary'],
    ['~/b-agentic-native-tool-path', 'outside'],
  ];
  writeFileSync(path.join(project, 'unicode space.txt'), 'unicode normalized');
  for (const [rawPath, kind] of rawPaths) {
    if (piPathUtils) {
      const expected = piPathUtils.resolveToCwd(rawPath, project);
      expect(t.resolveNativeToolPath(rawPath, project) === expected, `native resolver must match Pi resolveToCwd for ${rawPath}`);
    }
    for (const toolName of ['read', 'write', 'edit']) {
      const decision = t.nativePathDecision(toolName, rawPath, project).decision;
      const expectedDecision = kind === 'protected' ? (toolName === 'read' ? 'ask' : 'deny') : kind === 'outside' ? 'ask' : 'allow';
      expect(decision === expectedDecision, `${toolName} ${rawPath} must use its Pi-resolved target`);
    }
  }
  const projectAlias = path.join(nativeResolutionFixture, 'project-alias');
  symlinkSync(project, projectAlias, 'dir');
  for (const toolName of ['read', 'write', 'edit']) {
    expect(t.nativePathDecision(toolName, 'unicode\u202Fspace.txt', projectAlias).decision === 'allow', `${toolName} must permit a Pi-resolved path below a symlinked cwd`);
  }
  const fallbackRawPath = 'Meeting 10 AM.txt';
  writeFileSync(path.join(project, 'Meeting 10\u202FAM.txt'), 'Pi read fallback');
  if (piPathUtils) {
    expect(t.resolveNativeToolPath(fallbackRawPath, project, true) === piPathUtils.resolveReadPath(fallbackRawPath, project), 'native read resolver must match Pi filename fallbacks');
  }
  expect(t.nativePathDecision('read', fallbackRawPath, project).decision === 'allow', 'resolved Pi read fallback inside project must allow');
  const protectedLink = path.join(project, 'protected-link');
  symlinkSync(protectedPath, protectedLink);
  expect(t.nativePathDecision('read', protectedLink, project).decision === 'ask', 'native reads through Pi-resolved protected symlinks must ask');
  expect(t.nativePathDecision('write', protectedLink, project).decision === 'deny', 'native writes through Pi-resolved protected symlinks must deny');
  expect(t.nativePathDecision('edit', protectedLink, project).decision === 'deny', 'native edits through Pi-resolved protected symlinks must deny');
  expect(t.nativePathDecision('write', 'missing/new-file.ts', project).decision === 'allow', 'missing native writes below a confined existing ancestor must allow');
  expect(t.nativePathDecision('read', 'file://invalid-host/path', project).decision === 'ask', 'malformed native paths must fail closed');

  const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
  const asciiAgentRoot = path.join(nativeResolutionFixture, 'agent space');
  const unicodeAgentRoot = path.join(nativeResolutionFixture, 'agent\u00A0space');
  const genuineInstalledSkill = path.join(asciiAgentRoot, 'skills', 'b-plan', 'SKILL.md');
  const unicodeOutsideSkill = path.join(unicodeAgentRoot, 'skills', 'b-plan', 'SKILL.md');
  const protectedInstalledSkill = path.join(asciiAgentRoot, 'skills', 'b-implement', 'SKILL.md');
  try {
    mkdirSync(path.dirname(genuineInstalledSkill), { recursive: true });
    mkdirSync(path.dirname(unicodeOutsideSkill), { recursive: true });
    mkdirSync(path.dirname(protectedInstalledSkill), { recursive: true });
    writeFileSync(genuineInstalledSkill, 'genuine installed skill');
    writeFileSync(unicodeOutsideSkill, 'unicode-space outside skill');
    symlinkSync(protectedPath, protectedInstalledSkill);
    process.env.PI_CODING_AGENT_DIR = asciiAgentRoot;
    const unicodeOutsideUrl = pathToFileURL(unicodeOutsideSkill).href;
    if (piPathUtils) {
      expect(piPathUtils.resolveReadPath(unicodeOutsideUrl, project) === unicodeOutsideSkill, 'Pi resolver must retain URL-decoded Unicode spaces in effective targets');
    }
    expect(t.nativePathDecision('read', unicodeOutsideUrl, project).decision === 'ask', 'installed-skill allowance must not normalize an already-resolved outside target twice');
    expect(t.nativePathDecision('read', genuineInstalledSkill, project).decision === 'allow', 'genuine installed skill reads must remain allowed');
    expect(t.nativePathDecision('read', protectedInstalledSkill, project).decision === 'ask', 'protected installed-skill targets must still ask before any installed-skill allowance');
  } finally {
    if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
  }

  const nativeResolverContext = { ...noUiContext, cwd: project };
  await handlers.turn_start({ type: 'turn_start', turnIndex: 100, timestamp: 100 }, nativeResolverContext);
  for (const toolName of ['read', 'write', 'edit']) {
    const result = await toolCallHandler({ toolName, input: { path: '@credentials.ts' } }, nativeResolverContext);
    expect(result?.block === true, `permission integration must use ctx.cwd for ${toolName} @credentials.ts`);
  }
  await handlers.turn_start({ type: 'turn_start', turnIndex: 101, timestamp: 101 }, nativeResolverContext);
  expect(await toolCallHandler({ toolName: 'edit', input: { path: '@ordinary.ts', edits: [] } }, nativeResolverContext) === undefined, 'first Pi-normalized native edit must allow');
  const normalizedDuplicate = await toolCallHandler({ toolName: 'edit', input: { path: 'ordinary.ts', edits: [] } }, nativeResolverContext);
  expect(normalizedDuplicate?.block === true, 'Pi-normalized duplicate native edits must share one canonical path');
} finally {
  rmSync(nativeResolutionFixture, { recursive: true, force: true });
}
const nativeToolContext = { ...noUiContext, cwd: root };
await handlers.turn_start({ type: 'turn_start', turnIndex: 1, timestamp: 1 }, nativeToolContext);
expect(await toolCallHandler({ toolName: 'edit', input: { path: 'README.md', edits: [{ oldText: 'one', newText: 'two' }] } }, nativeToolContext) === undefined, 'first native edit for a path must remain allowed');
const duplicateEdit = await toolCallHandler({ toolName: 'edit', input: { path: './README.md', edits: [{ oldText: 'three', newText: 'four' }] } }, nativeToolContext);
expect(duplicateEdit?.block === true && duplicateEdit.reason.includes('merge disjoint replacements into one edits[] call') && duplicateEdit.reason.includes('reread and retry next turn'), 'same-turn duplicate native edit must be blocked with recovery guidance');
await handlers.turn_start({ type: 'turn_start', turnIndex: 2, timestamp: 2 }, nativeToolContext);
expect(await toolCallHandler({ toolName: 'edit', input: { path: 'README.md', edits: [{ oldText: 'five', newText: 'six' }] } }, nativeToolContext) === undefined, 'native edit must be permitted again on a later turn');
sentMessages.length = 0;
await handlers.tool_result({
  type: 'tool_result', toolCallId: 'edit-1', toolName: 'edit', input: { path: 'README.md' },
  content: [{ type: 'text', text: 'Could not find edits[0] in README.md. The oldText must match exactly including all whitespace and newlines.' }],
  isError: true,
}, nativeToolContext);
expect(sentMessages.length === 1 && sentMessages[0].options.deliverAs === 'steer' && sentMessages[0].message.display === false && sentMessages[0].message.details.path === 'README.md' && sentMessages[0].message.content.includes('Immediately read README.md') && sentMessages[0].message.content.includes('one exact retry'), 'exact-oldText failures must enqueue a path-specific recovery steer');
await handlers.tool_result({
  type: 'tool_result', toolCallId: 'edit-2', toolName: 'edit', input: { path: 'README.md' },
  content: [{ type: 'text', text: 'Could not find the exact text in README.md. The old text must match exactly including all whitespace and newlines.' }],
  isError: true,
}, nativeToolContext);
expect(sentMessages.length === 2 && sentMessages[1].message.details.path === 'README.md' && sentMessages[1].options.deliverAs === 'steer', 'single-edit exact-oldText failures must enqueue recovery for the runtime wording');
await handlers.tool_result({
  type: 'tool_result', toolCallId: 'edit-3', toolName: 'edit', input: { path: 'README.md' },
  content: [{ type: 'text', text: 'Could not edit README.md: permission denied.' }],
  isError: true,
}, nativeToolContext);
expect(sentMessages.length === 2, 'unrelated native edit errors must not enqueue recovery');
const installedSkillFixture = mkdtempSync(path.join(os.tmpdir(), 'b-agentic-installed-skills-'));
const installedSkillAliasParent = mkdtempSync(path.join(os.tmpdir(), 'b-agentic-installed-skills-alias-'));
const installedSkillAlias = path.join(installedSkillAliasParent, 'agent');
const externalSkillFixture = mkdtempSync(path.join(os.tmpdir(), 'b-agentic-external-skill-'));
const previousPiAgentDir = process.env.PI_CODING_AGENT_DIR;
try {
  const installedSkillPath = path.join(installedSkillFixture, 'skills', 'b-implement', 'SKILL.md');
  const installedOtherPath = path.join(installedSkillFixture, 'notes.md');
  const installedCustomSkillPath = path.join(installedSkillFixture, 'skills', 'b-custom', 'SKILL.md');
  const outsideSkillTarget = path.join(externalSkillFixture, 'outside-skill.md');
  mkdirSync(path.dirname(installedSkillPath), { recursive: true });
  mkdirSync(path.dirname(installedCustomSkillPath), { recursive: true });
  writeFileSync(installedSkillPath, 'Generated from skills/registry.yaml');
  writeFileSync(installedOtherPath, 'user data');
  writeFileSync(installedCustomSkillPath, 'user skill');
  writeFileSync(outsideSkillTarget, 'outside target');
  symlinkSync(installedSkillFixture, installedSkillAlias, 'dir');
  process.env.PI_CODING_AGENT_DIR = installedSkillAlias;
  expect(t.nativePathDecision('read', installedSkillPath).decision === 'allow', 'installed b-agentic skill reads through a root alias must auto-allow');
  expect(t.nativePathDecision('write', installedSkillPath).decision === 'ask', 'installed skill writes must remain approval-gated');
  expect(t.nativePathDecision('read', installedOtherPath).decision === 'ask', 'other Pi-agent files must remain approval-gated');
  expect(t.nativePathDecision('read', installedCustomSkillPath).decision === 'ask', 'unknown installed skills must remain approval-gated');
  const linkedSkillPath = path.join(installedSkillFixture, 'skills', 'b-debug', 'SKILL.md');
  mkdirSync(path.dirname(linkedSkillPath), { recursive: true });
  symlinkSync(outsideSkillTarget, linkedSkillPath);
  expect(t.nativePathDecision('read', linkedSkillPath).decision === 'ask', 'symlinked installed skill reads outside the agent root must remain gated');
} finally {
  if (previousPiAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousPiAgentDir;
  rmSync(installedSkillAliasParent, { recursive: true, force: true });
  rmSync(installedSkillFixture, { recursive: true, force: true });
  rmSync(externalSkillFixture, { recursive: true, force: true });
}
const codegraphTool = 'codegraph_codegraph_explore';
const codegraphArgs = { query: 'approval policy' };
expect(t.isTrustedManagedTool('codegraph', codegraphTool, codegraphArgs) === true, 'classified CodeGraph exploration must be trusted');
expect(t.isMcpOrCustomTool(codegraphTool, codegraphArgs) === false, 'CodeGraph direct execution must auto-allow');
expect(t.isMcpOrCustomTool(`mcp__codegraph__${codegraphTool}`, codegraphArgs) === false, 'CodeGraph prefixed execution must auto-allow');
expect(t.isMcpOrCustomTool('mcp__firecrawl__codegraph_codegraph_explore', codegraphArgs) === true, 'mismatched managed namespace must remain gated');
expect(t.isMcpOrCustomTool('mcp__user_server__codegraph_codegraph_explore', codegraphArgs) === true, 'unmanaged prefixed namespaces must remain gated');
const protectedPathFixture = mkdtempSync(path.join(os.tmpdir(), 'b-agentic-protected-path-'));
try {
  const secretPath = path.join(protectedPathFixture, '.env');
  const secretLink = path.join(protectedPathFixture, 'safe-link');
  const secretDirectory = path.join(protectedPathFixture, '.ssh');
  const secretDirectoryLink = path.join(protectedPathFixture, 'safe-directory');
  writeFileSync(secretPath, 'secret');
  mkdirSync(secretDirectory);
  symlinkSync(secretPath, secretLink);
  symlinkSync(secretDirectory, secretDirectoryLink);
  expect(t.nativePathDecision('read', secretLink).decision === 'ask', 'symlinked protected read must ask for approval');
  expect(t.nativePathDecision('write', secretLink).decision === 'deny', 'symlinked protected write must deny');
  expect(t.nativePathDecision('edit', path.join(secretDirectoryLink, 'new-file')).decision === 'deny', 'protected write through symlinked directory must deny');
  expect(t.commandDecision(`cat ${secretLink}`).decision === 'ask', 'shell reads through protected symlinks must ask');
  expect(t.commandDecision(`printf x > ${secretLink}`).decision === 'ask', 'shell writes through protected symlinks must ask');
} finally {
  rmSync(protectedPathFixture, { recursive: true, force: true });
}
for (const pathValue of ['.npmrc', '.netrc', '.pypirc', '.git-credentials', '.config/gh/hosts.yml', '.ssh/config']) {
  expect(t.nativePathDecision('read', pathValue).decision === 'ask', `${pathValue} must require approval`);
}
const protectedReadReason = t.nativePathDecision('read', '.env').reason;
expect(await t.confirmOrBlock({ hasUI: false, ui: { confirm: async () => true } }, 'test', 'test', protectedReadReason), 'protected native read must fail closed without UI');
expect((await t.confirmOrBlock({ hasUI: true, ui: { confirm: async () => true } }, 'test', 'test', protectedReadReason)) === undefined, 'approved protected native read must allow');
expect(await t.confirmOrBlock({ hasUI: true, ui: { confirm: async () => false } }, 'test', 'test', protectedReadReason), 'denied protected native read must block');

// Explicitly targeted mcp proxy executions route to the adapter broker;
// metadata and lifecycle selectors remain behind generic approval.
expect(t.isMcpOrCustomTool('bash') === false, 'bash is specialized');
for (const input of [
  {},
  { server: 'linear' },
  { search: 'get_issue', server: 'linear' },
  { describe: 'get_issue', server: 'linear' },
  { search: 'symbol' },
  { describe: 'tool' },
  { action: 'ui-messages' },
  { server: 'firecrawl' },
  { tool: 'user_tool' },
  { tool: 'firecrawl_parse' },
  { server: 'firecrawl', tool: 'firecrawl_search', extra: true },
  { server: '', tool: 'firecrawl_search' },
  { server: 'firecrawl', tool: '' },
  { server: 'firecrawl', tool: 'firecrawl_search', args: 'not-json' },
]) {
  expect(t.isMcpOrCustomTool('mcp', input) === true, 'non-execution mcp selectors must retain generic approval');
}
for (const input of [
  { server: 'user-server', tool: 'user_tool' },
  { server: 'firecrawl', tool: 'firecrawl_search', args: '{}' },
]) {
  expect(t.isMcpProxyToolExecution(input) === true, 'valid server/tool proxy executions must be recognized');
  expect(t.isMcpOrCustomTool('mcp', input) === false, 'valid proxy executions must bypass generic approval');
}
expect(t.isTrustedManagedGatewayCall({ server: 'firecrawl', tool: 'firecrawl_search', args: '{"query":"Pi","limit":1}' }) === true, 'validated conditional gateway execution must be classified safe');
expect(t.isTrustedManagedGatewayCall({ server: 'linear', tool: 'linear_get_issue', args: '{"issueId":"BAO-7"}' }) === false, 'retired Linear operations must not be trusted');
expect(t.isTrustedManagedGatewayCall({ server: 'mobbin', tool: 'mobbin_search_screens', args: '{}' }) === false, 'retired Mobbin operations must not be trusted');
for (const input of [
  { connect: 'firecrawl', tool: 'firecrawl_agent' },
  { action: 'auth-start', server: 'linear' },
  { server: 'linear', tool: 'get_issue_context', args: '{}' },
  { tool: 'playwright_browser_click' },
  { tool: 'playwright_browser_navigate', args: JSON.stringify({ url: 'https://example.com' }) },
  { tool: 'playwright_browser_take_screenshot', args: JSON.stringify({ filename: 'shot.png' }) },
]) {
  expect(t.isTrustedManagedGatewayCall(input) === false, 'unsafe or ambiguous gateway calls must remain untrusted');
}
expect(t.isMcpOrCustomTool('firecrawl_firecrawl_agent') === true, 'direct managed Firecrawl tools retain the top-level approval gate');
expect(t.isMcpOrCustomTool('firecrawl_developer_search') === true, 'direct trusted-looking Firecrawl names retain the top-level approval gate');
expect(t.isMcpOrCustomTool('browser_click') === true, 'direct managed Playwright tools retain the top-level approval gate');
expect(t.isMcpOrCustomTool('browser_snapshot') === true, 'direct trusted-looking Playwright names retain the top-level approval gate');
expect(t.isMcpOrCustomTool('some-extension-tool') === true, 'unknown tool is custom');
expect(t.isTrustedManagedTool('playwright', 'browser_snapshot', { depth: 2 }) === true, 'safe Playwright snapshots are trusted');
expect(t.isTrustedManagedTool('playwright', 'browser_snapshot', { filename: 'artifacts/snapshot.md' }) === false, 'project-confined snapshot filenames still require approval as local artifacts');
expect(t.isTrustedManagedTool('playwright', 'browser_snapshot', { filename: '/tmp/snapshot.md' }) === false, 'outside-project snapshot filenames require approval');
expect(t.isTrustedManagedTool('playwright', 'browser_snapshot', { target: 'main', depth: 1, filename: 'docs/snapshot.md' }) === false, 'snapshot artifact output requires approval alongside safe arguments');
expect(t.isTrustedManagedTool('playwright', 'browser_snapshot', { target: 'main', depth: 1, boxes: true }) === true, 'snapshots without an output path stay trusted');
expect(t.isTrustedManagedTool('playwright', 'browser_close') === false, 'browser close requires approval');
expect(t.isTrustedManagedTool('playwright', 'browser_resize') === false, 'browser resize requires approval');
expect(t.isTrustedManagedTool('playwright', 'browser_hover') === false, 'browser hover requires approval');
expect(t.isTrustedManagedTool('firecrawl', 'new_tool') === false, 'unlisted managed tool is not trusted');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_search', { query: 'Pi coding agent', limit: 10 }) === true, 'bounded Firecrawl search is trusted');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_search', { query: 'Pi coding agent', limit: 10, highlights: true }) === true, 'Firecrawl search highlights are trusted');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_search', { query: 'Pi coding agent', limit: 10, unexpected: true }) === false, 'unknown Firecrawl search arguments require approval');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_developer_search', { query: 'Pi MCP adapter approval broker', k: 10 }) === true, 'Firecrawl developer search is trusted');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_scrape', { url: 'https://example.org' }) === true, 'public Firecrawl scrape is trusted');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_scrape', { url: 'https://example.org', skipTlsVerification: true }) === false, 'Firecrawl scrape with TLS verification disabled must require approval');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_search', { query: 'Pi coding agent' }) === false, 'Firecrawl search without an explicit bound requires approval');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_search', { query: 'Pi coding agent', limit: 11 }) === false, 'Firecrawl search above the local bound requires approval');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_search', { query: 'Pi coding agent', limit: 0 }) === false, 'empty Firecrawl search bounds require approval');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_map', { url: 'https://example.org', limit: 10 }) === true, 'bounded public Firecrawl map is trusted');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_map', { url: 'http://127.0.0.1', limit: 10 }) === false, 'private Firecrawl map must require approval');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_map', { url: 'https://user:token@example.org', limit: 10 }) === false, 'credential-bearing Firecrawl map must require approval');
for (const [tool, input, expected, description] of [
  ['firecrawl_search', { query: 'Pi coding agent', limit: '10' }, false, 'Firecrawl search string bounds require approval'],
  ['firecrawl_search', { query: 'Pi coding agent', limit: NaN }, false, 'Firecrawl search NaN bounds require approval'],
  ['firecrawl_search', { query: 'Pi coding agent', limit: 1.5 }, false, 'Firecrawl search fractional bounds require approval'],
  ['firecrawl_search', { query: 'Pi coding agent', limit: -1 }, false, 'Firecrawl search negative bounds require approval'],
  ['firecrawl_map', { url: 'https://example.org', limit: 100 }, true, 'Firecrawl map upper boundary is trusted'],
  ['firecrawl_map', { url: 'https://example.org', limit: 101 }, false, 'Firecrawl map above the local bound requires approval'],
  ['firecrawl_map', { url: 'https://example.org', limit: '10' }, false, 'Firecrawl map string bounds require approval'],
  ['firecrawl_map', { url: 'https://example.org', limit: NaN }, false, 'Firecrawl map NaN bounds require approval'],
  ['firecrawl_map', { url: 'https://example.org', limit: 1.5 }, false, 'Firecrawl map fractional bounds require approval'],
  ['firecrawl_map', { url: 'https://example.org', limit: -1 }, false, 'Firecrawl map negative bounds require approval'],
]) {
  expect(t.isTrustedManagedTool('firecrawl', tool, input) === expected, description);
}
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_extract', { urls: ['https://example.org'], enableWebSearch: false }) === true, 'bounded public Firecrawl extract is trusted');
expect(t.isTrustedManagedTool('firecrawl', 'firecrawl_extract', { urls: ['https://example.org'], allowExternalLinks: true }) === false, 'unbounded Firecrawl extract must require approval');
expect(t.isTrustedManagedTool('linear', 'linear_get_issue') === false, 'retired Linear tools are not trusted');
expect(t.isTrustedManagedTool('mobbin', 'mobbin_search_screens') === false, 'retired Mobbin tools are not trusted');
expect(t.isTrustedManagedTool('mobbin', 'mobbin_update_screen') === false, 'retired Mobbin mutation tools are not trusted');
expect(t.isTrustedManagedTool('linear', 'list_issues') === false, 'retired Linear tools are not trusted');
expect(t.isTrustedManagedTool('user-server', 'user_tool') === false, 'unmanaged server is not trusted');
expect(t.approvalLabel('\u001b[31mtool\u0007\u009b') === ' [31mtool  ', 'broker approval labels must strip terminal control characters');
expect(!t.MANAGED_MCP_SERVERS.has('linear'), 'Linear is not a managed MCP server');
expect(!t.MANAGED_MCP_SERVERS.has('mobbin'), 'Mobbin is not a managed MCP server');
expect(t.MANAGED_MCP_SERVERS.has('playwright'), 'managed MCP servers present');

console.log('pi permission behavioral fixtures ok');
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
	local release_fixture="$1"
	local sandbox="$WORK_DIR/pi"
	local sandbox_adapter="$WORK_DIR/pi-adapter"
	local sandbox_preserve="$WORK_DIR/pi-preserve"
	local sandbox_replace="$WORK_DIR/pi-replace"
	local sandbox_mcp_merge="$WORK_DIR/pi-mcp-merge"
	local sandbox_extension_restore="$WORK_DIR/pi-extension-restore"
	local sandbox_extension_modified="$WORK_DIR/pi-extension-modified"
	local sandbox_extension_symlink="$WORK_DIR/pi-extension-symlink"
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
		"$sandbox_skill_modified/home" \
		"$sandbox_skill_reinstall/home" \
		"$sandbox_skill_stale/home" \
		"$sandbox_skill_symlink/home"

	# Core install layout without adapter package.
	expect_install_status 0 "$sandbox" "$release_fixture"
	assert_file "$sandbox/home/.pi/agent/AGENTS.md"
	assert_file "$sandbox/home/.pi/agent/skills/b-plan/SKILL.md"
	assert_no_path "$sandbox/home/.pi/agent/skills/b-plan/prompt.md"
	assert_file "$sandbox/home/.pi/agent/b-agentic/references/kernel.template.md"
	assert_file "$sandbox/home/.pi/agent/b-agentic/references/mcp_operations.yaml"
	assert_file "$sandbox/home/.pi/agent/b-agentic/references/capabilities.yaml"
	assert_no_path "$sandbox/home/.pi/agent/b-agentic/references/contract"
	assert_file "$sandbox/home/.pi/agent/mcp.json"
	for extension in b-agentic-permissions.ts b-agentic-mcp-permissions.ts b-agentic-auto-mode.ts b-agentic-sync.ts; do
		assert_file "$sandbox/home/.pi/agent/extensions/$extension"
		assert_file "$sandbox/home/.pi/agent/b-agentic/extensions/$extension"
	done
	for support in shell.ts mcp.ts permissions-data.ts worker.ts state.ts auto.ts capabilities.ts status.ts; do
		assert_file "$sandbox/home/.pi/agent/extensions/b-agentic-support/$support"
		assert_file "$sandbox/home/.pi/agent/b-agentic/extensions/b-agentic-support/$support"
	done
	assert_file "$sandbox/home/.pi/agent/b-agentic/install.json"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilityContractVersion'] == 2"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['contractVersion'] == 2"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "len(data['capabilities']['states']) == 18"
	assert_not_contains "$sandbox/home/.pi/agent/b-agentic/install.json" 'extension.b-agentic-consult'
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['states']['package.pi-mcp-adapter']['state'] == 'ready'"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['states']['package.pi-todo']['state'] == 'ready'"
	assert_not_contains "$sandbox/home/.pi/agent/b-agentic/install.json" 'package.pi-lsp'
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['states']['extension.b-agentic-status']['state'] == 'ready'"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['paths']['capabilityContract'].endswith('/references/capabilities.yaml')"
	assert_contains "$sandbox/home/.pi/agent/mcp.json" '"codegraph"'
	assert_contains "$sandbox/home/.pi/agent/mcp.json" '"lifecycle": "lazy"'
	assert_contains "$sandbox/home/.pi/agent/extensions/b-agentic-permissions.ts" 'tool_call'
	assert_equal_files "$sandbox/home/.pi/agent/extensions/b-agentic-preview-markdown.ts" "$sandbox/source/adapters/pi/packages/preview-markdown/extensions/b-agentic-preview-markdown.ts"
	assert_contains "$sandbox/home/.pi/agent/extensions/b-agentic-preview-markdown.ts" 'preview_markdown'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"mcpAdapterState": "ready"'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"extensions"'
	assert_contains "$sandbox/home/.pi/agent/AGENTS.md" 'b-agentic-managed'
	assert_file "$sandbox/smoke-bin/pi-install.log"
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:pi-mcp-adapter'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:pi-observational-memory'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@sreetej510/pi-usage'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@gotgenes/pi-anthropic-auth'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:pi-intercom'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@juicesharp/rpiv-ask-user-question'
	assert_not_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@narumitw/pi-lsp'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@juicesharp/rpiv-todo'
	assert_not_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@juicesharp/rpiv-ask-user-question@'
	assert_not_contains "$sandbox/smoke-bin/pi-install.log" 'npm:@juicesharp/rpiv-todo@'
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
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		bash "$ROOT_DIR/install.sh" --sync >/dev/null 2>&1
	assert_equal_files "$sandbox/home/.pi/agent/mcp.json" "$sync_mcp_snapshot"
	assert_equal_files "$sandbox/home/.pi/agent/b-agentic/install.json" "$sync_manifest_snapshot"
	assert_equal_files "$sandbox/home/.pi/agent/b-agentic/tooling/install/manifest_uninstall.py" "$sync_helper_snapshot"
	assert_equal_files "$sandbox/home/.pi/agent/skills/b-plan/SKILL.md" "$sandbox/source/skills/b-plan/SKILL.md"
	assert_equal_files "$sandbox/home/.pi/agent/AGENTS.md" "$sandbox/source/references/kernel.template.md"
	assert_equal_files "$sandbox/home/.pi/agent/extensions/b-agentic-sync.ts" "$sandbox/source/adapters/pi/extensions/b-agentic-sync.ts"
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
	HOME="$sandbox/home" \
		PATH="$(smoke_runtime_cli_path "$sandbox")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --update >/dev/null 2>&1
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
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
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
	expect_install_status 1 "$sandbox_preserve" "$release_fixture"
	assert_file "$sandbox_preserve/home/.pi/agent/AGENTS.md"
	assert_contains "$sandbox_preserve/home/.pi/agent/AGENTS.md" 'user-owned pi kernel'
	assert_file "$sandbox_preserve/home/.pi/agent/b-agentic/install.json"
	assert_contains "$sandbox_preserve/home/.pi/agent/b-agentic/install.json" '"activationState": "pending"'

	# --replace-memory overwrites user kernel.
	mkdir -p "$sandbox_replace/home/.pi/agent"
	printf 'user-owned pi kernel\n' >"$sandbox_replace/home/.pi/agent/AGENTS.md"
	expect_install_status 0 "$sandbox_replace" "$release_fixture" --replace-memory
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
	expect_install_status 0 "$sandbox_mcp_merge" "$release_fixture"
	assert_contains "$sandbox_mcp_merge/home/.pi/agent/mcp.json" '"user-server"'
	assert_json_value "$sandbox_mcp_merge/home/.pi/agent/mcp.json" "data['mcpServers']['serena'] == {'command': 'user-owned-serena', 'args': ['--custom'], 'env': {'USER_SETTING': 'keep-me'}, 'lifecycle': 'eager'}"
	assert_json_value "$sandbox_mcp_merge/home/.pi/agent/mcp.json" "data['settings']['serenaPreference'] == 'keep-me'"

	# Uninstall restores pre-existing entrypoint and support files after reinstall and managed-file deletion.
	mkdir -p "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-support"
	printf 'user-owned permission extension\n' >"$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-permissions.ts"
	printf 'user-owned status extension\n' >"$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-status.ts"
	printf 'user-owned shell support\n' >"$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-support/shell.ts"
	expect_install_status 0 "$sandbox_extension_restore" "$release_fixture"
	assert_not_contains "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-permissions.ts" 'user-owned permission extension'
	expect_install_status 0 "$sandbox_extension_restore" "$release_fixture"
	rm "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-permissions.ts"
	rm "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-status.ts"
	rm "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-support/shell.ts"
	expect_install_status 0 "$sandbox_extension_restore" "$release_fixture"
	expect_install_status 0 "$sandbox_extension_restore" "$release_fixture" --uninstall
	assert_contains "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-permissions.ts" 'user-owned permission extension'
	assert_contains "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-status.ts" 'user-owned status extension'
	assert_contains "$sandbox_extension_restore/home/.pi/agent/extensions/b-agentic-support/shell.ts" 'user-owned shell support'

	# Uninstall preserves symlink destinations instead of restoring through them.
	printf 'user-owned permission extension\n' >"$sandbox_extension_symlink/home/.pi/agent/extensions/b-agentic-permissions.ts"
	expect_install_status 0 "$sandbox_extension_symlink" "$release_fixture"
	cp "$sandbox_extension_symlink/home/.pi/agent/extensions/b-agentic-permissions.ts" "$sandbox_extension_symlink/target.ts"
	rm "$sandbox_extension_symlink/home/.pi/agent/extensions/b-agentic-permissions.ts"
	ln -s "$sandbox_extension_symlink/target.ts" "$sandbox_extension_symlink/home/.pi/agent/extensions/b-agentic-permissions.ts"
	expect_install_status 0 "$sandbox_extension_symlink" "$release_fixture" --uninstall
	[ -L "$sandbox_extension_symlink/home/.pi/agent/extensions/b-agentic-permissions.ts" ] || fail "expected symlinked extension to be preserved"
	assert_contains "$sandbox_extension_symlink/target.ts" 'tool_call'
	assert_not_contains "$sandbox_extension_symlink/target.ts" 'user-owned permission extension'

	# Uninstall preserves an extension modified after installation.
	expect_install_status 0 "$sandbox_extension_modified" "$release_fixture"
	printf 'post-install user modification\n' >"$sandbox_extension_modified/home/.pi/agent/extensions/b-agentic-permissions.ts"
	expect_install_status 0 "$sandbox_extension_modified" "$release_fixture" --uninstall
	assert_contains "$sandbox_extension_modified/home/.pi/agent/extensions/b-agentic-permissions.ts" 'post-install user modification'

	# Reinstall preserves a modified managed skill.
	expect_install_status 0 "$sandbox_skill_reinstall" "$release_fixture"
	printf '\npost-install skill modification\n' >>"$sandbox_skill_reinstall/home/.pi/agent/skills/b-plan/SKILL.md"
	expect_install_status 0 "$sandbox_skill_reinstall" "$release_fixture"
	assert_contains "$sandbox_skill_reinstall/home/.pi/agent/skills/b-plan/SKILL.md" 'post-install skill modification'

	# Stale modified and symlinked skills survive reinstall pruning.
	expect_install_status 0 "$sandbox_skill_stale" "$release_fixture"
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
	expect_install_status 0 "$sandbox_skill_stale" "$release_fixture"
	assert_contains "$sandbox_skill_stale/home/.pi/agent/skills/stale-skill/SKILL.md" 'user stale-skill edit'
	[ -L "$sandbox_skill_stale/home/.pi/agent/skills/stale-link" ] || fail "expected stale skill symlink to be preserved"

	# Source-backed uninstall preserves a modified skill.
	expect_install_status 0 "$sandbox_skill_modified" "$release_fixture"
	printf '\npost-install skill modification\n' >>"$sandbox_skill_modified/home/.pi/agent/skills/b-plan/SKILL.md"
	expect_install_status 0 "$sandbox_skill_modified" "$release_fixture" --uninstall
	assert_contains "$sandbox_skill_modified/home/.pi/agent/skills/b-plan/SKILL.md" 'post-install skill modification'

	# Source-backed uninstall preserves a symlinked skill.
	expect_install_status 0 "$sandbox_skill_symlink" "$release_fixture"
	cp -R "$sandbox_skill_symlink/home/.pi/agent/skills/b-plan" "$sandbox_skill_symlink/target-skill"
	rm -rf "$sandbox_skill_symlink/home/.pi/agent/skills/b-plan"
	ln -s "$sandbox_skill_symlink/target-skill" "$sandbox_skill_symlink/home/.pi/agent/skills/b-plan"
	expect_install_status 0 "$sandbox_skill_symlink" "$release_fixture" --uninstall
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
	expect_install_status 0 "$sandbox" "$release_fixture" --uninstall
	assert_no_path "$sandbox/home/.pi/agent/skills/b-plan"
	assert_no_path "$sandbox/home/.pi/agent/b-agentic/install.json"
	assert_no_path "$sandbox/home/.pi/agent/extensions/b-agentic-permissions.ts"
	assert_no_path "$sandbox/home/.pi/agent/themes/dracula.json"
	# User MCP entries would be preserved by merge cleanup; managed-only install removes mcp.json entirely.
}
