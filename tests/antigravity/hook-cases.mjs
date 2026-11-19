#!/usr/bin/env bun
// Behavior cases for antigravity/hooks/b-agy-hook.mjs. Every fixture is
// synthetic and inline; state lives in a temporary directory, never in a real
// home. Exits non-zero on the first failed expectation.
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { handle } from "../../antigravity/hooks/b-agy-hook.mjs";

const scratch = mkdtempSync(join(tmpdir(), "b-agy-hook-"));
process.env.B_AGENTIC_GATE_DIR = join(scratch, "gate");
delete process.env.B_AGENTIC_GATE_MODE;

const work = join(scratch, "work");
mkdirSync(work);

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

const base = (conversationId = "conv-main") => ({
  conversationId,
  cwd: work,
  workspacePaths: [work],
});
const pre = (name, args, id) => ({
  ...base(id),
  hookEventName: "PreToolUse",
  toolCall: { id: "call-1", name, args },
});
const post = (name, args, id) => ({
  ...base(id),
  hookEventName: "PostToolUse",
  toolCall: { id: "call-1", name, args },
});
const stop = (extra = {}, id) => ({
  ...base(id),
  hookEventName: "Stop",
  fullyIdle: true,
  continuationActive: false,
  ...extra,
});
const decision = async (event) => (await handle(event))?.decision ?? null;

// Secret paths through the file tools.
for (const tool of ["read_file", "write_file", "edit_file"]) {
  expect(
    `${tool} on a .env file is denied`,
    await decision(pre(tool, { Path: "/proj/app/.env" })),
    "deny",
  );
}
expect(
  "a pem key is denied",
  await decision(pre("read_file", { Path: "/proj/keys/server.pem" })),
  "deny",
);
expect(
  "an example env file is not an objection",
  await handle(pre("read_file", { Path: "/proj/.env.example" })),
  null,
);
expect(
  "an ordinary file is not an objection",
  await handle(pre("read_file", { Path: "/proj/src/app.mjs" })),
  null,
);

// Secret paths as shell words.
expect(
  "cat of a .env path is denied",
  await decision(pre("run_command", { CommandLine: "cat config/.env" })),
  "deny",
);
expect(
  "a quoted secret word in a chain is denied",
  await decision(
    pre("run_command", { CommandLine: "echo hi && head -n1 'a/secrets.json'" }),
  ),
  "deny",
);
expect(
  "a plain command is not an objection",
  await handle(pre("run_command", { CommandLine: "ls -la src" })),
  null,
);

// .b-agentic writes.
for (const tool of ["write_file", "edit_file"]) {
  expect(
    `${tool} into .b-agentic is denied`,
    await decision(
      pre(tool, { Path: join(work, ".b-agentic", "runs", "x", "state.json") }),
    ),
    "deny",
  );
}
expect(
  "read_file of a run artifact is allowed",
  await handle(
    pre("read_file", {
      Path: join(work, ".b-agentic", "runs", "x", "plan.md"),
    }),
  ),
  null,
);

// Codex guard: outside a git repository a plugin command is refused.
expect(
  "a refused Codex command is denied",
  await decision(
    pre("run_command", {
      CommandLine: "node /p/scripts/codex-companion.mjs review --wait",
    }),
  ),
  "deny",
);
expect(
  "a non-disclosing Codex command is not refused",
  await handle(
    pre("run_command", {
      CommandLine: "node /p/scripts/codex-companion.mjs status",
    }),
  ),
  null,
);

// Alexandria.
const scrape = (Arguments) =>
  pre("call_mcp_tool", {
    ServerName: "firecrawl",
    ToolName: "firecrawl_scrape",
    Arguments,
  });
expect(
  "a scrape with an alexandria argument forces a prompt, ignoring cached grants",
  await decision(scrape({ url: "https://example.test", alexandria: {} })),
  "force_ask",
);
expect(
  "a plain scrape is not an objection",
  await handle(scrape({ url: "https://example.test" })),
  null,
);
expect(
  "another MCP tool is not an objection",
  await handle(
    pre("call_mcp_tool", { ServerName: "context7", ToolName: "query-docs" }),
  ),
  null,
);

// Verify gate: dirty, one continue, then silence.
await handle(post("edit_file", { Path: "/proj/src/app.mjs" }));
expect(
  "Stop while not fully idle prints nothing",
  await handle(stop({ fullyIdle: false })),
  null,
);
const first = await handle(stop());
expect("first Stop continues", first?.decision, "continue");
expect(
  "the reminder text is carried",
  typeof first?.reason === "string" && first.reason.includes("verify gate"),
  true,
);
expect(
  "second Stop of the turn prints nothing",
  await handle(stop({ continuationActive: true })),
  null,
);
expect("a later Stop prints nothing", await handle(stop()), null);

// Prose edits stay clean.
await handle(post("write_file", { Path: "/proj/docs/notes.md" }));
expect("a prose edit does not dirty the gate", await handle(stop()), null);

// Clean after a non-inspection command.
await handle(post("write_file", { Path: "/proj/src/app.mjs" }));
await handle(post("run_command", { CommandLine: "bun test" }));
expect("a check command cleans the gate", await handle(stop()), null);

// An inspection command does not clean.
await handle(post("write_file", { Path: "/proj/src/app.mjs" }));
await handle(post("run_command", { CommandLine: "ls src" }));
expect(
  "inspection leaves the gate dirty",
  (await handle(stop()))?.decision,
  "continue",
);

// No reminder while a continuation is already active.
await handle(post("write_file", { Path: "/proj/src/app.mjs" }));
expect(
  "continuationActive prints nothing",
  await handle(stop({ continuationActive: true })),
  null,
);
expect("the state is cleared afterward", await handle(stop()), null);

// Subagent isolation: its edits dirty only its own conversation.
await handle(post("edit_file", { Path: "/proj/src/a.mjs" }, "conv-sub"));
expect("the parent stays clean", await handle(stop({}, "conv-main")), null);
expect(
  "the subagent conversation has its own state",
  (await handle(stop({}, "conv-sub")))?.decision,
  "continue",
);

// SessionStart context.
const started = (cwd) => ({
  ...base("conv-start"),
  cwd,
  hookEventName: "SessionStart",
});
expect(
  "SessionStart without context prints nothing",
  await handle(started(work)),
  null,
);
const runId = "20260101-demo";
const runDir = join(work, ".b-agentic", "runs", runId);
mkdirSync(runDir, { recursive: true });
writeFileSync(join(work, ".b-agentic", "active"), `${runId}\n`);
writeFileSync(
  join(runDir, "state.json"),
  JSON.stringify({ run_id: runId, phase: "implement" }),
);
mkdirSync(join(work, "docs", "specs"), { recursive: true });
writeFileSync(
  join(work, "docs", "specs", "demo.md"),
  "# Demo\n\nStatus: approved\n",
);
const context = await handle(started(work));
const text = context?.injectSteps?.[0]?.systemMessage?.systemMessage ?? "";
expect(
  "SessionStart carries run context",
  text.includes(`run ${runId} is in phase implement`),
  true,
);
expect(
  "SessionStart carries spec context",
  text.includes("docs/specs/demo.md"),
  true,
);

// Unknown tools and events.
expect(
  "an unknown tool prints nothing",
  await handle(pre("search_web", { Query: "x" })),
  null,
);
expect(
  "an unknown event prints nothing",
  await handle({ ...base(), hookEventName: "PreInvocation" }),
  null,
);
expect("a missing event prints nothing", await handle({}), null);

// Fail closed on a guard event.
const brokenLoader = async () => {
  throw new Error("import failed");
};
expect(
  "a failed import denies a guard event",
  (
    await handle(pre("read_file", { Path: "/proj/a.txt" }), {
      loader: brokenLoader,
    })
  )?.decision,
  "deny",
);
expect(
  "an internal error denies a guard event",
  (
    await handle(pre("read_file", { Path: "/proj/a.txt" }), {
      loader: async () => ({
        pathGuard: {
          agenticWrites() {
            throw new Error("boom");
          },
          blockedPaths() {
            throw new Error("boom");
          },
        },
      }),
    })
  )?.decision,
  "deny",
);
expect(
  "a failed import does not block a non-guard event",
  await handle(stop(), { loader: brokenLoader }),
  null,
);

// The other path names agy's edit schema may use are guarded too.
for (const key of ["TargetFile", "AbsolutePath"]) {
  expect(
    `edit_file ${key} on a .env file is denied`,
    await decision(pre("edit_file", { [key]: "/proj/app/.env" })),
    "deny",
  );
}

// Without B_AGENTIC_GATE_DIR the gate state goes under agy's folder, never ~/.claude.
const savedGate = process.env.B_AGENTIC_GATE_DIR;
const savedHome = process.env.HOME;
const fakeHome = join(scratch, "home");
mkdirSync(fakeHome);
delete process.env.B_AGENTIC_GATE_DIR;
process.env.HOME = fakeHome;
await handle(post("write_file", { Path: "/proj/src/home.mjs" }, "conv-home"));
const gateFile = join(
  fakeHome,
  ".gemini",
  "config",
  "b-agentic",
  "verify-gate",
  "conv-home.json",
);
expect(
  "the default gate state lives under agy's folder",
  existsSync(gateFile),
  true,
);
expect(
  "nothing is written under ~/.claude",
  existsSync(join(fakeHome, ".claude")),
  false,
);
delete process.env.B_AGENTIC_GATE_DIR;
process.env.HOME = savedHome;
process.env.B_AGENTIC_GATE_DIR = savedGate;

rmSync(scratch, { recursive: true, force: true });
console.log(`antigravity hook cases: ${passed} passed`);
