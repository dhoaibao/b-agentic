// b-agentic safety plugin for OpenCode. It reuses the Claude Code hook logic
// installed beside it (`../b-agentic/hooks`), so both runtimes apply the same
// rule: likely-secret paths are refused on file tools.
//
// This is defense in depth. OpenCode's native `permissions` rules (the
// installed opencode.json block) are the primary control; this plugin adds the
// checks a glob cannot express. It blocks by throwing from the V2 `execute.before`
// tool hook and fails open on anything it cannot interpret, so it cannot wedge a session.
// It cannot ask the user and cannot block a session from stopping, so the
// verify gate is not ported (see docs/decisions/ADR-002-dual-runtime-support.md).

const hooksUrl = (name) =>
  new URL(`../b-agentic/hooks/${name}`, import.meta.url).href;

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

// Every file a `patch` call touches. Its `patchText` names targets in `*** Add File:`,
// `*** Update File:`, `*** Delete File:`, and `*** Move to:` headers rather than in a path key.
export function patchPaths(patchText) {
  if (typeof patchText !== "string") return [];
  // Split on LF only, as OpenCode does, and keep each header's whole remainder: a CR, U+2028, or
  // U+2029 inside a path is part of the target it resolves. Match more loosely than its parser
  // (indentation, Unicode whitespace, case): over-blocking a malformed header is safe, while a
  // header the parser accepts and this misses is a bypass. Each fragment around an embedded
  // separator is returned too, so a name hidden behind one is still checked.
  const header =
    /^\s*\*\*\*\s*(?:Add File|Update File|Delete File|Move to)\s*:\s*([\s\S]*?)\s*$/i;
  return patchText.split("\n").flatMap((line) => {
    const target = header.exec(line)?.[1];
    return target ? [target, ...target.split(/[\r\u2028\u2029]/)] : [];
  });
}

// The reason a tool call is refused, or null. Never throws: an unreadable call is allowed.
export async function guardToolCall({ tool, args }) {
  const name = String(tool ?? "").toLowerCase();
  try {
    if (FILE_TOOLS.has(name)) {
      const { blockedPaths } = await import(hooksUrl("b-path-guard.mjs"));
      const blocked = [
        ...blockedPaths(pathInput(args), name === "glob" ? "Glob" : name),
        ...(name === "patch" ? patchPaths(args?.patchText) : []).flatMap(
          (path) => blockedPaths({ path }, name),
        ),
      ];
      return blocked.length === 0
        ? null
        : `b-agentic path guard: ${name} refused on likely-secret path ${blocked.join(", ")}. Likely-secret files (.env, *.pem, credentials.*, secrets.*) need explicit user permission to read or change; ask the user first.`;
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
    const reason = await guardToolCall({
      tool: event?.tool,
      args: event?.input,
    });
    if (reason) throw new Error(reason);
  });
}

export default { id: "b-agentic.opencode", setup };
