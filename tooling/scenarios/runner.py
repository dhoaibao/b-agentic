from __future__ import annotations

from pathlib import Path
import argparse
import json
import sys

from tooling.conformance.checker import check_transcript, parse_blocks


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "tooling" / "scenarios" / "schema.json"


def _display_path(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def _load_json(path: Path) -> dict:
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"{_display_path(path)}: top level must be an object")
    return data


def _validate_schema(manifest: dict, schema: dict) -> list[str]:
    errors: list[str] = []
    for key in schema["top_level_required"]:
        if key not in manifest:
            errors.append(f"scenario manifest missing required key {key!r}")

    cases = manifest.get("cases")
    if not isinstance(cases, list) or not cases:
        errors.append("scenario manifest cases must be a non-empty array")
        return errors

    allowed_kinds = set(schema["allowed_kinds"])
    allowed_route_fields = set(schema["allowed_route_fields"])
    allowed_failure_modes = set(schema["allowed_failure_modes"])
    allowed_optional_fields = set(schema.get("case_optional", []))
    allowed_case_fields = set(schema["case_required"]) | allowed_optional_fields

    for index, case in enumerate(cases):
        if not isinstance(case, dict):
            errors.append(f"scenario case {index} must be an object")
            continue
        for key in case:
            if key not in allowed_case_fields:
                errors.append(f"scenario case {index} has unsupported key {key!r}")
        for key in schema["case_required"]:
            if key not in case:
                errors.append(f"scenario case {index} missing required key {key!r}")
        kind = case.get("kind")
        if kind not in allowed_kinds:
            errors.append(f"scenario case {index} has invalid kind {kind!r}")
        if not isinstance(case.get("expect_conformance"), bool):
            errors.append(f"scenario case {index} expect_conformance must be boolean")
        expected_route = case.get("expected_route")
        if not isinstance(expected_route, dict) or not expected_route:
            errors.append(f"scenario case {index} expected_route must be a non-empty object")
        else:
            for key in expected_route:
                if key not in allowed_route_fields:
                    errors.append(f"scenario case {index} has unsupported route field {key!r}")
        if not isinstance(case.get("expected_verification"), bool):
            errors.append(f"scenario case {index} expected_verification must be boolean")
        failure_mode = case.get("expected_failure_mode")
        if failure_mode not in allowed_failure_modes:
            errors.append(f"scenario case {index} has invalid expected_failure_mode {failure_mode!r}")
        expected_error = case.get("expected_error_contains")
        if expected_error is not None and not isinstance(expected_error, str):
            errors.append(f"scenario case {index} expected_error_contains must be a string when provided")
        if case.get("expect_conformance") is False and not isinstance(expected_error, str):
            errors.append(
                f"scenario case {index} must set expected_error_contains when expect_conformance is false"
            )

    return errors


def _route_matches(kind: str, fields: dict[str, str], expected_route: dict[str, str]) -> list[str]:
    errors: list[str] = []
    for key, expected in expected_route.items():
        actual = fields.get(key)
        if actual != expected:
            errors.append(
                f"{kind} route field {key!r} mismatch: expected {expected!r}, got {actual!r}"
            )
    return errors


def _has_verification_signal(text: str) -> bool:
    lowered = text.lower()
    return "verification:" in lowered or "coverage / tests / operability:" in lowered or "checked and clean:" in lowered


def run_manifest(manifest_path: Path) -> list[str]:
    schema = _load_json(SCHEMA_PATH)
    manifest = _load_json(manifest_path)
    errors = _validate_schema(manifest, schema)
    if errors:
        return errors

    cases = manifest["cases"]
    for case in cases:
        case_name = case["name"]
        transcript_path = ROOT / case["path"]
        transcript = transcript_path.read_text()
        blocks, parse_errors = parse_blocks(transcript)
        conformance_errors = check_transcript(transcript_path)

        if case["expect_conformance"]:
            if conformance_errors:
                errors.append(f"{case_name}: expected conformance pass, got: {'; '.join(conformance_errors)}")
        else:
            if not conformance_errors:
                errors.append(f"{case_name}: expected conformance failure, but checker passed")
            else:
                expected_error = case["expected_error_contains"]
                if not any(expected_error in error for error in conformance_errors):
                    errors.append(
                        f"{case_name}: expected conformance error containing {expected_error!r}, got: "
                        + "; ".join(conformance_errors)
                    )

        if parse_errors:
            errors.append(f"{case_name}: parse errors: {'; '.join(parse_errors)}")
            continue

        matching_blocks = [block for block in blocks if block.kind == case["kind"]]
        if not matching_blocks:
            errors.append(f"{case_name}: no {case['kind']} block found")
            continue

        block = matching_blocks[0]
        errors.extend(f"{case_name}: {err}" for err in _route_matches(case["kind"], block.fields, case["expected_route"]))

        has_verification = _has_verification_signal(transcript)
        if has_verification != case["expected_verification"]:
            errors.append(
                f"{case_name}: expected_verification={case['expected_verification']}, got {has_verification}"
            )

        failure_mode = case["expected_failure_mode"]
        if failure_mode == "none":
            continue
        actual_failure_mode = block.fields.get("cause")
        if actual_failure_mode != failure_mode:
            errors.append(
                f"{case_name}: expected failure mode {failure_mode!r}, got {actual_failure_mode!r}"
            )

    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run b-agentic workflow scenario fixtures.")
    parser.add_argument("path", nargs="?", help="Scenario manifest to run")
    parser.add_argument("--self-test", dest="self_test", help="Scenario manifest to validate")
    args = parser.parse_args(argv)

    target = args.self_test or args.path
    if not target:
        parser.error("path is required unless --self-test is used")

    manifest_path = (ROOT / target) if not Path(target).is_absolute() else Path(target)
    errors = run_manifest(manifest_path)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print(f"{_display_path(manifest_path)}: scenario suite passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
