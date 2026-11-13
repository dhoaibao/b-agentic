// b-agentic guard core for Pi. Plain Node so it can be tested without Pi.
//
// It reuses the Claude Code hook modules for every decision (likely-secret
// paths, .b-agentic writes, shell-inspection classification, spec and run
// context), so both runtimes judge the same way. The file-tool guard fails
// closed: a missing hook module or any thrown error blocks the call. The
// verify reminder and the context injection are advisory and fail open, as
// they do on Claude Code.
import { pathToFileURL } from "node:url";

// Pi's file tools, named as the Claude hook modules know them. `find` takes a
// glob pattern, which the hooks check under the name Glob.
export const FILE_TOOLS = {
  read: "Read",
  edit: "Edit",
  write: "Write",
  grep: "Grep",
  find: "Glob",
  ls: "LS",
};

const HOOK_FILES = {
  pathGuard: "b-path-guard.mjs",
  verifyGate: "b-verify-gate.mjs",
  specContext: "b-spec-context.mjs",
  runContext: "b-run-context.mjs",
};

const RUN_CONTEXT_REASONS = new Set(["startup", "resume", "new"]);

const toBase = (hooksDir) => {
  const href =
    typeof hooksDir === "string" && !hooksDir.startsWith("file:")
      ? pathToFileURL(hooksDir).href
      : String(hooksDir);
  return href.endsWith("/") ? href : `${href}/`;
};

export async function loadHooks(hooksDir) {
  const base = toBase(hooksDir);
  const hooks = {};
  for (const [name, file] of Object.entries(HOOK_FILES)) {
    hooks[name] = await import(new URL(file, base).href);
  }
  return hooks;
}

const block = (reason) => ({ block: true, reason });

// `loader` is injectable so tests can simulate a missing or broken hook module.
export async function createGuard({ hooksDir, loader = loadHooks }) {
  let hooks = null;
  let loadError = "";
  try {
    hooks = await loader(hooksDir);
  } catch (error) {
    loadError = error instanceof Error ? error.message : String(error);
  }

  // Verify gate state: in memory, one instance per Pi session.
  let dirty = false;
  let reminded = false;
  // Context text waiting for the next run.
  let pending = [];
  let childGateError = "";

  const advisory = (fn) => {
    try {
      return fn();
    } catch {
      return undefined;
    }
  };

  return {
    get loadError() {
      return loadError;
    },

    // A reason a child session cannot be gated; subagent launches are then refused.
    setChildGateError(reason) {
      childGateError = reason;
    },

    toolCall({ toolName, input }, cwd) {
      try {
        if (childGateError && toolName.startsWith("subagent")) {
          return block(
            `b-agentic guard: child sessions cannot be gated (${childGateError}); ${toolName} is refused.`,
          );
        }
        const claudeName = FILE_TOOLS[toolName];
        if (claudeName === undefined) return undefined;
        if (hooks === null) {
          return block(
            `b-agentic guard unavailable (${loadError}); file tools are blocked until it is repaired. Reinstall b-agentic.`,
          );
        }
        const owned = hooks.pathGuard.agenticWrites(input, claudeName, cwd);
        if (owned.length > 0) {
          return block(
            `b-agentic path guard: ${toolName} refused on ${owned.join(", ")}. Run artifacts under .b-agentic are written only by b_run.py (python3 -I -B ~/.pi/agent/b-agentic/bin/b_run.py write <kind>) and b-state.mjs; read them with read.`,
          );
        }
        const secret = hooks.pathGuard.blockedPaths(input, claudeName);
        if (secret.length > 0) {
          return block(
            `b-agentic path guard: ${toolName} refused on likely-secret path ${secret.join(", ")}. Likely-secret files (.env, *.pem, credentials.*, secrets.*) need explicit user permission to read or change; ask the user first.`,
          );
        }
        return undefined;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return block(
          `b-agentic guard error (${message}); ${toolName} is blocked.`,
        );
      }
    },

    // A successful edit of a non-prose file arms the gate; a main-session shell
    // command that is not plain inspection counts as a check and disarms it.
    toolResult({ toolName, input, isError }) {
      advisory(() => {
        if (hooks === null) return;
        if (toolName === "bash") {
          if (!hooks.verifyGate.isInspection(input?.command)) dirty = false;
        } else if (
          (toolName === "edit" || toolName === "write") &&
          !isError &&
          typeof input?.path === "string" &&
          !hooks.verifyGate.PROSE_PATH.test(input.path)
        ) {
          dirty = true;
        }
      });
    },

    // One extra turn carrying the reminder, once per run.
    beforeSettle(event) {
      return advisory(() => {
        if (hooks === null || event.outcome !== "completed") return undefined;
        if (!dirty || reminded) return undefined;
        reminded = true;
        dirty = false;
        return {
          entries: [
            ...event.entries,
            {
              type: "custom_message",
              customType: "b-agentic-verify-gate",
              content: hooks.verifyGate.REMINDER,
              display: false,
            },
          ],
          continue: true,
        };
      });
    },

    settled() {
      dirty = false;
      reminded = false;
    },

    // The Claude SessionStart hooks, mapped to Pi's session events: run context on
    // startup, resume, and new session; spec and run context after compaction.
    sessionStart(reason, cwd) {
      advisory(() => {
        if (hooks === null || !RUN_CONTEXT_REASONS.has(reason)) return;
        const text = hooks.runContext.buildContext(
          hooks.runContext.activeRun(cwd),
        );
        if (text) pending.push(text);
      });
    },

    compacted(cwd) {
      advisory(() => {
        if (hooks === null) return;
        const spec = hooks.specContext.buildContext(
          hooks.specContext.approvedSpecs(cwd),
        );
        const run = hooks.runContext.buildContext(
          hooks.runContext.activeRun(cwd),
        );
        for (const text of [spec, run]) if (text) pending.push(text);
      });
    },

    // The message for the next run, or undefined when nothing is waiting.
    takeContext() {
      if (pending.length === 0) return undefined;
      const content = pending.join("\n");
      pending = [];
      return { customType: "b-agentic-context", content, display: false };
    },
  };
}
