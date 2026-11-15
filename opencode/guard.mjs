// b-agentic guard core for OpenCode. Plain ESM so it can be tested without OpenCode.
//
// It reuses the Claude Code hook modules for every decision (likely-secret
// paths, .b-agentic writes, shell-inspection classification, spec and run
// context), so both runtimes judge the same way. The file-tool guard fails
// closed: a missing hook module or any thrown error blocks the call. The verify
// reminder and the context injection are advisory and fail open, as they do on
// Claude Code. The plugin (`plugins/b-agentic.js`) turns a block into a throw.
import { execFileSync } from "node:child_process";
import { statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, resolve } from "node:path";
import { pathToFileURL } from "node:url";

// OpenCode's file tools (ADR-019 probe S2: read, edit, write take `path`; grep
// takes `pattern`, `path`, `include`; glob takes `pattern`, `path`; patch takes
// `patchText`), named as the Claude hook modules know them.
export const FILE_TOOLS = {
  read: "Read",
  edit: "Edit",
  write: "Write",
  grep: "Grep",
  glob: "Glob",
  patch: "Edit",
};

const HOOK_FILES = {
  pathGuard: "b-path-guard.mjs",
  verifyGate: "b-verify-gate.mjs",
  specContext: "b-spec-context.mjs",
  runContext: "b-run-context.mjs",
  codexGuard: "b-codex-guard.mjs",
};

// The Codex approval store: only the user records a disclosure approval, so no file tool may write it,
// whatever directory it lives in or which symlink names it.
const APPROVAL_STORE = "codex-approved-repos.json";

// OpenCode authorizes `grep` on its pattern and then runs ripgrep in the search directory, so a name check on
// the path and glob strings never sees the files a search reads. The guard lists the files with the same ripgrep
// traversal OpenCode uses for a search (`--hidden`, the `include` glob, `.git` excluded) and refuses the search
// when a likely-secret name is among them. It cannot list them (no ripgrep, a failure), so it refuses too.
export function protectedSearchTargets(hooks, searchPath, include, cwd) {
  const directory = resolve(cwd, searchPath ?? ".");
  let status;
  try {
    status = statSync(directory);
  } catch {
    return [];
  }
  if (!status.isDirectory()) return [];
  const args = [
    "--no-config",
    "--files",
    "--hidden",
    ...(typeof include === "string" && include !== ""
      ? [`--glob=${include}`]
      : []),
    "--glob=!**/.git/**",
    ".",
  ];
  let listed = "";
  try {
    listed = execFileSync("rg", args, {
      cwd: directory,
      encoding: "utf8",
      timeout: 20000,
      maxBuffer: 1 << 28,
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch (error) {
    // Exit code 1 is ripgrep's "nothing listed"; anything else means the listing is unknown.
    if (error?.status !== 1) {
      throw new Error(
        `ripgrep could not list ${directory} (${error?.code ?? error?.status ?? "failed"})`,
      );
    }
  }
  const found = [];
  for (const file of listed.split("\n")) {
    if (file === "") continue;
    if (hooks.pathGuard.blockedPaths({ path: file }, "Read").length > 0) {
      found.push(file);
      if (found.length >= 3) break;
    }
  }
  return found;
}

// Sessions of these agents are children: a child never receives the reminder.
const CHILD_AGENT = /^(b-|general$|explore$)/;

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

// Paths a `patch` tool call names, from its `*** Add|Update|Delete File:` and `*** Move to:` lines.
export function patchPaths(patchText) {
  if (typeof patchText !== "string") return [];
  const paths = [];
  for (const line of patchText.split("\n")) {
    // OpenCode trims every line before it reads a header, so an indented one is a real target.
    const match =
      /^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+?)$/.exec(
        line.trim(),
      );
    if (match) paths.push(match[1]);
  }
  return paths;
}

// The (Claude tool name, input) pairs a tool call stands for, or undefined for a tool the guard ignores.
// The paths a file-tool path may mean. OpenCode normalizes a path lexically (`path.resolve`, so `..` applies
// before any symlink is followed), expands a leading `~`, and keeps `$HOME` and `${HOME}` literal. The guard
// checks the path as written, its lexical resolution, and the home-expanded form of all three spellings, so the
// directory OpenCode really uses is always among the ones judged.
export function pathVariants(path, cwd) {
  if (typeof path !== "string" || path === "") return [path];
  const home = process.env.HOME || homedir();
  const candidates = [path];
  const expanded = /^(?:~|\$HOME|\$\{HOME\})(?=\/|$)/.exec(path);
  if (expanded) candidates.push(home + path.slice(expanded[0].length));
  const variants = new Set();
  for (const candidate of candidates) {
    variants.add(candidate);
    variants.add(resolve(cwd, candidate));
  }
  return [...variants];
}

function checks(tool, input) {
  const claude = FILE_TOOLS[tool];
  if (claude === undefined) return undefined;
  const path = input?.path ?? input?.filePath;
  switch (tool) {
    case "patch": {
      const paths = patchPaths(input?.patchText);
      // A patch always names at least one file; one whose targets cannot be read cannot be judged.
      return paths.length === 0
        ? [[claude, { path: undefined, unreadable: true }]]
        : paths.map((p) => [claude, { path: p }]);
    }
    case "grep":
      return [[claude, { path, glob: input?.include }]];
    case "glob":
      return [[claude, { path, pattern: input?.pattern }]];
    default:
      return [[claude, { path }]];
  }
}

// `loader` is injectable so tests can simulate a missing or broken hook module.
export async function createGuard({ hooksDir, loader = loadHooks }) {
  let hooks = null;
  let loadError = "";
  try {
    hooks = await loader(hooksDir);
  } catch (error) {
    loadError = error instanceof Error ? error.message : String(error);
  }

  // Per-session state, in memory for the life of the plugin instance.
  const dirty = new Set();
  const reminded = new Set();
  const ownTurn = new Set();
  const seen = new Set();
  const pending = new Map();

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

    // Returns {block, reason} for a refused call, undefined to let it run.
    // The Codex shell guard: refusals stay refusals, and a request to change the approval store is
    // refused too, because only the user records a disclosure approval (the native ask Claude Code
    // shows is not available to a plugin hook, so the user runs it themselves).
    async shellVerdict(input, cwd) {
      const command = input?.command;
      if (typeof command !== "string") return undefined;
      // The shell tool runs in `workdir` when it is given, so that directory, not the session's, decides
      // which repository a Codex command targets. A workdir that is not a path cannot be judged, and no
      // text matcher can tell which commands reach the Codex plugin (shell quoting, variables, and globs
      // all rewrite a name), so every fallback below refuses the command instead of guessing.
      const workdir = input?.workdir;
      if (
        workdir !== undefined &&
        (typeof workdir !== "string" || workdir === "")
      ) {
        return block(
          "b-agentic Codex guard: the shell workdir is not a path, so the command cannot be judged.",
        );
      }
      const directory = workdir === undefined ? cwd : resolve(cwd, workdir);
      try {
        const verdict = await hooks.codexGuard.judgeCommand(command, directory);
        if (verdict.decision === "refuse") {
          return block(`b-agentic Codex guard refused: ${verdict.reason}.`);
        }
        if (verdict.decision === "ask") {
          return block(
            `b-agentic Codex guard: ${verdict.reason} Only the user may record or change a Codex approval; ask them to run the command themselves.`,
          );
        }
        return undefined;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return block(
          `b-agentic Codex guard error (${message}); shell commands are blocked until it is repaired.`,
        );
      }
    },

    async toolBefore({ tool, input, sessionID, agent }, cwd) {
      try {
        const calls = checks(tool, input);
        if (calls === undefined) {
          if (tool === "shell") {
            if (hooks === null) {
              if (typeof input?.command === "string") {
                return block(
                  `b-agentic guard unavailable (${loadError}); shell commands are blocked until it is repaired. Reinstall b-agentic.`,
                );
              }
            } else {
              const verdict = await this.shellVerdict(input, cwd);
              if (verdict) return verdict;
            }
          }
          this.noteTool({ tool, input, sessionID, agent });
          return undefined;
        }
        if (hooks === null) {
          return block(
            `b-agentic guard unavailable (${loadError}); file tools are blocked until it is repaired. Reinstall b-agentic.`,
          );
        }
        const variants = calls.flatMap(([claude, input]) =>
          input.unreadable
            ? [[claude, input]]
            : pathVariants(input.path, cwd).map((path) => [
                claude,
                { ...input, path },
              ]),
        );
        for (const [claude, toolInput] of variants) {
          if (toolInput.unreadable) {
            return block(
              `b-agentic path guard: ${tool} refused: its target files cannot be determined, so they cannot be checked.`,
            );
          }
          const owned = hooks.pathGuard.agenticWrites(toolInput, claude, cwd);
          if (owned.length > 0) {
            return block(
              `b-agentic path guard: ${tool} refused on ${owned.join(", ")}. Run artifacts under .b-agentic are written only by b_run.py (python3 -I -B ~/.config/opencode/b-agentic/bin/b_run.py write <kind>) and b-state.mjs; read them with read.`,
            );
          }
          if (
            (claude === "Edit" || claude === "Write") &&
            typeof toolInput.path === "string" &&
            toolInput.path !== "" &&
            [
              toolInput.path,
              hooks.pathGuard.canonicalPath(toolInput.path, cwd),
            ].some((candidate) => basename(candidate) === APPROVAL_STORE)
          ) {
            return block(
              `b-agentic Codex guard: ${tool} refused on ${toolInput.path}. Only the user records or changes a Codex disclosure approval; ask them to do it.`,
            );
          }
          if (tool === "grep") {
            const reached = protectedSearchTargets(
              hooks,
              toolInput.path,
              toolInput.glob,
              cwd,
            );
            if (reached.length > 0) {
              return block(
                `b-agentic path guard: grep over ${toolInput.path ?? "the working directory"} would search likely-secret file(s) ${reached.join(", ")}. Search a narrower path or an include glob that excludes them; they need explicit user permission to read.`,
              );
            }
          }
          const secret = hooks.pathGuard.blockedPaths(toolInput, claude);
          if (secret.length > 0) {
            return block(
              `b-agentic path guard: ${tool} refused on likely-secret path ${secret.join(", ")}. Likely-secret files (.env, *.pem, credentials.*, secrets.*) need explicit user permission to read or change; ask the user first.`,
            );
          }
        }
        this.noteTool({ tool, input, sessionID, agent });
        return undefined;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return block(`b-agentic guard error (${message}); ${tool} is blocked.`);
      }
    },

    // A file edit of a non-prose file arms the gate; a main-session shell command
    // that is not plain inspection counts as a check and disarms it. The before
    // hook is the only tool signal the probe verified, so an edit counts when it
    // is issued, not when it succeeds.
    noteTool({ tool, input, sessionID, agent }) {
      advisory(() => {
        if (hooks === null || !sessionID) return;
        if (agent) seen.add(sessionID);
        if (CHILD_AGENT.test(agent ?? "")) return;
        if (tool === "shell") {
          if (!hooks.verifyGate.isInspection(input?.command))
            dirty.delete(sessionID);
        } else if (tool === "edit" || tool === "write") {
          const path = input?.path ?? input?.filePath;
          if (
            typeof path === "string" &&
            !hooks.verifyGate.PROSE_PATH.test(path)
          ) {
            dirty.add(sessionID);
          }
        } else if (tool === "patch") {
          const paths = patchPaths(input?.patchText);
          if (paths.some((p) => !hooks.verifyGate.PROSE_PATH.test(p)))
            dirty.add(sessionID);
        }
      });
    },

    // The reminder text for one extra turn once per run, or undefined.
    reminder(sessionID) {
      return advisory(() => {
        if (hooks === null || !dirty.has(sessionID) || reminded.has(sessionID))
          return undefined;
        reminded.add(sessionID);
        dirty.delete(sessionID);
        ownTurn.add(sessionID);
        return hooks.verifyGate.REMINDER;
      });
    },

    // A new execution started: a user-driven run resets the once-per-run reminder.
    executionStarted(sessionID) {
      if (ownTurn.delete(sessionID)) return;
      reminded.delete(sessionID);
    },

    // Spec and run context for the next model call of a session: once at its first call and after compaction.
    queueContext(sessionID, cwd) {
      advisory(() => {
        if (hooks === null) return;
        const spec = hooks.specContext.buildContext(
          hooks.specContext.approvedSpecs(cwd),
        );
        const run = hooks.runContext.buildContext(
          hooks.runContext.activeRun(cwd),
        );
        const texts = [spec, run].filter(Boolean);
        if (texts.length > 0) pending.set(sessionID, texts.join("\n"));
      });
    },

    firstCall(sessionID) {
      if (seen.has(`ctx:${sessionID}`)) return false;
      seen.add(`ctx:${sessionID}`);
      return true;
    },

    takeContext(sessionID) {
      const text = pending.get(sessionID);
      pending.delete(sessionID);
      return text;
    },
  };
}
