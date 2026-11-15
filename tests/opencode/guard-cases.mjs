// Cases for the OpenCode guard core (opencode/guard.mjs). Needs only bun: no OpenCode,
// network, or credentials. The hook modules come from claude/hooks, the same files the
// installer copies next to the plugin. Run: bun --no-env-file --config=/dev/null tests/opencode/guard-cases.mjs
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createGuard, FILE_TOOLS, patchPaths } from "../../opencode/guard.mjs";

const root = fileURLToPath(new URL("../..", import.meta.url));
const hooksDir = join(root, "claude", "hooks");
const work = mkdtempSync(join(tmpdir(), "opencode-guard-"));
// The Codex guard keeps its approval store here, never in the real home.
process.env.B_AGENTIC_STATE_DIR = join(work, "state");
const cases = [];
const test = (name, fn) => cases.push([name, fn]);

const guard = await createGuard({ hooksDir });
const call = async (tool, input, extra = {}, cwd = work) =>
  guard.toolBefore(
    { tool, input, sessionID: "ses_main", agent: "build", ...extra },
    cwd,
  );
const blocked = (result) => result?.block === true;

test("hook modules load from claude/hooks", async () => {
  assert.equal(guard.loadError, "");
});

test("secret paths are blocked for every file tool", async () => {
  for (const [tool, input] of [
    ["read", { path: "/repo/.env" }],
    ["read", { filePath: "/repo/.env" }],
    [
      "edit",
      { path: "config/.env.production", oldString: "a", newString: "b" },
    ],
    ["write", { path: "keys/server.pem", content: "x" }],
    ["grep", { pattern: "x", path: "aws-credentials.json" }],
    ["grep", { pattern: "x", include: "**/secrets.yaml" }],
    ["read", { path: "/repo/.ENV" }],
    ["read", { path: "/repo/Credentials.json" }],
    ["read", { path: "/repo/SECRETS.yaml" }],
    ["write", { path: "keys/server.PEM", content: "x" }],
    ["glob", { pattern: "**/.env" }],
    [
      "patch",
      {
        patchText:
          "*** Begin Patch\n*** Update File: app/.env.local\n*** End Patch",
      },
    ],
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
    ["read", { path: ".ENV.example" }],
    ["edit", { path: "README.md", oldString: "a", newString: "b" }],
    ["grep", { pattern: "x", include: "*.ts" }],
    ["glob", { pattern: "*.md" }],
    [
      "patch",
      {
        patchText: "*** Begin Patch\n*** Add File: src/a.ts\n+x\n*** End Patch",
      },
    ],
  ]) {
    assert.equal(
      await call(tool, input),
      undefined,
      `${tool} ${JSON.stringify(input)}`,
    );
  }
});

test("tools outside the file tools are not path-checked", async () => {
  assert.equal(await call("shell", { command: "cat .env" }), undefined);
  assert.equal(await call("fake_lookup", { path: ".env" }), undefined);
});

test("patchPaths reads every file a patch names", async () => {
  assert.deepEqual(
    patchPaths(
      "*** Begin Patch\n*** Add File: a.ts\n+x\n*** Update File: b.ts\n*** Move to: c.ts\n*** Delete File: d.ts\n*** End Patch",
    ),
    ["a.ts", "b.ts", "c.ts", "d.ts"],
  );
  assert.deepEqual(patchPaths(undefined), []);
});

test(".b-agentic writes are blocked and reads are allowed", async () => {
  for (const [tool, input] of [
    ["edit", { path: ".b-agentic/runs/x/spec.md" }],
    ["write", { path: ".b-agentic/runs/x/spec.md" }],
    ["patch", { patchText: "*** Update File: .b-agentic/runs/x/state.json" }],
  ]) {
    const result = await call(tool, input);
    assert.ok(blocked(result), `${tool} on .b-agentic must be blocked`);
    assert.match(result.reason, /b_run\.py/);
  }
  assert.equal(
    await call("read", { path: ".b-agentic/runs/x/spec.md" }),
    undefined,
  );
});

test("symlinks and .. cannot hide .b-agentic", async () => {
  mkdirSync(join(work, ".b-agentic", "runs"), { recursive: true });
  symlinkSync(join(work, ".b-agentic"), join(work, "link"));
  assert.ok(
    blocked(await call("write", { path: "link/runs/x.md", content: "x" })),
  );
  assert.ok(
    blocked(await call("edit", { path: "sub/../.b-agentic/state.json" })),
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
    const input =
      tool === "patch"
        ? { patchText: "*** Update File: a.txt" }
        : { path: "a.txt" };
    const result = await broken.toolBefore(
      { tool, input, sessionID: "s", agent: "build" },
      work,
    );
    assert.ok(blocked(result), `${tool} must be blocked`);
    assert.match(result.reason, /guard unavailable/);
  }
  assert.equal(
    await broken.toolBefore({ tool: "shell", input: {}, sessionID: "s" }, work),
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
  const result = await throwing.toolBefore(
    { tool: "read", input: { path: "a" } },
    work,
  );
  assert.ok(blocked(result));
  assert.match(result.reason, /guard error \(boom\)/);
});

test("a malformed input does not crash the guard", async () => {
  assert.equal(await call("read", null), undefined);
  assert.equal(await call("read", { path: 7 }), undefined);
});

const edited = (path, extra = {}) =>
  call("write", { path, content: "x" }, extra);
const ran = (command, extra = {}) => call("shell", { command }, extra);

test("the verify gate reminds once after an edit and then lets the run settle", async () => {
  guard.executionStarted("ses_main");
  await edited("src/a.ts");
  assert.match(guard.reminder("ses_main"), /verify gate/);
  await edited("src/b.ts");
  assert.equal(
    guard.reminder("ses_main"),
    undefined,
    "no second reminder in the same run",
  );
  guard.executionStarted("ses_main"); // the reminder turn itself
  assert.equal(guard.reminder("ses_main"), undefined);
  guard.executionStarted("ses_main"); // a user-driven run resets the gate
  await edited("src/c.ts");
  assert.match(guard.reminder("ses_main"), /verify gate/);
  guard.executionStarted("ses_main");
});

test("prose edits and inspection shell commands do not clear it; a real command does", async () => {
  guard.executionStarted("ses_main");
  await edited("notes.md");
  assert.equal(guard.reminder("ses_main"), undefined, "prose edit never arms");
  await edited("src/a.ts");
  await ran("rg foo src");
  assert.ok(guard.reminder("ses_main"), "inspection must not count as a check");
  guard.executionStarted("ses_main");
  guard.executionStarted("ses_main");
  await edited("src/a.ts");
  await ran("npm test");
  assert.equal(
    guard.reminder("ses_main"),
    undefined,
    "a real command counts as a check",
  );
});

test("a child session edit never arms the gate", async () => {
  guard.executionStarted("ses_child");
  await edited("src/a.ts", { sessionID: "ses_child", agent: "b-worker" });
  assert.equal(guard.reminder("ses_child"), undefined);
  await edited("src/a.ts", { sessionID: "ses_child", agent: "general" });
  assert.equal(guard.reminder("ses_child"), undefined);
});

test("shell: a self-approval or a direct companion call is refused, plain commands pass", async () => {
  const approve = `bun --no-env-file --config=/dev/null ${join(hooksDir, "b-codex-guard.mjs")} --approve`;
  const asked = await call("shell", { command: approve });
  assert.ok(blocked(asked), "the approval store is changed only by the user");
  assert.match(asked.reason, /Only the user may record/);
  assert.equal(
    asked.reason.match(/b-agentic Codex guard:/g).length,
    1,
    "the guard prefix appears once",
  );
  for (const revoke of [
    `bun --no-env-file --config=/dev/null ${join(hooksDir, "b-codex-guard.mjs")} --revoke`,
    `node ${join(hooksDir, "b-codex-gu''ard.mjs")} --revoke`,
  ]) {
    const revoked = await call("shell", { command: revoke });
    assert.ok(blocked(revoked), `removing the approval is refused: ${revoke}`);
    assert.match(revoked.reason, /Only the user may record or change/);
    assert.equal(revoked.reason.match(/b-agentic Codex guard:/g).length, 1);
  }
  const direct = await call("shell", {
    command:
      "node /home/u/.claude/plugins/cache/openai-codex/codex/1.0.6/scripts/codex-companion.mjs adversarial-review",
  });
  assert.ok(
    blocked(direct),
    "a direct companion call needs the guard's approval",
  );
  assert.match(direct.reason, /Codex guard refused/);
  assert.equal(
    await call("shell", { command: "git status --short" }),
    undefined,
  );
  assert.equal(await call("shell", { command: "rg foo src" }), undefined);
});

test("shell: every fallback refuses a command, including a quote-split Codex one", async () => {
  const split = [
    'node /tmp/codex-compan""ion.mjs adversarial-review --scope working-tree',
    "bun /x/b-codex-gu''ard.mjs --approve",
    "ls",
  ];
  const raise = await createGuard({
    hooksDir,
    loader: async () => ({
      pathGuard: { agenticWrites: () => [], blockedPaths: () => [] },
      verifyGate: { isInspection: () => true, PROSE_PATH: /\.md$/ },
      codexGuard: {
        judgeCommand() {
          throw new Error("boom");
        },
      },
    }),
  });
  const missing = await createGuard({
    hooksDir,
    loader: async () => {
      throw new Error("module missing");
    },
  });
  const real = await createGuard({ hooksDir });
  for (const command of split) {
    const input = { command };
    assert.ok(
      blocked(
        await raise.toolBefore(
          { tool: "shell", input, sessionID: "s", agent: "build" },
          work,
        ),
      ),
      `judge error: ${command}`,
    );
    assert.ok(
      blocked(await missing.toolBefore({ tool: "shell", input }, work)),
      `missing module: ${command}`,
    );
    assert.ok(
      blocked(
        await real.toolBefore(
          {
            tool: "shell",
            input: { command, workdir: 7 },
            sessionID: "s",
            agent: "build",
          },
          work,
        ),
      ),
      `invalid workdir: ${command}`,
    );
  }
  assert.equal(
    await missing.toolBefore({ tool: "shell", input: {} }, work),
    undefined,
    "a shell call without a command string is not a command",
  );
});

test("the Codex approval store cannot be written by a file tool, through any name", async () => {
  const store = join(work, "state", "codex-approved-repos.json");
  mkdirSync(join(work, "state"), { recursive: true });
  writeFileSync(store, "[]\n");
  symlinkSync(store, join(work, "alias.json"));
  for (const [tool, input] of [
    ["write", { path: store, content: "[]" }],
    ["edit", { path: store, oldString: "[", newString: "[1" }],
    ["patch", { patchText: `*** Update File: ${store}` }],
    ["write", { path: "alias.json", content: "[]" }],
    [
      "write",
      { path: "sub/../state/codex-approved-repos.json", content: "[]" },
    ],
    ["write", { path: "/elsewhere/codex-approved-repos.json", content: "[]" }],
  ]) {
    const result = await call(tool, input);
    assert.ok(
      blocked(result),
      `${tool} ${JSON.stringify(input)} must be blocked`,
    );
    assert.match(result.reason, /Only the user records/);
  }
  assert.equal(
    await call("read", { path: store }),
    undefined,
    "reading the store stays allowed",
  );
});

test("shell: the workdir, not the session directory, decides which repository a Codex call targets", async () => {
  const git = (dir) => {
    mkdirSync(dir, { recursive: true });
    execFileSync("git", ["init", "-q", dir]);
    return realpathSync(dir);
  };
  const approved = git(join(work, "repo-a"));
  const other = git(join(work, "repo-b"));
  writeFileSync(
    join(work, "state", "codex-approved-repos.json"),
    JSON.stringify([approved]) + "\n",
  );
  const command =
    "node /home/u/.claude/plugins/cache/openai-codex/codex/1.0.6/scripts/codex-companion.mjs adversarial-review";
  const here = await call("shell", { command }, {}, approved);
  const there = await call("shell", { command, workdir: other }, {}, approved);
  const relative = await call(
    "shell",
    { command, workdir: "../repo-b" },
    {},
    approved,
  );
  assert.ok(blocked(there), "an unapproved workdir must be judged on its own");
  assert.ok(
    blocked(relative),
    "a relative workdir resolves against the session directory",
  );
  assert.notEqual(
    JSON.stringify(here),
    JSON.stringify(there),
    "the approved directory and the workdir must not be judged alike",
  );
  assert.ok(
    blocked(await call("shell", { command, workdir: 7 }, {}, approved)),
    "a workdir that is not a path cannot be judged",
  );
  assert.equal(
    await call("shell", { command: "ls", workdir: other }, {}, approved),
    undefined,
  );
});

test("patch: indented headers are read as OpenCode reads them, and an unreadable patch is refused", async () => {
  for (const header of [
    "  *** Update File: .env.production",
    "\t*** Add File: keys/server.pem",
    "   *** Delete File: config/credentials.json",
    "  *** Move to: app/.env.local",
  ]) {
    const result = await call("patch", {
      patchText: `*** Begin Patch\n${header}\n*** End Patch`,
    });
    assert.ok(blocked(result), `${JSON.stringify(header)} must be blocked`);
    assert.match(result.reason, /likely-secret path/);
  }
  assert.deepEqual(
    patchPaths("*** Begin Patch\n   *** Update File: a.ts  \n*** End Patch"),
    ["a.ts"],
  );
  for (const patchText of [
    "",
    "*** Begin Patch\n*** End Patch",
    "no headers here",
  ]) {
    const result = await call("patch", { patchText });
    assert.ok(
      blocked(result),
      `${JSON.stringify(patchText)} names no file and must be refused`,
    );
    assert.match(result.reason, /cannot be determined/);
  }
  assert.equal(
    await call("patch", { patchText: "  *** Add File: src/a.ts\n+x" }),
    undefined,
  );
});

test("grep: a relative directory is listed once, not once per spelling", async () => {
  const repo = join(work, "grep-once");
  mkdirSync(join(repo, "src"), { recursive: true });
  writeFileSync(join(repo, "src", "a.ts"), "x\n");
  const realRg = execFileSync("sh", ["-c", "command -v rg"], {
    encoding: "utf8",
  }).trim();
  const shimDir = join(work, "rg-shim");
  const counter = join(work, "rg-count");
  mkdirSync(shimDir, { recursive: true });
  writeFileSync(counter, "");
  writeFileSync(
    join(shimDir, "rg"),
    `#!/bin/sh\necho x >> '${counter}'\nexec '${realRg}' "$@"\n`,
    { mode: 0o755 },
  );
  const savedPath = process.env.PATH;
  process.env.PATH = `${shimDir}:${savedPath}`;
  try {
    assert.equal(
      await call("grep", { pattern: "x", path: "src" }, {}, repo),
      undefined,
    );
  } finally {
    process.env.PATH = savedPath;
  }
  const listings = execFileSync("wc", ["-l", counter], { encoding: "utf8" })
    .trim()
    .split(/\s+/)[0];
  assert.equal(listings, "1", "one rg listing for one resolved directory");
});

test("grep: a directory search that would read a protected-name file is refused, as ripgrep would list it", async () => {
  const repo = join(work, "grep-repo");
  mkdirSync(join(repo, "config"), { recursive: true });
  mkdirSync(join(repo, "src"), { recursive: true });
  execFileSync("git", ["init", "-q", repo]);
  writeFileSync(
    join(repo, "config", "credentials.json"),
    '{"canary": "not-a-secret"}\n',
  );
  writeFileSync(join(repo, "config", "app.json"), "{}\n");
  writeFileSync(join(repo, "src", "a.ts"), "x\n");
  writeFileSync(join(repo, ".env.local"), "HIDDEN=1\n");
  const grep = (input) => call("grep", input, {}, repo);
  const reached = await grep({
    pattern: ".",
    path: "config",
    include: "*.json",
  });
  assert.ok(
    blocked(reached),
    "a broad glob over a directory with credentials.json must be refused",
  );
  assert.match(reached.reason, /credentials\.json/);
  assert.ok(
    blocked(await grep({ pattern: ".", path: "config" })),
    "no include means every file",
  );
  assert.ok(
    blocked(await grep({ pattern: ".+", path: "." })),
    "ripgrep runs with --hidden, so .env.local is searched",
  );
  assert.ok(
    blocked(await grep({ pattern: ".", path: "config", include: "[c]*.json" })),
    "a character class selects credentials.json",
  );
  assert.ok(
    blocked(await grep({ pattern: ".", path: "config", include: "!*.ts" })),
    "a negative glob selects credentials.json",
  );
  assert.equal(
    await grep({ pattern: "x", path: "src" }),
    undefined,
    "a clean directory is searched",
  );
  assert.equal(
    await grep({ pattern: ".", path: "config", include: "*.ts" }),
    undefined,
    "include excludes the protected name",
  );
  assert.equal(
    await grep({ pattern: ".", path: "config", include: "!*.json" }),
    undefined,
    "a negative glob can exclude it",
  );
  assert.equal(
    await grep({ pattern: "x", path: "config/app.json" }),
    undefined,
    "a single clean file is searched",
  );
  assert.equal(
    await grep({ pattern: "x", path: ".", include: "src/**" }),
    undefined,
  );
  writeFileSync(
    join(repo, ".gitignore"),
    "config/credentials.json\n.env.local\n",
  );
  assert.equal(
    await grep({ pattern: ".", path: "config" }),
    undefined,
    "an ignored file is not searched",
  );
  assert.equal(await grep({ pattern: ".", path: "." }), undefined);
  const path = process.env.PATH;
  process.env.PATH = join(work, "no-such-bin");
  try {
    assert.ok(
      blocked(await grep({ pattern: "x", path: "src" })),
      "without ripgrep the listing is unknown, so the search is refused",
    );
  } finally {
    process.env.PATH = path;
  }
});

test("home-relative paths are expanded like OpenCode expands them", async () => {
  const home = join(work, "home");
  mkdirSync(join(home, "project", "config"), { recursive: true });
  mkdirSync(join(home, ".b-agentic"), { recursive: true });
  writeFileSync(
    join(home, "project", "config", "credentials.json"),
    '{"canary": "not-a-secret"}\n',
  );
  const saved = process.env.HOME;
  process.env.HOME = home;
  try {
    for (const path of [
      "~/project/config",
      "$HOME/project/config",
      "${HOME}/project/config",
    ]) {
      const result = await call("grep", {
        pattern: ".+",
        path,
        include: "*.json",
      });
      assert.ok(
        blocked(result),
        `${path} must be scanned as the expanded directory`,
      );
      assert.match(result.reason, /credentials\.json/);
    }
    assert.ok(
      blocked(
        await call("grep", { pattern: ".+", path: "~", include: "project/**" }),
      ),
      "~ itself expands",
    );
    assert.ok(
      blocked(
        await call("write", { path: "~/.b-agentic/state.json", content: "x" }),
      ),
      "a home-relative .b-agentic write",
    );
    assert.ok(
      blocked(
        await call("patch", {
          patchText: "*** Update File: ~/project/config/credentials.json",
        }),
      ),
    );
    assert.equal(
      await call("read", { path: "~/project/notes.txt" }),
      undefined,
    );
  } finally {
    if (saved === undefined) delete process.env.HOME;
    else process.env.HOME = saved;
  }
});

test("a symlink plus dot-dot plus an alias into .b-agentic is judged the way OpenCode resolves it", async () => {
  const base = join(work, "alias-case");
  const outside = join(base, "outside", "child");
  mkdirSync(outside, { recursive: true });
  mkdirSync(join(base, "repo", ".b-agentic", "runs", "r"), { recursive: true });
  symlinkSync(outside, join(base, "repo", "step"));
  symlinkSync(
    join(base, "repo", ".b-agentic"),
    join(base, "repo", "run-files"),
  );
  const repo = join(base, "repo");
  const alias = "step/../run-files/runs/r/spec.md";
  for (const [tool, input] of [
    ["write", { path: alias, content: "x" }],
    ["edit", { path: alias, oldString: "a", newString: "b" }],
    ["patch", { patchText: `*** Update File: ${alias}` }],
  ]) {
    const result = await call(tool, input, {}, repo);
    assert.ok(blocked(result), `${tool} through ${alias} must be blocked`);
    assert.match(result.reason, /b_run\.py/);
  }
  assert.equal(
    await call("write", { path: "step/../notes.txt", content: "x" }, {}, repo),
    undefined,
  );
});

test("HOME variables stay literal in OpenCode, and the guard judges the literal and the expanded directory", async () => {
  const home = join(work, "home2");
  const repo = join(work, "literal-repo");
  mkdirSync(join(home, "config"), { recursive: true });
  mkdirSync(join(repo, "$HOME", "config"), { recursive: true });
  writeFileSync(
    join(repo, "$HOME", "config", "credentials.json"),
    '{"canary": "not-a-secret"}\n',
  );
  const saved = process.env.HOME;
  process.env.HOME = home;
  try {
    for (const path of ["$HOME/config", "${HOME}/config"]) {
      const literal = path.startsWith("${") ? "${HOME}" : "$HOME";
      mkdirSync(join(repo, literal, "config"), { recursive: true });
      writeFileSync(join(repo, literal, "config", "credentials.json"), "{}\n");
      const result = await call(
        "grep",
        { pattern: ".+", path, include: "*.json" },
        {},
        repo,
      );
      assert.ok(
        blocked(result),
        `${path} must scan the literal directory OpenCode searches`,
      );
      assert.match(result.reason, /credentials\.json/);
    }
  } finally {
    if (saved === undefined) delete process.env.HOME;
    else process.env.HOME = saved;
  }
});

// Context injection equals the Claude hook output for the same project.
const project = join(work, "project");
mkdirSync(join(project, "docs", "specs"), { recursive: true });
writeFileSync(
  join(project, "docs", "specs", "feature.md"),
  "# Feature\n\nStatus: approved\n",
);
const runId = "20261115-demo";
mkdirSync(join(project, ".b-agentic", "runs", runId), { recursive: true });
writeFileSync(join(project, ".b-agentic", "active"), `${runId}\n`);
writeFileSync(
  join(project, ".b-agentic", "runs", runId, "state.json"),
  JSON.stringify({ run_id: runId, phase: "implement" }),
);
const specHook = await import(join(hooksDir, "b-spec-context.mjs"));
const runHook = await import(join(hooksDir, "b-run-context.mjs"));
const expected = [
  specHook.buildContext(specHook.approvedSpecs(project)),
  runHook.buildContext(runHook.activeRun(project)),
]
  .filter(Boolean)
  .join("\n");

test("context is queued once per session, then again on request, and clears when taken", async () => {
  assert.equal(guard.firstCall("ses_ctx"), true);
  assert.equal(guard.firstCall("ses_ctx"), false);
  guard.queueContext("ses_ctx", project);
  assert.equal(guard.takeContext("ses_ctx"), expected);
  assert.equal(guard.takeContext("ses_ctx"), undefined);
});

test("a project without specs or a run queues nothing", async () => {
  guard.queueContext("ses_none", work);
  assert.equal(guard.takeContext("ses_none"), undefined);
});

let failed = 0;
for (const [name, fn] of cases) {
  try {
    await fn();
    console.log(`ok - ${name}`);
  } catch (error) {
    failed += 1;
    console.log(`not ok - ${name}\n${error?.stack ?? error}`);
  }
}
rmSync(work, { recursive: true, force: true });
if (failed > 0) {
  console.log(`${failed} of ${cases.length} cases failed`);
  process.exit(1);
}
console.log(`${cases.length} cases passed`);
