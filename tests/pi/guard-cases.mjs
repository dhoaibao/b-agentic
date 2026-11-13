// Cases for the Pi guard core (pi/extensions/b-agentic/guard.mjs) and for the
// child-gate registration glue in the extension entry (index.ts). Needs only
// node: no Pi, network, or credentials. The hook modules come from claude/hooks,
// the same files the installer copies next to the Pi extension.
import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createGuard,
  FILE_TOOLS,
} from "../../pi/extensions/b-agentic/guard.mjs";
import extension from "../../pi/extensions/b-agentic/index.ts";

const root = fileURLToPath(new URL("../..", import.meta.url));
const hooksDir = join(root, "claude", "hooks");
const work = mkdtempSync(join(tmpdir(), "pi-guard-"));
const cases = [];
const test = (name, fn) => cases.push([name, fn]);

const guard = await createGuard({ hooksDir });
const call = (toolName, input, cwd = work) =>
  guard.toolCall({ toolName, input }, cwd);
const blocked = (result) => result?.block === true;

test("hook modules load from claude/hooks", () => {
  assert.equal(guard.loadError, "");
});

test("secret paths are blocked for every file tool", () => {
  for (const [tool, input] of [
    ["read", { path: "/repo/.env" }],
    ["edit", { path: "config/.env.production", edits: [] }],
    ["write", { path: "keys/server.pem", content: "x" }],
    ["grep", { pattern: "x", path: "aws-credentials.json" }],
    ["grep", { pattern: "x", glob: "**/secrets.yaml" }],
    ["find", { pattern: "**/.env" }],
    ["ls", { path: "app/.env.local" }],
  ]) {
    const result = call(tool, input);
    assert.ok(
      blocked(result),
      `${tool} ${JSON.stringify(input)} must be blocked`,
    );
    assert.match(result.reason, /likely-secret path/);
  }
});

test("ordinary paths and .env.example are allowed", () => {
  for (const [tool, input] of [
    ["read", { path: "src/index.ts" }],
    ["read", { path: ".env.example" }],
    ["edit", { path: "README.md", edits: [] }],
    ["grep", { pattern: "x", glob: "*.ts" }],
    ["find", { pattern: "*.md" }],
    ["ls", {}],
  ]) {
    assert.equal(
      call(tool, input),
      undefined,
      `${tool} ${JSON.stringify(input)}`,
    );
  }
});

test("tools outside the file tools are not path-checked", () => {
  assert.equal(call("bash", { command: "cat .env" }), undefined);
  assert.equal(call("mcp__fake__lookup", { path: ".env" }), undefined);
});

test(".b-agentic writes are blocked and reads are allowed", () => {
  for (const tool of ["edit", "write"]) {
    const result = call(tool, { path: ".b-agentic/runs/x/spec.md" });
    assert.ok(blocked(result), `${tool} on .b-agentic must be blocked`);
    assert.match(result.reason, /b_run\.py/);
  }
  assert.equal(call("read", { path: ".b-agentic/runs/x/spec.md" }), undefined);
});

test("symlinks and .. cannot hide .b-agentic", () => {
  mkdirSync(join(work, ".b-agentic", "runs"), { recursive: true });
  symlinkSync(join(work, ".b-agentic"), join(work, "link"));
  assert.ok(blocked(call("write", { path: "link/runs/x.md", content: "x" })));
  assert.ok(
    blocked(call("edit", { path: "sub/../.b-agentic/state.json", edits: [] })),
  );
});

test("an unloadable hook module blocks every file tool", async () => {
  const broken = await createGuard({
    hooksDir,
    loader: async () => {
      throw new Error("module missing");
    },
  });
  assert.match(broken.loadError, /module missing/);
  for (const tool of Object.keys(FILE_TOOLS)) {
    const result = broken.toolCall(
      { toolName: tool, input: { path: "a.txt" } },
      work,
    );
    assert.ok(blocked(result), `${tool} must be blocked`);
    assert.match(result.reason, /guard unavailable/);
  }
  assert.equal(
    broken.toolCall({ toolName: "bash", input: {} }, work),
    undefined,
  );
});

test("a thrown hook error blocks the call", async () => {
  const throwing = await createGuard({
    hooksDir,
    loader: async () => ({
      pathGuard: {
        agenticWrites() {
          throw new Error("boom");
        },
        blockedPaths: () => [],
      },
    }),
  });
  const result = throwing.toolCall(
    { toolName: "read", input: { path: "a" } },
    work,
  );
  assert.ok(blocked(result));
  assert.match(result.reason, /guard error \(boom\)/);
});

test("a malformed input does not crash the guard", () => {
  assert.equal(call("read", null), undefined);
  assert.equal(call("read", { path: 7 }), undefined);
});

const edited = (path, isError = false) =>
  guard.toolResult({ toolName: "write", input: { path }, isError });
const settle = () =>
  guard.beforeSettle({ outcome: "completed", entries: [{ keep: true }] });

test("the verify gate reminds once after an edit and then lets the run settle", () => {
  guard.settled();
  edited("src/a.ts");
  const reminder = settle();
  assert.equal(reminder.continue, true);
  assert.equal(reminder.entries.length, 2);
  assert.deepEqual(reminder.entries[0], { keep: true });
  assert.match(reminder.entries[1].content, /verify gate/);
  edited("src/b.ts");
  assert.equal(settle(), undefined, "no second reminder in the same run");
  guard.settled();
  assert.equal(settle(), undefined, "nothing is dirty after the run settles");
});

test("prose edits, failed edits, and inspection shell commands do not arm or clear it", () => {
  guard.settled();
  edited("notes.md");
  edited("src/a.ts", true);
  assert.equal(settle(), undefined);
  edited("src/a.ts");
  guard.toolResult({
    toolName: "bash",
    input: { command: "rg foo src" },
    isError: false,
  });
  assert.ok(settle(), "inspection must not count as a check");
  guard.settled();
  edited("src/a.ts");
  guard.toolResult({
    toolName: "bash",
    input: { command: "npm test" },
    isError: false,
  });
  assert.equal(settle(), undefined, "a real command counts as a check");
  guard.settled();
});

test("an aborted or failed run is not reminded", () => {
  edited("src/a.ts");
  for (const outcome of ["aborted", "error"]) {
    assert.equal(guard.beforeSettle({ outcome, entries: [] }), undefined);
  }
  guard.settled();
});

// Context injection equals the Claude hook output for the same project.
const project = join(work, "project");
mkdirSync(join(project, "docs", "specs"), { recursive: true });
writeFileSync(
  join(project, "docs", "specs", "feature.md"),
  "# Feature\n\nStatus: approved\n",
);
const runId = "20261113-demo";
mkdirSync(join(project, ".b-agentic", "runs", runId), { recursive: true });
writeFileSync(join(project, ".b-agentic", "active"), `${runId}\n`);
writeFileSync(
  join(project, ".b-agentic", "runs", runId, "state.json"),
  JSON.stringify({ run_id: runId, phase: "implement" }),
);
const specHook = await import(join(hooksDir, "b-spec-context.mjs"));
const runHook = await import(join(hooksDir, "b-run-context.mjs"));
const expectedSpec = specHook.buildContext(specHook.approvedSpecs(project));
const expectedRun = runHook.buildContext(runHook.activeRun(project));

test("startup, resume, and new sessions queue only the run context", () => {
  for (const reason of ["startup", "resume", "new"]) {
    guard.sessionStart(reason, project);
    const message = guard.takeContext();
    assert.equal(message.content, expectedRun, reason);
    assert.equal(message.display, false);
  }
  for (const reason of ["reload", "fork"]) {
    guard.sessionStart(reason, project);
    assert.equal(guard.takeContext(), undefined, reason);
  }
});

test("compaction queues the spec context and the run context, then clears", () => {
  guard.compacted(project);
  assert.equal(guard.takeContext().content, `${expectedSpec}\n${expectedRun}`);
  assert.equal(guard.takeContext(), undefined);
});

test("a project without specs or a run queues nothing", () => {
  guard.compacted(work);
  guard.sessionStart("startup", work);
  assert.equal(guard.takeContext(), undefined);
});

test("subagent launches are refused when child sessions cannot be gated", () => {
  const solo = { toolName: "subagent", input: { agent: "b-reviewer" } };
  assert.equal(guard.toolCall(solo, work), undefined);
  guard.setChildGateError("registration failed");
  assert.ok(blocked(guard.toolCall(solo, work)));
  assert.ok(
    blocked(guard.toolCall({ toolName: "subagent_launch", input: {} }, work)),
  );
  assert.equal(
    guard.toolCall({ toolName: "bash", input: {} }, work),
    undefined,
  );
  guard.setChildGateError("");
});

// The extension entry, loaded through Node's type stripping with a fake `pi`
// and a temporary agent directory per case. In the repository layout the hook
// modules are not next to it, so these cases exercise the child gate only.
const REGISTRATIONS = "__bAgenticChildRegistrations";
const BUNDLES = {
  working: `export function registerRequiredChildExtensions(options) {
  const entry = { options, disposed: false };
  (globalThis.${REGISTRATIONS} ??= []).push(entry);
  return {
    dispose() {
      entry.disposed = true;
    },
  };
}
`,
  noExport: "export const version = 1;\n",
  throwing: `export function registerRequiredChildExtensions() {
  throw new Error("registration exploded");
}
`,
};
const bundleEntry = (dir) =>
  join(
    dir,
    "npm",
    "node_modules",
    "pi-subagents",
    "bundle",
    "required-child-extensions.js",
  );
const permissionEntry = (dir) =>
  join(
    dir,
    "npm",
    "node_modules",
    "@gotgenes",
    "pi-permission-system",
    "src",
    "index.ts",
  );
const writeEntry = (path, text) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
};
const agentDirWith = (name, { bundle, permission }) => {
  const dir = join(work, `agent-${name}`);
  mkdirSync(dir, { recursive: true });
  if (bundle !== undefined) {
    writeEntry(bundleEntry(dir), bundle);
    writeFileSync(
      join(dir, "npm", "node_modules", "pi-subagents", "package.json"),
      '{ "type": "module" }\n',
    );
  }
  if (permission) writeEntry(permissionEntry(dir), "export default 1;\n");
  return dir;
};
const loadExtension = async (dir) => {
  const handlers = {};
  const previous = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = dir;
  try {
    await extension({
      on(name, handler) {
        handlers[name] = handler;
      },
    });
  } finally {
    if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previous;
  }
  const ctx = {
    cwd: work,
    sessionManager: { getSessionId: () => "session-1" },
  };
  globalThis[REGISTRATIONS] = [];
  return {
    start: () => handlers.session_start({ reason: "startup" }, ctx),
    subagent: () =>
      handlers.tool_call(
        { toolName: "subagent", input: { agent: "b-reviewer" } },
        ctx,
      ),
    bash: () =>
      handlers.tool_call({ toolName: "bash", input: { command: "true" } }, ctx),
  };
};
const refusedFor = (result, pattern) => {
  assert.ok(blocked(result), "the subagent launch must be refused");
  assert.match(result.reason, /child sessions cannot be gated/);
  assert.match(result.reason, pattern);
};

test("extension: a missing pi-subagents registration module refuses subagent launches", async () => {
  const dir = agentDirWith("no-module", { permission: true });
  const pi = await loadExtension(dir);
  await pi.start();
  const result = pi.subagent();
  refusedFor(result, /pi-subagents/);
  assert.ok(result.reason.includes(bundleEntry(dir)), result.reason);
  assert.equal(pi.bash(), undefined, "other tools stay unaffected");
});

test("extension: a registration module without the register function refuses subagent launches", async () => {
  const dir = agentDirWith("no-export", {
    bundle: BUNDLES.noExport,
    permission: true,
  });
  const pi = await loadExtension(dir);
  await pi.start();
  refusedFor(pi.subagent(), /registerRequiredChildExtensions/);
});

test("extension: a missing permission-system entry refuses subagent launches", async () => {
  const dir = agentDirWith("no-permission", { bundle: BUNDLES.working });
  const pi = await loadExtension(dir);
  await pi.start();
  const result = pi.subagent();
  refusedFor(result, /pi-permission-system/);
  assert.ok(result.reason.includes(permissionEntry(dir)), result.reason);
  assert.deepEqual(
    globalThis[REGISTRATIONS],
    [],
    "the guard must not be registered alone",
  );
});

test("extension: a throwing registration refuses subagent launches", async () => {
  const dir = agentDirWith("throwing", {
    bundle: BUNDLES.throwing,
    permission: true,
  });
  const pi = await loadExtension(dir);
  await pi.start();
  refusedFor(pi.subagent(), /registration exploded/);
});

test("extension: with both entries the guard and the permission system are required for every child", async () => {
  const dir = agentDirWith("complete", {
    bundle: BUNDLES.working,
    permission: true,
  });
  const pi = await loadExtension(dir);
  await pi.start();
  assert.deepEqual(
    globalThis[REGISTRATIONS].map((entry) => entry.options),
    [
      {
        sessionId: "session-1",
        extensions: [
          {
            id: "b-agentic-guard",
            path: join(root, "pi", "extensions", "b-agentic", "index.ts"),
          },
          { id: "pi-permission-system", path: permissionEntry(dir) },
        ],
        requireForAllRunners: true,
      },
    ],
  );
  assert.equal(pi.subagent(), undefined, "a gated launch is allowed");
});

test("extension: a later session start clears a repaired gate and refuses again when it breaks", async () => {
  const dir = agentDirWith("repaired", { bundle: BUNDLES.working });
  const pi = await loadExtension(dir);
  await pi.start();
  refusedFor(pi.subagent(), /pi-permission-system/);
  writeEntry(permissionEntry(dir), "export default 1;\n");
  await pi.start();
  assert.equal(pi.subagent(), undefined, "the repaired gate allows launches");
  rmSync(permissionEntry(dir));
  await pi.start();
  refusedFor(pi.subagent(), /pi-permission-system/);
  assert.deepEqual(
    globalThis[REGISTRATIONS].map((entry) => entry.disposed),
    [true],
    "the earlier registration is released",
  );
});

let failed = 0;
for (const [name, fn] of cases) {
  try {
    await fn();
    console.log(`guard case passed: ${name}`);
  } catch (error) {
    failed += 1;
    console.error(`guard case FAILED: ${name}\n${error.stack ?? error}`);
  }
}
rmSync(work, { recursive: true, force: true });
if (failed > 0) {
  console.error(`${failed} guard case(s) failed`);
  process.exit(1);
}
console.log("Pi guard cases passed.");
