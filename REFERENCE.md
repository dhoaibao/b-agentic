# b-agentic operational reference

[Back to the public overview](README.md)

This reference defines the single supported runtime, Claude Code, with Codex as
the independent reviewer. It covers installation, the permission boundary, the
review gate, MCP configuration, and validation. The earlier Pi runtime was
removed (last commit `ac38e4a`) and is not maintained here.

## Install and lifecycle

```bash
git clone https://github.com/dhoaibao/b-agentic.git && cd b-agentic && ./install.sh
```

`./install.sh` installs from the checkout that contains it. Piped
(`curl -fsSL .../install.sh | bash`), it clones the source to
`~/.b-agentic-claude` first; it never uses `~/.b-agentic`, which may still hold
the frozen Pi installer. The script never runs vendor installers and never
writes under `~/.pi`.

- `--dry-run` prints the plan and changes nothing.
- `--update` fast-forwards the checkout (`--ref=<tag-branch-or-commit>` checks
  out a ref) and then syncs. A plain run is already idempotent: unchanged
  inputs write nothing.
- `--force` replaces a managed file you modified, or a same-named file b-agentic
  did not install, after a backup. Without it such files are kept with a warning.
- `--uninstall` removes only recorded, unmodified assets and entries and keeps
  `~/.claude/b-agentic/backups`.
- `--with-clickup` / `--without-clickup` (or `B_AGENTIC_CLICKUP_MCP=yes`) select
  the optional ClickUp MCP server. The choice is recorded and preserved.
- Only `~/.claude` is supported. A different `CLAUDE_CONFIG_DIR` is refused
  because the managed hooks, agents, and instructions refer to that path.

What it manages, all recorded in `~/.claude/b-agentic/install.json`:

| Asset                              | Installed path                                                                       |
| ---------------------------------- | ------------------------------------------------------------------------------------ |
| Skills (also `/b-<name>` commands) | `skills/b-*/SKILL.md`                                                                |
| Specialists                        | `agents/b-*.md`                                                                      |
| Hooks and CLIs                     | `b-agentic/hooks/*.mjs`, `b-agentic/bin/*.mjs`                                       |
| References                         | `b-agentic/references/`                                                              |
| Kernel                             | block between `<!-- b-agentic:start -->` and `<!-- b-agentic:end -->` in `CLAUDE.md` |
| Permissions and hooks              | entries merged into `settings.json`                                                  |
| MCP servers                        | entries merged into `~/.claude.json`                                                 |

It plans in memory and refuses before its first write when a user file is
malformed or wrongly shaped, the kernel markers are duplicated or reversed, or a
managed directory is a symlink; backs up each file it changes under
`b-agentic/backups/`; writes through (never replaces) a symlinked config file;
merges rather than replaces user-owned keys, arrays, and hooks; and treats a
file, hook, or server as its own only when a previous run recorded it, so an
identical user-owned copy survives uninstall and a modified kernel block or hook
is kept. Every destination, including backups and the manifest, is validated
before the first write, and an interrupted run is recorded as `pending` so a
retry or `--uninstall` still recognizes both the old and the new state. The
piped bootstrap honors `--dry-run` before cloning or fetching, runs git with its
destination overrides cleared, and refuses a source checkout whose worktree or
git directory is under `~/.pi`. Claude Code rewrites `~/.claude.json` while it
runs, so restart it after an install. The installer reports missing tools (`rtk`,
`codegraph`, `bunx`, `claude`, `codex`) and prints, but never runs, the Codex
plugin commands.

## Kernel and skills

Claude Code loads `~/.claude/CLAUDE.md` and discovers `skills/b-*/SKILL.md`.
The main session reads one skill before acting or invokes `/b-<name>`.
`skills/registry.yaml` and `skills/*/prompt.md` are canonical;
`tooling/generate/registry_sync.py` generates `SKILL.md`, `claude/agents/*.md`,
the kernel's generated blocks, and `claude/configs/settings.template.json`.
Explicit-request skills (`b-commit`, `b-pr-summary`) route only on explicit
user request and stay model-invocable.

The four specialists are `b-planner`, `b-researcher`, `b-debugger`, and
`b-auditor`. Their tool lists omit `Edit`, `Write`, `NotebookEdit`, and nested
delegation and carry only read-only MCP tools (plus three bounded Firecrawl
tools for `b-researcher`). Read-only behavior is instructed, not enforced by a
child-specific permission block: shell access can still mutate state. Delegated
skills never run in the main session; the generated `Delegation boundary` and
the kernel carry this, so a missing subagent is reported instead of bypassed. A
child result is evidence, not authorization. Models are Anthropic aliases from
the registry.

## Review gate

`b-review` runs in the main session. Codex is the independent reviewer through
the [`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc)
plugin, which you install yourself:

```text
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/codex:setup
```

Then sign in to Codex and keep the plugin's review gate (a Stop hook) disabled.
The gate sequence is:

1. Freeze the candidate: `node ~/.claude/b-agentic/bin/b-candidate-snapshot.mjs`
   gives HEAD, SHA-256 digests of the staged and unstaged binary diffs, sorted
   untracked paths with type and content digest, and one `fingerprint` (F0). It
   covers the whole repository, lists protected paths and submodules without
   hashing or diffing them, excludes git-ignored files unless named with
   `--include-ignored`, and refuses when a repository clean/process filter would
   run or the repository is a partial clone. Exit 0 is complete, 3 incomplete,
   2 refused.
2. Early preflight: `node ~/.claude/b-agentic/hooks/b-codex-guard.mjs --check` refuses
   when a likely-secret path is tracked, staged, or untracked-and-not-ignored,
   when a submodule or embedded repository hides paths, or when the repository
   has no standing approval. Approve once per repository with `--approve` after
   the user agrees to send it to Codex (OpenAI); `--revoke` withdraws it.
3. Run the gate with the wrapper, from the repository, with nothing editing:
   `node ~/.claude/b-agentic/bin/b-codex-review.mjs --scope working-tree --round
<n> --focus-file <path>` (or `--base <ref>`; `--kind native` for the plugin's
   focus-less review; `--include-ignored <path>` as at step 1). The wrapper
   reruns the secret and approval gate, freezes the candidate (`f0`), finds the
   plugin's `codex-companion.mjs` under `~/.claude/plugins` (or
   `B_AGENTIC_CODEX_COMPANION`), runs the review in the foreground with an
   argument vector, freezes again (`f1`), and maps the result. It prints JSON:
   `f0`, `f1`, `unchanged`, `timed_out`, `truncated`, the raw plugin output, and
   `mapped`. Exit 0 is a completed review. Exit 3 is a void one: the candidate
   changed or could not be re-snapshotted, the run hit `--timeout-minutes` (30 by
   default, at most 35791; stopped with SIGTERM, then SIGKILL after
   `--kill-grace-seconds`, and its pipes closed by the wrapper if a descendant
   still holds them) or
   the 8 MB output cap, or the result was unmappable or finding-less. Exit 2 is a
   refusal or failure, including an incomplete snapshot before the plugin runs
   and a non-zero plugin exit. A run that was cut short is never mapped, whatever
   status it exited with.
4. Main checks that `f0` equals the step-1 fingerprint and `unchanged` is true,
   and recomputes the fingerprint itself; a difference voids the review.
5. `mapped` carries finding IDs `R<round>-<n>` and a provisional verdict (the
   same mapping `b-codex-verdict.mjs` applies to saved output). Main classifies
   against the blocker taxonomy and owns the final `Verdict:` line.

The `b-codex-guard` PreToolUse hook is a tripwire for accidental direct calls to
the plugin script, not the boundary: it applies the same checks to plain
spellings and refuses background or implicit-target reviews, but deliberately
obfuscated spellings (ANSI-C quoting, brace or glob expansion, names built at run
time) are out of scope.

Codex's read-only sandbox can read every workspace file and Codex has no ignore
mechanism, so ignored secret files remain an accepted residual risk. Review never
commits or pushes. Plugin command syntax and result shape come from its
documentation and are not exercised live by this repository's checks.

## Permission boundary

`claude/configs/settings.template.json` is generated from
`references/mcp_operations.yaml`. It allows repository-local tools and named
read-only and conditional-read MCP tools, asks before classified mutations, uploads, lifecycle, and
auth tools, asks before a plain `git push` or `gh pr create`, and denies the
named dangerous commands (`git pull`, `git reset --hard`, `git clean -f`,
`git branch -D`, `rm -rf`, `sudo`, `doas`, `docker system prune`, bare shells,
`bash -s`/`sh -s`, `gh pr merge`, `gh repo delete`, and force, delete, mirror,
all/branches, prune, and `main` or `master` pushes, each also under an `rtk` prefix where
relevant) and unambiguous secret files. Global-option forms such as `git -C <dir> push`
(which also asks for `git stash push`) and combined short flags such as `-uf`
are asked about but not pattern-denied; `:branch` delete refspecs and default
branches not named `main` or `master` also stay at the ask prompt. The
`b-path-guard` hook applies the exact path rules to the file tools (including the
`*.env.example` allowance that deny rules cannot express). Hooks:
`b-path-guard` and `b-codex-guard` run before tools; `b-verify-gate` tracks
edits and, when the main session edited a non-prose file after its last shell
command, blocks the first stop once with the verify and review reminder.
Claude Code prompts for outside-project writes instead of denying them. These
rules are not a process or filesystem sandbox; shell indirection and MCP
arguments they cannot see remain residual risks. The kernel additionally
requires approval for other destructive, privileged, ambiguous, protected, or
external/shared actions.

## MCP and readiness

`claude/configs/mcp.base.json` configures CodeGraph, Context7, Brave Search,
Firecrawl, Playwright, Mobbin, Notion, Excalidraw, draw.io, and shadcn;
`mcp.clickup.json` is the optional ClickUp server. Tools are addressed as
`mcp__<server>__<tool>`. Credentials are `${VAR}` references; the installer
collects none.

| MCP          | Local prerequisite                                                    |
| ------------ | --------------------------------------------------------------------- |
| CodeGraph    | `codegraph` and an index for graph questions                          |
| Context7     | `CONTEXT7_API_KEY`                                                    |
| Brave Search | `bunx`, `BRAVE_API_KEY`                                               |
| Firecrawl    | `bunx`, `FIRECRAWL_API_KEY`                                           |
| Playwright   | `bunx` (isolated/headless testing)                                    |
| Mobbin       | approved OAuth/account when requested                                 |
| Notion       | approved OAuth when Notion content is requested                       |
| Excalidraw   | approved `create_view` calls, MCP UI viewer                           |
| draw.io      | `bunx`, approved `open_drawio_*` calls, default browser (optional)    |
| shadcn       | `bunx`, project `components.json`                                     |
| ClickUp      | optional install opt-in, `bunx`, `CLICKUP_API_KEY`, `CLICKUP_TEAM_ID` |

Notion is the official hosted server and reaches the user's whole private
workspace, so every read is `conditional-read` (allowed in the main session,
never granted to the specialists) and every write asks. Excalidraw's
`create_view` and draw.io's `open_drawio_*` ask on every call and send diagram
text to a hosted endpoint or open the draw.io web editor. draw.io runs
`bunx @drawio/mcp@1.6.3` with `DRAWIO_ICON_SERVICE_URL=off`; the pin freezes only
the top-level package, and the package runs unsandboxed with your permissions.
`list_pages` and `get_page` are deliberately unclassified so they keep the
approval prompt.

`scripts/mcp-doctor.sh --allow-degraded` reports local launcher, configuration,
and environment-variable presence only. It never reads credential values, starts
servers, authenticates, or navigates a browser. Configured does not mean
connected or usable. `scripts/skill-doctor.sh` checks the installed skill and
specialist payload and the kernel block. RTK remains a prerequisite for
supported shell command families; CodeGraph is the first stop for code-structure,
call-flow, and pre-edit impact questions in an indexed project, and agents never
run its init, index, sync, daemon, or install commands.

## Verification and repository map

```bash
python3 tooling/generate/registry_sync.py --self-test --check
scripts/validate-skills.sh --release
scripts/b-agentic-audit.sh
npm run quality
rtk git diff --check
```

Plain `scripts/validate-skills.sh` runs the generator self-test and check, the
policy and routing checks, the hook and verdict-mapper probe
(`tests/hooks/hooks-probe.sh`), and the snapshot CLI probe
(`tests/snapshot/cli-probe.sh`). `--release` (CI) adds the sandbox installer
probe (`tests/install/claude-install-probe.sh`) and the RTK readiness check. None
needs Claude Code, Codex, credentials, or a network.

`skills/` and `references/` hold canonical workflow guidance; `claude/` holds
generated specialists and settings plus the hooks, CLIs, and MCP templates;
`tooling/generate/`, `tooling/install/`, and `tooling/validate/` own
generation, lifecycle, and static checks; `tests/` covers behavior, hooks,
snapshots, and the installer. See the [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md).
