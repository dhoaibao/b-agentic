#!/usr/bin/env bun
// b-agentic Codex review guard. The independent review gate sends a repository
// to OpenAI Codex through the openai/codex-plugin-cc plugin, and Codex's
// read-only sandbox can read every file in the workspace. Sending code to Codex
// needs no per-repository approval (ADR-021); this guard refuses that
// transmission unless
//   1. no likely-secret path is tracked, staged, or untracked-and-not-ignored,
//      no submodule or embedded repository hides paths from a name scan, no
//      untracked symlink would be followed by the plugin, and for a --base
//      review no likely-secret path appears in merge-base..HEAD or in any
//      commit inside it (ignored protected files and history outside the
//      reviewed range are the accepted residual risk);
//   2. a review command runs in the foreground against an explicit target.
//
// Modes:
//   (no args)          PreToolUse hook: stdin JSON, exit 2 with a stderr reason
//                      blocks a Bash call that runs the plugin's companion script.
//   --check [--base <ref>]
//                      Evaluate the current repository (and the review range of
//                      <ref>); JSON on stdout, exit 0 when allowed and 3 when
//                      refused.
// It reads path names only, never file content.
import { execFileSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";

// The snapshot CLI is loaded only when a guarded command needs a scan, so the
// common case (a Bash call that is not a Codex review) skips its parse cost.
const snapshot = () => import("../bin/b-candidate-snapshot.mjs");

// Plugin subcommands that never send repository content to Codex; every other
// subcommand (review, adversarial-review, task, rescue, transfer, ...) is guarded.
const NON_DISCLOSING = new Set(["status", "result", "cancel", "setup", "help"]);
const REVIEW_SUBCOMMANDS = new Set(["review", "adversarial-review"]);

export function repositoryRoot(cwd) {
  const out = execFileSync("git", ["-C", cwd, "rev-parse", "--show-toplevel"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
    env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" },
  });
  return realpathSync(out.replace(/\n$/, ""));
}

// Quote-aware, fail-closed split of a shell command into segments. Anything it
// cannot interpret with certainty (expansions, subshells, unbalanced quotes,
// input redirection, a redirect without a target) is reported as ambiguous
// rather than guessed. Comments are dropped as the shell drops them.
export function tokenize(command) {
  // The plugin's own root variable is the one expansion a real invocation uses.
  const text = command.replaceAll("${CLAUDE_PLUGIN_ROOT}", "/plugin-root");
  const segments = [{ tokens: [], redirects: [] }];
  const backgrounded = new Set();
  let token = null;
  let pending = null; // a redirect operator waiting for its target word
  let ambiguous = null;
  const last = () => segments[segments.length - 1];
  const flush = () => {
    if (token === null) return;
    if (pending !== null) {
      last().redirects.push({ op: pending, target: token });
      pending = null;
    } else {
      last().tokens.push(token);
    }
    token = null;
  };
  const boundary = (background) => {
    flush();
    if (pending !== null) {
      ambiguous ??= "a redirection without a target";
      pending = null;
    }
    if (background) backgrounded.add(segments.length - 1);
    segments.push({ tokens: [], redirects: [] });
  };
  const redirect = (op) => {
    if (pending !== null) ambiguous ??= "chained redirections";
    if (token !== null && /^\d+$/.test(token))
      token = null; // fd prefix
    else flush();
    pending = op;
  };
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === "'") {
      const end = text.indexOf("'", i + 1);
      if (end === -1) {
        ambiguous = "unterminated quote";
        break;
      }
      token = (token ?? "") + text.slice(i + 1, end);
      i = end;
    } else if (ch === '"') {
      let buffer = "";
      let j = i + 1;
      for (; j < text.length && text[j] !== '"'; j++) {
        if (text[j] === "\\" && j + 1 < text.length) {
          j++;
        } else if (text[j] === "$" || text[j] === "`") {
          ambiguous ??= "shell expansion";
        }
        buffer += text[j];
      }
      if (j >= text.length) {
        ambiguous = "unterminated quote";
        break;
      }
      token = (token ?? "") + buffer;
      i = j;
    } else if (ch === "\\") {
      if (text[i + 1] === "\n") i++;
      else if (i + 1 < text.length) token = (token ?? "") + text[++i];
    } else if (ch === "#" && token === null) {
      const newline = text.indexOf("\n", i);
      i = newline === -1 ? text.length : newline - 1;
    } else if (ch === "$" || ch === "`" || ch === "(" || ch === ")") {
      ambiguous ??= "shell expansion or subshell";
      token = (token ?? "") + ch;
    } else if (ch === "<") {
      ambiguous ??= "input redirection or heredoc";
    } else if (ch === ">") {
      let op = ">";
      if (text[i + 1] === ">") {
        op = ">>";
        i++;
      }
      if (text[i + 1] === "&") {
        // `2>&1`, `>&2`, `>&-` duplicate or close a descriptor; `>&word` is a
        // file redirect. The operand is read as the next word either way.
        i++;
        op += "&";
      }
      redirect(op);
    } else if (ch === "&") {
      if (text[i + 1] === ">") {
        i += text[i + 2] === ">" ? 2 : 1;
        redirect("&>");
      } else if (text[i + 1] === "&") {
        i++;
        boundary(false);
      } else {
        boundary(true);
      }
    } else if (ch === " " || ch === "\t") {
      flush();
    } else if (ch === ";" || ch === "\n" || ch === "|") {
      boundary(false);
    } else {
      token = (token ?? "") + ch;
    }
  }
  flush();
  if (pending !== null) ambiguous ??= "a redirection without a target";
  return { segments, backgrounded, ambiguous };
}

const COMPANION_NAME = "codex-companion.mjs";
const COMPANION_WORD = /(^|\/)codex-companion\.mjs$/;
// The plugin script name with line continuations, quotes, escapes, and expansion
// characters removed, so `codex-compan""ion.mjs` and a backslash-newline split are
// still the plugin. Splitting the name across variables is shell indirection the
// guard cannot see (a documented residual risk).
const joinedText = (text) =>
  text.replace(/\\\r?\n/g, "").replace(/['"\\$`{}]/g, "");
export const mentionsCompanion = (text) =>
  joinedText(text).includes(COMPANION_NAME);
const redirectAllowed = ({ op, target }) =>
  target === "/dev/null" ||
  // `2>&1` and `>&-` duplicate or close a descriptor; `>&word` is a file.
  (op.endsWith("&") && /^(\d+|-)$/.test(target));

// Finds the plugin companion invocation in a Bash command. The guard is
// default-deny: when the script name survives shell joining anywhere in the
// call, the call must be exactly one `node <path>/codex-companion.mjs
// <subcommand> [args]` command (optionally with `/dev/null` or descriptor
// redirections and a comment). Wrappers, neighbouring commands, interpreters
// that merely carry the name, and anything uninterpretable are refused.
export function findCompanionInvocations(command) {
  const result = { invocations: [], refusal: null };
  if (typeof command !== "string" || !mentionsCompanion(command)) {
    return result;
  }
  const refuse = (why) => {
    result.refusal ??= why;
    return result;
  };
  const { segments, backgrounded, ambiguous } = tokenize(command);
  if (ambiguous) {
    return refuse(
      `the command names the Codex plugin but cannot be interpreted safely (${ambiguous}); run the plugin command on its own`,
    );
  }
  const live = segments
    .map((segment, index) => ({ ...segment, index }))
    .filter(
      (segment) => segment.tokens.length > 0 || segment.redirects.length > 0,
    );
  if (live.length !== 1) {
    return refuse(
      "the command names the Codex plugin but is not exactly one plugin command; run the plugin command on its own",
    );
  }
  const [{ tokens, redirects, index }] = live;
  if (
    tokens.length < 3 ||
    tokens[0] !== "node" ||
    !COMPANION_WORD.test(tokens[1])
  ) {
    return refuse(
      "an unsupported plugin invocation (expected exactly `node <path>/codex-companion.mjs <subcommand> ...`; no wrapper, interpreter flag, variable prefix, or missing subcommand)",
    );
  }
  if (tokens.slice(2).some((word) => mentionsCompanion(word))) {
    return refuse("the plugin script name appears more than once in the call");
  }
  if (backgrounded.has(index)) {
    return refuse("a gate review must not be backgrounded with `&`");
  }
  if (!redirects.every(redirectAllowed)) {
    return refuse(
      "a plugin invocation may only redirect to /dev/null or duplicate a descriptor",
    );
  }
  result.invocations.push({ subcommand: tokens[2], args: tokens.slice(3) });
  return result;
}

function optionValue(args, name) {
  const inline = args.find((item) => item.startsWith(`${name}=`));
  if (inline !== undefined) return inline.slice(name.length + 1);
  const index = args.indexOf(name);
  if (index === -1) return null;
  const value = args[index + 1];
  return value !== undefined && !value.startsWith("-") ? value : "";
}

// Directory options would let the plugin review a repository other than the one
// the guard scanned, so they are refused for every guarded subcommand.
const DIRECTORY_OPTION = /^(--cwd|--cd|--workdir|--directory|--repo|-C)(=|$)/;

export function invocationReasons(invocation) {
  const { subcommand, args } = invocation;
  const reasons = [];
  if (args.some((item) => DIRECTORY_OPTION.test(item))) {
    reasons.push(
      "directory options are not supported: the review target must be the repository the guard scanned",
    );
  }
  if (!REVIEW_SUBCOMMANDS.has(subcommand)) return reasons;
  // The plugin's parser keeps the LAST repeated option, accepts single-dash
  // spellings (`-base x`), and treats everything after `--` as text, so the
  // guard's first-match reading could scan a different base than the plugin
  // reviews. Gate reviews therefore refuse every spelling that could disagree.
  const occurrences = (name) =>
    args.filter((item) => item === name || item.startsWith(`${name}=`)).length;
  if (
    args.includes("--") ||
    args.some((item) => /^-[^-]/.test(item)) ||
    args.some((item) => item.startsWith("--wait=")) ||
    // The plugin splits `--name=value` with split("=", 2), so it would keep
    // only the text before a second `=`, while git allows `=` in ref names.
    args.some((item) => /^--(base|scope)=.*=/.test(item)) ||
    ["--base", "--scope", "--wait"].some((name) => occurrences(name) > 1)
  ) {
    reasons.push(
      "ambiguous review options: repeated --base/--scope/--wait, single-dash spellings, --wait=value, an inline --base/--scope value containing '=', and `--` can make the plugin review a target the guard did not scan",
    );
  }
  if (
    args.some(
      (item) => item === "--background" || item.startsWith("--background="),
    )
  ) {
    reasons.push(
      "a gate review must run in the foreground: drop --background and use --wait",
    );
  }
  // Allow-list: the plugin consumes the next token as the value of every
  // value option (--model, --m, --cwd, ...), so an unlisted option can swallow
  // --base or --scope and leave the guard scanning a target the plugin never
  // reviews. Only --wait, --scope, and --base (each with a plain value) and
  // focus text are accepted; --background and directory options have their own
  // refusals.
  const unsupported = [];
  for (let index = 0; index < args.length; index++) {
    const item = args[index];
    if (!item.startsWith("-")) continue;
    if (item === "--wait" || /^--(scope|base)=/.test(item)) continue;
    if (item === "--scope" || item === "--base") {
      if (args[index + 1] !== undefined && !args[index + 1].startsWith("-")) {
        index += 1;
        continue;
      }
    } else if (
      item === "--background" ||
      item.startsWith("--background=") ||
      DIRECTORY_OPTION.test(item)
    ) {
      continue;
    }
    unsupported.push(item);
  }
  if (unsupported.length > 0) {
    reasons.push(
      `unsupported review option ${unsupported.join(" ")}: a gate review accepts only --wait, --scope <value>, --base <value>, and focus text, because other plugin options can consume the target option`,
    );
  }
  if (!args.includes("--wait")) reasons.push("a gate review must pass --wait");
  const scope = optionValue(args, "--scope");
  const base = optionValue(args, "--base");
  if (base === "" || scope === "") {
    reasons.push("--scope and --base need a value");
  } else if (scope !== "working-tree" && !base) {
    reasons.push(
      "a gate review needs an explicit target: --scope working-tree or --base <ref>",
    );
  }
  return reasons;
}

// `base` is the explicit comparison ref a caller (the wrapper or --check) will
// review; a direct plugin call carries its own `--base`. Each is resolved and
// its range scanned, because a base review sends the whole merge-base..HEAD
// diff, including protected files that HEAD has since deleted or renamed.
export async function evaluate({ command, cwd, base }) {
  const reasons = [];
  let root = null;
  let range = null;
  const found = findCompanionInvocations(command);
  try {
    root = repositoryRoot(cwd);
  } catch {
    reasons.push(
      "not inside a git repository, so protected paths cannot be checked",
    );
  }
  if (root) {
    try {
      const scan = await (await snapshot()).checkProtected(cwd);
      if (scan.blocking.length > 0) {
        reasons.push(
          `likely-secret paths present: ${scan.blocking.join(", ")}`,
        );
      }
      if (scan.opaque.length > 0) {
        reasons.push(
          `opaque repository boundaries hide paths from the scan: ${scan.opaque.map((item) => item.path).join(", ")}`,
        );
      }
      if (scan.symlinks.length > 0) {
        reasons.push(
          `untracked symlinks would be followed by the plugin and can expose files the name scan never sees: ${scan.symlinks.map((item) => item.path).join(", ")}; stage, ignore, or remove them`,
        );
      }
    } catch (error) {
      reasons.push(
        `secret check failed: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    const bases = new Set();
    if (base) bases.add(base);
    for (const invocation of found.invocations) {
      if (!REVIEW_SUBCOMMANDS.has(invocation.subcommand)) continue;
      const value = optionValue(invocation.args, "--base");
      if (value) bases.add(value);
    }
    for (const ref of bases) {
      try {
        const scanned = await (await snapshot()).resolveReviewRange(cwd, ref);
        if (ref === base) range = scanned;
        if (scanned.blocking.length > 0) {
          reasons.push(
            `likely-secret paths in the review range ${ref}..HEAD: ${scanned.blocking.join(", ")}; review the working tree or choose a later base`,
          );
        }
        if (scanned.opaque.length > 0) {
          reasons.push(
            `submodules in the review range ${ref}..HEAD hide paths from the scan: ${scanned.opaque.map((item) => item.path).join(", ")}`,
          );
        }
      } catch (error) {
        reasons.push(
          `review range check failed: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    }
  }
  if (found.refusal) reasons.push(found.refusal);
  for (const invocation of found.invocations) {
    reasons.push(...invocationReasons(invocation));
  }
  return {
    ok: reasons.length === 0,
    root,
    range,
    reasons: [...new Set(reasons)],
  };
}

// The decision for one shell command: `allow`, or `refuse` with the reasons.
// Used by this file's Claude Code hook.
export async function judgeCommand(command, cwd) {
  const found = findCompanionInvocations(command);
  const guarded =
    found.refusal !== null ||
    found.invocations.some((item) => !NON_DISCLOSING.has(item.subcommand));
  if (!guarded) return { decision: "allow" };
  const result = await evaluate({ command, cwd });
  if (result.ok) return { decision: "allow" };
  return {
    decision: "refuse",
    reason: `/codex ${found.invocations.map((item) => item.subcommand).join(", ") || "command"}: ${result.reasons.join("; ")}`,
  };
}

async function hook() {
  const raw = readFileSync(0, "utf8");
  let event = null;
  try {
    event = JSON.parse(raw);
  } catch {
    // An unreadable envelope that names the plugin is refused; anything else
    // cannot be a review command and is allowed.
  }
  const command = event?.tool_input?.command;
  const refuse = (why) => {
    process.stderr.write(`b-agentic Codex guard refused: ${why}.\n`);
    return 2;
  };
  if (typeof command !== "string") {
    return mentionsCompanion(raw)
      ? refuse("unreadable hook input that mentions the Codex plugin")
      : 0;
  }
  if (event.tool_name !== undefined && event.tool_name !== "Bash") return 0;
  const verdict = await judgeCommand(command, event.cwd || process.cwd());
  return verdict.decision === "refuse" ? refuse(verdict.reason) : 0;
}

async function main(argv) {
  if (argv.length === 0) return hook();
  const mode = argv[0];
  if (mode === "--check") {
    const baseIndex = argv.indexOf("--base");
    const base = baseIndex === -1 ? undefined : argv[baseIndex + 1];
    if (baseIndex !== -1 && !base) throw new Error("--base needs a ref");
    const result = await evaluate({ command: null, cwd: process.cwd(), base });
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return result.ok ? 0 : 3;
  }
  throw new Error(`unknown argument: ${mode}`);
}

function isEntryPoint() {
  try {
    return (
      import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href
    );
  } catch {
    return false;
  }
}

if (isEntryPoint()) {
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code;
    },
    (error) => {
      process.stderr.write(
        `${error instanceof Error ? error.message : String(error)}\n`,
      );
      process.exitCode = 2;
    },
  );
}
