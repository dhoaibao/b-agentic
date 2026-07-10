/**
 * b-agentic first-party permission extension for Pi.
 *
 * Enforces safety-tools.md gates via Pi's tool_call event:
 * - ask: commits, pushes, pulls, reverts, dependency writes, long-lived services, rm -rf
 * - deny: destructive git history/worktree rewrites and selected docker prune/rm families
 * - block write/edit to secret and repository-control paths
 * - ask for MCP/custom tools by default (external side effects)
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
  ["npm", "install"],
  ["pnpm", "install"],
  ["yarn", "install"],
  ["bun", "install"],
  ["cargo", "install"],
  ["cargo", "add"],
  ["go", "install"],
  ["go", "get"],
  ["pip", "install"],
  ["pip3", "install"],
  ["poetry", "add"],
  ["uv", "add"],
  ["uv", "pip", "install"],
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
 * Read-only discovery tools (grep/find/ls) are allow-listed so ordinary
 * local evidence gathering does not prompt. Everything else is ask.
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

const WRAPPER_COMMANDS = new Set(["rtk", "sudo", "command", "nohup", "nice", "time", "env"]);

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

/** Split on shell operators outside quotes. Unbalanced quotes => single segment (caller may fail closed). */
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
  // Subshells, expansions, and eval make static matching unreliable — fail closed with ask.
  // Source-dot only at segment start (not path tokens like "cd .").
  return /\$\(|`|\beval\b|\bsource\b|(?:^|[;&|]\s*)\.\s+\S/.test(command);
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

function stripWrappers(tokens: string[]): string[] {
  let i = 0;
  while (i < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i])) {
    i += 1;
  }
  while (i < tokens.length && WRAPPER_COMMANDS.has(tokens[i])) {
    const wrapper = tokens[i];
    i += 1;
    if (wrapper === "env") {
      while (i < tokens.length) {
        if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i])) {
          i += 1;
          continue;
        }
        if (tokens[i] === "-u" || tokens[i] === "-C" || tokens[i] === "-S") {
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
    // rtk / nohup / time: consume only the wrapper token
  }
  return tokens.slice(i);
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
    // Options that take a value: -C <path>, -c <name=value>
    if (t === "-C" || t === "-c") {
      i += tokens[i + 1] ? 2 : 1;
      continue;
    }
    // Combined forms like -cfoo.bar=baz
    if (t.startsWith("-c") && t.length > 2) {
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
  if (stripped[0] === "git") {
    return gitEffectiveTokens(stripped);
  }
  return stripped;
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

function segmentDecision(segment: string): { decision: Decision; reason: string } {
  const tokens = normalizeTokens(tokenize(segment));
  if (tokens.length === 0) {
    return { decision: "allow", reason: "" };
  }

  // Interpreter wrappers hide the real command body from static matching.
  if (isInterpreterOpaque(tokens)) {
    return {
      decision: "ask",
      reason: "Requires approval: interpreter/eval-style command (opaque -c/-e body)",
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

  return { decision: "allow", reason: "" };
}

function commandDecision(command: string): { decision: Decision; reason: string } {
  const trimmed = command.trim();
  if (!trimmed) {
    return { decision: "allow", reason: "" };
  }

  if (hasAmbiguousShellSyntax(trimmed)) {
    return {
      decision: "ask",
      reason: "Requires approval: ambiguous shell syntax (subshell/eval/source)",
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

function isProtectedPath(pathValue: string): boolean {
  const normalized = pathValue.replace(/\\/g, "/");
  const base = normalized.split("/").pop() || normalized;
  for (const marker of PROTECTED_PATH_MARKERS) {
    if (marker.startsWith(".") && !marker.includes("/")) {
      if (base === marker || base.endsWith(marker) || normalized.includes(`/${marker}`)) {
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

function isMcpOrCustomTool(toolName: string): boolean {
  if (SPECIALIZED_TOOLS.has(toolName)) {
    return false;
  }
  // Adapter proxy, direct MCP tools, or any non-built-in extension tool.
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
      if (pathValue && isProtectedPath(pathValue)) {
        return {
          block: true,
          reason: `Blocked ${event.toolName} of protected path: ${pathValue}`,
        };
      }
      return undefined;
    }

    // Read-only discovery built-ins: allow without prompt.
    if (event.toolName === "grep" || event.toolName === "find" || event.toolName === "ls") {
      return undefined;
    }

    // MCP adapter proxy, direct MCP tools, and any other custom tool: ask by default.
    if (isMcpOrCustomTool(event.toolName)) {
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
  hasAmbiguousShellSyntax,
  isInterpreterOpaque,
  SPECIALIZED_TOOLS,
  ASK_COMMANDS,
  DENY_COMMANDS,
};
