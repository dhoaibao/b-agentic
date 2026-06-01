# b-review reference

Use for security-sensitive changed code and b-agentic suite self-audits.

## Security checklist

- **Boundaries:** validate inputs at the first boundary; reject or normalize unexpected fields; treat APIs, config, logs, and webhooks as untrusted.
- **Auth/authz:** confirm protected paths check authentication and resource authorization; elevated actions fail closed.
- **Injection/encoding:** parameterize queries; sanitize shell/template/HTML sinks; preserve output encoding.
- **Sensitive data:** remove secrets, tokens, internal fields, stack traces, and private details from logs/responses.
- **Abuse controls:** check rate limits, retry bounds, upload size, pagination, idempotency, replay safety, and pathological parsing/regex paths.
- **Dependencies/config:** question new sensitive-path dependencies; ensure security config fails closed when missing or mis-set.

## Audit-suite checklists (`--audit-suite`)

Pick the smallest matching surface, name baseline/samples/skips, and inspect highest-risk paths first.

### Installer or update path

- Install/update/dry-run/uninstall/idempotency/backup/partial failure.
- Managed markers, pruning rules, and user-owned file preservation.
- Paths match README and runtime contract.

### Runtime contract or governance

- Routing precedence, source-of-truth order, safety gates, approval lifetime.
- Artifact paths, status blocks, handoff envelopes, and schema consistency.
- Global rules are not duplicated unnecessarily inside skill files.

### Validator or tool boundary

- Rules enforce documented invariants without forcing duplicated runtime policy.
- Failures are actionable and tied to maintained files.
- Generated frontmatter, docs coverage, installed support files, and source-to-generated sync are checked.

### Route, tool, or public contract boundary

- Identify consumers before judging route/tool/schema/CLI changes safe.
- Check shapes, auth gates, error behavior, documented flags/fields, examples, docs, generated clients, and tests.

### Dependency, generated, or security-sensitive surface

- Dependencies: approval, lockfile, security, license, engine, and package-manager impact.
- Generated artifacts: source command known; manual edits labeled partial with regeneration follow-up.
- Security rules: auth/authz, secrets, private data, destructive commands, external writes, and public-web privacy gates need direct evidence.

### b-agentic suite audit

- Check `skills/registry.yaml`, `skills/*/prompt.md`, generated `skills/*/SKILL.md`, `runtimes/*/kernel.md`, runtime wrappers, and `references/contract/` only where they define overlapping runtime-facing behavior.
- Verify trigger boundaries, stop conditions, task workflows, schemas, paths, tool priorities, and safety gates.
- Run `scripts/validate-skills.sh` unless explicitly skipped.
