// b-agentic safety plugin for OpenCode. It reuses the Claude Code hook logic
// installed beside it (`../b-agentic/hooks`), so both runtimes apply the same
// rules: likely-secret paths are refused on file tools, and a Codex review that
// would send an unapproved or unclean repository to Codex is refused on shell.
//
// This is defense in depth. OpenCode's native `permissions` rules (the
// installed opencode.json block) are the primary control; this plugin adds the
// checks a glob cannot express. It blocks by throwing from `tool.execute.before`
// and fails open on anything it cannot interpret, so it cannot wedge a session.
// It cannot ask the user and cannot block a session from stopping, so the
// verify gate and the approval prompt are not ported (see REFERENCE.md).

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

// OpenCode names a file argument `filePath`; the guard reads the Claude Code keys.
export function pathInput(args) {
  const value = args && typeof args === "object" ? args : {};
  return {
    file_path: value.filePath ?? value.file_path,
    path: value.path,
    glob: value.include ?? value.glob,
    pattern: value.pattern,
  };
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

async function BAgenticPlugin(ctx) {
  return {
    "tool.execute.before": async (input, output) => {
      const reason = await guardToolCall({
        tool: input?.tool,
        args: output?.args,
        cwd: ctx?.directory,
      });
      if (reason) throw new Error(reason);
    },
  };
}

export default { id: "b-agentic.opencode", server: BAgenticPlugin, setup() {} };
