/**
 * b-agentic first-party permission extension for Pi.
 *
 * Enforces kernel safety gates via Pi's tool_call event:
 * - ask: commits, pushes, pulls, reverts, dependency writes, long-lived services, rm -rf
 * - deny: destructive git history/worktree rewrites and selected docker prune/rm families
 * - block write/edit to secret and repository-control paths
 * - allow metadata discovery plus classified read-only and safe conditional-read MCP operations
 * - ask before managed mutations/uploads, user/unknown MCP servers, auth actions, and other custom tools
 *
 * Normalizes bare and rtk-wrapped shell commands, compound shell segments,
 * env/sudo wrappers, and git option prefixes. Fails closed without UI.
 */

import { realpathSync, statSync } from "node:fs";
import { isIP } from "node:net";
import { dirname, isAbsolute, relative } from "node:path";
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

const DANGEROUS_ASK_COMMANDS: string[][] = [
  ["dd"], ["mkfs"], ["chmod"], ["chown"], ["kill"], ["pkill"], ["killall"],
  ["shutdown"], ["reboot"], ["poweroff"], ["halt"],
  ["systemctl", "stop"], ["systemctl", "restart"], ["systemctl", "disable"],
  ["docker", "rm"], ["docker", "container", "rm"], ["docker", "image", "rm"],
  ["docker", "compose", "down"], ["kubectl", "delete"],
];

const PROTECTED_PATH_MARKERS = [
  ".env",
  "credentials.",
  "secrets.",
  ".pem",
  ".key",
  ".p12",
  ".pfx",
  ".npmrc",
  ".netrc",
  ".pypirc",
  ".git-credentials",
  ".ssh/",
  ".config/gh/",
  ".aws/",
  ".kube/",
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
 * bypass the kernel's RTK and shell-tool policy. Managed MCP operations are
 * approved only when their canonical classification is safe.
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

// generated:mcp-runtime-policy:start
/** Generated from references/mcp_operations.yaml. */
const MANAGED_MCP_SERVERS = new Set([
  "brave-search",
  "codegraph",
  "context7",
  "firecrawl",
  "playwright",
  "serena"
]);

/** Cached gateway operations classified as read-only in mcp_operations.yaml. */
const MCP_TRUSTED_GATEWAY_OPERATIONS = new Set([
  "describe",
  "search",
  "ui-messages"
]);

/** Read operations that are autonomous only for a validated safe argument shape. */
const MCP_CONDITIONAL_TOOLS = new Set([
  "firecrawl:firecrawl_extract",
  "firecrawl:firecrawl_map",
  "firecrawl:firecrawl_scrape",
  "firecrawl:firecrawl_search",
  "playwright:browser_console_messages",
  "playwright:browser_network_request",
  "playwright:browser_network_requests",
  "playwright:browser_snapshot",
  "playwright:browser_tabs",
  "serena:serena_find_declaration",
  "serena:serena_find_implementations",
  "serena:serena_find_referencing_symbols",
  "serena:serena_find_symbol",
  "serena:serena_get_diagnostics_for_file",
  "serena:serena_get_symbols_overview",
  "serena:serena_search_for_pattern"
]);

/** Known arguments for conditional operations, generated from the canonical policy. */
const MCP_CONDITIONAL_ARGUMENTS: Record<string, readonly string[]> = {
  "firecrawl:firecrawl_extract": [
    "urls",
    "prompt",
    "schema",
    "allowExternalLinks",
    "enableWebSearch",
    "includeSubdomains"
  ],
  "firecrawl:firecrawl_map": [
    "url",
    "search",
    "sitemap",
    "includeSubdomains",
    "limit",
    "ignoreQueryParameters"
  ],
  "firecrawl:firecrawl_scrape": [
    "url",
    "formats",
    "jsonOptions",
    "queryOptions",
    "screenshotOptions",
    "parsers",
    "pdfOptions",
    "onlyMainContent",
    "redactPII",
    "includeTags",
    "excludeTags",
    "waitFor",
    "actions",
    "mobile",
    "skipTlsVerification",
    "removeBase64Images",
    "location",
    "storeInCache",
    "zeroDataRetention",
    "maxAge",
    "lockdown",
    "proxy",
    "profile"
  ],
  "firecrawl:firecrawl_search": [
    "query",
    "limit",
    "tbs",
    "filter",
    "location",
    "includeDomains",
    "excludeDomains",
    "sources",
    "categories",
    "scrapeOptions",
    "enterprise"
  ],
  "playwright:browser_console_messages": [
    "level",
    "all",
    "filename"
  ],
  "playwright:browser_network_request": [
    "index",
    "part",
    "filename"
  ],
  "playwright:browser_network_requests": [
    "static",
    "filter",
    "filename"
  ],
  "playwright:browser_snapshot": [
    "target",
    "filename",
    "depth",
    "boxes"
  ],
  "playwright:browser_tabs": [
    "action",
    "index",
    "url"
  ],
  "serena:serena_find_declaration": [
    "relative_path",
    "regex",
    "containing_symbol_name_path",
    "include_body",
    "include_info"
  ],
  "serena:serena_find_implementations": [
    "name_path",
    "relative_path",
    "include_info",
    "include_kinds",
    "exclude_kinds",
    "max_answer_chars"
  ],
  "serena:serena_find_referencing_symbols": [
    "name_path",
    "relative_path",
    "include_kinds",
    "exclude_kinds",
    "max_answer_chars"
  ],
  "serena:serena_find_symbol": [
    "name_path_pattern",
    "depth",
    "relative_path",
    "include_body",
    "include_info",
    "include_kinds",
    "exclude_kinds",
    "substring_matching",
    "max_matches",
    "max_answer_chars"
  ],
  "serena:serena_get_diagnostics_for_file": [
    "relative_path",
    "start_line",
    "end_line",
    "min_severity",
    "max_answer_chars"
  ],
  "serena:serena_get_symbols_overview": [
    "relative_path",
    "depth",
    "max_answer_chars"
  ],
  "serena:serena_search_for_pattern": [
    "substring_pattern",
    "context_lines_before",
    "context_lines_after",
    "paths_include_glob",
    "paths_exclude_glob",
    "relative_path",
    "restrict_search_to_code_files",
    "multiline",
    "max_answer_chars"
  ]
};

const SERENA_TRUSTED_TOOLS = new Set([
  "serena_find_declaration",
  "serena_find_implementations",
  "serena_find_referencing_symbols",
  "serena_find_symbol",
  "serena_get_diagnostics_for_file",
  "serena_get_symbols_overview",
  "serena_initial_instructions",
  "serena_list_memories",
  "serena_read_memory",
  "serena_search_for_pattern"
]);

const CODEGRAPH_TRUSTED_TOOLS = new Set([
  "codegraph_codegraph_explore"
]);

const CONTEXT7_TRUSTED_TOOLS = new Set([
  "context7_query-docs",
  "context7_resolve-library-id"
]);

const BRAVE_SEARCH_TRUSTED_TOOLS = new Set([
  "brave_search_brave_image_search",
  "brave_search_brave_llm_context",
  "brave_search_brave_local_search",
  "brave_search_brave_news_search",
  "brave_search_brave_place_search",
  "brave_search_brave_summarizer",
  "brave_search_brave_video_search",
  "brave_search_brave_web_search"
]);

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
  "firecrawl_search"
]);

const PLAYWRIGHT_TRUSTED_TOOLS = new Set([
  "browser_close",
  "browser_console_messages",
  "browser_find",
  "browser_hover",
  "browser_navigate_back",
  "browser_network_request",
  "browser_network_requests",
  "browser_resize",
  "browser_snapshot",
  "browser_tabs",
  "browser_wait_for"
]);
// generated:mcp-runtime-policy:end

const WRAPPER_COMMANDS = new Set(["rtk", "sudo", "command", "nohup", "nice", "time", "env"]);
/** RTK subcommands that execute another command and must expose it to policy matching. */
const RTK_EXECUTION_WRAPPERS = new Set(["proxy", "err", "test", "summary", "run"]);
/** Native command families exposed by `rtk --help`. Agents must use RTK for supported families. */
const RTK_REQUIRED_COMMANDS = new Set([
  "ls", "tree", "git", "gh", "glab", "aws", "psql", "pnpm", "find", "diff",
  "dotnet", "docker", "kubectl", "oc", "grep", "rg", "wget", "wc",
  "jest", "vitest", "prisma", "tsc", "next", "lint", "prettier", "format",
  "playwright", "cargo", "npm", "npx", "curl", "ruff", "pytest", "mypy",
  "rake", "rubocop", "rspec", "pip", "go", "gt", "golangci-lint", "gradlew", "mvn",
]);

/** Interpreters that execute opaque code or script files; always approval-required. */
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
      } else if (ch === "\\" && quote === '"' && i + 1 < command.length) {
        if (command[i + 1] === "\r" && command[i + 2] === "\n") i += 2;
        else if (command[i + 1] === "\n") i += 1;
        else {
          current += command[i + 1];
          i += 1;
        }
      } else {
        current += ch;
      }
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }
    if (ch === "\\" && i + 1 < command.length) {
      if (command[i + 1] === "\r" && command[i + 2] === "\n") i += 2;
      else if (command[i + 1] === "\n") i += 1;
      else {
        current += command[i + 1];
        i += 1;
      }
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
      } else if (ch === "\\" && quote === '"' && i + 1 < command.length) {
        if (command[i + 1] === "\r" && command[i + 2] === "\n") {
          current = current.slice(0, -1);
          i += 2;
        } else if (command[i + 1] === "\n") {
          current = current.slice(0, -1);
          i += 1;
        } else {
          current += command[i + 1];
          i += 1;
        }
      }
      continue;
    }
    if (ch === "\\" && i + 1 < command.length) {
      if (command[i + 1] === "\r" && command[i + 2] === "\n") i += 2;
      else if (command[i + 1] === "\n") i += 1;
      else {
        current += ch + command[i + 1];
        i += 1;
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

function hasUnquotedGlob(command: string): boolean {
  let quote: "'" | '"' | null = null;
  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    if (quote) {
      if (ch === quote) quote = null;
      else if (ch === "\\" && quote === '"') i += 1;
      continue;
    }
    if (ch === "\\") {
      i += 1;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }
    if (ch === "*" || ch === "?" || ch === "[") return true;
  }
  return false;
}

function hasAmbiguousShellSyntax(command: string): boolean {
  // Expansions, substitutions, process substitutions, unquoted globs, and eval
  // make static command/path matching unreliable — fail closed with ask.
  // Source-dot only at segment start (not path tokens like "cd .").
  return /\$|`|[<>]\(|\beval\b|\bsource\b|(?:^|[;&|]\s*)\.\s+\S/.test(command) || hasUnquotedGlob(command);
}

function hasShellControlSyntax(command: string): boolean {
  // Control structures require shell parsing across segments; fail closed with approval instead of
  // treating keywords such as `if` or `while` as raw executables.
  return /(?:^|[;\n]\s*)(?:if|for|while|until|case|select|coproc|function|then|elif|else|fi|do|done|esac)\b|(?:^|[;\n]\s*)[{}]/.test(command);
}

function hasUnbalancedQuotes(command: string): boolean {
  let quote: "'" | '"' | null = null;
  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    if (quote) {
      if (ch === quote) quote = null;
      else if (ch === "\\" && quote === '"') i += 1;
    } else if (ch === "\\") {
      i += 1;
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
 * Detect interpreter invocations whose code is opaque to static matching:
 * eval flags, modules/stdin, and script files. Always require approval.
 */
function isInterpreterOpaque(tokens: string[]): boolean {
  if (tokens.length === 0) {
    return false;
  }
  const base = baseName(tokens[0]);
  if (!INTERPRETER_BASES.has(base)) {
    return false;
  }
  for (let i = 1; i < tokens.length; i += 1) {
    const t = tokens[i];
    if (
      t === "-c" || t === "-e" || t === "--eval" || t === "-Command" ||
      t.startsWith("--eval=") || t === "-"
    ) {
      return true;
    }
    if (t === "-m" || t === "--module") {
      // json.tool parses data; unlike a general module it does not execute
      // project code and remains an allowed fallback when jq is unavailable.
      return tokens[i + 1] !== "json.tool";
    }
    // Combined short flags: bash -lc, bash -ic, etc.
    if (t.startsWith("-") && !t.startsWith("--") && t.length > 2) {
      if ((base === "bash" || base === "sh" || base === "dash" || base === "zsh" || base === "ksh") && t.includes("c")) {
        return true;
      }
      continue;
    }
    // The first positional argument is a script file or runtime input.
    if (!t.startsWith("-")) return true;
  }
  return false;
}

function isRelativeExecutablePath(tokens: string[]): boolean {
  return tokens[0]?.startsWith("./") || tokens[0]?.startsWith("../");
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
    if (wrapper === "rtk") {
      while (i < tokens.length && (
        tokens[i] === "--ultra-compact" || tokens[i] === "--skip-env" ||
        tokens[i] === "-v" || tokens[i] === "-vv" || tokens[i] === "-vvv" ||
        tokens[i] === "--verbose"
      )) i += 1;

      if (RTK_EXECUTION_WRAPPERS.has(tokens[i])) {
        const rtkOperation = tokens[i];
        i += 1;
        while (tokens[i] === "--ultra-compact" || tokens[i] === "--skip-env") i += 1;
        if (tokens[i] === "--") i += 1;
        if (rtkOperation === "run" && (
          tokens[i] === "-c" || tokens[i] === "--command" || tokens[i]?.startsWith("--command=")
        )) {
          // `rtk run -c` passes an opaque body to sh -c.
          opaque = true;
          i += tokens[i]?.startsWith("--command=") ? 1 : (tokens[i + 1] ? 2 : 1);
        } else if (tokens[i]?.startsWith("-")) {
          // Unknown execution-wrapper options could hide the effective command.
          opaque = true;
        }
        // proxy/err/test/summary and positional run expose the effective command
        // as their remaining arguments, so the normal safety policy classifies it.
        continue;
      }
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

function isRmRecursive(tokens: string[]): boolean {
  if (tokens[0] !== "rm") {
    return false;
  }
  const rest = tokens.slice(1);
  const chars = shortFlagChars(rest);
  return /[rR]/.test(chars) || rest.includes("--recursive");
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

function isGitDestructiveWorktreeOrStashOperation(tokens: string[]): boolean {
  if (tokens[0] !== "git") return false;
  if (tokens[1] === "restore") return true;
  if (tokens[1] === "checkout") {
    return tokens.includes("--") || tokens.includes("--force") || shortFlagChars(tokens.slice(2)).includes("f");
  }
  if (tokens[1] === "switch") return tokens.includes("--discard-changes");
  return tokens[1] === "stash" && tokens.slice(2).some((token) => ["clear", "drop", "pop"].includes(token));
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

function isRtkSupportedCommand(rawTokens: string[], tokens: string[]): boolean {
  return isRtkWrapped(rawTokens) && RTK_REQUIRED_COMMANDS.has(tokens[0]);
}

function isDirectRtkRequiredCommand(rawTokens: string[], tokens: string[]): boolean {
  return !isRtkWrapped(rawTokens) && RTK_REQUIRED_COMMANDS.has(tokens[0]);
}

function hasShellExecutionProxy(tokens: string[]): boolean {
  return tokens[0] === "xargs" || (
    tokens[0] === "find" && tokens.some((token) => ["-exec", "-execdir", "-ok", "-okdir"].includes(token))
  );
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

  const rtkSupported = isRtkSupportedCommand(rawTokens, tokens);

  // Shell access to a literal protected path is always approval-gated, even
  // through rtk/wrapper commands or in a compound segment. This deliberately
  // covers both reads and writes: the shell parser cannot reliably infer intent.
  if (tokens.some((token) => isProtectedPath(token) || isProtectedLocalPath(token))) {
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

  // Interpreter wrappers and relative executable paths hide code from static matching.
  if (isInterpreterOpaque(tokens) || isRelativeExecutablePath(stripWrappers(rawTokens))) {
    return {
      decision: "ask",
      reason: "Requires approval: opaque script or executable invocation",
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

  if (isGitDestructiveWorktreeOrStashOperation(tokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: Git operation can discard worktree or stash changes",
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

  if (isRmRecursive(tokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: recursive rm",
    };
  }

  for (const pattern of DANGEROUS_ASK_COMMANDS) {
    if (matchesPrefix(tokens, pattern) || (pattern[0] === "mkfs" && tokens[0].startsWith("mkfs."))) {
      return {
        decision: "ask",
        reason: `Requires approval: ${pattern.join(" ")}`,
      };
    }
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

  // RTK only removes the wrapper requirement for commands already classified
  // as safe; approvals and denials above remain independent of RTK.
  if (rtkSupported) {
    return { decision: "allow", reason: "" };
  }

  if (isDirectRtkRequiredCommand(rawTokens, tokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: use RTK for supported command families",
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
  if (!pathValue || !isProtectedLocalPath(pathValue)) {
    return { decision: "allow", reason: "" };
  }
  if (toolName === "read") {
    return { decision: "ask", reason: `Requires approval: read of protected path: ${pathValue}` };
  }
  return { decision: "deny", reason: `Blocked ${toolName} of protected path: ${pathValue}` };
}

/**
 * Protect literal secret paths and paths that resolve through a symlink.
 * For a not-yet-created write target, resolve its nearest existing ancestor so
 * a symlinked directory cannot redirect the write into a protected location.
 */
function isProtectedLocalPath(pathValue: string): boolean {
  if (isProtectedPath(pathValue)) return true;
  let candidate = pathValue;
  while (candidate) {
    try {
      return isProtectedPath(realpathSync(candidate));
    } catch {
      const parent = dirname(candidate);
      if (parent === candidate) return false;
      candidate = parent;
    }
  }
  return false;
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
    if (marker.endsWith("/") && base === marker.slice(0, -1)) {
      return true;
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
  // Metadata-only calls must contain exactly one metadata selector and no
  // execution selector. This prevents search/describe from laundering auth.
  if (
    typeof value.tool === "string" ||
    typeof value.connect === "string" ||
    typeof value.server === "string"
  ) {
    return false;
  }
  const hasAction = typeof value.action === "string";
  const hasSearch = typeof value.search === "string";
  const hasDescribe = typeof value.describe === "string";
  if ([hasAction, hasSearch, hasDescribe].filter(Boolean).length !== 1) {
    return false;
  }
  if (hasAction) {
    return MCP_TRUSTED_GATEWAY_OPERATIONS.has(value.action as string);
  }
  // Search and describe use cached metadata only; they do not call a server.
  return MCP_TRUSTED_GATEWAY_OPERATIONS.has(hasSearch ? "search" : "describe");
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

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, allowed: Set<string>): boolean {
  return Object.keys(value).every((key) => allowed.has(key));
}

function isPublicIpv4(host: string): boolean {
  const octets = host.split(".").map(Number);
  if (octets.length !== 4 || octets.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return false;
  const [a, b, c] = octets;
  return !(
    a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 0 && c === 0) ||
    (a === 192 && b === 0 && c === 2) ||
    (a === 192 && b === 168) ||
    (a === 198 && (b === 18 || b === 19)) ||
    (a === 198 && b === 51 && c === 100) ||
    (a === 203 && b === 0 && c === 113)
  );
}

function ipv6Value(host: string): bigint | null {
  const normalized = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (isIP(normalized) !== 6) return null;
  const halves = normalized.split("::");
  if (halves.length > 2) return null;
  const parseHalf = (part: string): string[] => part ? part.split(":") : [];
  const left = parseHalf(halves[0]);
  const right = parseHalf(halves[1] || "");
  const expandIpv4 = (parts: string[]): string[] => {
    const last = parts.at(-1);
    if (!last || isIP(last) !== 4) return parts;
    const octets = last.split(".").map(Number);
    return [...parts.slice(0, -1), ((octets[0] << 8) | octets[1]).toString(16), ((octets[2] << 8) | octets[3]).toString(16)];
  };
  const expandedLeft = expandIpv4(left);
  const expandedRight = expandIpv4(right);
  const missing = 8 - expandedLeft.length - expandedRight.length;
  if ((halves.length === 1 && missing !== 0) || missing < 0) return null;
  const groups = [...expandedLeft, ...Array(missing).fill("0"), ...expandedRight];
  return groups.reduce((value, group) => (value << 16n) | BigInt(`0x${group || "0"}`), 0n);
}

function isPublicIpv6(host: string): boolean {
  const value = ipv6Value(host);
  if (value === null || value === 0n || value === 1n) return false;
  if ((value >> 32n) === 0xffffn) return isPublicIpv4([
    Number((value >> 24n) & 255n), Number((value >> 16n) & 255n),
    Number((value >> 8n) & 255n), Number(value & 255n),
  ].join("."));
  return !(
    (value >> 121n) === 0x7en || // fc00::/7 unique-local
    (value >> 118n) === 0x3fan || // fe80::/10 link-local
    (value >> 120n) === 0xffn || // ff00::/8 multicast
    (value >> 96n) === 0x20010db8n || // documentation
    (value >> 32n) === 0n // IPv4-compatible and other special low addresses
  );
}

function isSafeWebUrl(value: unknown): boolean {
  if (typeof value !== "string") return false;
  try {
    const parsed = new URL(value);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
    if (parsed.username || parsed.password) return false;
    const host = parsed.hostname.replace(/^\[|\]$/g, "").toLowerCase().replace(/\.$/, "");
    const ipVersion = isIP(host);
    if (ipVersion === 4) return isPublicIpv4(host);
    if (ipVersion === 6) return isPublicIpv6(host);
    if (!host.includes(".")) return false;
    return ![".localhost", ".local", ".internal", ".home", ".lan", ".test", ".invalid", ".example", ".onion"]
      .some((suffix) => host === suffix.slice(1) || host.endsWith(suffix));
  } catch {
    return false;
  }
}

function hasProtectedPathArgument(input: Record<string, unknown>, keys: string[]): boolean {
  return keys.some((key) => {
    const value = input[key];
    if (typeof value !== "string" || !value) return false;
    const literalized = value.replace(/[!*?{}\[\]]/g, "");
    return isProtectedLocalPath(value) || isProtectedPath(literalized) || PROTECTED_PATH_MARKERS.some((marker) => value.includes(marker));
  });
}

function isProjectConfinedPath(pathValue: unknown, requireFile = false): boolean {
  if (typeof pathValue !== "string" || !pathValue || isProtectedLocalPath(pathValue)) return false;
  try {
    const projectRoot = realpathSync(process.cwd());
    const target = realpathSync(pathValue);
    const projectRelative = relative(projectRoot, target);
    const confined = !isAbsolute(projectRelative) && projectRelative !== ".." &&
      !projectRelative.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`);
    return confined && (!requireFile || statSync(target).isFile());
  } catch {
    return false;
  }
}

function isSafeSerenaPatternSearch(input: Record<string, unknown>): boolean {
  if (input.restrict_search_to_code_files !== true) return false;
  if (input.paths_include_glob || input.paths_exclude_glob) return false;
  return isProjectConfinedPath(input.relative_path, true);
}

function isSafeFirecrawlScrapeOptions(input: Record<string, unknown>): boolean {
  const allowed = new Set([
    "formats", "jsonOptions", "queryOptions", "screenshotOptions", "parsers", "pdfOptions",
    "onlyMainContent", "redactPII", "includeTags", "excludeTags", "waitFor", "mobile",
    "skipTlsVerification", "removeBase64Images", "location", "storeInCache", "zeroDataRetention",
    "maxAge", "lockdown", "proxy",
  ]);
  return hasOnlyKeys(input, allowed) && input.storeInCache !== true;
}

function isSafeFirecrawlMap(input: Record<string, unknown>): boolean {
  const known = MCP_CONDITIONAL_ARGUMENTS["firecrawl:firecrawl_map"];
  return hasOnlyKeys(input, new Set(known)) &&
    isSafeWebUrl(input.url) &&
    Number.isInteger(input.limit) && input.limit > 0 && input.limit <= 100 &&
    input.includeSubdomains !== true;
}

function isSafeFirecrawlExtract(input: Record<string, unknown>): boolean {
  const known = MCP_CONDITIONAL_ARGUMENTS["firecrawl:firecrawl_extract"];
  return hasOnlyKeys(input, new Set(known)) &&
    Array.isArray(input.urls) && input.urls.length > 0 && input.urls.length <= 10 &&
    input.urls.every(isSafeWebUrl) &&
    input.allowExternalLinks !== true && input.enableWebSearch !== true && input.includeSubdomains !== true;
}

function isConditionallyTrustedTool(server: string, base: string, input: unknown): boolean {
  if (!isPlainObject(input)) return false;

  if (server === "serena") {
    const known = MCP_CONDITIONAL_ARGUMENTS[`${server}:${base}`];
    if (!known || !hasOnlyKeys(input, new Set(known)) ||
      hasProtectedPathArgument(input, ["relative_path", "paths_include_glob", "paths_exclude_glob"])) return false;
    if (input.relative_path !== undefined && !isProjectConfinedPath(input.relative_path)) return false;
    return base !== "serena_search_for_pattern" || isSafeSerenaPatternSearch(input);
  }

  if (server === "firecrawl" && base === "firecrawl_search") {
    const allowed = new Set(["query", "limit", "tbs", "filter", "location", "includeDomains", "excludeDomains", "sources", "categories", "scrapeOptions", "enterprise"]);
    if (!hasOnlyKeys(input, allowed) || typeof input.query !== "string" || !input.query.trim()) return false;
    return input.scrapeOptions === undefined || (isPlainObject(input.scrapeOptions) && isSafeFirecrawlScrapeOptions(input.scrapeOptions));
  }

  if (server === "firecrawl" && base === "firecrawl_scrape") {
    const { url, ...options } = input;
    return isSafeWebUrl(url) && isSafeFirecrawlScrapeOptions(options);
  }

  if (server === "firecrawl" && base === "firecrawl_map") {
    return isSafeFirecrawlMap(input);
  }

  if (server === "firecrawl" && base === "firecrawl_extract") {
    return isSafeFirecrawlExtract(input);
  }

  if (server === "playwright" && base === "browser_snapshot") {
    return hasOnlyKeys(input, new Set(["target", "depth", "boxes"]));
  }

  if (server === "playwright" && base === "browser_console_messages") {
    return hasOnlyKeys(input, new Set(["level", "all"]));
  }

  if (server === "playwright" && base === "browser_network_requests") {
    return hasOnlyKeys(input, new Set(["static", "filter"]));
  }

  if (server === "playwright" && base === "browser_network_request") {
    return hasOnlyKeys(input, new Set(["index", "part"]));
  }

  if (server === "playwright" && base === "browser_tabs") {
    return hasOnlyKeys(input, new Set(["action"])) && input.action === "list";
  }

  return false;
}

function gatewayToolArguments(input: Record<string, unknown>): unknown {
  const encoded = input.args;
  if (typeof encoded === "string") {
    try {
      return JSON.parse(encoded);
    } catch {
      return null;
    }
  }
  return isPlainObject(encoded) ? encoded : null;
}

/**
 * Trust only managed MCP operations classified as read-only, or conditional-read
 * operations whose arguments pass their corresponding safety checks.
 */
function isTrustedManagedTool(server: string, toolName: string, input?: unknown): boolean {
  if (!isManagedServer(server)) return false;
  const base = managedToolBaseName(toolName, server);
  if (MCP_CONDITIONAL_TOOLS.has(`${server}:${base}`)) {
    return isConditionallyTrustedTool(server, base, input);
  }
  if (server === "serena") return SERENA_TRUSTED_TOOLS.has(base);
  if (server === "codegraph") return CODEGRAPH_TRUSTED_TOOLS.has(base);
  if (server === "context7") return CONTEXT7_TRUSTED_TOOLS.has(base);
  if (server === "brave-search") return BRAVE_SEARCH_TRUSTED_TOOLS.has(base);
  if (server === "firecrawl") return FIRECRAWL_TRUSTED_TOOLS.has(base);
  if (server === "playwright") return PLAYWRIGHT_TRUSTED_TOOLS.has(base);
  return false;
}

/**
 * True when this call is a trusted managed b-agentic MCP action that should
 * run without a Pi approval prompt. Fail closed on mixed MCP selectors,
 * server/tool origin mismatch, auth bootstrap, and non-managed servers.
 */
function isTrustedManagedMcpCall(toolName: string, input?: unknown): boolean {
  if (toolName !== "mcp") {
    const server = managedServerFromToolName(toolName);
    if (!server) {
      return false;
    }
    return isTrustedManagedTool(server, toolName, input);
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
    return false;
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
    const server = fromName || explicitServer;
    if (!server || !isManagedServer(server)) {
      return false;
    }
    return isTrustedManagedTool(server, tool, gatewayToolArguments(value as Record<string, unknown>));
  }

  if (typeof value.server === "string") {
    return false;
  }

  return false;
}

/**
 * Returns true when the tool call should go through the custom/MCP approval prompt.
 * Built-ins, MCP metadata discovery, and classified safe managed operations return false.
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

    // Managed mutations, uploads, auth, user/unknown MCP, and custom tools ask.
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
  isRelativeExecutablePath,
  isRtkWrapped,
  hasOpaqueWrapper,
  isStandaloneEnvCommand,
  isRtkSupportedCommand,
  isDirectRtkRequiredCommand,
  isRmRecursive,
  hasInlineGitAliasInvocation,
  hasOpaqueGitOptions,
  hasOpaquePackageOptions,
  nativePathDecision,
  isProtectedLocalPath,
  confirmOrBlock,
  SPECIALIZED_TOOLS,
  MANAGED_MCP_SERVERS,
  MCP_TRUSTED_GATEWAY_OPERATIONS,
  MCP_CONDITIONAL_TOOLS,
  isConditionallyTrustedTool,
  SERENA_TRUSTED_TOOLS,
  CODEGRAPH_TRUSTED_TOOLS,
  CONTEXT7_TRUSTED_TOOLS,
  BRAVE_SEARCH_TRUSTED_TOOLS,
  FIRECRAWL_TRUSTED_TOOLS,
  PLAYWRIGHT_TRUSTED_TOOLS,
  ASK_COMMANDS,
  DANGEROUS_ASK_COMMANDS,
  DENY_COMMANDS,
  RTK_REQUIRED_COMMANDS,
  RTK_EXECUTION_WRAPPERS,
  isProjectConfinedPath,
};
