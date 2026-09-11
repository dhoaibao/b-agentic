import { existsSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, dirname, isAbsolute, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  ASK_COMMANDS,
  DANGEROUS_ASK_COMMANDS,
  DENY_COMMANDS,
  PROTECTED_PATH_MARKERS,
  SERVICE_COMMANDS,
} from "./permissions-data.ts";

export type Decision = "allow" | "ask" | "deny";

export {
  ASK_COMMANDS,
  DANGEROUS_ASK_COMMANDS,
  DENY_COMMANDS,
  PROTECTED_PATH_MARKERS,
  SERVICE_COMMANDS,
};

export const COMPOUND_SOURCE_CODE_FILENAME =
  /^[^.]+\..+\.(?:[cm]?[jt]sx?|py|rb|go|rs|java|kt|kts|c(?:c|pp|xx)?|h(?:pp)?|cs|php|swift|scala|vue|svelte|astro)$/i;

/**
 * Built-in and first-party Pi tools with specialized policy.
 * Legacy discovery tools (grep/find/ls) are blocked so agents use bash with
 * modern shell tools (rg/fdfind/eza) per the kernel. recall and todo are first-party
 * memory and task tools. Managed MCP operations are approved only when classified safe.
 */
export const SPECIALIZED_TOOLS = new Set([
  "bash",
  "write",
  "edit",
  "read",
  "recall",
  "todo",
  "ask_user_question",
  "mcpScript",
  "grep",
  "find",
  "ls",
]);

export const WRAPPER_COMMANDS = new Set([
  "rtk",
  "sudo",
  "command",
  "nohup",
  "nice",
  "time",
  "env",
]);
/** RTK subcommands that execute another command and must expose it to policy matching. */
export const RTK_EXECUTION_WRAPPERS = new Set([
  "proxy",
  "err",
  "test",
  "summary",
  "run",
]);
/**
 * Every native family supported by RTK must go through RTK, including
 * discovery commands. Modern replacements remain direct only when RTK does
 * not support that command family.
 */
export const RTK_REQUIRED_COMMANDS = new Set([
  "git",
  "gh",
  "glab",
  "aws",
  "psql",
  "pnpm",
  "dotnet",
  "docker",
  "kubectl",
  "oc",
  "wget",
  "jest",
  "vitest",
  "ctest",
  "prisma",
  "tsc",
  "next",
  "lint",
  "prettier",
  "format",
  "playwright",
  "cargo",
  "npm",
  "npx",
  "curl",
  "ruff",
  "pytest",
  "mypy",
  "rake",
  "rubocop",
  "rspec",
  "pip",
  "go",
  "gt",
  "golangci-lint",
  "gradlew",
  "mvn",
  "mvnd",
  "ecs",
  "paratest",
  "pest",
  "phpt",
  "php",
  "phpstan",
  "phpunit",
  "pint",
  "sbt",
  "uv",
  "bun",
  "bunx",
  "deno",
  "ls",
  "tree",
  "find",
  "diff",
  "grep",
  "rg",
  "wc",
]);
/** Reserved for future RTK-native families that are explicitly exempted. */
export const RTK_OPTIONAL_COMMANDS = new Set([]);

/** Interpreters that execute opaque code or script files; always approval-required. */
export const INTERPRETER_BASES = new Set([
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
  "bunx",
  "pwsh",
  "powershell",
]);

export function tokenize(command: string): string[] {
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
export function splitShellSegments(command: string): string[] {
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

export function hasUnquotedGlob(command: string): boolean {
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

export function hasUnsafeShellSyntax(command: string): boolean {
  // Expansions, substitutions, process substitutions, and eval make static
  // command/path matching unreliable — fail closed with ask. Source-dot only
  // at segment start (not path tokens like "cd .").
  let quote: "'" | '"' | null = null;
  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    if (quote) {
      if (ch === quote) quote = null;
      else if (ch === "\\" && quote === '"') i += 1;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }
    if (ch === "{" && command.slice(i).match(/^\{[^}]*,/)) return true;
  }
  return /\$|`|[<>]\(|\bsource\b|\beval\b|(?:^|[;&|]\s*)\.\s+\S/.test(command);
}

export function hasAmbiguousShellSyntax(command: string): boolean {
  // Unquoted globs are ambiguous for general shell policy because expansion
  // changes the paths being inspected. Read-only policy may permit them only
  // after proving the whole command is a direct read-only allowlisted command.
  return hasUnsafeShellSyntax(command) || hasUnquotedGlob(command);
}

export function hasShellControlSyntax(command: string): boolean {
  // Control structures require shell parsing across segments; fail closed with approval instead of
  // treating keywords such as `if` or `while` as raw executables.
  return /(?:^|[;\n]\s*)(?:if|for|while|until|case|select|coproc|function|then|elif|else|fi|do|done|esac)\b|(?:^|[;\n]\s*)[{}]/.test(
    command,
  );
}

export function hasUnbalancedQuotes(command: string): boolean {
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

export function baseName(token: string): string {
  const slash = Math.max(token.lastIndexOf("/"), token.lastIndexOf("\\"));
  return slash >= 0 ? token.slice(slash + 1) : token;
}

/**
 * Detect interpreter invocations whose code is opaque to static matching.
 * Inline/eval bodies and non-project modules remain gated; existing project-local
 * script files are routine automation and may run autonomously.
 */
export function isInterpreterOpaque(tokens: string[]): boolean {
  if (tokens.length === 0) {
    return false;
  }
  const base = baseName(tokens[0]);
  if (!INTERPRETER_BASES.has(base)) {
    return false;
  }
  if (
    base === "bun" &&
    ["install", "i", "add", "remove", "uninstall", "update"].includes(
      packageOperation(tokens).operation || "",
    )
  ) {
    return false;
  }
  for (let i = 1; i < tokens.length; i += 1) {
    const t = tokens[i];
    if (
      t === "-c" ||
      t === "-e" ||
      t === "--eval" ||
      t === "-Command" ||
      t.startsWith("--eval=") ||
      t === "-"
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
      if (
        (base === "bash" ||
          base === "sh" ||
          base === "dash" ||
          base === "zsh" ||
          base === "ksh") &&
        t.includes("c")
      ) {
        return true;
      }
      continue;
    }
    // Existing project-local script files are routine repository automation.
    if (!t.startsWith("-")) return !isExistingProjectConfinedLocalPath(t);
  }
  return false;
}

export function isOpaqueExecutablePath(rawTokens: string[]): boolean {
  const trustedRoots = [
    "/bin",
    "/sbin",
    "/usr/bin",
    "/usr/sbin",
    "/usr/local/bin",
    "/opt/homebrew/bin",
  ];
  const isOpaque = (executable: string | undefined): boolean => {
    if (!executable) return false;
    if (isExistingProjectConfinedLocalPath(executable)) return false;
    if (
      executable.startsWith("~") ||
      executable.startsWith("./") ||
      executable.startsWith("../")
    )
      return true;
    if (!isAbsolute(executable)) return false;
    const normalizedExecutable = resolve(executable);
    return !trustedRoots.some(
      (root) =>
        normalizedExecutable === root ||
        normalizedExecutable.startsWith(`${root}/`),
    );
  };
  const firstExecutable = rawTokens.find(
    (token) => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(token),
  );
  const unwrappedExecutable = unwrapTokens(rawTokens).tokens[0];
  return isOpaque(firstExecutable) || isOpaque(unwrappedExecutable);
}

export function unwrapTokens(tokens: string[]): {
  tokens: string[];
  wrappers: Set<string>;
  opaque: boolean;
} {
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
      while (
        i < tokens.length &&
        tokens[i].startsWith("-") &&
        tokens[i] !== "--"
      ) {
        if (
          ["-u", "-g", "-C", "-n", "-p"].includes(tokens[i]) &&
          tokens[i + 1]
        ) {
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
      while (
        i < tokens.length &&
        (tokens[i] === "--ultra-compact" ||
          tokens[i] === "--skip-env" ||
          tokens[i] === "-v" ||
          tokens[i] === "-vv" ||
          tokens[i] === "-vvv" ||
          tokens[i] === "--verbose")
      )
        i += 1;

      if (RTK_EXECUTION_WRAPPERS.has(tokens[i])) {
        const rtkOperation = tokens[i];
        i += 1;
        while (tokens[i] === "--ultra-compact" || tokens[i] === "--skip-env")
          i += 1;
        if (tokens[i] === "--") i += 1;
        if (
          rtkOperation === "run" &&
          (tokens[i] === "-c" ||
            tokens[i] === "--command" ||
            tokens[i]?.startsWith("--command="))
        ) {
          // `rtk run -c` passes an opaque body to sh -c.
          opaque = true;
          i += tokens[i]?.startsWith("--command=") ? 1 : tokens[i + 1] ? 2 : 1;
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

export function stripWrappers(tokens: string[]): string[] {
  return unwrapTokens(tokens).tokens;
}

export function hasInlineGitAliasInvocation(tokens: string[]): boolean {
  if (tokens[0] !== "git") {
    return false;
  }
  const aliases = new Set<string>();
  let i = 1;
  while (i < tokens.length && tokens[i].startsWith("-")) {
    const option = tokens[i];
    let value: string;
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
    } else if (
      option === "-C" ||
      option === "--git-dir" ||
      option === "--work-tree" ||
      option === "--namespace"
    ) {
      i += 2;
      continue;
    } else if (
      option.startsWith("--git-dir=") ||
      option.startsWith("--work-tree=") ||
      option.startsWith("--namespace=")
    ) {
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

export function gitEffectiveTokens(tokens: string[]): string[] {
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
    if (
      t === "-C" ||
      t === "-c" ||
      t === "--git-dir" ||
      t === "--work-tree" ||
      t === "--namespace" ||
      t === "--config-env"
    ) {
      i += tokens[i + 1] ? 2 : 1;
      continue;
    }
    // Combined forms like -cfoo.bar=baz and long options with inline values.
    if (t.startsWith("-c") && t.length > 2) {
      i += 1;
      continue;
    }
    if (
      t.startsWith("--git-dir=") ||
      t.startsWith("--work-tree=") ||
      t.startsWith("--namespace=") ||
      t.startsWith("--config-env=")
    ) {
      i += 1;
      continue;
    }
    i += 1;
  }
  out.push(...tokens.slice(i));
  return out;
}

export function normalizeTokens(tokens: string[]): string[] {
  const stripped = stripWrappers(tokens);
  if (stripped[0]) {
    stripped[0] = baseName(stripped[0]);
  }
  if (stripped[0] === "git") {
    return gitEffectiveTokens(stripped);
  }
  return stripped;
}

const EMPTY_MODERN_SHELL_TOOLS: ReadonlySet<string> = new Set();
const PACKAGE_VALUE_OPTIONS = new Set(["--prefix", "--dir", "--manifest-path"]);
const PACKAGE_VALUELESS_OPTIONS = new Set([
  "--silent",
  "--json",
  "--offline",
  "--version",
]);
const OPAQUE_PACKAGE_MANAGERS = new Set([
  "npm",
  "npx",
  "pnpm",
  "yarn",
  "bun",
  "cargo",
  "go",
  "pip",
  "pip3",
  "poetry",
  "uv",
]);
const DEPENDENCY_PATH_MANAGERS = new Set([
  "npm",
  "pnpm",
  "yarn",
  "bun",
  "cargo",
  "go",
  "pip",
  "pip3",
  "poetry",
  "uv",
]);
const DEPENDENCY_WRITES: Record<string, ReadonlySet<string>> = {
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
const DEPENDENCY_PATH_OPTIONS = new Set([
  "--prefix",
  "--dir",
  "--manifest-path",
  "--target",
  "--root",
]);
const DEPENDENCY_GLOBAL_OPTIONS = new Set([
  "-g",
  "--global",
  "--user",
  "--system",
  "--break-system-packages",
]);
const PACKAGE_EXECUTION_OPERATIONS: Record<string, ReadonlySet<string>> = {
  npm: new Set(["exec", "rebuild", "run", "run-script", "test", "start"]),
  bun: new Set(["run", "test", "x"]),
};
const PACKAGE_NON_EXECUTION_OPERATIONS = new Set([
  "audit",
  "help",
  "info",
  "licenses",
  "list",
  "outdated",
  "root",
  "search",
  "view",
  "why",
]);

export function packageOperation(tokens: string[]): {
  operation: string | null;
  opaque: boolean;
} {
  let i = 1;
  while (i < tokens.length) {
    const token = tokens[i];
    if (!token.startsWith("-")) return { operation: token, opaque: false };
    if (token === "--")
      return { operation: tokens[i + 1] || null, opaque: false };
    if (token.includes("=")) {
      i += 1;
      continue;
    }
    if (PACKAGE_VALUE_OPTIONS.has(token)) {
      if (!tokens[i + 1]) return { operation: null, opaque: true };
      i += 2;
      continue;
    }
    if (PACKAGE_VALUELESS_OPTIONS.has(token)) {
      i += 1;
      continue;
    }
    // Do not let an unparsed global option hide a dependency operation.
    return { operation: null, opaque: true };
  }
  return { operation: null, opaque: false };
}

export function hasOpaquePackageOptions(tokens: string[]): boolean {
  return (
    OPAQUE_PACKAGE_MANAGERS.has(tokens[0]) && packageOperation(tokens).opaque
  );
}

export function hasDependencyWrite(tokens: string[]): boolean {
  const manager = tokens[0];
  const { operation } = packageOperation(tokens);
  if (!manager || !operation) return false;
  if (manager === "uv" && operation === "pip") {
    return tokens
      .slice(2)
      .some(
        (token) =>
          token === "install" || token === "uninstall" || token === "sync",
      );
  }
  return DEPENDENCY_WRITES[manager]?.has(operation) ?? false;
}

/** Dependency managers may target another directory, but only inside this project. */
export function hasDependencyPathRisk(tokens: string[]): boolean {
  const manager = tokens[0];
  if (!manager || !DEPENDENCY_PATH_MANAGERS.has(manager)) return false;

  const operation = packageOperation(tokens).operation;
  // These install binaries into a toolchain-managed location rather than the
  // repository, even when a package manager cache is already present.
  if ((manager === "cargo" || manager === "go") && operation === "install")
    return true;

  for (let i = 1; i < tokens.length; i += 1) {
    const token = tokens[i];
    const inline = token.match(
      /^(--prefix|--dir|--manifest-path|--target|--root)=(.*)$/,
    );
    if (inline) {
      if (!inline[2] || !isProjectConfinedLocalPath(inline[2])) return true;
      continue;
    }
    if (
      DEPENDENCY_GLOBAL_OPTIONS.has(token) ||
      /^(?:--global|--user|--system)=/.test(token)
    )
      return true;
    if (/^--location=(?:global|system)$/.test(token)) return true;
    if (
      token === "--location" &&
      /^(?:global|system)$/.test(tokens[i + 1] ?? "")
    )
      return true;
    if (DEPENDENCY_PATH_OPTIONS.has(token)) {
      const target = tokens[i + 1];
      if (!target || !isProjectConfinedLocalPath(target)) return true;
      i += 1;
    }
  }

  // Yarn's `global` command installs outside the repository by definition.
  return manager === "yarn" && operation === "global";
}

export function hasOpaquePackageExecution(tokens: string[]): boolean {
  const manager = tokens[0];
  if (manager === "npx") return true;
  const { operation } = packageOperation(tokens);
  if (!manager || !operation) return false;
  if (PACKAGE_EXECUTION_OPERATIONS[manager]?.has(operation)) return true;
  if (manager === "pnpm" || manager === "yarn") {
    return !PACKAGE_NON_EXECUTION_OPERATIONS.has(operation);
  }
  return false;
}

export const B_AGENTIC_SKILL_NAMES = new Set([
  "b-plan",
  "b-research",
  "b-design",
  "b-frontend",
  "b-diagram",
  "b-implement",
  "b-init",
  "b-refactor",
  "b-debug",
  "b-test",
  "b-browser",
  "b-agentic-audit",
  "b-review",
  "b-commit",
  "b-pr-summary",
]);

export const LOCAL_PATH_COMMANDS = new Set([
  "7z",
  "ar",
  "awk",
  "bat",
  "batcat",
  "cat",
  "cmp",
  "cp",
  "cpio",
  "curl",
  "diff",
  "eza",
  "exa",
  "fd",
  "fdfind",
  "file",
  "find",
  "git",
  "grep",
  "head",
  "install",
  "less",
  "ln",
  "ls",
  "make",
  "mkdir",
  "mkfifo",
  "mknod",
  "more",
  "mv",
  "pax",
  "readlink",
  "realpath",
  "rg",
  "rm",
  "rmdir",
  "rsync",
  "sed",
  "shred",
  "stat",
  "tail",
  "tar",
  "tee",
  "test",
  "touch",
  "truncate",
  "unzip",
  "unlink",
  "wc",
  "wget",
  "zip",
]);

export function expandLocalPath(pathValue: string): string {
  if (pathValue === "~") return homedir();
  if (pathValue.startsWith("~/")) return resolve(homedir(), pathValue.slice(2));
  return resolve(pathValue);
}

const UNICODE_SPACES = /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g;

/** Mirror Pi's native-tool path resolution without changing shell path syntax. */
export function resolveNativeToolPath(
  pathValue: string,
  cwd: string = process.cwd(),
  read = false,
): string {
  let normalized = pathValue.replace(UNICODE_SPACES, " ");
  if (normalized.startsWith("@")) normalized = normalized.slice(1);
  if (normalized === "~") normalized = homedir();
  else if (normalized.startsWith("~/"))
    normalized = resolve(homedir(), normalized.slice(2));
  if (/^file:\/\//.test(normalized)) normalized = fileURLToPath(normalized);
  const resolved = resolve(cwd, normalized);
  if (!read || existsSync(resolved)) return resolved;

  const macOsScreenshotPath = resolved.replace(/ (AM|PM)\./gi, "\u202F$1.");
  if (macOsScreenshotPath !== resolved && existsSync(macOsScreenshotPath))
    return macOsScreenshotPath;
  const nfdPath = resolved.normalize("NFD");
  if (nfdPath !== resolved && existsSync(nfdPath)) return nfdPath;
  const curlyQuotePath = resolved.replace(/'/g, "\u2019");
  if (curlyQuotePath !== resolved && existsSync(curlyQuotePath))
    return curlyQuotePath;
  const nfdCurlyQuotePath = nfdPath.replace(/'/g, "\u2019");
  if (nfdCurlyQuotePath !== resolved && existsSync(nfdCurlyQuotePath))
    return nfdCurlyQuotePath;
  return resolved;
}

export function canonicalNativeToolPath(
  pathValue: string,
  cwd: string,
): string {
  const resolved = resolveNativeToolPath(pathValue, cwd);
  try {
    return realpathSync(resolved);
  } catch {
    return resolved;
  }
}

export function isConfinedRelativePath(
  pathValue: string,
  projectRoot: string,
): boolean {
  const projectRelative = relative(projectRoot, pathValue);
  return (
    !isAbsolute(projectRelative) &&
    projectRelative !== ".." &&
    !projectRelative.startsWith(
      `..${process.platform === "win32" ? "\\" : "/"}`,
    )
  );
}

export function isInstalledBAgenticSkillPath(effectivePath: string): boolean {
  if (!effectivePath) return false;
  try {
    const configuredAgentDir =
      process.env.PI_CODING_AGENT_DIR?.trim() ||
      resolve(homedir(), ".pi", "agent");
    const agentRoot = realpathSync(expandLocalPath(configuredAgentDir));
    const absoluteTarget = realpathSync(effectivePath);
    if (isProtectedLocalPath(absoluteTarget)) return false;
    const targetParts = relative(agentRoot, absoluteTarget).split(/[\\/]/);
    if (
      targetParts.length !== 3 ||
      targetParts[0] !== "skills" ||
      !B_AGENTIC_SKILL_NAMES.has(targetParts[1]) ||
      targetParts[2] !== "SKILL.md"
    )
      return false;
    return isConfinedRelativePath(realpathSync(absoluteTarget), agentRoot);
  } catch {
    return false;
  }
}

function isProjectConfinedResolvedPath(pathValue: string): boolean {
  if (!pathValue) return false;
  try {
    const projectRoot = realpathSync(process.cwd());
    const absoluteTarget = expandLocalPath(pathValue);
    let existing = absoluteTarget;
    while (!existsSync(existing)) {
      const parent = dirname(existing);
      if (parent === existing) return false;
      existing = parent;
    }
    return (
      isConfinedRelativePath(absoluteTarget, projectRoot) &&
      isConfinedRelativePath(realpathSync(existing), projectRoot)
    );
  } catch {
    return false;
  }
}

export function isProjectConfinedLocalPath(pathValue: string): boolean {
  if (!pathValue || isProtectedLocalPath(pathValue)) return false;
  return isProjectConfinedResolvedPath(pathValue);
}

export function isExistingProjectConfinedLocalPath(pathValue: string): boolean {
  return (
    existsSync(expandLocalPath(pathValue)) &&
    isProjectConfinedLocalPath(pathValue)
  );
}

function isNativeProjectConfinedPath(
  effectivePath: string,
  cwd: string,
): boolean {
  try {
    const projectRoot = realpathSync(cwd);
    let existing = effectivePath;
    while (!existsSync(existing)) {
      const parent = dirname(existing);
      if (parent === existing) return false;
      existing = parent;
    }
    // Resolve the existing ancestor before comparing it with the canonical
    // project root. `cwd` may itself use a symlinked macOS path such as /tmp,
    // while realpathSync(cwd) uses its /private/tmp target.
    return isConfinedRelativePath(realpathSync(existing), projectRoot);
  } catch {
    return false;
  }
}

export function isExternalUrl(value: string): boolean {
  return /^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(value);
}

export function isRemoteTarget(value: string): boolean {
  if (/^[A-Za-z]:[\\/]/.test(value)) return false;
  return /^(?:[^@/\s]+@)?(?:\[[^\]]+\]|[A-Za-z0-9._-]+):.+/.test(value);
}

export function hasWorkingDirectoryChangeRisk(
  rawTokens: string[],
  tokens: string[],
): boolean {
  const command = baseName(tokens[0] || "");
  if (["cd", "popd", "pushd"].includes(command)) return true;
  for (let i = 0; i < rawTokens.length; i += 1) {
    const token = rawTokens[i];
    let target: string;
    if (token === "-C" || token === "--chdir" || token === "--directory") {
      target = rawTokens[i + 1] || "";
    } else if (token.startsWith("-C") && token.length > 2) {
      target = token.slice(2);
    } else if (
      token.startsWith("--chdir=") ||
      token.startsWith("--directory=")
    ) {
      target = token.slice(token.indexOf("=") + 1);
    } else {
      continue;
    }
    if (!target || !isProjectConfinedLocalPath(target)) return true;
  }
  return false;
}

export type JqOperands = {
  valid: boolean;
  externalProgram: boolean;
  nullInput: boolean;
  program?: string;
  programIndex?: number;
  filePaths: string[];
  inputPaths: string[];
};

/** Parse jq's safe standard flag/value forms, separating filters from filesystem operands. */
export function jqOperands(tokens: string[]): JqOperands {
  const result: JqOperands = {
    valid: tokens[0] === "jq",
    externalProgram: false,
    nullInput: false,
    filePaths: [],
    inputPaths: [],
  };
  const flags = new Set([
    "c",
    "r",
    "j",
    "0",
    "a",
    "S",
    "C",
    "M",
    "e",
    "s",
    "R",
    "n",
  ]);
  const longFlags = new Set([
    "--compact-output",
    "--raw-output",
    "--join-output",
    "--raw-output0",
    "--ascii-output",
    "--sort-keys",
    "--color-output",
    "--monochrome-output",
    "--exit-status",
    "--slurp",
    "--raw-input",
    "--null-input",
  ]);
  const valueCounts = new Map([
    ["--arg", 2],
    ["--argjson", 2],
    ["--rawfile", 2],
    ["--slurpfile", 2],
    ["--argfile", 2],
    ["-L", 1],
    ["--library-path", 1],
    ["-f", 1],
    ["--from-file", 1],
  ]);
  const fileValueOffsets = new Map([
    ["--rawfile", 2],
    ["--slurpfile", 2],
    ["--argfile", 2],
    ["-L", 1],
    ["--library-path", 1],
    ["-f", 1],
    ["--from-file", 1],
  ]);
  let afterOptions = false;
  for (let index = 1; index < tokens.length; index += 1) {
    const token = tokens[index]!;
    if (!afterOptions && token === "--") {
      afterOptions = true;
      continue;
    }
    if (!afterOptions) {
      const count = valueCounts.get(token);
      if (count !== undefined) {
        if (index + count >= tokens.length) return { ...result, valid: false };
        const fileOffset = fileValueOffsets.get(token);
        if (fileOffset !== undefined)
          result.filePaths.push(tokens[index + fileOffset]!);
        if (token === "-f" || token === "--from-file")
          result.externalProgram = true;
        index += count;
        continue;
      }
      if (token === "--null-input") {
        result.nullInput = true;
        continue;
      }
      if (longFlags.has(token)) continue;
      if (
        /^-[^-]+$/.test(token) &&
        token
          .slice(1)
          .split("")
          .every((flag) => flags.has(flag))
      ) {
        if (token.includes("n")) result.nullInput = true;
        continue;
      }
      if (token.startsWith("-")) return { ...result, valid: false };
    }
    if (result.externalProgram || result.program !== undefined)
      result.inputPaths.push(token);
    else {
      result.program = token;
      result.programIndex = index;
    }
  }
  return result.externalProgram || result.program !== undefined
    ? result
    : { ...result, valid: false };
}

function jqInputPathRisk(tokens: string[]): boolean {
  const parsed = jqOperands(tokens);
  return (
    !parsed.valid ||
    [...parsed.filePaths, ...parsed.inputPaths].some(
      (path) => !isProjectConfinedLocalPath(path),
    )
  );
}

export function hasLocalFilesystemRisk(
  tokens: string[],
  options: { allowUnquotedGlob?: boolean } = {},
): boolean {
  if (tokens.length === 0) return false;

  const command = baseName(tokens[0]);
  if (["curl", "wget"].includes(command)) {
    for (let i = 1; i < tokens.length; i += 1) {
      const token = tokens[i];
      const inlineOutput = token.match(/^--(?:output|output-document)=(.*)$/);
      if (inlineOutput?.[1] && !isProjectConfinedLocalPath(inlineOutput[1]))
        return true;
      if (["-o", "-O", "--output", "--output-document"].includes(token)) {
        const target = tokens[i + 1] || "";
        if (target && !isProjectConfinedLocalPath(target)) return true;
        i += 1;
      }
    }
  }

  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    const redirection = token.match(/^(?:\d+)?(?:>>|>|&>>|&>|<)(.*)$/);
    if (!redirection) continue;
    const target = redirection[1] || tokens[i + 1] || "";
    if (
      target &&
      !/^&?\d+$/.test(target) &&
      !isProjectConfinedLocalPath(target)
    )
      return true;
  }

  if (command === "rm") return true;
  if (command === "jq") return jqInputPathRisk(tokens);
  if (command === "rsync" && tokens.slice(1).some(isRemoteTarget)) return true;
  if (!LOCAL_PATH_COMMANDS.has(command)) return false;
  return tokens.slice(1).some((token) => {
    if (
      !token ||
      token.startsWith("-") ||
      isNegatedGlob(token) ||
      isExternalUrl(token) ||
      /^&?\d+$/.test(token)
    )
      return false;
    if (options.allowUnquotedGlob && /[*?[\]{}]/.test(token)) {
      const staticPrefix = token.split(/[*?[\]{}]/, 1)[0] || ".";
      if (isProjectConfinedResolvedPath(staticPrefix)) return false;
      return true;
    }
    return !isProjectConfinedLocalPath(token);
  });
}

export function hasExternalOrSharedMutationRisk(tokens: string[]): boolean {
  const command = tokens[0];
  if (!command) return false;

  if (["aws", "psql", "scp", "sftp", "ssh"].includes(command)) return true;

  if (["npm", "pnpm", "yarn", "bun"].includes(command)) {
    const registryMutationMarkers = new Set([
      "access",
      "deprecate",
      "dist-tag",
      "link",
      "owner",
      "publish",
      "star",
      "token",
      "unlink",
      "unpublish",
      "unstar",
      "version",
    ]);
    const externalScriptMarkers = new Set([
      "deploy",
      "release",
      "ship",
      "upload",
    ]);
    if (
      tokens
        .slice(1)
        .some(
          (token) =>
            registryMutationMarkers.has(token) ||
            externalScriptMarkers.has(token),
        )
    )
      return true;
    if (
      tokens.includes("config") &&
      tokens
        .slice(tokens.indexOf("config") + 1)
        .some((token) => ["delete", "set"].includes(token))
    )
      return true;
  }

  if (command === "gh" || command === "glab") {
    const mutationMarkers = new Set([
      "api",
      "approve",
      "archive",
      "auth",
      "cancel",
      "checkout",
      "clone",
      "close",
      "comment",
      "create",
      "delete",
      "disable",
      "edit",
      "enable",
      "fork",
      "merge",
      "ready",
      "reopen",
      "request-changes",
      "set",
      "transfer",
      "unarchive",
      "upload",
    ]);
    if (tokens.slice(1).some((token) => mutationMarkers.has(token)))
      return true;
    if (command === "gh" && tokens[1] === "workflow" && tokens[2] === "run")
      return true;
    const readOnlyMarkers = new Set([
      "checks",
      "diff",
      "get",
      "help",
      "list",
      "logs",
      "search",
      "show",
      "status",
      "trace",
      "verify",
      "version",
      "view",
      "watch",
    ]);
    return !tokens.slice(1).some((token) => readOnlyMarkers.has(token));
  }

  if (command === "kubectl" || command === "oc") {
    const mutationOperations = new Set([
      "annotate",
      "apply",
      "attach",
      "autoscale",
      "certificate",
      "cordon",
      "cp",
      "create",
      "delete",
      "drain",
      "edit",
      "exec",
      "expose",
      "label",
      "patch",
      "replace",
      "rollout",
      "run",
      "scale",
      "set",
      "taint",
      "uncordon",
    ]);
    if (tokens.slice(1).some((token) => mutationOperations.has(token)))
      return true;
    const readOnlyOperations = new Set([
      "api-resources",
      "api-versions",
      "auth",
      "cluster-info",
      "describe",
      "diff",
      "explain",
      "get",
      "logs",
      "top",
      "version",
      "wait",
    ]);
    return !tokens.slice(1).some((token) => readOnlyOperations.has(token));
  }

  if (command === "docker") {
    const mutationOperations = new Set([
      "attach",
      "build",
      "commit",
      "cp",
      "create",
      "exec",
      "import",
      "kill",
      "load",
      "login",
      "logout",
      "pause",
      "pull",
      "push",
      "rename",
      "restart",
      "rm",
      "rmi",
      "run",
      "save",
      "start",
      "stop",
      "tag",
      "unpause",
      "update",
    ]);
    if (tokens[1] === "compose") {
      const composeMutationOperations = new Set([
        "build",
        "cp",
        "create",
        "down",
        "exec",
        "kill",
        "pause",
        "pull",
        "push",
        "restart",
        "rm",
        "run",
        "start",
        "stop",
        "unpause",
        "up",
        "watch",
      ]);
      if (tokens.slice(2).some((token) => composeMutationOperations.has(token)))
        return true;
      return !tokens
        .slice(2)
        .some((token) =>
          new Set(["config", "images", "logs", "ls", "ps", "top"]).has(token),
        );
    }
    if (tokens.slice(1).some((token) => mutationOperations.has(token)))
      return true;
    const readOnlyOperations = new Set([
      "diff",
      "events",
      "history",
      "images",
      "info",
      "inspect",
      "logs",
      "ls",
      "port",
      "ps",
      "stats",
      "top",
      "version",
    ]);
    return !tokens.slice(1).some((token) => readOnlyOperations.has(token));
  }

  if (command === "curl") {
    return tokens
      .slice(1)
      .some((token) =>
        /^(?:-d|-F|-T|-X|--data(?:-|$)|--form(?:-|$)|--request(?:=|$)|--upload-file(?:=|$))/.test(
          token,
        ),
      );
  }

  if (command === "wget") {
    return tokens
      .slice(1)
      .some((token) =>
        /^(?:--method(?:=|$)|--post-data(?:=|$)|--post-file(?:=|$)|--body-data(?:=|$)|--body-file(?:=|$))/.test(
          token,
        ),
      );
  }

  return false;
}

export function matchesPrefix(tokens: string[], pattern: string[]): boolean {
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

export function shortFlagChars(tokens: string[]): string {
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

export function isRmRecursive(tokens: string[]): boolean {
  if (tokens[0] !== "rm") {
    return false;
  }
  const rest = tokens.slice(1);
  const chars = shortFlagChars(rest);
  return /[rR]/.test(chars) || rest.includes("--recursive");
}

export function hasOpaqueGitOptions(tokens: string[]): boolean {
  if (tokens[0] !== "git") return false;
  const valueOptions = new Set([
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--config-env",
  ]);
  const valuelessOptions = new Set([
    "--no-pager",
    "--bare",
    "--literal-pathspecs",
    "--no-optional-locks",
    "--version",
  ]);
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

export function isGitForcePush(tokens: string[]): boolean {
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

export function isGitCleanForce(tokens: string[]): boolean {
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

export function isGitBranchForceDelete(tokens: string[]): boolean {
  if (!matchesPrefix(tokens, ["git", "branch"])) {
    return false;
  }
  return (
    tokens.includes("-D") ||
    (tokens.includes("--delete") && tokens.includes("--force"))
  );
}

export function isGitDestructiveWorktreeOrStashOperation(
  tokens: string[],
): boolean {
  if (tokens[0] !== "git") return false;
  if (tokens[1] === "restore") return true;
  if (tokens[1] === "checkout") {
    return (
      tokens.includes("--") ||
      tokens.includes("--force") ||
      shortFlagChars(tokens.slice(2)).includes("f")
    );
  }
  if (tokens[1] === "switch") return tokens.includes("--discard-changes");
  return (
    tokens[1] === "stash" &&
    tokens.slice(2).some((token) => ["clear", "drop", "pop"].includes(token))
  );
}

/** Shared-scope Git config writes require approval; project-local config remains autonomous. */
export function hasGitSharedScopeConfigRisk(tokens: string[]): boolean {
  if (tokens[0] !== "git" || tokens[1] !== "config") return false;
  return tokens
    .slice(2)
    .some(
      (token) =>
        token === "--global" ||
        token === "--system" ||
        token.startsWith("--global=") ||
        token.startsWith("--system="),
    );
}

export function hasGitMutationRisk(tokens: string[]): boolean {
  if (tokens[0] !== "git") return false;
  const operation = tokens[1];
  if (!operation) return false;
  if (operation === "reflog")
    return !new Set(["", "show", "list"]).has(tokens[2] || "");
  if (
    operation === "fsck" &&
    tokens
      .slice(2)
      .some((token) => token === "--lost-found" || token.startsWith("--lost"))
  )
    return true;
  const readOnlyOperations = new Set([
    "annotate",
    "blame",
    "cat-file",
    "count-objects",
    "describe",
    "diff",
    "diff-tree",
    "for-each-ref",
    "fsck",
    "grep",
    "help",
    "log",
    "ls-files",
    "ls-remote",
    "ls-tree",
    "merge-base",
    "name-rev",
    "rev-list",
    "rev-parse",
    "shortlog",
    "show",
    "show-ref",
    "status",
    "verify-commit",
    "verify-tag",
    "version",
    "whatchanged",
  ]);
  if (readOnlyOperations.has(operation)) return false;
  if (operation === "branch" || operation === "tag") {
    const rest = tokens.slice(2);
    const mutationFlags = new Set([
      "-c",
      "-C",
      "-d",
      "-D",
      "-f",
      "-m",
      "-M",
      "-s",
      "-u",
      "--annotate",
      "--copy",
      "--create-reflog",
      "--delete",
      "--edit-description",
      "--force",
      "--move",
      "--set-upstream-to",
      "--sign",
      "--unset-upstream",
      "--file",
      "--message",
    ]);
    const attachedShortMutationFlags =
      operation === "branch"
        ? ["-c", "-C", "-d", "-D", "-f", "-m", "-M", "-s", "-u"]
        : ["-a", "-F", "-f", "-m", "-s", "-u"];
    if (
      rest.some(
        (token) =>
          mutationFlags.has(token) ||
          attachedShortMutationFlags.some((flag) => token.startsWith(flag)) ||
          [...mutationFlags].some((flag) => token.startsWith(`${flag}=`)) ||
          (token.startsWith("--") &&
            [
              "--annotate",
              "--copy",
              "--create-reflog",
              "--delete",
              "--edit-description",
              "--file",
              "--force",
              "--message",
              "--move",
              "--set-upstream-to",
              "--sign",
              "--unset-upstream",
            ].some((flag) => flag.startsWith(token) || token.startsWith(flag))),
      )
    )
      return true;
    const listMode = rest.some((token) => token === "-l" || token === "--list");
    const valueOptions = new Set([
      "--contains",
      "--format",
      "--merged",
      "--no-contains",
      "--no-merged",
      "--points-at",
      "--sort",
    ]);
    for (let i = 0; i < rest.length; i += 1) {
      if (valueOptions.has(rest[i])) {
        i += 1;
      } else if (!rest[i].startsWith("-") && !listMode) {
        return true;
      }
    }
    return false;
  }
  if (operation === "reflog")
    return !new Set(["", "show", "list"]).has(tokens[2] || "");
  if (operation === "stash")
    return !new Set(["list", "show"]).has(tokens[2] ?? "");
  if (operation === "submodule")
    return tokens[2] !== "status" || tokens.length !== 3;
  if (operation === "worktree")
    return tokens[2] !== "list" || tokens.length !== 3;
  if (operation === "remote")
    return !new Set(["-v", "get-url", "show"]).has(tokens[2] || "show");
  return true;
}

export function isRtkWrapped(rawTokens: string[]): boolean {
  return unwrapTokens(rawTokens).wrappers.has("rtk");
}

export function hasOpaqueWrapper(rawTokens: string[]): boolean {
  return unwrapTokens(rawTokens).opaque;
}

export function isStandaloneEnvCommand(rawTokens: string[]): boolean {
  const unwrapped = unwrapTokens(rawTokens);
  return (
    unwrapped.wrappers.has("env") &&
    !unwrapped.wrappers.has("rtk") &&
    unwrapped.tokens.length === 0
  );
}

export function isRtkSupportedCommand(
  rawTokens: string[],
  tokens: string[],
): boolean {
  return isRtkWrapped(rawTokens) && RTK_REQUIRED_COMMANDS.has(tokens[0]);
}

export function isDirectRtkRequiredCommand(
  rawTokens: string[],
  tokens: string[],
): boolean {
  return !isRtkWrapped(rawTokens) && RTK_REQUIRED_COMMANDS.has(tokens[0]);
}

export const MODERN_SHELL_REPLACEMENTS: Record<string, readonly string[]> = {
  grep: ["rg"],
  find: ["fd", "fdfind"],
  cat: ["bat", "batcat"],
  ls: ["eza", "exa"],
  sed: ["sd"],
  awk: ["sd"],
};

export function modernShellToolAvailability(): Set<string> {
  const paths = (process.env.PATH || "").split(delimiter).filter(Boolean);
  const extensions =
    process.platform === "win32"
      ? (process.env.PATHEXT || ".EXE;.CMD;.BAT").split(";")
      : [""];
  const available = new Set<string>();
  for (const candidates of Object.values(MODERN_SHELL_REPLACEMENTS)) {
    for (const candidate of candidates) {
      if (
        paths.some((entry) =>
          extensions.some((extension) =>
            existsSync(resolve(entry, `${candidate}${extension}`)),
          ),
        )
      ) {
        available.add(candidate);
      }
    }
  }
  if (
    paths.some((entry) =>
      extensions.some((extension) =>
        existsSync(resolve(entry, `jq${extension}`)),
      ),
    )
  ) {
    available.add("jq");
  }
  return available;
}

export function availableModernReplacement(
  tokens: string[],
  available: ReadonlySet<string>,
): string | undefined {
  const command = tokens[0];
  const candidates =
    command === "python" || command === "python3"
      ? tokens[1] === "-m" && tokens[2] === "json.tool"
        ? ["jq"]
        : []
      : MODERN_SHELL_REPLACEMENTS[command] || [];
  return candidates.find((candidate) => available.has(candidate));
}

export function isLiteralGitContentPath(pathspec: string): boolean {
  if (
    !pathspec ||
    isAbsolute(pathspec) ||
    pathspec.startsWith(":") ||
    /[*?[\]{}]/.test(pathspec)
  )
    return false;
  try {
    return statSync(resolve(process.cwd(), pathspec)).isFile();
  } catch {
    return false;
  }
}

function isSafeGitObjectPath(object: string): boolean {
  const colon = object.lastIndexOf(":");
  if (colon < 1) return false;
  const path = object.slice(colon + 1);
  return (
    Boolean(path) &&
    !path.startsWith("/") &&
    !path.startsWith("(") &&
    !/[*?[\]{}]/.test(path) &&
    !isProtectedPath(path)
  );
}

export function isUnscopedGitContentRead(tokens: string[]): boolean {
  const operation = tokens[1];
  if (tokens[0] !== "git" || !["diff", "show", "diff-tree"].includes(operation))
    return false;
  const pathSeparator = tokens.indexOf("--");
  const options = tokens.slice(
    2,
    pathSeparator < 0 ? undefined : pathSeparator,
  );
  const patchOutput = new Set([
    "-p",
    "-u",
    "--patch",
    "--patch-with-stat",
    "--patch-with-raw",
    "--binary",
  ]);
  if (
    options.some(
      (token) =>
        patchOutput.has(token) ||
        token.startsWith("--word-diff") ||
        token.startsWith("--color-words"),
    )
  ) {
    return true;
  }
  const metadataOnly = new Set([
    "--check",
    "--exit-code",
    "--name-only",
    "--name-status",
    "--no-patch",
    "--numstat",
    "--quiet",
    "--raw",
    "--shortstat",
    "--stat",
    "--summary",
    "-s",
  ]);
  if (options.some((token) => metadataOnly.has(token))) return false;
  if (pathSeparator < 0) return operation !== "diff-tree";
  return tokens
    .slice(pathSeparator + 1)
    .some((pathspec) => !isLiteralGitContentPath(pathspec));
}

export function isVersionCheck(tokens: string[]): boolean {
  return tokens.length === 2 && ["--version", "-V"].includes(tokens[1]);
}

export function hasShellExecutionProxy(tokens: string[]): boolean {
  return (
    tokens[0] === "xargs" ||
    (tokens[0] === "find" &&
      tokens.some((token) =>
        ["-exec", "-execdir", "-ok", "-okdir"].includes(token),
      ))
  );
}

export function hasEnvironmentBootstrapModifier(rawTokens: string[]): boolean {
  return rawTokens.some(
    (token) =>
      /^[A-Za-z_][A-Za-z0-9_]*\+?=/.test(token) || baseName(token) === "env",
  );
}

export function segmentDecision(
  segment: string,
  modernTools: ReadonlySet<string> = EMPTY_MODERN_SHELL_TOOLS,
  options: { allowUnquotedGlob?: boolean } = {},
): { decision: Decision; reason: string } {
  // Retain the optional argument for callers and test exports; classification does not use availability.
  void modernTools;
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
  const jqProgramIndex = jqOperands(tokens).programIndex;
  if (
    tokens.some(
      (token, index) =>
        !isNegatedGlob(token) &&
        index !== jqProgramIndex &&
        !(options.allowUnquotedGlob && /[*?[\]{}]/.test(token)) &&
        (isProtectedPath(token) || isProtectedLocalPath(token)),
    )
  ) {
    return {
      decision: "ask",
      reason: "Requires approval: shell command references a protected path",
    };
  }

  if (hasWorkingDirectoryChangeRisk(rawTokens, tokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: shell command changes the working directory",
    };
  }

  if (hasLocalFilesystemRisk(tokens, options)) {
    return {
      decision: "ask",
      reason:
        "Requires approval: shell command reads or mutates outside the project or removes local files",
    };
  }

  if (hasGitSharedScopeConfigRisk(tokens)) {
    return {
      decision: "ask",
      reason:
        "Requires approval: Git configuration may mutate shared user/system scope",
    };
  }

  if (
    isUnscopedGitContentRead(tokens) &&
    !(
      options.allowUnquotedGlob &&
      (tokens[1] === "diff-tree" ||
        tokens.some((token) => /[*?[\]{}]/.test(token)) ||
        tokens.includes("--") ||
        (tokens[1] === "show" && tokens.slice(2).some(isSafeGitObjectPath)))
    )
  ) {
    return {
      decision: "ask",
      reason:
        "Requires approval: Git content read must name existing non-protected file paths after --",
    };
  }

  // Inline aliases can execute arbitrary shell payloads. Parse neither their
  // definitions nor bodies; fail closed when the configured alias is invoked.
  const rawUnwrappedTokens = stripWrappers(rawTokens);
  const unwrappedTokens = [...rawUnwrappedTokens];
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

  if (hasDependencyPathRisk(tokens)) {
    return {
      decision: "ask",
      reason:
        "Requires approval: dependency operation targets an outside-project path",
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

  if (
    matchesPrefix(tokens, ["git", "reset", "--hard"]) ||
    (matchesPrefix(tokens, ["git", "reset"]) && tokens.includes("--hard"))
  ) {
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
      reason:
        "Requires approval: Git operation can discard worktree or stash changes",
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

  if (unwrapTokens(rawTokens).wrappers.has("sudo")) {
    return {
      decision: "ask",
      reason: "Requires approval: sudo elevates command privileges",
    };
  }

  // Interpreter wrappers and executable paths outside trusted system roots hide code from static matching.
  if (isInterpreterOpaque(tokens) || isOpaqueExecutablePath(rawTokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: opaque script or executable invocation",
    };
  }

  if (isRmRecursive(tokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: recursive rm",
    };
  }

  for (const pattern of DANGEROUS_ASK_COMMANDS) {
    if (
      matchesPrefix(tokens, pattern) ||
      (pattern[0] === "mkfs" && tokens[0].startsWith("mkfs."))
    ) {
      return {
        decision: "ask",
        reason: `Requires approval: ${pattern.join(" ")}`,
      };
    }
  }

  if (isVersionCheck(tokens)) {
    return { decision: "allow", reason: "" };
  }

  if (hasExternalOrSharedMutationRisk(tokens)) {
    return {
      decision: "ask",
      reason:
        "Requires approval: external or shared-environment operation may mutate state",
    };
  }

  for (const pattern of ASK_COMMANDS) {
    if (matchesPrefix(tokens, pattern)) {
      return {
        decision: "ask",
        reason: `Requires approval: ${pattern.join(" ")}`,
      };
    }
  }

  return { decision: "allow", reason: "" };
}

export function commandDecision(
  command: string,
  modernTools: ReadonlySet<string> = EMPTY_MODERN_SHELL_TOOLS,
  options: { allowUnquotedGlob?: boolean } = {},
): { decision: Decision; reason: string } {
  const trimmed = command.trim();
  if (!trimmed) {
    return { decision: "allow", reason: "" };
  }

  const ambiguous = options.allowUnquotedGlob
    ? hasUnbalancedQuotes(trimmed) ||
      hasUnsafeShellSyntax(trimmed) ||
      hasShellControlSyntax(trimmed)
    : hasUnbalancedQuotes(trimmed) ||
      hasAmbiguousShellSyntax(trimmed) ||
      hasShellControlSyntax(trimmed);
  if (ambiguous) {
    return {
      decision: "ask",
      reason:
        "Requires approval: ambiguous shell syntax (quotes/expansion/control structure/eval/source)",
    };
  }

  const segments = splitShellSegments(trimmed);
  const environmentModified = segments.some((segment) =>
    hasEnvironmentBootstrapModifier(tokenize(segment)),
  );
  const hasCodegraphInit = segments.some((segment) => {
    const tokens = normalizeTokens(tokenize(segment));
    return tokens[0] === "codegraph" && tokens[1] === "init";
  });
  if (environmentModified && hasCodegraphInit) {
    return {
      decision: "ask",
      reason:
        "Requires approval: CodeGraph initialization with environment modification",
    };
  }
  let worst: { decision: Decision; reason: string } = {
    decision: "allow",
    reason: "",
  };
  const rank = { allow: 0, ask: 1, deny: 2 };

  for (const segment of segments) {
    const result = segmentDecision(segment, modernTools, options);
    if (rank[result.decision] > rank[worst.decision]) {
      worst = result;
    }
  }
  return worst;
}

export function nativePathDecision(
  toolName: string,
  pathValue: string,
  cwd: string = process.cwd(),
): { decision: Decision; reason: string } {
  if (!pathValue) return { decision: "allow", reason: "" };
  let effectivePath: string;
  try {
    effectivePath = resolveNativeToolPath(pathValue, cwd, toolName === "read");
  } catch {
    return {
      decision: "ask",
      reason: `Requires approval: malformed native path: ${pathValue}`,
    };
  }
  if (isProtectedLocalPath(effectivePath)) {
    if (toolName === "read") {
      return {
        decision: "ask",
        reason: `Requires approval: read of protected path: ${pathValue}`,
      };
    }
    return {
      decision: "deny",
      reason: `Blocked ${toolName} of protected path: ${pathValue}`,
    };
  }
  if (toolName === "read" && isInstalledBAgenticSkillPath(effectivePath)) {
    return { decision: "allow", reason: "" };
  }
  if (isNativeProjectConfinedPath(effectivePath, cwd)) {
    return { decision: "allow", reason: "" };
  }
  return {
    decision: "ask",
    reason: `Requires approval: ${toolName} outside the project: ${pathValue}`,
  };
}

/**
 * Protect literal secret paths and paths that resolve through a symlink.
 * For a not-yet-created write target, resolve its nearest existing ancestor so
 * a symlinked directory cannot redirect the write into a protected location.
 */
export function isProtectedLocalPath(pathValue: string): boolean {
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

/** An exclusion glob does not access the paths it names. */
export function isNegatedGlob(token: string): boolean {
  return token.startsWith("!") && /[*?[\]{}]/.test(token.slice(1));
}

export function isProtectedPath(pathValue: string): boolean {
  const normalized = pathValue.replace(/\\/g, "/");
  const segments = normalized.split("/");
  const base = segments[segments.length - 1] || normalized;
  for (const marker of PROTECTED_PATH_MARKERS) {
    if (marker.startsWith(".") && !marker.includes("/")) {
      // Public environment templates contain placeholders, not credentials.
      // Skip only the dotenv marker so protected parent directories still match.
      if (marker === ".env" && base === ".env.example") continue;
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
    if (marker.endsWith("/")) {
      if (base === marker.slice(0, -1) || normalized.includes(marker)) {
        return true;
      }
      continue;
    }
    // Match secret-like names at a path-component boundary. A substring
    // match would incorrectly classify code such as provider-secrets.service.ts.
    if (marker === "credentials." || marker === "secrets.") {
      // Preserve literal secret files such as credentials.ts, but allow
      // compound source filenames such as credentials.service.ts.
      if (
        segments.some(
          (segment) =>
            segment.startsWith(marker) &&
            !COMPOUND_SOURCE_CODE_FILENAME.test(segment),
        )
      ) {
        return true;
      }
      continue;
    }
    if (marker.startsWith("id_")) {
      if (
        segments.some(
          (segment) =>
            segment === marker ||
            segment.startsWith(`${marker}.`) ||
            segment.startsWith(`${marker}_`) ||
            segment.startsWith(`${marker}-`),
        )
      ) {
        return true;
      }
      continue;
    }
  }
  return false;
}
