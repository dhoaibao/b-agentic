// b-agentic safety plugin for OpenCode. It reuses the Claude Code hook logic
// installed beside it (`../b-agentic/hooks`), so both runtimes apply the same
// rules: likely-secret paths are refused on file tools, and a Codex review that
// would send an unapproved or unclean repository to Codex is refused on shell.
//
// This is defense in depth. OpenCode's native `permissions` rules (the
// installed opencode.json block) are the primary control; this plugin adds the
// checks a glob cannot express. It blocks by throwing from the V2 `execute.before`
// tool hook and fails open on anything it cannot interpret, so it cannot wedge a session.
// It cannot ask the user and cannot block a session from stopping, so the
// verify gate and the approval prompt are not ported (see REFERENCE.md).

import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

const hooksUrl = (name) =>
  new URL(`../b-agentic/hooks/${name}`, import.meta.url).href;

const SHELL_TOOLS = new Set(["bash", "shell"]);
const FILE_TOOLS = new Set([
  "read",
  "edit",
  "write",
  "patch",
  "multiedit",
  "grep",
  "glob",
  "list",
]);

// V2 file tools take `path` (V1 used `filePath`); the guard reads the Claude Code keys.
export function pathInput(args) {
  const value = args && typeof args === "object" ? args : {};
  return {
    file_path: value.filePath ?? value.file_path,
    path: value.path,
    glob: value.include ?? value.glob,
    pattern: value.pattern,
  };
}

// The directory a shell call runs in: `workdir` resolved the way OpenCode does, against the
// session location (a leading `~` is the home directory), else the location itself.
export function shellCwd(workdir, base) {
  const root = base || process.cwd();
  if (typeof workdir !== "string" || workdir === "") return root;
  const expanded = /^~(?=\/|$)/.test(workdir)
    ? join(homedir(), workdir.slice(1))
    : workdir;
  return isAbsolute(expanded) ? resolve(expanded) : resolve(root, expanded);
}

// The reason a tool call is refused, or null. Never throws: an unreadable call is allowed.
export async function guardToolCall({ tool, args, cwd }) {
  const name = String(tool ?? "").toLowerCase();
  try {
    if (FILE_TOOLS.has(name)) {
      const { blockedPaths } = await import(hooksUrl("b-path-guard.mjs"));
      const blocked = blockedPaths(
        pathInput(args),
        name === "glob" ? "Glob" : name,
      );
      return blocked.length === 0
        ? null
        : `b-agentic path guard: ${name} refused on likely-secret path ${blocked.join(", ")}. Likely-secret files (.env, *.pem, credentials.*, secrets.*) need explicit user permission to read or change; ask the user first.`;
    }
    if (SHELL_TOOLS.has(name) && typeof args?.command === "string") {
      const { judgeCommand } = await import(hooksUrl("b-codex-guard.mjs"));
      const verdict = await judgeCommand(args.command, cwd || process.cwd());
      return verdict.decision === "refuse"
        ? `b-agentic Codex guard refused: ${verdict.reason.replaceAll("AskUserQuestion", "question")}.`
        : null;
    }
  } catch {
    return null;
  }
  return null;
}

// OpenCode V2 plugin: `setup(ctx)` registers one `execute.before` tool hook, and a throw from
// it fails that call alone with the thrown message (V1's `server()` hooks are ignored by V2).
async function setup(ctx) {
  await ctx.tool.hook("execute.before", async (event) => {
    const args = event?.input;
    const reason = await guardToolCall({
      tool: event?.tool,
      args,
      cwd: shellCwd(args?.workdir, ctx?.location?.directory),
    });
    if (reason) throw new Error(reason);
  });
}

export default { id: "b-agentic.opencode", setup };
