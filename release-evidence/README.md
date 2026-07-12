# Release evidence

Live production-ready claims require operator attestations for every runtime changed by the release, plus static verification. Attestation files are claims recorded by an authorized operator; they are not self-proving release gates.

## Evidence classes

| Class | Source | Proves |
|---|---|---|
| `static` | `scripts/validate-skills.sh`, doctors, config validators, `scripts/verify-release-evidence.sh` | Generated sync, install/config shape, policy regression, attestation shape/revision consistency |
| `simulated` | `scripts/runtime-acceptance.sh --active` | CLI protocol/adapter harness command construction |
| `live` | Fresh interactive session + operator attestation | Kernel load, skill invocation, MCP call, approval/deny gates **as claimed by the operator** |

Simulated probes never substitute for live evidence. Attestation files never substitute for static verification.

## Record a live attestation

After an authorized fresh-session pass:

```bash
scripts/record-release-evidence.sh \
  --runtime=pi \
  --operator="$USER" \
  --kernel=pass \
  --skill=pass \
  --mcp=pass \
  --approval-gate=pass \
  --deny-gate=pass \
  --note-kernel='fresh session quoted contract path' \
  --note-skill='invoked b-summary; observed blocked empty staging' \
  --note-mcp='Serena tool call returned expected text' \
  --note-approval-gate='git commit prompted; denied by operator' \
  --note-deny-gate='git reset --hard blocked with policy reason'
```

Default output path:

```text
release-evidence/<runtime>-<UTC-timestamp>.json
```

`record-release-evidence.sh` records metadata and operator-provided gate outcomes. It does **not** run static validation, verify tags, or independently confirm that the gates occurred.

## Verify release readiness inputs

```bash
# Full production-ready claim: only operation-enforced / full-with-live-evidence runtimes
scripts/verify-release-evidence.sh --runtime=pi

# Explicit evidence files must use <runtime>-*.json names, or pair one file with one --runtime
scripts/verify-release-evidence.sh --evidence=release-evidence/pi-20260710T120000Z.json
scripts/verify-release-evidence.sh --runtime=pi --evidence=/tmp/attestation.json


# Also require an immutable tag matching pyproject version
scripts/verify-release-evidence.sh --runtime=pi --require-tag=v2026.07.10
```

## Production-ready rule

A revision may be labeled production-ready only when:

1. static validation and audit pass for that revision;
2. an operator attestation exists for every runtime claimed in the release with all five gates `pass` (`kernel`, `skill`, `mcp`, `approval-gate`, `deny-gate`);
3. attestation `runtime.name` matches the requested runtime (filename and body must agree);
4. attestation `package.version` and exact `package.git_rev` match the candidate revision (`unknown` is rejected);
5. attestation `runtime.cli` and resolvable `runtime.cli_version` identify the live CLI under test (captured operator claim for the session; not a supported-version policy matrix);
6. attestation `runtime.support_tier` and `runtime.mcp_enforcement` are required and must exactly match `runtimes/registry.yaml` for that runtime on the candidate revision;
7. runtimes with `production_claim: excluded` cannot be release-attested;
8. full verification rejects `production_claim: shell-gated-only` runtimes unless `--scoped-claim=shell-gated-only` is set; scoped mode is never a full production-ready claim;
9. package version, changelog entry, and immutable Git tag (`vYYYY.MM.DD`) are prepared for shipping;
10. unsupported or unattested runtimes are explicitly excluded from the production-ready claim.


Live operator attestations for Pi are still required before any full production-ready label. Static validation alone never completes Priority 0.2.

Attestations are checked into `release-evidence/` as operator claims bound to an exact package revision. They are not self-proving: do not record credentials, sessions, private prompts, or customer data, and do not treat simulated `--active` probes as live proof.

See `schema.example.json` for the attestation JSON shape and `skill-evaluation.md` for the versioned live skill-routing protocol.

## Live tool-ownership matrix (release evidence only)

When recording production evidence, cover representative tool ownership and fallbacks without expanding the core kernel:

| Domain | Expected tool | Fallback / blocker |
|---|---|---|
| Local structure / impact | CodeGraph or Serena | Local search/reads; state missing index/auth honestly |
| External docs / web facts | Context7, Firecrawl, or Brave | Official docs/search snippets or evidence gap |
| Browser evidence | Playwright | Supplied/CI evidence or missing-browser blocker |

Record the tool used and the fallback only when the primary tool is missing, indexless, or auth-blocked.
