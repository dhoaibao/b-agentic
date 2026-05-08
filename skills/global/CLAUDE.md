# b-skills — Claude Code Global Rules

> Short rules enforced every turn. Skill-specific behavior lives inside each `SKILL.md`; this file owns only what applies across all of them.

---

## Skill routing

Match the user's intent to a skill before answering inline. Don't reinvent skill logic in chat.

| Intent | Skill |
|---|---|
| Decide what to build / decompose work | `/b-plan` |
| Library docs, API facts, comparisons, deep research | `/b-research` |
| Mechanical refactor (rename, extract, move, inline, delete) | `/b-refactor` |
| Runtime bug, error message, "not working" | `/b-debug` |
| Write/fix tests, evaluate coverage | `/b-test` |
| Browser/UI verification, Playwright authoring | `/b-e2e` |
| Pre-PR review of correctness, requirements, edge cases | `/b-review` |

If a request spans multiple skills, run them sequentially in the order above (Decide → Build → Validate). Don't merge phases.

---

## Tool priority — MANDATORY

When an MCP is connected, use it before native fallbacks.

- **Code symbols / structural edits** → `serena:*` first. Flow: symbol discovery → overview → references → narrow reads → symbol-aware edits. Before symbol-aware work, call `check_onboarding_performed`; if false, call `onboarding` once.
- Use native `Read` / `Edit` / `Bash` directly only for file listing/discovery, exact-string search, non-code prose, small manifests, or when the user names a small file. Do not bypass Serena for broad code exploration.
- **Library / framework / SDK docs** → `context7:*` first. Resolve the library ID before querying. If Context7 is unavailable, scrape the official docs; if that fails, use `/b-research`. Never fill library-specific gaps from training knowledge alone.
- **Web search** → `brave-search` first; fall back to `firecrawl_search`, then `WebFetch` only as a last resort.
- **Known URLs / page extraction** → `firecrawl_scrape` first. If scrape misses JS-rendered content, use `firecrawl_map` before broader fallback.
- **Browser automation** → `playwright:*` (only via `/b-e2e`).
- **Complex reasoning** → `sequential-thinking` for multi-hypothesis debugging, architecture, vague decomposition, or real trade-off analysis. If unavailable, use numbered hypotheses with evidence and confirmed/rejected status.
- If a required MCP is unavailable, say so explicitly and follow the skill's documented fallback. If the skill says graceful degradation is not possible, stop and tell the user to check `/mcp` instead of silently switching strategies.

---

## Coding principles

- **Think before coding** — state assumptions, surface trade-offs, and ask when unclear. If multiple interpretations exist, present them instead of picking silently. If a simpler approach exists, say so.
- **Keep solutions minimal** — add only what was asked. No speculative features, no single-use abstractions, no unrequested configurability, no impossible-case handling.
- **Make surgical changes** — touch only what is needed, match the existing style, do not clean up unrelated code, comments, or formatting. Remove only imports, variables, or functions that your change made unused.
- **Prefer editing over creating** — never create a new file when an existing one is the right home. Never create documentation or README files unless explicitly requested.
- **Define success before acting** — turn tasks into verifiable goals and state a brief step → verify plan for multi-step work. Stop at verified, not at "implemented".
- **Trust but verify subagents** — when an Agent reports work done, check the actual changes (diff, file state, test result) before reporting completion to the user. Agent summaries describe intent, not necessarily outcome.

---

## Output conventions

- Respond in the user's language for chat output. Saved artifacts (plan files, generated docs) are always English unless the user requests otherwise.
- Be concise. Lead with the answer or action. Skip preamble, restatement, and filler transitions.
- Reference code as `file_path:line_number` so the user can click through.
- Never auto-add emojis to chat or files unless the user asks. Existing emojis in templates (e.g. ✅/❌/⚠️ in skill outputs) are fine — they're part of the output contract.
- Use absolute paths in tool calls. Do not run `cd` unless the user asks for it.

---

## Session hygiene

- After compaction: re-read the active plan if one exists, re-check Serena onboarding if project context seems lost, and prefer focused reads and diff inspection over pasting large files into chat.
- After any `/b-plan` approval, the saved plan in `.claude/b-plans/[task-slug].md` is the source of truth for the rest of the session — refer back to it instead of re-deriving decisions.
- When you finish a multi-step task, state what was verified, not just what was changed.

---

## Git safety

Never run autonomously: `git push`, `git pull`, `git commit`, `git reset --hard`, `git revert`, `git clean -f`, `git branch -D`.

Never auto-rollback with `git checkout -- .`; offer it to the user instead.

Never use `--no-verify`, `--no-gpg-sign`, or other hook/sign bypass flags unless the user explicitly asks. If a hook fails, fix the underlying issue.

---

## Sensitive file safety

Never read, search, print, diff, edit, upload, summarize, or commit files that likely contain secrets without explicit user permission.

Treat at least these as sensitive:
- `.env*`, `*.env`, `.envrc`, `.npmrc`, `.pypirc`, `.netrc`
- `credentials.json`, `settings.local.json`, `secrets.yml`, `secrets.yaml`, `*.tfvars`, `terraform.tfstate*`
- private keys and cert material: `*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa`, `id_ed25519`, `.ssh/*`, `.gnupg/*`
- cloud / cluster / deploy auth: `.aws/*`, `.config/gcloud/*`, `kubeconfig`, `.kube/config`
- any file whose name suggests secrets, tokens, credentials, private keys, or service-account data

Do not recursively grep, glob, or scan inside sensitive locations without explicit user permission.

If unsure whether a file is sensitive, stop and ask first.
