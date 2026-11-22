// b-agentic guard for Pi. Plain Node (Pi loads extensions under Node), so the
// cases in tests/pi/guard-cases.mjs run without Pi.
//
// Every decision reuses the Claude Code hook modules (likely-secret paths,
// .b-agentic writes, shell-inspection classification, spec and run context,
// the Alexandria argument check), so both runtimes judge the same way. The
// guards fail closed: a missing hook module, a thrown error, a missing
// confirmation prompt, or a child session that cannot be gated blocks or
// refuses. The verify reminder and the context injection are advisory and fail
// open, as they do on Claude Code.
import { spawnSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  readlinkSync,
  realpathSync,
  statSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// The Pi release the extension API was checked against. Older builds lack the
// events used here, so loading throws and Pi runs nothing (fail closed).
export const PI_FLOOR = "1.6.0";

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

// Copied next to the extension by the installer, from claude/hooks.
export const HOOK_FILES = {
  pathGuard: "b-path-guard.mjs",
  verifyGate: "b-verify-gate.mjs",
  specContext: "b-spec-context.mjs",
  runContext: "b-run-context.mjs",
  alexandria: "b-alexandria-guard.mjs",
};

// Used only when the Alexandria hook cannot load, so the call is still refused.
const ALEXANDRIA_TOOL = "mcp__firecrawl__firecrawl_scrape";
const RUN_CONTEXT_REASONS = new Set(["startup", "resume", "new"]);
const HELPERS = "~/.pi/agent/b-agentic/bin";

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
const message = (error) =>
  error instanceof Error ? error.message : String(error);

// Pi resolves a tool path before it opens the file: Unicode spaces become
// spaces, a leading @ is dropped, ~ expands to the home directory, and a
// file:// URL becomes its path (utils/paths.js normalizePath in Pi 1.6.0). The
// hooks read the raw spelling, so the same rules run here first; every spelling
// is checked, not only the normalized one.
const UNICODE_SPACES = /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g;
const PATH_KEYS = ["path", "file_path"];
export function piPath(value) {
  let text = value.replace(UNICODE_SPACES, " ");
  if (text.startsWith("@")) text = text.slice(1);
  if (text === "~") return homedir();
  if (text.startsWith("~/")) return join(homedir(), text.slice(2));
  return /^file:\/\//.test(text) ? fileURLToPath(text) : text;
}

// Where Pi's file tools land: the input's `..` is collapsed first
// (path.resolve), then the operating system walks the components, expanding
// each link where it stands, so a `..` inside a link's target applies after
// the links before it. A component that does not exist yet (the file a write
// creates, even through a dangling link) is kept as written.
export function piResolve(text, cwd) {
  const queue = resolve(cwd, text).split("/").filter(Boolean);
  let current = "/";
  let hops = 0;
  while (queue.length > 0) {
    const part = queue.shift();
    if (part === ".") continue;
    if (part === "..") {
      current = dirname(current);
      continue;
    }
    const next = join(current, part);
    let info;
    try {
      info = lstatSync(next);
    } catch {
      current = next;
      continue;
    }
    if (!info.isSymbolicLink()) {
      current = next;
      continue;
    }
    hops += 1;
    if (hops > 40) return next;
    const target = readlinkSync(next);
    if (isAbsolute(target)) current = "/";
    queue.unshift(...target.split("/").filter(Boolean));
  }
  return current;
}

// `read` tries these spellings of the resolved path when the first does not
// exist (path-utils.js resolveReadPath in Pi 1.6.0), on every platform.
const READ_FALLBACKS = [
  (path) => path.replace(/ (AM|PM)\./gi, "\u202F$1."),
  (path) => path.normalize("NFD"),
  (path) => path.replace(/'/g, "\u2019"),
  (path) => path.normalize("NFD").replace(/'/g, "\u2019"),
];

// The tool input spelled as Pi will open it: normalized, with each fallback
// spelling `read` may select, and with the target resolved (relative to the
// working directory when inside it), so neither a link nor a `..` can name a
// protected file by another name.
function inputVariants(input, cwd, isRead) {
  if (input === null || typeof input !== "object") return [input];
  const variants = [input];
  let base = cwd;
  try {
    base = realpathSync(cwd);
  } catch {
    // A missing cwd keeps the lexical form.
  }
  for (const key of PATH_KEYS) {
    if (typeof input[key] !== "string" || input[key] === "") continue;
    const text = piPath(input[key]);
    const spellings = [text];
    if (isRead) {
      const absolute = resolve(cwd, text);
      for (const fallback of READ_FALLBACKS) spellings.push(fallback(absolute));
    }
    for (const spelling of spellings) {
      variants.push({ ...input, [key]: spelling });
      const real = piResolve(spelling, cwd);
      const inside = relative(base, real);
      variants.push({
        ...input,
        [key]:
          inside !== "" && !inside.startsWith("..") && !isAbsolute(inside)
            ? inside
            : real,
      });
    }
  }
  return variants;
}

// The files a Pi grep run searches in `dir`: the same ripgrep flags that decide
// which files are visited (ignore rules, hidden files, the glob), listed with
// NUL separators so a name holding a newline or a row delimiter stays whole.
// Pi's output rows cannot be split back into paths reliably, so the check runs
// on this list before the search. Throws when ripgrep cannot list the tree.
export function listSearchFiles({ dir, glob, command = "rg" }) {
  const args = ["--no-config", "--files", "--hidden", "--null"];
  if (typeof glob === "string" && glob !== "") {
    args.push("--glob", glob.replace(/^(!?)(?:\.\/)+/, "$1"));
  }
  args.push(".");
  const run = spawnSync(command, args, {
    cwd: dir,
    encoding: "utf8",
    maxBuffer: 256 * 1024 * 1024,
  });
  // Exit 1 means no file matched.
  if (run.error || (run.status !== 0 && run.status !== 1)) {
    throw new Error(
      `ripgrep could not list the search tree (${run.error?.message ?? String(run.stderr).trim()})`,
    );
  }
  return run.stdout.split("\0").filter(Boolean);
}

// A user command that names a secret path, or `.b-agentic` without being plain
// inspection. The check is token-level and narrow on purpose: a user's own
// shell is not sandboxed, this only stops the two accidents the path guard
// exists for.
// Case-insensitive for the same reason as the shared path guard: `.B-Agentic` is the same folder on a
// case-insensitive filesystem. A name that only starts with it (`.b-agentic.md`) is an ordinary file.
const NAMES_AGENTIC =
  /(^|[^A-Za-z0-9_-])\.b-agentic(?![A-Za-z0-9_-]|\.[A-Za-z0-9_-])/i;
const WORD_BREAKS = /[\s'"`;|&<>()=:,]+/;

// `loader` is injectable so tests can simulate a missing or broken hook module.
// `childEntries` are files the child gate needs; one that disappears later
// refuses subagent launches again. `listFiles` and `rgCommand` list a grep's
// search tree.
export async function createGuard({
  hooksDir,
  loader = loadHooks,
  childEntries = [],
  listFiles = listSearchFiles,
  rgCommand = "rg",
}) {
  let hooks = null;
  let loadError = "";
  try {
    hooks = await loader(hooksDir);
  } catch (error) {
    loadError = message(error);
  }

  // Verify gate state: in memory, one instance per Pi session.
  let dirty = false;
  let reminded = false;
  let pending = [];
  // Closed until registration succeeds: no subagent runs ungated.
  let childGateError = "child gating is not registered yet";

  const advisory = (fn) => {
    try {
      return fn();
    } catch {
      return undefined;
    }
  };
  const gateOff = () => hooks === null || hooks.verifyGate.gateMode() === "off";

  const childRefusal = (toolName) => {
    // A child loads this same guard, so a degraded one cannot gate it.
    let reason =
      hooks === null
        ? `the hook modules failed to load: ${loadError}`
        : childGateError;
    if (!reason) {
      const missing = childEntries.find((path) => !existsSync(path));
      if (missing !== undefined) reason = `${missing} is missing`;
    }
    return reason
      ? block(
          `b-agentic guard: child sessions cannot be gated (${reason}); ${toolName} is refused.`,
        )
      : undefined;
  };

  // A directory search prints matching lines with their file names, so a
  // likely-secret file in the searched tree would leak through `grep` even
  // though `read` refuses it. The files the search would visit are listed first
  // and the call is refused when one of them is protected (a failure to list
  // refuses too). A `glob` or a narrower `path` that leaves them out passes.
  const searchRefusal = (input, cwd) => {
    const asked =
      typeof input?.path === "string" && input.path !== "" ? input.path : ".";
    const dir = piResolve(piPath(asked), cwd);
    let isDirectory = false;
    try {
      isDirectory = statSync(dir).isDirectory();
    } catch {
      // A missing path is Pi's error to report.
    }
    if (!isDirectory) return undefined;
    const secret = listFiles({ dir, glob: input?.glob, command: rgCommand })
      .filter(
        (file) =>
          hooks.pathGuard.blockedPaths({ path: file }, "Read").length > 0,
      )
      .slice(0, 3);
    return secret.length === 0
      ? undefined
      : block(
          `b-agentic path guard: grep would search likely-secret file ${secret.map((file) => JSON.stringify(file)).join(", ")} under ${dir}. Narrow the path, or add a glob that leaves it out; likely-secret files need explicit user permission.`,
        );
  };

  const confirmAlexandria = async (ctx) => {
    if (!ctx?.hasUI || typeof ctx.ui?.confirm !== "function") {
      return block(
        "b-agentic guard: firecrawl_scrape with an alexandria argument runs billed provider lookups and needs a confirmation prompt, which this session cannot show; the call is refused.",
      );
    }
    const approved = await ctx.ui.confirm(
      "Alexandria lookup",
      "firecrawl_scrape was called with an alexandria argument, which runs billed provider lookups. Allow it?",
    );
    return approved === true
      ? undefined
      : block("b-agentic guard: the alexandria lookup was not approved.");
  };

  return {
    get loadError() {
      return loadError;
    },

    // A reason a child session cannot be gated, or "" once registered.
    setChildGateError(reason) {
      childGateError = reason;
    },

    // `ctx` carries cwd, hasUI and ui.confirm.
    async toolCall({ toolName, input }, ctx) {
      try {
        if (toolName.startsWith("subagent")) return childRefusal(toolName);
        const claudeName = FILE_TOOLS[toolName];
        if (hooks === null) {
          if (claudeName === undefined && toolName !== ALEXANDRIA_TOOL)
            return undefined;
          return block(
            `b-agentic guard unavailable (${loadError}); ${toolName} is blocked until it is repaired. Reinstall b-agentic.`,
          );
        }
        if (toolName === hooks.alexandria.GUARDED_TOOL) {
          return hooks.alexandria.needsAsk({
            tool_name: toolName,
            tool_input: input,
          })
            ? await confirmAlexandria(ctx)
            : undefined;
        }
        if (claudeName === undefined) return undefined;
        const cwd = ctx?.cwd;
        const variants = inputVariants(input, cwd, toolName === "read");
        const owned = variants.flatMap((variant) =>
          hooks.pathGuard.agenticWrites(variant, claudeName, cwd),
        );
        if (owned.length > 0) {
          return block(
            `b-agentic path guard: ${toolName} refused on ${[...new Set(owned)].join(", ")}. Run artifacts under .b-agentic are written only by ${HELPERS}/b-run write <kind> and ${HELPERS}/b-state; read them with read.`,
          );
        }
        const secret = variants.flatMap((variant) =>
          hooks.pathGuard.blockedPaths(variant, claudeName),
        );
        if (secret.length > 0) {
          return block(
            `b-agentic path guard: ${toolName} refused on likely-secret path ${[...new Set(secret)].join(", ")}. Likely-secret files (.env, *.pem, credentials.*, secrets.*) need explicit user permission to read or change; ask the user first.`,
          );
        }
        if (toolName === "grep") return searchRefusal(input, cwd);
        return undefined;
      } catch (error) {
        return block(
          `b-agentic guard error (${message(error)}); ${toolName} is blocked.`,
        );
      }
    },

    // A user's `!` command, also the RPC `bash` command. Pi cannot block it:
    // the handler replaces its result, and a handler that throws is rethrown.
    userBash({ command }) {
      const refuse = (reason) => ({
        result: {
          output: `b-agentic guard: ${reason}\n`,
          exitCode: 1,
          cancelled: false,
          truncated: false,
        },
      });
      try {
        if (hooks === null) {
          return refuse(
            `guard unavailable (${loadError}); this command is refused until it is repaired.`,
          );
        }
        const text = typeof command === "string" ? command : "";
        const secret = text
          .split(WORD_BREAKS)
          .filter(Boolean)
          .filter(
            (word) =>
              hooks.pathGuard.blockedPaths({ path: word }, "Read").length,
          );
        if (secret.length > 0) {
          return refuse(
            `this command names likely-secret path ${secret.join(", ")}. Likely-secret files (.env, *.pem, credentials.*, secrets.*) need explicit permission; run it outside Pi if you mean it.`,
          );
        }
        if (NAMES_AGENTIC.test(text) && !hooks.verifyGate.isInspection(text)) {
          return refuse(
            `this command names .b-agentic and is not plain inspection. Run artifacts are written only by ${HELPERS}/b-run write <kind> and ${HELPERS}/b-state.`,
          );
        }
        return undefined;
      } catch (error) {
        return refuse(`guard error (${message(error)}); command refused.`);
      }
    },

    // A successful edit of a non-prose file arms the gate; a shell command that
    // is not plain inspection counts as a check and disarms it.
    toolResult({ toolName, input, isError }) {
      advisory(() => {
        if (gateOff()) return;
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

    // One extra turn carrying the reminder, once per run. `observe` never continues.
    beforeSettle(event) {
      return advisory(() => {
        if (gateOff() || hooks.verifyGate.gateMode() !== "enforce")
          return undefined;
        if (event.outcome !== "completed" || !dirty || reminded)
          return undefined;
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

const versionParts = (text) =>
  String(text)
    .split(/[.-]/)
    .slice(0, 3)
    .map((part) => Number.parseInt(part, 10));

export function atLeast(version, floor = PI_FLOOR) {
  const have = versionParts(version);
  const need = versionParts(floor);
  if (have.length < 3 || have.some(Number.isNaN)) return false;
  for (let i = 0; i < 3; i += 1) {
    if (have[i] !== need[i]) return have[i] > need[i];
  }
  return true;
}

// Wires the guard to Pi's events. Throws at load when the Pi build is below the
// floor or has no event API, so Pi exits without running a tool.
// - version: Pi's VERSION; entryPath: this extension's index.ts (the file Pi
//   loads, which children must load too); hooksDir: the copied Claude hooks;
//   agentDir: Pi's agent folder, where the npm packages live;
//   importModule: injectable for tests.
export async function register(
  pi,
  {
    version,
    entryPath,
    hooksDir,
    agentDir = process.env.PI_CODING_AGENT_DIR ??
      join(homedir(), ".pi", "agent"),
    importModule = (path) => import(pathToFileURL(path).href),
  },
) {
  if (!atLeast(version)) {
    throw new Error(
      `b-agentic needs Pi ${PI_FLOOR} or newer (found ${version}); upgrade Pi.`,
    );
  }
  if (typeof pi?.on !== "function") {
    throw new Error("b-agentic needs the Pi extension event API (pi.on).");
  }

  const packages = join(agentDir, "npm", "node_modules");
  const subagents = join(
    packages,
    "pi-subagents",
    "bundle",
    "required-child-extensions.js",
  );
  const permission = join(
    packages,
    "@gotgenes",
    "pi-permission-system",
    "src",
    "index.ts",
  );
  // Pi downloads ripgrep into its agent folder when none is on PATH.
  const bundledRg = join(agentDir, "bin", "rg");
  const guard = await createGuard({
    hooksDir,
    childEntries: [subagents, permission],
    rgCommand: existsSync(bundledRg) ? bundledRg : "rg",
  });

  pi.on("tool_call", (event, ctx) => guard.toolCall(event, ctx));
  pi.on("user_bash", (event) => guard.userBash(event));
  pi.on("tool_result", (event) => {
    guard.toolResult(event);
  });
  pi.on("agent_before_settle", (event) => guard.beforeSettle(event));
  pi.on("agent_settled", () => {
    guard.settled();
  });
  pi.on("session_compact", (_event, ctx) => {
    guard.compacted(ctx.cwd);
  });
  pi.on("before_agent_start", () => {
    const content = guard.takeContext();
    return content ? { message: content } : undefined;
  });

  // Specialist children load only the extensions they list. Registering this
  // guard and the permission system as required child extensions applies both
  // to every pi-subagents child; a load failure then rejects the launch. When
  // either entry is missing or registration fails, children cannot be gated,
  // so every subagent launch is refused.
  let registration;
  const release = () => {
    const held = registration;
    registration = undefined;
    held?.dispose();
  };
  pi.on("session_start", async (event, ctx) => {
    guard.sessionStart(event.reason, ctx.cwd);
    try {
      release();
      for (const [name, path] of [
        ["pi-subagents", subagents],
        ["pi-permission-system", permission],
      ]) {
        if (!existsSync(path)) {
          throw new Error(
            `the ${name} package is not installed: ${path} is missing`,
          );
        }
      }
      const api = await importModule(subagents);
      if (typeof api.registerRequiredChildExtensions !== "function") {
        throw new Error(
          `${subagents} does not export registerRequiredChildExtensions`,
        );
      }
      registration = api.registerRequiredChildExtensions({
        sessionId: ctx.sessionManager.getSessionId(),
        extensions: [
          { id: "b-agentic-guard", path: entryPath },
          { id: "pi-permission-system", path: permission },
        ],
        requireForAllRunners: true,
      });
      guard.setChildGateError("");
    } catch (error) {
      guard.setChildGateError(message(error));
    }
  });
  pi.on("session_shutdown", release);
  return guard;
}
