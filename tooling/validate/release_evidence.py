#!/usr/bin/env python3

"""Verify release attestation records plus static release gates.

This is not live-session automation. It checks that:
- package version and git revision are consistent with the checkout;
- optional git tag/ref points at HEAD;
- static validation/audit commands pass when requested;
- required runtime attestation files exist, bind to the requested runtime,
  match HEAD, and claim all gates pass.

Operator attestations remain claims unless an authorized live session produced them.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE_DIR = ROOT / "release-evidence"
REQUIRED_GATES = ("kernel", "skill", "mcp", "approval-gate", "deny-gate")


def package_version(root: Path = ROOT) -> str:
    text = (root / "pyproject.toml").read_text()
    match = re.search(r'^version\s*=\s*"([^"]+)"', text, re.MULTILINE)
    if not match:
        raise SystemExit("pyproject.toml: missing version")
    return match.group(1)


def git_rev(root: Path = ROOT) -> str:
    completed = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    return completed.stdout.strip()


def registered_runtimes(root: Path = ROOT) -> set[str]:
    data = json.loads((root / "runtimes" / "registry.yaml").read_text())
    names: set[str] = set()
    for item in data.get("runtimes", []):
        if isinstance(item, dict) and isinstance(item.get("name"), str) and item["name"]:
            names.add(item["name"])
    return names


def git_tag_points_to_head(tag: str, root: Path = ROOT) -> tuple[bool, str]:
    completed = subprocess.run(
        ["git", "-C", str(root), "rev-parse", f"{tag}^{{}}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        return False, completed.stderr.strip() or f"tag not found: {tag}"
    return completed.stdout.strip() == git_rev(root), completed.stdout.strip()


def load_attestation(path: Path) -> dict:
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected object")
    return data


def infer_runtime_from_filename(path: Path, known_runtimes: set[str]) -> str | None:
    name = path.name
    if not name.endswith(".json"):
        return None
    # Longest match first so future compound names remain unambiguous.
    for runtime in sorted(known_runtimes, key=len, reverse=True):
        if name.startswith(f"{runtime}-"):
            return runtime
    return None


def validate_attestation(
    path: Path,
    expected_version: str,
    expected_rev: str,
    expected_runtime: str | None = None,
    known_runtimes: set[str] | None = None,
) -> list[str]:
    errors: list[str] = []
    try:
        data = load_attestation(path)
    except Exception as exc:
        return [f"{path}: invalid JSON: {exc}"]

    if data.get("record_type") not in {None, "operator-attestation"}:
        errors.append(f"{path}: record_type must be operator-attestation")
    if data.get("evidence_class") != "live":
        errors.append(f"{path}: evidence_class must be live")

    package = data.get("package") or {}
    if package.get("version") != expected_version:
        errors.append(
            f"{path}: package.version {package.get('version')!r} != pyproject {expected_version!r}"
        )

    # Release verification always requires an exact HEAD binding. "unknown" is not releasable.
    if not expected_rev:
        errors.append(f"{path}: repository HEAD could not be resolved; release verification requires git rev")
    else:
        actual_rev = package.get("git_rev")
        if actual_rev != expected_rev:
            errors.append(
                f"{path}: package.git_rev {actual_rev!r} != HEAD {expected_rev!r}"
            )

    # Explicit non-release marker from the recorder when git rev was unresolved.
    if data.get("release_eligible") is False:
        errors.append(f"{path}: attestation is marked release_eligible=false")

    runtime = data.get("runtime") or {}
    actual_runtime = runtime.get("name")
    if not isinstance(actual_runtime, str) or not actual_runtime:
        errors.append(f"{path}: runtime.name missing")
    else:
        if known_runtimes is not None and actual_runtime not in known_runtimes:
            errors.append(
                f"{path}: runtime.name {actual_runtime!r} is not a registered runtime"
            )
        if expected_runtime is None:
            errors.append(
                f"{path}: expected runtime could not be determined; "
                "use a <runtime>-*.json filename or pass --runtime=<name>"
            )
        elif actual_runtime != expected_runtime:
            errors.append(
                f"{path}: runtime.name {actual_runtime!r} != expected runtime {expected_runtime!r}"
            )

    gates = data.get("gates")
    if not isinstance(gates, list):
        errors.append(f"{path}: gates must be a list")
        return errors

    by_name = {
        item.get("name"): item
        for item in gates
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    for gate in REQUIRED_GATES:
        item = by_name.get(gate)
        if item is None:
            errors.append(f"{path}: missing gate {gate!r}")
            continue
        if item.get("status") != "pass":
            errors.append(f"{path}: gate {gate!r} status is {item.get('status')!r}, expected pass")

    # Prefer the explicit attestation flag; fall back only for legacy files.
    attested = data.get("operator_attested_all_gates_pass")
    if attested is None:
        attested = data.get("production_ready_for_runtime")
    if attested is not True:
        errors.append(f"{path}: operator did not attest all gates pass")

    return errors


def find_latest_attestation(runtime: str, evidence_dir: Path = EVIDENCE_DIR) -> Path | None:
    candidates = sorted(evidence_dir.glob(f"{runtime}-*.json"))
    candidates = [path for path in candidates if path.name != "schema.example.json"]
    return candidates[-1] if candidates else None


def run_static_checks(root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    commands = [
        ([sys.executable, "tooling/generate/registry_sync.py", "--check"], "registry sync"),
        ([sys.executable, "tooling/validate/shared.py"], "shared validation"),
        ([sys.executable, "tooling/validate/mcp_policy.py"], "MCP policy regression"),
        ([sys.executable, "tooling/validate/behavior.py"], "routing fixtures"),
        ([sys.executable, "tooling/validate/suite_audit.py"], "suite audit"),
    ]
    for command, label in commands:
        completed = subprocess.run(command, cwd=root, capture_output=True, text=True)
        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout or "failed").strip().splitlines()
            summary = detail[0] if detail else "failed"
            errors.append(f"static check failed ({label}): {summary}")
    return errors


def collect_evidence_targets(
    runtimes: list[str],
    evidence_files: list[str],
    known_runtimes: set[str],
    evidence_dir: Path = EVIDENCE_DIR,
    root: Path = ROOT,
) -> tuple[list[tuple[Path, str]], list[str]]:
    """Return (path, expected_runtime) pairs and collection errors.

    Explicit --evidence paths must either:
    - use a `<registered-runtime>-*.json` filename, or
    - be paired with exactly one --runtime=<name> when only one evidence file is supplied.

    When --evidence is provided, do not also require auto-discovered
    release-evidence/<runtime>-*.json files for the listed --runtime values.
    """
    errors: list[str] = []
    targets: list[tuple[Path, str]] = []

    for runtime in runtimes:
        if runtime not in known_runtimes:
            errors.append(f"unsupported runtime: {runtime}")

    # Discovery mode: --runtime only.
    if runtimes and not evidence_files:
        for runtime in runtimes:
            if runtime not in known_runtimes:
                continue
            latest = find_latest_attestation(runtime, evidence_dir=evidence_dir)
            if latest is None:
                errors.append(
                    f"missing live attestation for runtime {runtime!r} under {evidence_dir}/"
                )
                continue
            targets.append((latest, runtime))

    single_runtime_hint = runtimes[0] if len(runtimes) == 1 else None
    for raw in evidence_files:
        path = Path(raw).expanduser()
        resolved = path if path.is_absolute() else (root / path)
        inferred = infer_runtime_from_filename(resolved, known_runtimes)
        if inferred is not None:
            targets.append((resolved, inferred))
            continue
        if single_runtime_hint is not None and len(evidence_files) == 1:
            # Allow: --runtime=codex --evidence=/tmp/attestation.json
            targets.append((resolved, single_runtime_hint))
            continue
        errors.append(
            f"{resolved}: cannot bind evidence file to a registered runtime; "
            "name it <runtime>-*.json or pass exactly one --runtime=<name> with one --evidence file"
        )

    return targets, errors


def verify(
    runtimes: list[str],
    evidence_files: list[str],
    require_tag: str = "",
    skip_static: bool = False,
    root: Path = ROOT,
    evidence_dir: Path = EVIDENCE_DIR,
) -> list[str]:
    version = package_version(root)
    rev = git_rev(root)
    known = registered_runtimes(root)
    errors: list[str] = []

    if not skip_static:
        errors.extend(run_static_checks(root))

    if require_tag:
        ok, detail = git_tag_points_to_head(require_tag, root=root)
        if not ok:
            errors.append(f"require-tag {require_tag!r} does not point at HEAD: {detail}")
        expected_tag = f"v{version}"
        if require_tag != expected_tag:
            errors.append(
                f"require-tag {require_tag!r} does not match package version tag {expected_tag!r}"
            )

    targets, collect_errors = collect_evidence_targets(
        runtimes,
        evidence_files,
        known,
        evidence_dir=evidence_dir,
        root=root,
    )
    errors.extend(collect_errors)

    if not targets and not runtimes and not evidence_files:
        errors.append("provide --runtime and/or --evidence attestation files to verify")

    seen: set[Path] = set()
    for path, expected_runtime in targets:
        if path in seen:
            continue
        seen.add(path)
        if not path.exists():
            errors.append(f"attestation file missing: {path}")
            continue
        # Filename-inferred runtime (from --evidence) and explicit --runtime both bind.
        errors.extend(
            validate_attestation(
                path,
                version,
                rev,
                expected_runtime=expected_runtime,
                known_runtimes=known,
            )
        )

    return errors


def self_test() -> int:
    """Regression fixtures for runtime binding and git revision requirements."""
    failures: list[str] = []
    version = "2026.07.10"
    head = "abc123def456"
    known = {"codex", "pi", "claude-code"}

    def write(path: Path, runtime: str, rev: str) -> None:
        payload = {
            "schema_version": 1,
            "record_type": "operator-attestation",
            "evidence_class": "live",
            "package": {"name": "b-agentic", "version": version, "git_rev": rev},
            "runtime": {"name": runtime},
            "gates": [{"name": gate, "status": "pass", "note": ""} for gate in REQUIRED_GATES],
            "operator_attested_all_gates_pass": True,
            "release_eligible": rev != "unknown",
        }
        path.write_text(json.dumps(payload, indent=2) + "\n")

    with tempfile.TemporaryDirectory(prefix="b-agentic-release-evidence-") as tmp:
        tmp_path = Path(tmp)
        good = tmp_path / "codex-good.json"
        mismatched = tmp_path / "codex-mismatch.json"
        unknown_rev = tmp_path / "codex-unknown.json"
        arbitrary = tmp_path / "arbitrary.json"
        write(good, "codex", head)
        write(mismatched, "pi", head)  # filename claims codex, body claims pi
        write(unknown_rev, "codex", "unknown")
        write(arbitrary, "not-a-registered-runtime", head)

        # Exact match should pass.
        errs = validate_attestation(
            good, version, head, expected_runtime="codex", known_runtimes=known
        )
        if errs:
            failures.append(f"good attestation unexpectedly failed: {errs}")

        # Filename/runtime mismatch must fail.
        errs = validate_attestation(
            mismatched, version, head, expected_runtime="codex", known_runtimes=known
        )
        if not any("runtime.name 'pi' != expected runtime 'codex'" in item for item in errs):
            failures.append(f"mismatched runtime not rejected: {errs}")

        # Explicit evidence path with inferred filename runtime must also reject body mismatch.
        inferred = infer_runtime_from_filename(mismatched, known)
        if inferred != "codex":
            failures.append(f"filename inference failed: {inferred!r}")
        errs = validate_attestation(
            mismatched, version, head, expected_runtime=inferred, known_runtimes=known
        )
        if not errs:
            failures.append("explicit evidence path accepted runtime mismatch")

        # unknown git rev must fail even when expected_rev is available.
        errs = validate_attestation(
            unknown_rev, version, head, expected_runtime="codex", known_runtimes=known
        )
        if not any("package.git_rev 'unknown'" in item for item in errs):
            failures.append(f"unknown git_rev not rejected: {errs}")

        # release_eligible=false must fail.
        payload = json.loads(good.read_text())
        payload["release_eligible"] = False
        bad_eligible = tmp_path / "codex-ineligible.json"
        bad_eligible.write_text(json.dumps(payload) + "\n")
        errs = validate_attestation(
            bad_eligible, version, head, expected_runtime="codex", known_runtimes=known
        )
        if not any("release_eligible=false" in item for item in errs):
            failures.append(f"release_eligible=false not rejected: {errs}")

        # Empty expected_rev must fail closed.
        errs = validate_attestation(
            good, version, "", expected_runtime="codex", known_runtimes=known
        )
        if not any("HEAD could not be resolved" in item for item in errs):
            failures.append(f"empty HEAD not rejected: {errs}")

        # Arbitrary evidence filename with unregistered runtime.name must fail.
        # This is the exact bypass: --evidence=arbitrary.json and no runtime binding.
        inferred_arbitrary = infer_runtime_from_filename(arbitrary, known)
        if inferred_arbitrary is not None:
            failures.append(f"arbitrary filename unexpectedly inferred runtime: {inferred_arbitrary!r}")
        targets, collect_errors = collect_evidence_targets(
            runtimes=[],
            evidence_files=[str(arbitrary)],
            known_runtimes=known,
            evidence_dir=tmp_path,
            root=tmp_path,
        )
        if targets:
            failures.append(f"arbitrary evidence path was accepted as target: {targets}")
        if not any("cannot bind evidence file to a registered runtime" in item for item in collect_errors):
            failures.append(f"arbitrary evidence path not rejected at collection: {collect_errors}")
        # Even if a caller forced expected_runtime=None, validation must still reject.
        errs = validate_attestation(
            arbitrary, version, head, expected_runtime=None, known_runtimes=known
        )
        if not any("is not a registered runtime" in item for item in errs):
            failures.append(f"unregistered runtime.name not rejected: {errs}")
        if not any("expected runtime could not be determined" in item for item in errs):
            failures.append(f"missing expected runtime not rejected: {errs}")

        # Paired form is allowed: --runtime=codex --evidence=arbitrary.json
        targets, collect_errors = collect_evidence_targets(
            runtimes=["codex"],
            evidence_files=[str(arbitrary)],
            known_runtimes=known,
            evidence_dir=tmp_path,
            root=tmp_path,
        )
        if collect_errors:
            failures.append(f"paired --runtime/--evidence unexpectedly failed collection: {collect_errors}")
        if not any(path == arbitrary and runtime == "codex" for path, runtime in targets):
            failures.append(f"paired --runtime/--evidence missing codex target: {targets}")
        # Body still must match the bound runtime and be registered.
        errs = validate_attestation(
            arbitrary, version, head, expected_runtime="codex", known_runtimes=known
        )
        if not any("is not a registered runtime" in item for item in errs):
            failures.append(f"paired path accepted unregistered runtime body: {errs}")

    if failures:
        for item in failures:
            print(item, file=sys.stderr)
        print("release evidence self-test failed", file=sys.stderr)
        return 1

    print("Release evidence self-test passed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify operator release attestations and optional static release gates. "
            "Does not execute live runtime sessions."
        )
    )
    parser.add_argument(
        "--runtime",
        action="append",
        dest="runtimes",
        default=[],
        help="Runtime that must have a live attestation (repeatable).",
    )
    parser.add_argument(
        "--evidence",
        action="append",
        dest="evidence_files",
        default=[],
        help="Explicit attestation file path (repeatable).",
    )
    parser.add_argument(
        "--require-tag",
        default="",
        help="Optional immutable tag name that must point at HEAD (for example v2026.07.10).",
    )
    parser.add_argument(
        "--skip-static",
        action="store_true",
        help="Skip static validation/audit commands.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run built-in regression fixtures and exit.",
    )
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    errors = verify(
        runtimes=args.runtimes,
        evidence_files=args.evidence_files,
        require_tag=args.require_tag,
        skip_static=args.skip_static,
    )

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        print(
            "Release evidence verification failed. "
            "Attestations are operator claims; static checks and tags are verified separately.",
            file=sys.stderr,
        )
        return 1

    version = package_version()
    print(
        "Release evidence verification passed "
        f"(version={version}, static={'skipped' if args.skip_static else 'ok'})."
    )
    print(
        "Note: this verifies attestation shape/runtime/revision consistency and static gates; "
        "it does not independently re-run live interactive sessions."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
