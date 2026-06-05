# b-agentic - Runtime Contract Index

> Slim shared reference snapshot for the b-agentic workflow harness. The active runtime kernel lives in the runtime memory file; these files are read only when a kernel rule or skill step needs the detailed schema, rubric, or safety gate.

Installed contract roots:
- Claude Code: `~/.claude/b-agentic/references/contract/`
- OpenCode: `~/.config/opencode/b-agentic/references/contract/`
- Codex CLI: `~/.codex/b-agentic/references/contract/`

Temporary scratch roots:
- Claude Code: `/tmp/claude-code/b-agentic/`
- OpenCode: `/tmp/opencode/b-agentic/`
- Codex CLI: `/tmp/codex-cli/b-agentic/`

## Runtime Surface

| File | Owns | Read before |
|---|---|---|
| `contract/runtime.md` | routing, source of truth, plan lifecycle, modes, risk, evidence, execution, artifacts, session start | selecting/switching skills, validating plans, classifying risk, verifying completion, writing artifacts |
| `contract/safety-tools.md` | approvals, privacy, untrusted content, patch/git safety, MCP/tool ownership, fallbacks | mutating files/environments/deps/git, using MCPs, degrading tool paths, handling sensitive data |
| `contract/output.md` | status block, handoff envelope, cause classes, verdicts, readiness wording | non-trivial final output, blocked states, handoffs, review verdicts |
| `contract/state-machine.md` | strict/advisory state, intent, action validation, runtime capabilities | claiming strict mode, emitting high-risk action intent, recovering state, checking runtime enforcement |
| `contract/decisions.md` | high-risk completion, test-vs-bug routing, browser boundary, snapshots, flakes, cannot-reproduce | resolving shared edge cases across skills |

Keep this directory small. Skill-specific detail belongs under `skills/<name>/reference.md`; maintainer-only checks belong under `tooling/`, `tests/`, or `runtimes/`.

---
