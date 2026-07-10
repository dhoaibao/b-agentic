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
  --runtime=claude-code \
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
# Verify attestations for changed runtimes and run static checks
scripts/verify-release-evidence.sh --runtime=claude-code --runtime=pi

# Explicit evidence files must use <runtime>-*.json names, or pair one file with one --runtime
scripts/verify-release-evidence.sh --evidence=release-evidence/claude-code-20260710T120000Z.json
scripts/verify-release-evidence.sh --runtime=claude-code --evidence=/tmp/attestation.json

# Also require an immutable tag matching pyproject version
scripts/verify-release-evidence.sh --runtime=claude-code --require-tag=v2026.07.10
```

## Production-ready rule

A revision may be labeled production-ready only when:

1. static validation and audit pass for that revision;
2. an operator attestation exists for every changed runtime with all five gates `pass`;
3. attestation `runtime.name` matches the requested runtime (filename and body must agree);
4. attestation `package.version` and exact `package.git_rev` match the candidate revision (`unknown` is rejected);
5. package version, changelog entry, and immutable Git tag (`vYYYY.MM.DD`) are prepared for shipping.

See `schema.example.json` for the attestation JSON shape.
