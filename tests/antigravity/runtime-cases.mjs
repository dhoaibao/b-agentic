#!/usr/bin/env bun
// Behavior cases for the Antigravity CLI runtime parts that live in claude/bin: the lock owner
// fallback, the prune hint, the worker-profile check, and the Codex companion environment.
// Everything runs in a temporary directory with a temporary HOME, and the child processes get an
// explicit environment so this session's own variables never leak in. Exits non-zero on the first
// failed expectation.
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { companionEnv } from "../../claude/bin/b-codex-review.mjs";
import { HINT_RUNS } from "../../claude/bin/b-state-core.mjs";
import { defaultOwner, runsHint } from "../../claude/bin/b-state-store.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const scratch = mkdtempSync(join(tmpdir(), "b-agy-runtime-"));
const savedEnv = { ...process.env };

let passed = 0;
function expect(label, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    console.error(`FAIL ${label}\n  expected ${e}\n  actual   ${a}`);
    rmSync(scratch, { recursive: true, force: true });
    process.exit(1);
  }
  passed += 1;
}

function withEnv(values, run) {
  for (const key of ["CLAUDE_CODE_SESSION_ID", "ANTIGRAVITY_CONVERSATION_ID"]) {
    delete process.env[key];
  }
  Object.assign(process.env, values);
  try {
    return run();
  } finally {
    for (const key of Object.keys(process.env)) delete process.env[key];
    Object.assign(process.env, savedEnv);
  }
}

// --- lock owner: Claude Code first, then the Antigravity conversation id ---
const owner = (env, args = {}) =>
  withEnv(env, () => {
    try {
      return defaultOwner(args);
    } catch (error) {
      return `invalid: ${error.message.includes("--owner")}`;
    }
  });
expect(
  "agy owner",
  owner({ ANTIGRAVITY_CONVERSATION_ID: "agy-conv-1" }),
  "agy-conv-1",
);
expect(
  "claude wins",
  owner({
    CLAUDE_CODE_SESSION_ID: "claude-s-1",
    ANTIGRAVITY_CONVERSATION_ID: "agy-conv-1",
  }),
  "claude-s-1",
);
expect("no owner", owner({}), "invalid: true");
expect(
  "explicit owner wins",
  owner({ ANTIGRAVITY_CONVERSATION_ID: "agy-conv-1" }, { owner: "named" }),
  "named",
);

// --- prune hint names the agy path only under agy ---
const runsRoot = join(scratch, "hint");
for (let i = 0; i <= HINT_RUNS; i += 1) {
  mkdirSync(join(runsRoot, ".b-agentic", "runs", `20260101-run-${String(i)}`), {
    recursive: true,
  });
}
const hint = (env) => withEnv(env, () => runsHint(runsRoot));
expect(
  "hint on agy",
  hint({ ANTIGRAVITY_CONVERSATION_ID: "agy-conv-1" }).includes(
    "~/.gemini/config/b-agentic/bin/b_run.py prune",
  ),
  true,
);
expect(
  "hint on claude",
  hint({}).includes("~/.claude/b-agentic/bin/b_run.py prune"),
  true,
);
expect(
  "hint with both",
  hint({
    CLAUDE_CODE_SESSION_ID: "claude-s-1",
    ANTIGRAVITY_CONVERSATION_ID: "agy-conv-1",
  }).includes("~/.claude/b-agentic/bin/b_run.py prune"),
  true,
);

// --- worker-profile checks the agy agent folders under agy ---
const home = join(scratch, "home");
const repo = join(scratch, "repo");
mkdirSync(home);
mkdirSync(repo);
const childEnv = (extra = {}) => ({
  PATH: process.env.PATH,
  HOME: home,
  LANG: "C",
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_CONFIG_SYSTEM: "/dev/null",
  ...extra,
});
const run = (command, args, env, cwd = repo) =>
  spawnSync(command, args, { cwd, env, encoding: "utf8" });
run("git", ["init", "-q"], childEnv());

const generated = readFileSync(
  join(root, "antigravity", "agents", "b-worker.md"),
  "utf8",
);
const place = (folder, text) => {
  rmSync(join(repo, ".agents"), { recursive: true, force: true });
  rmSync(join(repo, ".claude"), { recursive: true, force: true });
  rmSync(join(home, ".gemini"), { recursive: true, force: true });
  mkdirSync(folder, { recursive: true });
  writeFileSync(join(folder, "b-worker.md"), text);
};
const profile = (env) => {
  const result = run(
    "python3",
    ["-I", "-B", join(root, "claude", "bin", "b_run.py"), "worker-profile"],
    childEnv(env),
  );
  return JSON.parse(result.stdout);
};
const agy = { ANTIGRAVITY_CONVERSATION_ID: "agy-conv-1" };

place(join(repo, ".agents", "agents"), generated);
let result = profile(agy);
expect(
  "project profile",
  [result.ok, result.source, result.profiles],
  [true, "project", 1],
);

place(join(home, ".gemini", "config", "agents"), generated);
result = profile(agy);
expect(
  "user profile",
  [result.ok, result.source, result.profiles],
  [true, "user", 1],
);

place(
  join(repo, ".agents", "agents"),
  generated.replace("run_command]", "run_command, call_mcp_tool]"),
);
result = profile(agy);
expect("call_mcp_tool refused", result.ok, false);
expect(
  "call_mcp_tool named",
  result.problems.some((problem) => problem.includes("call_mcp_tool")),
  true,
);

place(
  join(repo, ".agents", "agents"),
  generated.replace("model: inherit", "model: inherit\nbogus: 1"),
);
result = profile(agy);
expect(
  "unknown key refused",
  result.problems.some((problem) => problem.includes("'bogus'")),
  true,
);

place(join(repo, ".agents", "agents"), generated);
result = profile({
  CLAUDE_CODE_SESSION_ID: "claude-s-1",
  ANTIGRAVITY_CONVERSATION_ID: "agy-conv-1",
});
expect("claude scope wins", [result.ok, result.profiles], [false, 0]);

place(join(repo, ".claude", "agents"), generated);
result = profile(agy);
expect(
  "claude folder ignored under agy",
  [result.ok, result.profiles],
  [false, 0],
);

// --- the Codex companion never sees an ANTIGRAVITY_* variable ---
expect(
  "companionEnv strips the agy variables",
  companionEnv({
    ANTIGRAVITY_CSRF_TOKEN: "t",
    ANTIGRAVITY_CONVERSATION_ID: "c",
    PATH: "/bin",
    KEEP: "1",
  }),
  { PATH: "/bin", KEEP: "1" },
);
expect("companionEnv keeps a plain environment", companionEnv({ A: "1" }), {
  A: "1",
});

const plugin = join(scratch, "plugin");
mkdirSync(plugin);
const fake = join(plugin, "codex-companion.mjs");
const envLog = join(scratch, "companion-env.json");
writeFileSync(
  fake,
  `import { writeFileSync } from "node:fs";
writeFileSync(${JSON.stringify(envLog)}, JSON.stringify(Object.keys(process.env).sort()));
process.stdout.write('{"verdict":"approve","findings":[]}');
`,
);
const reviewRepo = join(scratch, "review-repo");
mkdirSync(reviewRepo);
const gitEnv = childEnv();
run("git", ["init", "-q"], gitEnv, reviewRepo);
writeFileSync(join(reviewRepo, "a.txt"), "x\n");
run("git", ["add", "."], gitEnv, reviewRepo);
run(
  "git",
  [
    "-c",
    "user.name=t",
    "-c",
    "user.email=t@example.invalid",
    "commit",
    "-qm",
    "i",
  ],
  gitEnv,
  reviewRepo,
);
const wrapped = run(
  "bun",
  [
    "--no-env-file",
    "--config=/dev/null",
    join(root, "claude", "bin", "b-codex-review.mjs"),
    "--scope",
    "working-tree",
  ],
  childEnv({
    B_AGENTIC_CODEX_COMPANION: fake,
    ANTIGRAVITY_CSRF_TOKEN: "synthetic",
    ANTIGRAVITY_CONVERSATION_ID: "agy-conv-1",
    KEEP_ME: "1",
  }),
  reviewRepo,
);
expect("wrapper ran", wrapped.status, 0);
const seen = JSON.parse(readFileSync(envLog, "utf8"));
expect(
  "companion got no ANTIGRAVITY_ variable",
  seen.filter((key) => key.startsWith("ANTIGRAVITY_")),
  [],
);
expect("companion kept the rest", seen.includes("KEEP_ME"), true);

rmSync(scratch, { recursive: true, force: true });
console.log(`antigravity runtime cases: ${passed} passed`);
