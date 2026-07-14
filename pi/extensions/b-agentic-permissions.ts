/**
 * b-agentic first-party permission extension for Pi.
 *
 * Enforces kernel safety gates via Pi's tool_call event:
 * - ask: commits, pushes, pulls, reverts, dependency writes, long-lived services, rm -rf
 * - deny: destructive git history/worktree rewrites and selected docker prune/rm families
 * - block write/edit to secret and repository-control paths
 * - allow MCP metadata discovery and operation-level trusted managed MCP tools
 * - ask before Firecrawl/Playwright external-mutation tools, user/unknown MCP servers,
 *   auth actions, and other custom tools
 *
 * Normalizes bare and rtk-wrapped shell commands, compound shell segments,
 * env/sudo wrappers, and git option prefixes. Fails closed without UI.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type Decision = "allow" | "ask" | "deny";

const ASK_COMMANDS: string[][] = [
  ["git", "commit"],
  ["git", "push"],
  ["git", "pull"],
  ["git", "revert"],
  ["npm", "install"], ["npm", "i"], ["npm", "ci"], ["npm", "add"], ["npm", "remove"], ["npm", "uninstall"], ["npm", "update"],
  ["pnpm", "install"], ["pnpm", "i"], ["pnpm", "add"], ["pnpm", "remove"], ["pnpm", "uninstall"], ["pnpm", "update"], ["pnpm", "up"],
  ["yarn", "install"], ["yarn", "add"], ["yarn", "remove"], ["yarn", "uninstall"], ["yarn", "upgrade"], ["yarn", "up"],
  ["bun", "install"], ["bun", "add"], ["bun", "remove"], ["bun", "uninstall"], ["bun", "update"],
  ["cargo", "install"], ["cargo", "add"], ["cargo", "remove"], ["cargo", "update"],
  ["go", "install"], ["go", "get"],
  ["pip", "install"], ["pip", "uninstall"], ["pip3", "install"], ["pip3", "uninstall"],
  ["poetry", "add"], ["poetry", "install"], ["poetry", "remove"], ["poetry", "update"],
  ["uv", "add"], ["uv", "remove"], ["uv", "sync"], ["uv", "lock"], ["uv", "pip", "install"], ["uv", "pip", "uninstall"],
  ["rm", "-rf"],
  ["rm", "-fr"],
];

const DENY_COMMANDS: string[][] = [
  ["git", "reset", "--hard"],
  ["git", "clean", "-f"],
  ["git", "push", "--force"],
  ["git", "push", "--force-with-lease"],
  ["git", "branch", "-D"],
  ["docker", "system", "prune"],
  ["docker", "volume", "rm"],
];

const SERVICE_COMMANDS: string[][] = [
  ["docker", "compose", "up"],
  ["docker-compose", "up"],
  ["npm", "run", "dev"],
  ["pnpm", "dev"],
  ["yarn", "dev"],
  ["bun", "run", "dev"],
  ["cargo", "watch"],
];

const PROTECTED_PATH_MARKERS = [
  ".env",
  "credentials.",
  "secrets.",
  ".pem",
  ".key",
  ".p12",
  ".pfx",
  "/.git/",
  ".git/",
  "id_rsa",
  "id_ed25519",
  "id_ecdsa",
  "id_dsa",
];

/**
 * Built-in Pi tools with specialized policy.
 * Legacy discovery tools (grep/find/ls) are handled below so they cannot
 * bypass the kernel's RTK and shell-tool policy. Managed MCP tools are
 * auto-approved only via operation-level allowlists below.
 */
const SPECIALIZED_TOOLS = new Set([
  "bash",
  "write",
  "edit",
  "read",
  "grep",
  "find",
  "ls",
]);

/** Managed MCP servers installed by b-agentic. */
const MANAGED_MCP_SERVERS = new Set([
  "serena",
  "codegraph",
  "context7",
  "brave-search",
  "firecrawl",
  "playwright",
]);

/**
 * Managed MCP operations auto-approved without a prompt. These sets must remain
 * closed-world mirrors of references/mcp_operations.yaml: any unclassified or
 * mutating operation requires approval.
 */
const SERENA_TRUSTED_TOOLS = new Set([
  "serena_search_for_pattern",
  "serena_get_symbols_overview",
  "serena_find_symbol",
  "serena_find_referencing_symbols",
  "serena_find_implementations",
  "serena_find_declaration",
  "serena_get_diagnostics_for_file",
  "serena_read_memory",
  "serena_list_memories",
  "serena_initial_instructions",
]);

const CODEGRAPH_TRUSTED_TOOLS = new Set([
  "codegraph_codegraph_explore",
]);

const CONTEXT7_TRUSTED_TOOLS = new Set([
  "context7_resolve-library-id",
  "context7_query-docs",
]);

const BRAVE_SEARCH_TRUSTED_TOOLS = new Set([
  "brave_search_brave_web_search",
  "brave_search_brave_local_search",
  "brave_search_brave_video_search",
  "brave_search_brave_image_search",
  "brave_search_brave_news_search",
  "brave_search_brave_summarizer",
  "brave_search_brave_llm_context",
  "brave_search_brave_place_search",
]);

/**
 * Firecrawl tools auto-approved without a prompt (bounded read/extract/status only).
 * External-mutation and local-upload tools stay gated: agent, crawl, interact,
 * monitor, feedback submission, and parse (local file upload).
 */
const FIRECRAWL_TRUSTED_TOOLS = new Set([
  "firecrawl_agent_status",
  "firecrawl_check_crawl_status",
  "firecrawl_extract",
  "firecrawl_map",
  "firecrawl_research_inspect_paper",
  "firecrawl_research_read_paper",
  "firecrawl_research_related_papers",
  "firecrawl_research_search_github",
  "firecrawl_research_search_papers",
  "firecrawl_scrape",
  "firecrawl_search",
  "firecrawl_interact_stop",
]);

/**
 * Playwright tools auto-approved for observational browser evidence.
 * Click/type/upload/evaluate and other page-mutating actions stay gated.
 */
const PLAYWRIGHT_TRUSTED_TOOLS = new Set([
  "browser_snapshot",
  "browser_take_screenshot",
  "browser_console_messages",
  "browser_network_requests",
  "browser_network_request",
  "browser_wait_for",
  "browser_navigate",
  "browser_navigate_back",
  "browser_resize",
  "browser_hover",
  "browser_close",
  "browser_tabs",
]);

const WRAPPER_COMMANDS = new Set(["rtk", "sudo", "command", "nohup", "nice", "time", "env"]);
/**
 * Native command families exposed by `rtk --help`, plus supported package-manager
 * aliases. Agents must use RTK for supported families and `rtk proxy` for raw executables.
 */
const RTK_REQUIRED_COMMANDS = new Set([
  "ls", "tree", "git", "gh", "glab", "aws", "psql", "pnpm", "find", "diff",
  "dotnet", "docker", "kubectl", "oc", "grep", "rg", "wget", "wc",
  "jest", "vitest", "prisma", "tsc", "next", "lint", "prettier", "format",
  "playwright", "cargo", "npm", "npx", "yarn", "bun", "curl", "ruff", "pytest", "mypy",
  "rake", "rubocop", "rspec", "pip", "go", "gt", "golangci-lint", "gradlew", "mvn",
]);
/** Unsupported raw utilities with mandatory modern replacements. */
const RAW_REPLACEMENT_COMMANDS = new Set(["cat", "sed", "awk"]);
const SHELL_BUILTINS = new Set(["cd", ":", "true", "false", "break", "continue", "return", "exit", "export", "readonly", "unset", "shift", "trap", "umask", "ulimit"]);

/** Interpreters that accept opaque -c/-e script bodies; always approval-required. */
const INTERPRETER_BASES = new Set([
  "bash",
  "sh",
  "dash",
  "zsh",
  "ksh",
  "fish",
  "node",
  "nodejs",
  "python",
  "python2",
  "python3",
  "ruby",
  "perl",
  "php",
  "lua",
  "deno",
  "bun",
  "pwsh",
  "powershell",
]);

function tokenize(command: string): string[] {
  const tokens: string[] = [];
  let current = "";
  let quote: "'" | '"' | null = null;
  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    if (quote) {
      if (ch === quote) {
        quote = null;
      } else {
        current += ch;
      }
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }
    if (/\s/.test(ch)) {
      if (current) {
        tokens.push(current);
        current = "";
      }
      continue;
    }
    current += ch;
  }
  if (current) {
    tokens.push(current);
  }
  return tokens;
}

/** Split on shell command separators outside quotes. Unbalanced quotes => single segment (caller may fail closed). */
function splitShellSegments(command: string): string[] {
  const segments: string[] = [];
  let current = "";
  let quote: "'" | '"' | null = null;
  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    const next = command[i + 1];
    if (quote) {
      current += ch;
      if (ch === quote) {
        quote = null;
      }
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      current += ch;
      continue;
    }
    if (ch === "\n" || ch === "\r") {
      if (current.trim()) {
        segments.push(current.trim());
      }
      current = "";
      if (ch === "\r" && next === "\n") {
        i += 1;
      }
      continue;
    }
    if (ch === ";" || ch === "|") {
      if (ch === "|" && next === "|") {
        if (current.trim()) {
          segments.push(current.trim());
        }
        current = "";
        i += 1;
        continue;
      }
      if (current.trim()) {
        segments.push(current.trim());
      }
      current = "";
      continue;
    }
    if (ch === "&") {
      if (next === "&") {
        if (current.trim()) {
          segments.push(current.trim());
        }
        current = "";
        i += 1;
        continue;
      }
      // background &
      if (current.trim()) {
        segments.push(current.trim());
      }
      current = "";
      continue;
    }
    current += ch;
  }
  if (current.trim()) {
    segments.push(current.trim());
  }
  return segments.length > 0 ? segments : [command.trim()].filter(Boolean);
}

function hasAmbiguousShellSyntax(command: string): boolean {
  // Expansions, substitutions, process substitutions, and eval make static path matching unreliable — fail closed with ask.
  // Source-dot only at segment start (not path tokens like "cd .").
  return /\$|`|[<>]\(|\beval\b|\bsource\b|(?:^|[;&|]\s*)\.\s+\S/.test(command);
}

function hasShellControlSyntax(command: string): boolean {
  // Control structures require shell parsing across segments; fail closed with approval instead of
  // treating keywords such as `if` or `while` as raw executables.
  return /(?:^|[;\n]\s*)(?:if|for|while|until|case|select|coproc|function|then|elif|else|fi|do|done|esac)\b|(?:^|[;\n]\s*)[{}]/.test(command);
}

function hasUnbalancedQuotes(command: string): boolean {
  let quote: "'" | '"' | null = null;
  for (const ch of command) {
    if (quote) {
      if (ch === quote) quote = null;
    } else if (ch === "'" || ch === '"') {
      quote = ch;
    }
  }
  return quote !== null;
}

function baseName(token: string): string {
  const slash = Math.max(token.lastIndexOf("/"), token.lastIndexOf("\\"));
  return slash >= 0 ? token.slice(slash + 1) : token;
}

/**
 * Detect interpreter/eval-style invocation whose payload is opaque to static matching
 * (bash -c, sh -c, node -e, python -c, ...). Always require approval.
 */
function isInterpreterOpaque(tokens: string[]): boolean {
  if (tokens.length === 0) {
    return false;
  }
  const base = baseName(tokens[0]);
  if (!INTERPRETER_BASES.has(base)) {
    return false;
  }
  // Common opaque-script flags across shells and runtimes.
  for (let i = 1; i < tokens.length; i += 1) {
    const t = tokens[i];
    if (
      t === "-c" ||
      t === "-e" ||
      t === "--eval" ||
      t === "-Command" ||
      t.startsWith("--eval=")
    ) {
      return true;
    }
    // Combined short flags: bash -lc, bash -ic, etc.
    if (t.startsWith("-") && !t.startsWith("--") && t.length > 2) {
      if ((base === "bash" || base === "sh" || base === "dash" || base === "zsh" || base === "ksh") && t.includes("c")) {
        return true;
      }
    }
  }
  return false;
}

function unwrapTokens(tokens: string[]): { tokens: string[]; wrappers: Set<string>; opaque: boolean } {
  let i = 0;
  let opaque = false;
  const wrappers = new Set<string>();
  while (i < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i])) {
    i += 1;
  }
  while (i < tokens.length && WRAPPER_COMMANDS.has(baseName(tokens[i]))) {
    const wrapper = baseName(tokens[i]);
    wrappers.add(wrapper);
    i += 1;
    if (wrapper === "env") {
      while (i < tokens.length) {
        if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i])) {
          i += 1;
          continue;
        }
        if (tokens[i] === "-S") {
          // env -S parses and executes its following string as a command.
          // The string is opaque to this tokenizer, so approval is required.
          opaque = true;
          i += tokens[i + 1] ? 2 : 1;
          continue;
        }
        if (tokens[i] === "-u" || tokens[i] === "-C") {
          i += tokens[i + 1] ? 2 : 1;
          continue;
        }
        if (tokens[i].startsWith("-") && tokens[i] !== "--") {
          i += 1;
          continue;
        }
        if (tokens[i] === "--") {
          i += 1;
        }
        break;
      }
      continue;
    }
    if (wrapper === "sudo" || wrapper === "nice" || wrapper === "command") {
      while (i < tokens.length && tokens[i].startsWith("-") && tokens[i] !== "--") {
        if (["-u", "-g", "-C", "-n", "-p"].includes(tokens[i]) && tokens[i + 1]) {
          i += 2;
        } else {
          i += 1;
        }
      }
      if (tokens[i] === "--") {
        i += 1;
      }
      continue;
    }
    if (wrapper === "rtk" && tokens[i] === "proxy") {
      // `rtk proxy <cmd>` deliberately preserves the raw command, but policy
      // must still classify that command rather than the proxy subcommand.
      i += 1;
    }
    // nohup / time: consume only the wrapper token
  }
  return { tokens: tokens.slice(i), wrappers, opaque };
}

function stripWrappers(tokens: string[]): string[] {
  return unwrapTokens(tokens).tokens;
}

function hasInlineGitAliasInvocation(tokens: string[]): boolean {
  if (tokens[0] !== "git") {
    return false;
  }
  const aliases = new Set<string>();
  let i = 1;
  while (i < tokens.length && tokens[i].startsWith("-")) {
    const option = tokens[i];
    let value = "";
    if (option === "-c") {
      value = tokens[i + 1] || "";
      i += 2;
    } else if (option.startsWith("-c") && option.length > 2) {
      value = option.slice(2);
      i += 1;
    } else if (option === "--config-env") {
      value = tokens[i + 1] || "";
      i += 2;
    } else if (option.startsWith("--config-env=")) {
      value = option.slice("--config-env=".length);
      i += 1;
    } else if (option === "-C" || option === "--git-dir" || option === "--work-tree" || option === "--namespace") {
      i += 2;
      continue;
    } else if (option.startsWith("--git-dir=") || option.startsWith("--work-tree=") || option.startsWith("--namespace=")) {
      i += 1;
      continue;
    } else {
      i += 1;
      continue;
    }
    const match = /^alias\.([^=]+)=/.exec(value);
    if (match) aliases.add(match[1]);
    const configEnvMatch = /^alias\.([^=]+)=/.exec(value);
    if (configEnvMatch) aliases.add(configEnvMatch[1]);
  }
  return aliases.has(tokens[i]);
}

function gitEffectiveTokens(tokens: string[]): string[] {
  if (tokens[0] !== "git") {
    return tokens;
  }
  const out = ["git"];
  let i = 1;
  while (i < tokens.length) {
    const t = tokens[i];
    if (t === "--") {
      i += 1;
      break;
    }
    if (!t.startsWith("-")) {
      break;
    }
    // Options that take a value before the Git subcommand.
    if (t === "-C" || t === "-c" || t === "--git-dir" || t === "--work-tree" || t === "--namespace" || t === "--config-env") {
      i += tokens[i + 1] ? 2 : 1;
      continue;
    }
    // Combined forms like -cfoo.bar=baz and long options with inline values.
    if (t.startsWith("-c") && t.length > 2) {
      i += 1;
      continue;
    }
    if (t.startsWith("--git-dir=") || t.startsWith("--work-tree=") || t.startsWith("--namespace=") || t.startsWith("--config-env=")) {
      i += 1;
      continue;
    }
    i += 1;
  }
  out.push(...tokens.slice(i));
  return out;
}

function normalizeTokens(tokens: string[]): string[] {
  const stripped = stripWrappers(tokens);
  if (stripped[0]) {
    stripped[0] = baseName(stripped[0]);
  }
  if (stripped[0] === "git") {
    return gitEffectiveTokens(stripped);
  }
  return stripped;
}

function packageOperation(tokens: string[]): { operation: string | null; opaque: boolean } {
  const valueOptions = new Set(["--prefix", "--dir", "--manifest-path"]);
  const valuelessOptions = new Set(["--silent", "--json", "--offline", "--version"]);
  let i = 1;
  while (i < tokens.length) {
    const token = tokens[i];
    if (!token.startsWith("-")) return { operation: token, opaque: false };
    if (token === "--") return { operation: tokens[i + 1] || null, opaque: false };
    if (token.includes("=")) {
      i += 1;
      continue;
    }
    if (valueOptions.has(token)) {
      if (!tokens[i + 1]) return { operation: null, opaque: true };
      i += 2;
      continue;
    }
    if (valuelessOptions.has(token)) {
      i += 1;
      continue;
    }
    // Do not let an unparsed global option hide a dependency operation.
    return { operation: null, opaque: true };
  }
  return { operation: null, opaque: false };
}

function hasOpaquePackageOptions(tokens: string[]): boolean {
  return new Set(["npm", "pnpm", "yarn", "bun", "cargo", "go", "pip", "pip3", "poetry", "uv"]).has(tokens[0])
    && packageOperation(tokens).opaque;
}

function hasDependencyWrite(tokens: string[]): boolean {
  const manager = tokens[0];
  const { operation } = packageOperation(tokens);
  if (!manager || !operation) return false;
  const writes: Record<string, Set<string>> = {
    npm: new Set(["install", "i", "ci", "add", "remove", "uninstall", "update"]),
    pnpm: new Set(["install", "i", "add", "remove", "uninstall", "update", "up"]),
    yarn: new Set(["install", "add", "remove", "uninstall", "upgrade", "up"]),
    bun: new Set(["install", "add", "remove", "uninstall", "update"]),
    cargo: new Set(["install", "add", "remove", "update"]),
    go: new Set(["install", "get"]),
    pip: new Set(["install", "uninstall"]),
    pip3: new Set(["install", "uninstall"]),
    poetry: new Set(["add", "install", "remove", "update"]),
    uv: new Set(["add", "remove", "sync", "lock"]),
  };
  if (manager === "uv" && operation === "pip") {
    return tokens.slice(2).some((token) => token === "install" || token === "uninstall" || token === "sync");
  }
  return writes[manager]?.has(operation) ?? false;
}

function matchesPrefix(tokens: string[], pattern: string[]): boolean {
  if (tokens.length < pattern.length) {
    return false;
  }
  for (let i = 0; i < pattern.length; i += 1) {
    if (tokens[i] !== pattern[i]) {
      return false;
    }
  }
  return true;
}

function shortFlagChars(tokens: string[]): string {
  let chars = "";
  for (const token of tokens) {
    if (token.startsWith("--")) {
      continue;
    }
    if (token.startsWith("-") && token.length > 1) {
      chars += token.slice(1);
    }
  }
  return chars;
}

function isRmRecursiveForce(tokens: string[]): boolean {
  if (tokens[0] !== "rm") {
    return false;
  }
  const rest = tokens.slice(1);
  if (rest.includes("-rf") || rest.includes("-fr") || rest.includes("-Rf") || rest.includes("-fR")) {
    return true;
  }
  const chars = shortFlagChars(rest);
  const recursive = /[rR]/.test(chars) || rest.includes("--recursive");
  const force = chars.includes("f") || rest.includes("--force");
  return recursive && force;
}

function hasOpaqueGitOptions(tokens: string[]): boolean {
  if (tokens[0] !== "git") return false;
  const valueOptions = new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"]);
  const valuelessOptions = new Set(["--no-pager", "--bare", "--literal-pathspecs", "--no-optional-locks"]);
  for (let i = 1; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (!token.startsWith("-")) return false;
    if (token === "--") return false;
    if (token.startsWith("-c") || token.includes("=")) continue;
    if (valueOptions.has(token)) {
      i += 1;
      continue;
    }
    if (valuelessOptions.has(token)) continue;
    return true;
  }
  return false;
}

function isGitForcePush(tokens: string[]): boolean {
  if (tokens[0] !== "git") {
    return false;
  }
  if (!tokens.includes("push")) {
    return false;
  }
  return (
    tokens.includes("--force") ||
    tokens.includes("--force-with-lease") ||
    tokens.includes("-f")
  );
}

function isGitCleanForce(tokens: string[]): boolean {
  if (!matchesPrefix(tokens, ["git", "clean"])) {
    return false;
  }
  const rest = tokens.slice(2);
  if (rest.includes("--force")) {
    return true;
  }
  return rest.some((t) => {
    if (t === "-f" || t.startsWith("-f")) {
      return true;
    }
    return t.startsWith("-") && !t.startsWith("--") && t.includes("f");
  });
}

function isGitBranchForceDelete(tokens: string[]): boolean {
  if (!matchesPrefix(tokens, ["git", "branch"])) {
    return false;
  }
  return tokens.includes("-D") || (tokens.includes("--delete") && tokens.includes("--force"));
}

function isRtkWrapped(rawTokens: string[]): boolean {
  return unwrapTokens(rawTokens).wrappers.has("rtk");
}

function hasOpaqueWrapper(rawTokens: string[]): boolean {
  return unwrapTokens(rawTokens).opaque;
}

function isStandaloneEnvCommand(rawTokens: string[]): boolean {
  const unwrapped = unwrapTokens(rawTokens);
  return (
    unwrapped.wrappers.has("env") &&
    !unwrapped.wrappers.has("rtk") &&
    unwrapped.tokens.length === 0
  );
}

function isDirectRtkRequiredCommand(rawTokens: string[], tokens: string[]): boolean {
  if (isRtkWrapped(rawTokens)) {
    return false;
  }
  if (RTK_REQUIRED_COMMANDS.has(tokens[0]) || RAW_REPLACEMENT_COMMANDS.has(tokens[0])) {
    return true;
  }
  return (
    (tokens[0] === "python" || tokens[0] === "python3") &&
    tokens[1] === "-m" &&
    tokens[2] === "json.tool"
  );
}

function hasShellExecutionProxy(tokens: string[]): boolean {
  return tokens[0] === "xargs" || (
    tokens[0] === "find" && tokens.some((token) => ["-exec", "-execdir", "-ok", "-okdir"].includes(token))
  );
}

function isDirectRawExternalCommand(rawTokens: string[], tokens: string[]): boolean {
  return !isRtkWrapped(rawTokens) && Boolean(tokens[0]) && !SHELL_BUILTINS.has(tokens[0]);
}

function segmentDecision(segment: string): { decision: Decision; reason: string } {
  const rawTokens = tokenize(segment);
  const tokens = normalizeTokens(rawTokens);
  if (hasOpaqueWrapper(rawTokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: env -S command string is opaque",
    };
  }
  if (isStandaloneEnvCommand(rawTokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: use RTK for the standalone env command",
    };
  }
  if (tokens.length === 0) {
    return { decision: "allow", reason: "" };
  }

  // Shell access to a literal protected path is always approval-gated, even
  // through rtk/wrapper commands or in a compound segment. This deliberately
  // covers both reads and writes: the shell parser cannot reliably infer intent.
  if (tokens.some(isProtectedPath)) {
    return {
      decision: "ask",
      reason: "Requires approval: shell command references a protected path",
    };
  }

  // Inline aliases can execute arbitrary shell payloads. Parse neither their
  // definitions nor bodies; fail closed when the configured alias is invoked.
  const unwrappedTokens = stripWrappers(rawTokens);
  if (unwrappedTokens[0]) unwrappedTokens[0] = baseName(unwrappedTokens[0]);
  if (hasInlineGitAliasInvocation(unwrappedTokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: inline Git alias invocation is opaque",
    };
  }
  if (hasOpaqueGitOptions(unwrappedTokens) || hasOpaquePackageOptions(tokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: unrecognized pre-operation option is opaque",
    };
  }

  // Interpreter wrappers hide the real command body from static matching.
  if (isInterpreterOpaque(tokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: interpreter/eval-style command (opaque -c/-e body)",
    };
  }

  if (hasShellExecutionProxy(tokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: shell execution proxy is opaque",
    };
  }

  if (isGitForcePush(tokens)) {
    return {
      decision: "deny",
      reason: "Denied by b-agentic policy: git push --force",
    };
  }

  if (matchesPrefix(tokens, ["git", "reset", "--hard"]) || (matchesPrefix(tokens, ["git", "reset"]) && tokens.includes("--hard"))) {
    return {
      decision: "deny",
      reason: "Denied by b-agentic policy: git reset --hard",
    };
  }

  if (isGitCleanForce(tokens)) {
    return {
      decision: "deny",
      reason: "Denied by b-agentic policy: git clean -f",
    };
  }

  if (isGitBranchForceDelete(tokens)) {
    return {
      decision: "deny",
      reason: "Denied by b-agentic policy: git branch -D",
    };
  }

  for (const pattern of DENY_COMMANDS) {
    if (matchesPrefix(tokens, pattern)) {
      return {
        decision: "deny",
        reason: `Denied by b-agentic policy: ${pattern.join(" ")}`,
      };
    }
  }

  if (isRmRecursiveForce(tokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: rm -rf",
    };
  }

  if (hasDependencyWrite(tokens)) {
    return { decision: "ask", reason: "Requires approval: dependency write" };
  }

  for (const pattern of ASK_COMMANDS) {
    if (matchesPrefix(tokens, pattern)) {
      return {
        decision: "ask",
        reason: `Requires approval: ${pattern.join(" ")}`,
      };
    }
  }

  for (const pattern of SERVICE_COMMANDS) {
    if (matchesPrefix(tokens, pattern)) {
      return {
        decision: "ask",
        reason: `Requires approval for long-lived service: ${pattern.join(" ")}`,
      };
    }
  }

  if (isDirectRtkRequiredCommand(rawTokens, tokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: use RTK for supported command families or the required raw replacement",
    };
  }

  if (isDirectRawExternalCommand(rawTokens, tokens)) {
    return {
      decision: "deny",
      reason: "Denied by b-agentic policy: use rtk proxy for raw external commands",
    };
  }

  return { decision: "allow", reason: "" };
}

function commandDecision(command: string): { decision: Decision; reason: string } {
  const trimmed = command.trim();
  if (!trimmed) {
    return { decision: "allow", reason: "" };
  }

  if (hasUnbalancedQuotes(trimmed) || hasAmbiguousShellSyntax(trimmed) || hasShellControlSyntax(trimmed)) {
    return {
      decision: "ask",
      reason: "Requires approval: ambiguous shell syntax (quotes/expansion/control structure/eval/source)",
    };
  }

  const segments = splitShellSegments(trimmed);
  let worst: { decision: Decision; reason: string } = { decision: "allow", reason: "" };
  const rank = { allow: 0, ask: 1, deny: 2 };

  for (const segment of segments) {
    const result = segmentDecision(segment);
    if (rank[result.decision] > rank[worst.decision]) {
      worst = result;
    }
  }
  return worst;
}

function nativePathDecision(toolName: string, pathValue: string): { decision: Decision; reason: string } {
  if (!pathValue || !isProtectedPath(pathValue)) {
    return { decision: "allow", reason: "" };
  }
  if (toolName === "read") {
    return { decision: "ask", reason: `Requires approval: read of protected path: ${pathValue}` };
  }
  return { decision: "deny", reason: `Blocked ${toolName} of protected path: ${pathValue}` };
}

function isProtectedPath(pathValue: string): boolean {
  const normalized = pathValue.replace(/\\/g, "/");
  const base = normalized.split("/").pop() || normalized;
  for (const marker of PROTECTED_PATH_MARKERS) {
    if (marker.startsWith(".") && !marker.includes("/")) {
      if (
        base === marker ||
        base.startsWith(`${marker}.`) ||
        base.endsWith(marker) ||
        normalized.includes(`/${marker}`)
      ) {
        return true;
      }
      continue;
    }
    if (normalized.includes(marker) || base.includes(marker)) {
      return true;
    }
  }
  return false;
}

function isTrustedMcpProxyCall(input: unknown): boolean {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    return false;
  }

  const value = input as {
    action?: unknown;
    search?: unknown;
    describe?: unknown;
    tool?: unknown;
    connect?: unknown;
    server?: unknown;
  };
  // Metadata-only calls must not be mixed with execution selectors.
  if (
    typeof value.tool === "string" ||
    typeof value.connect === "string" ||
    typeof value.server === "string"
  ) {
    return false;
  }
  // Search and describe use cached metadata only; they do not call a server.
  return (
    value.action === "ui-messages" ||
    typeof value.search === "string" ||
    typeof value.describe === "string"
  );
}

function normalizeServerId(value: string): string {
  return value.trim().toLowerCase().replace(/_/g, "-");
}

function isManagedServer(server: string): boolean {
  return MANAGED_MCP_SERVERS.has(normalizeServerId(server));
}

/**
 * Strip adapter/namespace prefixes to get the server-local tool base name.
 * Examples:
 *   mcp__firecrawl__firecrawl_search -> firecrawl_search
 *   firecrawl_firecrawl_search -> firecrawl_search
 *   playwright_browser_click -> browser_click
 *   browser_click -> browser_click
 */
function managedToolBaseName(toolName: string, server: string): string {
  let name = toolName;
  if (name.startsWith("mcp__")) {
    const parts = name.split("__");
    name = parts.length >= 3 ? parts.slice(2).join("__") : name;
  }

  const serverUnderscore = server.replace(/-/g, "_");
  const repeated = `${serverUnderscore}_${serverUnderscore}_`;
  // Firecrawl's adapter prefix duplicates its public `firecrawl_` tool id.
  // Other managed tools retain their policy identifier unchanged.
  if (server === "firecrawl" && name.startsWith(repeated)) {
    return name.slice(serverUnderscore.length + 1);
  }
  const prefixed = `${serverUnderscore}_`;
  if (name.startsWith(prefixed)) {
    // firecrawl_search stays firecrawl_search; playwright_browser_click -> browser_click
    if (server === "playwright") {
      return name.slice(prefixed.length);
    }
    // firecrawl tools keep their firecrawl_ prefix as the public tool id
    if (server === "firecrawl" && name.startsWith("firecrawl_firecrawl_")) {
      return name.slice("firecrawl_".length);
    }
  }
  return name;
}

/**
 * Resolve managed server id from a direct or namespaced tool name.
 * Supports adapter forms (serena_find_symbol, brave_search_*), mcp__server__tool,
 * and bare server ids.
 */
function managedServerFromToolName(toolName: string): string | null {
  if (toolName.startsWith("mcp__")) {
    const parts = toolName.split("__");
    if (parts.length >= 2 && isManagedServer(parts[1])) {
      return normalizeServerId(parts[1]);
    }
  }

  const prefixes: Array<[string, string]> = [
    ["serena_", "serena"],
    ["codegraph_", "codegraph"],
    ["context7_", "context7"],
    ["firecrawl_", "firecrawl"],
    ["playwright_", "playwright"],
    ["brave_search_", "brave-search"],
    ["brave-search_", "brave-search"],
  ];
  for (const [prefix, server] of prefixes) {
    if (toolName === server || toolName.startsWith(prefix)) {
      return server;
    }
  }
  // Playwright tools often appear as bare browser_* names when directTools is on.
  if (toolName.startsWith("browser_")) {
    return "playwright";
  }
  // Underscore alias for brave-search when used as a bare server token.
  if (toolName === "brave_search") {
    return "brave-search";
  }
  return null;
}

/**
 * Operation-level trust for a managed server tool. Every managed server uses
 * an explicit allowlist so new or mutating operations require approval.
 */
function isTrustedManagedTool(server: string, toolName: string): boolean {
  if (!isManagedServer(server)) {
    return false;
  }
  const base = managedToolBaseName(toolName, server);
  const trustedTools = {
    serena: SERENA_TRUSTED_TOOLS,
    codegraph: CODEGRAPH_TRUSTED_TOOLS,
    context7: CONTEXT7_TRUSTED_TOOLS,
    "brave-search": BRAVE_SEARCH_TRUSTED_TOOLS,
    firecrawl: FIRECRAWL_TRUSTED_TOOLS,
    playwright: PLAYWRIGHT_TRUSTED_TOOLS,
  }[server];
  return trustedTools?.has(base) ?? false;
}

/**
 * True when this call is a trusted managed b-agentic MCP action that should
 * run without a Pi approval prompt. Fail closed on mixed MCP selectors,
 * server/tool origin mismatch, Firecrawl/Playwright external-mutation tools,
 * auth bootstrap, and non-managed servers.
 */
function isTrustedManagedMcpCall(toolName: string, input?: unknown): boolean {
  if (toolName !== "mcp") {
    const server = managedServerFromToolName(toolName);
    if (!server) {
      return false;
    }
    return isTrustedManagedTool(server, toolName);
  }

  if (!input || typeof input !== "object" || Array.isArray(input)) {
    return false;
  }

  const value = input as {
    action?: unknown;
    server?: unknown;
    connect?: unknown;
    tool?: unknown;
    search?: unknown;
    describe?: unknown;
  };

  // OAuth / auth bootstrap remains approval-gated.
  if (value.action === "auth-start" || value.action === "auth-complete") {
    return false;
  }

  const hasConnect = typeof value.connect === "string";
  const hasTool = typeof value.tool === "string";
  // Mixed selectors can launder a sensitive tool behind a trusted connect/list.
  // connect must be the sole selector when present.
  if (
    hasConnect &&
    (hasTool ||
      typeof value.action === "string" ||
      typeof value.server === "string" ||
      typeof value.search === "string" ||
      typeof value.describe === "string")
  ) {
    return false;
  }

  if (hasConnect) {
    return isManagedServer(value.connect as string);
  }

  if (hasTool) {
    const tool = value.tool as string;
    const fromName = managedServerFromToolName(tool);
    const explicitServer =
      typeof value.server === "string" ? normalizeServerId(value.server) : null;

    // Explicit server and tool-name origin must agree when both are present.
    if (explicitServer && fromName && explicitServer !== fromName) {
      return false;
    }
    // If tool name has no managed origin, do not let an explicit server rewrite it.
    if (explicitServer && !fromName) {
      return false;
    }

    const server = fromName || explicitServer;
    if (!server || !isManagedServer(server)) {
      return false;
    }
    return isTrustedManagedTool(server, tool);
  }

  // Listing tools / scoping to a managed server without a tool call.
  if (typeof value.server === "string") {
    return isManagedServer(value.server);
  }

  return false;
}

/**
 * Returns true when the tool call should go through the custom/MCP approval prompt.
 * Built-ins, MCP metadata discovery, and ordinary managed MCP tools return false.
 */
function isMcpOrCustomTool(toolName: string, input?: unknown): boolean {
  if (SPECIALIZED_TOOLS.has(toolName)) {
    return false;
  }
  if (toolName === "mcp") {
    if (isTrustedMcpProxyCall(input)) {
      return false;
    }
    if (isTrustedManagedMcpCall(toolName, input)) {
      return false;
    }
    return true;
  }
  if (isTrustedManagedMcpCall(toolName, input)) {
    return false;
  }
  // Direct non-managed MCP tools or any other non-built-in extension tool require approval.
  return true;
}

async function confirmOrBlock(
  ctx: { hasUI: boolean; ui: { confirm: (title: string, message: string) => Promise<boolean> } },
  title: string,
  message: string,
  reason: string,
): Promise<{ block: true; reason: string } | undefined> {
  if (!ctx.hasUI) {
    return { block: true, reason: `${reason} (no UI; fail-closed)` };
  }
  const ok = await ctx.ui.confirm(title, message);
  if (!ok) {
    return { block: true, reason: `${reason} (denied by user)` };
  }
  return undefined;
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "bash") {
      const command = String((event.input as { command?: string }).command || "");
      const { decision, reason } = commandDecision(command);
      if (decision === "deny") {
        return { block: true, reason };
      }
      if (decision === "ask") {
        return confirmOrBlock(
          ctx,
          "b-agentic approval",
          `${reason}\n\nCommand:\n${command}\n\nAllow this tool call?`,
          reason,
        );
      }
      return undefined;
    }

    if (event.toolName === "write" || event.toolName === "edit" || event.toolName === "read") {
      const pathValue = String((event.input as { path?: string }).path || "");
      const { decision, reason } = nativePathDecision(event.toolName, pathValue);
      if (decision === "deny") {
        return { block: true, reason };
      }
      if (decision === "ask") {
        return confirmOrBlock(
          ctx,
          "b-agentic approval",
          `${reason}\n\nAllow this tool call?`,
          reason,
        );
      }
      return undefined;
    }

    // The kernel requires RTK for supported discovery families; do not let
    // direct built-ins bypass that policy.
    if (event.toolName === "grep" || event.toolName === "find" || event.toolName === "ls") {
      return {
        block: true,
        reason: "Blocked direct discovery tool: use the corresponding RTK command",
      };
    }

    // User/unknown MCP, Firecrawl/Playwright external mutations, auth, and custom tools ask.
    // Trusted managed MCP tools (operation-level) and metadata discovery are auto-allowed.
    if (isMcpOrCustomTool(event.toolName, event.input)) {
      const inputPreview = JSON.stringify(event.input ?? {}).slice(0, 400);
      return confirmOrBlock(
        ctx,
        "b-agentic approval",
        `Requires approval: tool "${event.toolName}" may perform external or side-effecting work.\n\nInput:\n${inputPreview}\n\nAllow this tool call?`,
        `Requires approval: custom/MCP tool ${event.toolName}`,
      );
    }

    return undefined;
  });
}

// Test helpers for unit-style smoke coverage without loading Pi.
export const __test__ = {
  tokenize,
  normalizeTokens,
  splitShellSegments,
  stripWrappers,
  commandDecision,
  isProtectedPath,
  isMcpOrCustomTool,
  isTrustedMcpProxyCall,
  isTrustedManagedMcpCall,
  isTrustedManagedTool,
  isManagedServer,
  managedServerFromToolName,
  managedToolBaseName,
  hasAmbiguousShellSyntax,
  hasShellControlSyntax,
  hasUnbalancedQuotes,
  isInterpreterOpaque,
  isRtkWrapped,
  hasOpaqueWrapper,
  isStandaloneEnvCommand,
  isDirectRtkRequiredCommand,
  hasInlineGitAliasInvocation,
  hasOpaqueGitOptions,
  hasOpaquePackageOptions,
  nativePathDecision,
  confirmOrBlock,
  SPECIALIZED_TOOLS,
  MANAGED_MCP_SERVERS,
  SERENA_TRUSTED_TOOLS,
  CODEGRAPH_TRUSTED_TOOLS,
  CONTEXT7_TRUSTED_TOOLS,
  BRAVE_SEARCH_TRUSTED_TOOLS,
  FIRECRAWL_TRUSTED_TOOLS,
  PLAYWRIGHT_TRUSTED_TOOLS,
  ASK_COMMANDS,
  DENY_COMMANDS,
  RTK_REQUIRED_COMMANDS,
};
