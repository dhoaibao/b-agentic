// Cases for the Pi guard core (pi/extensions/b-agentic/guard.mjs). Needs only
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
  atLeast,
  createGuard,
  FILE_TOOLS,
  piPath,
  piResolve,
  register,
} from "../../pi/extensions/b-agentic/guard.mjs";

const root = fileURLToPath(new URL("../..", import.meta.url));
const hooksDir = join(root, "claude", "hooks");
const work = mkdtempSync(join(tmpdir(), "pi-guard-"));
const cases = [];
const test = (name, fn) => cases.push([name, fn]);

const guard = await createGuard({ hooksDir });
guard.setChildGateError("");
const ctx = { cwd: work, hasUI: false };
const call = (toolName, input, context = ctx) =>
  guard.toolCall({ toolName, input }, context);
const blocked = (result) => result?.block === true;

test("hook modules load from claude/hooks", () => {
  assert.equal(guard.loadError, "");
});

// AC-1
test("secret paths are blocked for every file tool", async () => {
  for (const [tool, input] of [
    ["read", { path: "/repo/.env" }],
    ["edit", { path: "config/.env.production", edits: [] }],
    ["write", { path: "keys/server.pem", content: "x" }],
    ["grep", { pattern: "x", path: "aws-credentials.json" }],
    ["grep", { pattern: "x", glob: "**/secrets.yaml" }],
    ["find", { pattern: "**/.env" }],
    ["ls", { path: "app/.env.local" }],
  ]) {
    const result = await call(tool, input);
    assert.ok(
      blocked(result),
      `${tool} ${JSON.stringify(input)} must be blocked`,
    );
    assert.match(result.reason, /likely-secret path/);
  }
});

test("ordinary paths and .env.example are allowed", async () => {
  for (const [tool, input] of [
    ["read", { path: "src/index.ts" }],
    ["read", { path: ".env.example" }],
    ["edit", { path: "README.md", edits: [] }],
    ["grep", { pattern: "x", glob: "*.ts" }],
    ["find", { pattern: "*.md" }],
    ["ls", {}],
  ]) {
    assert.equal(
      await call(tool, input),
      undefined,
      `${tool} ${JSON.stringify(input)}`,
    );
  }
});

test("tools outside the file tools are not path-checked", async () => {
  assert.equal(await call("bash", { command: "cat .env" }), undefined);
  assert.equal(await call("mcp__fake__lookup", { path: ".env" }), undefined);
});

test(".b-agentic writes are blocked and reads are allowed", async () => {
  for (const tool of ["edit", "write"]) {
    const result = await call(tool, { path: ".b-agentic/runs/x/spec.md" });
    assert.ok(blocked(result), `${tool} on .b-agentic must be blocked`);
    assert.match(result.reason, /~\/\.pi\/agent\/b-agentic\/bin\/b-run write/);
  }
  assert.equal(
    await call("read", { path: ".b-agentic/runs/x/spec.md" }),
    undefined,
  );
});

test(".b-agentic is refused in any letter case, and only as a whole component", async () => {
  for (const path of [
    ".B-Agentic/runs/x/spec.md",
    "sub/.B-AGENTIC/state.json",
  ]) {
    for (const tool of ["edit", "write"]) {
      assert.ok(blocked(await call(tool, { path })), `${tool} on ${path}`);
    }
    assert.equal(await call("read", { path }), undefined, `read ${path}`);
  }
  for (const path of ["docs/B-Agentic-notes.md", "x.B-AGENTIC"]) {
    assert.equal(await call("write", { path }), undefined, path);
  }
});

test("symlinks and .. cannot hide .b-agentic", async () => {
  mkdirSync(join(work, ".b-agentic", "runs"), { recursive: true });
  symlinkSync(join(work, ".b-agentic"), join(work, "link"));
  assert.ok(
    blocked(await call("write", { path: "link/runs/x.md", content: "x" })),
  );
  assert.ok(
    blocked(
      await call("edit", { path: "sub/../.b-agentic/state.json", edits: [] }),
    ),
  );
});

test("the spellings Pi normalizes cannot hide a protected path", async () => {
  assert.equal(piPath("@.env"), ".env");
  assert.equal(piPath("a\u00A0b"), "a b");
  assert.equal(piPath("file:///tmp/x/.env"), "/tmp/x/.env");
  for (const [tool, input] of [
    ["read", { path: "@.env" }],
    ["read", { path: "file://" + join(work, ".env") }],
    ["edit", { path: "@.b-agentic/runs/x/spec.md", edits: [] }],
    ["write", { path: "file://" + join(work, ".b-agentic", "x.md") }],
    ["write", { path: "~/../../" + join(work, ".b-agentic", "x.md") }],
    ["write", { path: "@sub/../.b-agentic/state.json", content: "x" }],
  ]) {
    assert.ok(
      blocked(await call(tool, input)),
      `${tool} ${JSON.stringify(input)} must be blocked`,
    );
  }
  assert.equal(await call("read", { path: "@src/index.ts" }), undefined);
});

test("a symlink to a likely-secret file is refused by its target name", async () => {
  writeFileSync(join(work, "plain.txt"), "ok\n");
  symlinkSync(join(work, "plain.txt"), join(work, "to-plain"));
  writeFileSync(join(work, ".env"), "TOKEN=1\n");
  symlinkSync(join(work, ".env"), join(work, "notes-link"));
  const result = await call("read", { path: "notes-link" });
  assert.ok(blocked(result));
  assert.match(result.reason, /likely-secret path/);
  assert.equal(await call("read", { path: "to-plain" }), undefined);
});

test("Pi collapses .. before links apply, and a dangling link resolves to its target", async () => {
  mkdirSync(join(work, "deep", "sub"), { recursive: true });
  symlinkSync(join(work, "deep", "sub"), join(work, "d"));
  symlinkSync(join(work, ".env"), join(work, "envlink"));
  // Pi opens <cwd>/envlink (the .. is collapsed first); the OS order would not.
  assert.equal(piResolve("d/../envlink", work), join(work, ".env"));
  const hidden = await call("read", { path: "d/../envlink" });
  assert.ok(blocked(hidden));
  assert.match(hidden.reason, /likely-secret path/);
  // A write through a dangling link creates its target.
  symlinkSync(
    join(work, ".b-agentic", "runs", "created.md"),
    join(work, "dangling"),
  );
  assert.equal(
    piResolve("dangling", work),
    join(work, ".b-agentic", "runs", "created.md"),
  );
  assert.ok(blocked(await call("write", { path: "dangling", content: "x" })));
  symlinkSync(join(work, "no-such-dir", "key.pem"), join(work, "dangling-pem"));
  assert.ok(
    blocked(await call("write", { path: "dangling-pem", content: "x" })),
  );
  assert.equal(
    await call("write", { path: "new-file.ts", content: "x" }),
    undefined,
  );
});

test("a .. inside a link target applies after the links before it", async () => {
  mkdirSync(join(work, ".b-agentic", "runs"), { recursive: true });
  symlinkSync(join(work, ".b-agentic", "runs"), join(work, "toruns"));
  // Lexically a/../x.md is x.md; the OS expands toruns first, so it lands in .b-agentic.
  symlinkSync("toruns/../created.md", join(work, "nested"));
  assert.equal(
    piResolve("nested", work),
    join(work, ".b-agentic", "created.md"),
  );
  assert.ok(blocked(await call("write", { path: "nested", content: "x" })));
});

// Pi's read tool falls back to other spellings of an absent path.
test("a read fallback spelling that is a link to a secret is refused", async () => {
  writeFileSync(join(work, ".env"), "TOKEN=1\n");
  symlinkSync(join(work, ".env"), join(work, "it\u2019s.txt"));
  const result = await call("read", { path: "it's.txt" });
  assert.ok(blocked(result));
  assert.match(result.reason, /likely-secret path/);
  assert.equal(await call("read", { path: "it's-not-there.txt" }), undefined);
  // Only read falls back; edit and write open the path as written.
  assert.equal(
    await call("write", { path: "it's.txt", content: "x" }),
    undefined,
  );
});

// A directory grep is checked against the files it would search.
const grepWith = async (files, input = { pattern: "x", path: "." }) => {
  const searched = [];
  const g = await createGuard({
    hooksDir,
    listFiles: (request) => {
      searched.push(request);
      if (files instanceof Error) throw files;
      return files;
    },
  });
  return {
    result: await g.toolCall({ toolName: "grep", input }, ctx),
    searched,
  };
};

test("a directory grep that would search a likely-secret file is refused", async () => {
  const { result, searched } = await grepWith(["src/a.ts", ".env.local"]);
  assert.ok(blocked(result));
  assert.match(result.reason, /\.env\.local/);
  assert.equal(searched[0].dir, work);
  for (const name of [
    "weird-1- name.env",
    "foo.env.\nbar",
    "dir\n.env",
    "deep/credentials.json",
  ]) {
    const refused = await grepWith(["ok.ts", name]);
    assert.ok(blocked(refused.result), JSON.stringify(name));
    assert.ok(refused.result.reason.includes(JSON.stringify(name)));
  }
});

test("a directory grep over ordinary files, or narrowed by a glob, passes", async () => {
  assert.equal((await grepWith(["a.ts", ".env.example"])).result, undefined);
  const narrowed = await grepWith(["a.ts"], {
    pattern: "x",
    path: ".",
    glob: "*.ts",
  });
  assert.equal(narrowed.result, undefined);
  assert.equal(narrowed.searched[0].glob, "*.ts");
});

test("a failure to list the search tree refuses the grep", async () => {
  const { result } = await grepWith(new Error("rg is missing"));
  assert.ok(blocked(result));
  assert.match(result.reason, /rg is missing/);
});

test("a grep on one file is checked by name only and lists nothing", async () => {
  writeFileSync(join(work, "one.txt"), "x\n");
  const one = await grepWith(["unused"], { pattern: "x", path: "one.txt" });
  assert.equal(one.result, undefined);
  assert.equal(one.searched.length, 0);
  assert.ok(
    blocked((await grepWith([], { pattern: "x", path: ".env" })).result),
  );
});

test("a malformed input does not crash the guard", async () => {
  assert.equal(await call("read", null), undefined);
  assert.equal(await call("read", { path: 7 }), undefined);
});

// AC-2
test("an unloadable hook module blocks every file tool and the alexandria tool", async () => {
  const broken = await createGuard({
    hooksDir,
    loader: async () => {
      throw new Error("module missing");
    },
  });
  assert.match(broken.loadError, /module missing/);
  for (const tool of [
    ...Object.keys(FILE_TOOLS),
    "mcp__firecrawl__firecrawl_scrape",
  ]) {
    const result = await broken.toolCall(
      { toolName: tool, input: { path: "a.txt" } },
      ctx,
    );
    assert.ok(blocked(result), `${tool} must be blocked`);
    assert.match(result.reason, /guard unavailable/);
  }
  assert.equal(
    await broken.toolCall({ toolName: "bash", input: {} }, ctx),
    undefined,
  );
  assert.equal(broken.userBash({ command: "ls" }).result.exitCode, 1);
  // Child gating can look complete, but a child loads the same broken guard.
  broken.setChildGateError("");
  const child = await broken.toolCall(
    { toolName: "subagent", input: { agent: "b-reviewer" } },
    ctx,
  );
  assert.ok(blocked(child), "a degraded guard must not admit a child");
  assert.match(child.reason, /hook modules failed to load/);
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
        canonicalPath: (path) => path,
      },
      alexandria: { GUARDED_TOOL: "x" },
    }),
  });
  const result = await throwing.toolCall(
    { toolName: "read", input: { path: "a" } },
    ctx,
  );
  assert.ok(blocked(result));
  assert.match(result.reason, /guard error \(boom\)/);
});

test("subagent launches are refused until child gating registers, and when it fails or loses an entry", async () => {
  const solo = { toolName: "subagent", input: { agent: "b-reviewer" } };
  const parallel = {
    toolName: "subagent",
    input: {
      workflow: "parallel",
      args: { tasks: [{ agent: "b-worker", task: "x", cwd: work }] },
    },
  };
  const launch = {
    toolName: "subagent_launch",
    input: { agent: "b-worker", cwd: work },
  };
  const fresh = await createGuard({ hooksDir });
  assert.ok(blocked(await fresh.toolCall(solo, ctx)), "starts closed");
  assert.ok(
    blocked(await fresh.toolCall(parallel, ctx)),
    "parallel starts closed",
  );
  assert.ok(blocked(await fresh.toolCall(launch, ctx)), "launch starts closed");
  assert.match((await fresh.toolCall(solo, ctx)).reason, /not registered yet/);
  fresh.setChildGateError("");
  assert.equal(await fresh.toolCall(solo, ctx), undefined);
  assert.equal(await fresh.toolCall(parallel, ctx), undefined);
  assert.equal(await fresh.toolCall(launch, ctx), undefined);
  fresh.setChildGateError("registration failed");
  assert.ok(blocked(await fresh.toolCall(solo, ctx)));
  assert.ok(blocked(await fresh.toolCall(parallel, ctx)));
  assert.ok(blocked(await fresh.toolCall(launch, ctx)));
  assert.equal(
    await fresh.toolCall({ toolName: "bash", input: {} }, ctx),
    undefined,
  );

  const lost = await createGuard({
    hooksDir,
    childEntries: [join(work, "gone", "entry.js")],
  });
  lost.setChildGateError("");
  const result = await lost.toolCall(solo, ctx);
  assert.ok(blocked(result));
  assert.match(result.reason, /gone.entry\.js is missing/);
});

// AC-3
const userBash = (command) => guard.userBash({ command });

test("user_bash refuses secret paths and returns a refusal result", () => {
  for (const command of [
    "cat .env",
    "cat 'config/.env.production'",
    "grep x < keys/server.pem",
    "scp aws-credentials.json host:",
    "FOO=secrets.yaml cat $FOO",
  ]) {
    const out = userBash(command);
    assert.deepEqual(
      { ...out.result, output: undefined },
      { output: undefined, exitCode: 1, cancelled: false, truncated: false },
      command,
    );
    assert.match(out.result.output, /likely-secret path/);
  }
});

test("user_bash refuses .b-agentic unless the command is plain inspection", () => {
  for (const command of [
    "echo x > .b-agentic/active",
    "echo x > .B-Agentic/active",
    "echo x > .b-agentic*",
    "echo x > .b-agentic.*",
    "echo x > .b-agentic./active",
    "echo x > .b-agentic.",
    "rm -rf .B-AGENTIC/runs",
    "rm -rf .b-agentic/runs",
    "sed -i s/a/b/ .b-agentic/runs/x/state.json",
  ]) {
    const out = userBash(command);
    assert.equal(out.result.exitCode, 1, command);
    assert.match(out.result.output, /\.b-agentic/);
  }
  for (const command of [
    "ls .b-agentic",
    "ls .B-AGENTIC",
    "touch .B-Agentic.md",
    "touch .b-agentic.md",
    "cat .b-agentic/runs/x/spec.md",
    "git status --short",
    "npm test",
    "cat .env.example",
  ]) {
    assert.equal(userBash(command), undefined, command);
  }
});

test("user_bash never throws on odd input", () => {
  for (const command of [undefined, null, 7, {}]) {
    assert.equal(userBash(command), undefined);
  }
});

test("a user_bash guard error refuses instead of throwing", async () => {
  const failing = await createGuard({
    hooksDir,
    loader: async () => ({
      pathGuard: {
        blockedPaths() {
          throw new Error("boom");
        },
      },
    }),
  });
  const out = failing.userBash({ command: "ls" });
  assert.equal(out.result.exitCode, 1);
  assert.match(out.result.output, /guard error \(boom\)/);
});

// AC-4
const edited = (path, isError = false, g = guard) =>
  g.toolResult({ toolName: "write", input: { path }, isError });
const settle = (g = guard, outcome = "completed") =>
  g.beforeSettle({ outcome, entries: [{ keep: true }] });
const withMode = async (mode, fn) => {
  const previous = process.env.B_AGENTIC_GATE_MODE;
  if (mode === undefined) delete process.env.B_AGENTIC_GATE_MODE;
  else process.env.B_AGENTIC_GATE_MODE = mode;
  try {
    return await fn();
  } finally {
    if (previous === undefined) delete process.env.B_AGENTIC_GATE_MODE;
    else process.env.B_AGENTIC_GATE_MODE = previous;
  }
};

test("the verify gate reminds once after an edit and then lets the run settle", async () => {
  await withMode(undefined, () => {
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
});

test("prose edits, failed edits, and inspection shell commands do not arm or clear it", async () => {
  await withMode(undefined, () => {
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
});

test("an aborted or failed run is not reminded", async () => {
  await withMode(undefined, () => {
    edited("src/a.ts");
    for (const outcome of ["aborted", "error"]) {
      assert.equal(settle(guard, outcome), undefined, outcome);
    }
    guard.settled();
  });
});

test("gate modes off and observe give no reminder", async () => {
  for (const mode of ["off", "observe"]) {
    await withMode(mode, () => {
      guard.settled();
      edited("src/a.ts");
      assert.equal(settle(), undefined, mode);
      guard.settled();
    });
  }
  await withMode("typo", () => {
    guard.settled();
    edited("src/a.ts");
    assert.ok(settle(), "an unknown mode is enforce");
    guard.settled();
  });
});

// AC-5: context injection equals the Claude hook output for the same project.
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
  assert.ok(expectedRun && expectedSpec, "fixture builds both contexts");
  for (const reason of ["startup", "resume", "new"]) {
    guard.sessionStart(reason, project);
    const queued = guard.takeContext();
    assert.equal(queued.content, expectedRun, reason);
    assert.equal(queued.display, false);
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

// AC-6
const scrape = (input) => ({
  toolName: "mcp__firecrawl__firecrawl_scrape",
  input,
});

test("an alexandria argument asks through ctx.ui.confirm and is blocked headless", async () => {
  const asked = [];
  const ui = (answer) => ({
    cwd: work,
    hasUI: true,
    ui: {
      confirm: async (...args) => {
        asked.push(args);
        return answer;
      },
    },
  });
  const withArg = scrape({ url: "https://x.test", alexandria: { q: 1 } });
  assert.equal(await guard.toolCall(withArg, ui(true)), undefined);
  assert.equal(asked.length, 1);
  assert.ok(blocked(await guard.toolCall(withArg, ui(false))));
  assert.ok(blocked(await guard.toolCall(withArg, ctx)), "headless");
  assert.ok(
    blocked(await guard.toolCall(withArg, { cwd: work, hasUI: true, ui: {} })),
    "no confirm function",
  );
  const throwing = {
    cwd: work,
    hasUI: true,
    ui: {
      confirm() {
        throw new Error("prompt failed");
      },
    },
  };
  assert.ok(blocked(await guard.toolCall(withArg, throwing)));
});

test("firecrawl_scrape without an alexandria argument is not asked", async () => {
  assert.equal(
    await guard.toolCall(scrape({ url: "https://x.test" }), ctx),
    undefined,
  );
  assert.equal(
    await guard.toolCall(scrape({ url: "u", alexandria: null }), ctx),
    undefined,
  );
});

// AC-7
const REGISTRATIONS = [];
const fakeBundle = {
  registerRequiredChildExtensions(options) {
    const entry = { options, disposed: false };
    REGISTRATIONS.push(entry);
    return {
      dispose() {
        entry.disposed = true;
      },
    };
  },
};
const touch = (path) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, "export default 1;\n");
};
const subagentsEntry = (dir) =>
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
const entryPath = join(root, "pi", "extensions", "b-agentic", "index.ts");
const fakePi = () => {
  const handlers = {};
  return {
    handlers,
    on(name, handler) {
      handlers[name] = handler;
    },
  };
};
const sessionCtx = {
  cwd: work,
  hasUI: false,
  sessionManager: { getSessionId: () => "session-1" },
};
const loaded = async (name, { subagents, permission, bundle = fakeBundle }) => {
  const agentDir = join(work, `agent-${name}`);
  mkdirSync(agentDir, { recursive: true });
  if (subagents) touch(subagentsEntry(agentDir));
  if (permission) touch(permissionEntry(agentDir));
  const pi = fakePi();
  REGISTRATIONS.length = 0;
  await register(pi, {
    version: "1.6.0",
    entryPath,
    hooksDir,
    agentDir,
    importModule: async () => bundle,
  });
  return {
    agentDir,
    pi,
    start: () => pi.handlers.session_start({ reason: "startup" }, sessionCtx),
    subagent: () =>
      pi.handlers.tool_call(
        { toolName: "subagent", input: { agent: "b-reviewer" } },
        sessionCtx,
      ),
  };
};
const refusedFor = (result, pattern) => {
  assert.ok(blocked(result), "the subagent launch must be refused");
  assert.match(result.reason, /child sessions cannot be gated/);
  assert.match(result.reason, pattern);
};

test("a Pi version below the floor, or a missing event API, throws at load", async () => {
  for (const version of ["1.5.9", "0.99.0", "", "dev"]) {
    await assert.rejects(
      register(fakePi(), { version, entryPath, hooksDir }),
      /needs Pi 1\.6\.0 or newer/,
      version,
    );
  }
  await assert.rejects(
    register({}, { version: "1.6.0", entryPath, hooksDir }),
    /event API/,
  );
  assert.equal(atLeast("1.6.0"), true);
  assert.equal(atLeast("1.10.2"), true);
  assert.equal(atLeast("2.0.0"), true);
  assert.equal(atLeast("1.6.0-beta.1"), true);
  assert.equal(atLeast("1.5.99"), false);
});

test("register wires every event the guard uses", async () => {
  const run = await loaded("wired", { subagents: true, permission: true });
  assert.deepEqual(Object.keys(run.pi.handlers).sort(), [
    "agent_before_settle",
    "agent_settled",
    "before_agent_start",
    "session_compact",
    "session_shutdown",
    "session_start",
    "tool_call",
    "tool_result",
    "user_bash",
  ]);
  assert.equal(run.pi.handlers.before_agent_start(), undefined);
});

test("with both entries the guard and the permission system are required for every child", async () => {
  const run = await loaded("complete", { subagents: true, permission: true });
  refusedFor(await run.subagent(), /not registered yet/);
  await run.start();
  assert.deepEqual(
    REGISTRATIONS.map((entry) => entry.options),
    [
      {
        sessionId: "session-1",
        extensions: [
          { id: "b-agentic-guard", path: entryPath },
          { id: "pi-permission-system", path: permissionEntry(run.agentDir) },
        ],
        requireForAllRunners: true,
      },
    ],
  );
  assert.equal(await run.subagent(), undefined, "a gated launch is allowed");
  await run.pi.handlers.session_shutdown();
  assert.equal(REGISTRATIONS[0].disposed, true);
});

test("a missing package entry or a failing registration refuses subagent launches", async () => {
  const none = await loaded("no-subagents", { permission: true });
  await none.start();
  refusedFor(await none.subagent(), /pi-subagents/);

  const alone = await loaded("no-permission", { subagents: true });
  await alone.start();
  refusedFor(await alone.subagent(), /pi-permission-system/);
  assert.deepEqual(REGISTRATIONS, [], "the guard is never registered alone");

  const noExport = await loaded("no-export", {
    subagents: true,
    permission: true,
    bundle: {},
  });
  await noExport.start();
  refusedFor(await noExport.subagent(), /registerRequiredChildExtensions/);

  const throwing = await loaded("throwing", {
    subagents: true,
    permission: true,
    bundle: {
      registerRequiredChildExtensions() {
        throw new Error("registration exploded");
      },
    },
  });
  await throwing.start();
  refusedFor(await throwing.subagent(), /registration exploded/);
});

test("a package entry that disappears after registration refuses launches again", async () => {
  const run = await loaded("lost", { subagents: true, permission: true });
  await run.start();
  assert.equal(await run.subagent(), undefined);
  rmSync(permissionEntry(run.agentDir));
  refusedFor(await run.subagent(), /pi-permission-system/);
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
