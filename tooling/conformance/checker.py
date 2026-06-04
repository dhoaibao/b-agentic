from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import argparse
import json
import re
import sys

from tooling.policy.load import load_output_policy


ROOT = Path(__file__).resolve().parents[2]
SKILL_REGISTRY_PATH = ROOT / "skills" / "registry.yaml"
BLOCK_RE = re.compile(r"```text\s*\n(?P<body>\[(?:status|handoff)\][\s\S]*?)\n```", re.MULTILINE)
FIELD_RE = re.compile(r"^(?P<key>[a-z-]+):\s(?P<value>.+)$")
VERIFICATION_RE = re.compile(
    r"(^|\n)(Verification:|Coverage / Tests / Operability:|Coverage/Tests/Observability:|Checked and clean:)",
    re.MULTILINE,
)
COMMAND_RE = re.compile(r"`(?P<command>[^`]+)`")
COMMAND_START_RE = re.compile(
    r"^(?:[A-Za-z_][A-Za-z0-9_-]*=[^\s]+\s+)*(?:"
    r"(?:bash|sh|zsh|python3?|node|npm|pnpm|yarn|bun|npx|cargo|go|pytest|ruff|mypy|tsc|git|gh|make|cmake|gradle|mvn|swift|ruby|bundle|rspec|deno|jq|rg|fd|grep|sed|awk|scripts/|\./)"
    r")(?:\s|$)"
)
FAILED_VERIFICATION_RE = re.compile(
    r"\b(fail(?:ed|ing)?|error|errored|skipp?ed|not run|did not run|not executed)\b",
    re.IGNORECASE,
)
UNRESOLVED_BROWSER_GAP_RE = re.compile(
    r"(real-browser/visual/e2e evidence remains relevant but absent|browser gap|unresolved browser gap)",
    re.IGNORECASE,
)
RUN_ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[a-z0-9-]+$")


@dataclass
class ParsedBlock:
    kind: str
    fields: dict[str, str]
    raw: str


def display_path(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def load_skill_names() -> set[str]:
    registry = json.loads(SKILL_REGISTRY_PATH.read_text())
    names: set[str] = set()
    for skill in registry.get("skills", []):
        if isinstance(skill, dict):
            name = skill.get("name")
            if isinstance(name, str) and name:
                names.add(name)
    return names


def parse_blocks(text: str) -> tuple[list[ParsedBlock], list[str]]:
    blocks: list[ParsedBlock] = []
    errors: list[str] = []

    for match in BLOCK_RE.finditer(text):
        raw = match.group("body")
        lines = [line.rstrip() for line in raw.splitlines() if line.strip()]
        if not lines:
            errors.append("empty fenced block")
            continue

        header = lines[0].strip()
        if header not in {"[status]", "[handoff]"}:
            errors.append(f"unknown block header {header!r}")
            continue

        fields: dict[str, str] = {}
        for line in lines[1:]:
            field_match = FIELD_RE.match(line)
            if not field_match:
                errors.append(f"{header}: malformed field line {line!r}")
                continue
            key = field_match.group("key")
            value = field_match.group("value")
            if key in fields:
                errors.append(f"{header}: duplicate field {key!r}")
                continue
            fields[key] = value

        blocks.append(ParsedBlock(kind=header[1:-1], fields=fields, raw=raw))

    if not blocks:
        errors.append("no [status] or [handoff] fenced block found")

    return blocks, errors


def has_verification_evidence(text: str) -> bool:
    for match in VERIFICATION_RE.finditer(text):
        section_start = match.end()
        status_start = text.find("```text\n[status]", section_start)
        handoff_start = text.find("```text\n[handoff]", section_start)
        block_starts = [index for index in [status_start, handoff_start] if index != -1]
        section_end = min(block_starts) if block_starts else len(text)
        section = text[section_start:section_end]
        for line in section.splitlines():
            commands = [match.group("command").strip() for match in COMMAND_RE.finditer(line)]
            if any(COMMAND_START_RE.search(command) for command in commands) and not FAILED_VERIFICATION_RE.search(line):
                return True
    return False


def has_browser_evidence_gap(text: str) -> bool:
    return bool(UNRESOLVED_BROWSER_GAP_RE.search(text))


def has_named_artifacts(value: str | None) -> bool:
    if not value:
        return False
    return value.strip().lower() != "none"


def validate_status_block(
    block: ParsedBlock,
    transcript: str,
    policy: dict,
    skill_names: set[str],
) -> list[str]:
    errors: list[str] = []
    fields = block.fields
    status_policy = policy["status_block"]
    required = set(status_policy["required_fields"])
    optional = set(status_policy["optional_fields"])
    allowed_fields = required | optional

    missing = sorted(required - set(fields))
    for field in missing:
        errors.append(f"[status]: missing required field {field!r}")

    unknown = sorted(set(fields) - allowed_fields)
    for field in unknown:
        errors.append(f"[status]: unknown field {field!r}")

    state = fields.get("state")
    if state and state not in status_policy["state_values"]:
        errors.append(f"[status]: unknown state {state!r}")

    skill = fields.get("skill")
    if skill and skill not in skill_names:
        errors.append(f"[status]: unknown skill {skill!r}")

    next_skill = fields.get("next")
    if next_skill and next_skill != "none" and next_skill not in skill_names:
        errors.append(f"[status]: unknown next skill {next_skill!r}")

    cause = fields.get("cause")
    if state in {"blocked", "needs-input"}:
        if not cause:
            errors.append(f"[status]: state {state!r} requires a cause")
        elif cause not in policy["cause_classes"]:
            errors.append(f"[status]: unknown cause {cause!r}")
    elif cause:
        errors.append(f"[status]: cause must be omitted when state is {state!r}")

    verdict = fields.get("verdict")
    verdict_owners = policy["skill_verdicts"]
    if skill in verdict_owners:
        if not verdict:
            errors.append(f"[status]: skill {skill!r} requires a verdict")
        elif verdict not in verdict_owners[skill]:
            errors.append(f"[status]: unknown verdict {verdict!r} for {skill}")
    elif verdict:
        errors.append(f"[status]: skill {skill!r} must not emit verdict {verdict!r}")

    run_id = fields.get("run-id")
    if run_id and not RUN_ID_RE.match(run_id):
        errors.append(f"[status]: invalid run-id {run_id!r}")
    elif not run_id:
        if has_named_artifacts(fields.get("artifacts")):
            errors.append("[status]: run-id is required when artifacts are named")

    if verdict == "READY FOR PR":
        if not has_verification_evidence(transcript):
            errors.append("[status]: READY FOR PR requires explicit passing verification command evidence in the transcript")
        if has_browser_evidence_gap(transcript):
            errors.append("[status]: READY FOR PR cannot be used while unresolved browser evidence gaps are present")

    if verdict == "READY WITH FOLLOW-UPS":
        if "follow-up" not in transcript.lower() and "skipped" not in transcript.lower():
            errors.append("[status]: READY WITH FOLLOW-UPS requires a follow-up or skipped-check signal in the transcript")

    if verdict == "NEEDS FIXES" and "findings" not in transcript.lower():
        errors.append("[status]: NEEDS FIXES requires findings context in the transcript")

    return errors


def validate_handoff_block(
    block: ParsedBlock,
    policy: dict,
    skill_names: set[str],
) -> list[str]:
    errors: list[str] = []
    fields = block.fields
    handoff_policy = policy["handoff_block"]
    required = set(handoff_policy["required_fields"])
    optional = set(handoff_policy["optional_fields"])
    allowed_fields = required | optional

    missing = sorted(required - set(fields))
    for field in missing:
        errors.append(f"[handoff]: missing required field {field!r}")

    unknown = sorted(set(fields) - allowed_fields)
    for field in unknown:
        errors.append(f"[handoff]: unknown field {field!r}")

    source = fields.get("source")
    if source and source not in skill_names:
        errors.append(f"[handoff]: unknown source skill {source!r}")

    next_skill = fields.get("next-skill")
    if next_skill and next_skill not in skill_names:
        errors.append(f"[handoff]: unknown next skill {next_skill!r}")

    run_id = fields.get("run-id")
    if run_id and not RUN_ID_RE.match(run_id):
        errors.append(f"[handoff]: invalid run-id {run_id!r}")
    elif not run_id:
        if has_named_artifacts(fields.get("files")):
            errors.append("[handoff]: run-id is required when files are named")

    return errors


def check_transcript(path: Path) -> list[str]:
    transcript = path.read_text()
    errors: list[str] = []
    _, policy = load_output_policy(errors)
    if errors or not isinstance(policy, dict):
        return errors or ["policy model could not be loaded"]

    required_policy_keys = {"status_block", "handoff_block", "cause_classes", "skill_verdicts", "readiness"}
    missing_policy_keys = sorted(required_policy_keys - set(policy))
    if missing_policy_keys:
        errors.append(
            "policy model is incomplete: missing "
            + ", ".join(repr(key) for key in missing_policy_keys)
        )
        return errors

    skill_names = load_skill_names()
    blocks, parse_errors = parse_blocks(transcript)
    errors.extend(parse_errors)

    for block in blocks:
        if block.kind == "status":
            errors.extend(validate_status_block(block, transcript, policy, skill_names))
        elif block.kind == "handoff":
            errors.extend(validate_handoff_block(block, policy, skill_names))

    return errors


def run_fixture_suite(manifest_path: Path) -> list[str]:
    manifest = json.loads(manifest_path.read_text())
    errors: list[str] = []
    cases = manifest.get("cases")
    if not isinstance(cases, list):
        return [f"{display_path(manifest_path)}: missing cases array"]

    for index, case in enumerate(cases):
        if not isinstance(case, dict):
            errors.append(f"{display_path(manifest_path)}: case {index} must be an object")
            continue
        path_value = case.get("path")
        expected_valid = case.get("valid")
        expected_error = case.get("error_contains")
        simulate_policy_failure = case.get("simulate_policy_failure", False)
        if not isinstance(path_value, str) or not isinstance(expected_valid, bool):
            errors.append(f"{display_path(manifest_path)}: case {index} missing path/valid")
            continue

        case_path = ROOT / path_value
        if not isinstance(simulate_policy_failure, bool):
            errors.append(f"{display_path(manifest_path)}: case {index} invalid simulate_policy_failure flag")
            continue

        if simulate_policy_failure:
            original_load_output_policy = load_output_policy

            def fake_load_output_policy(load_errors: list[str]) -> tuple[dict, dict]:
                load_errors.append("simulated policy failure")
                return {}, {}

            globals()["load_output_policy"] = fake_load_output_policy
            try:
                case_errors = check_transcript(case_path)
            finally:
                globals()["load_output_policy"] = original_load_output_policy
        else:
            case_errors = check_transcript(case_path)

        if expected_valid and case_errors:
            errors.append(f"{path_value}: expected valid, got errors: {'; '.join(case_errors)}")
        if not expected_valid and not case_errors:
            errors.append(f"{path_value}: expected invalid, but checker passed")
        if not expected_valid and isinstance(expected_error, str):
            if not any(expected_error in err for err in case_errors):
                errors.append(
                    f"{path_value}: expected an error containing {expected_error!r}, got: {'; '.join(case_errors)}"
                )

    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Check b-agentic transcript conformance.")
    parser.add_argument("path", nargs="?", help="Transcript file to check")
    parser.add_argument("--self-test", dest="self_test", help="Fixture manifest to validate")
    args = parser.parse_args(argv)

    if args.self_test:
        errors = run_fixture_suite((ROOT / args.self_test) if not Path(args.self_test).is_absolute() else Path(args.self_test))
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        print("Conformance fixture suite passed.")
        return 0

    if not args.path:
        parser.error("path is required unless --self-test is used")

    path = (ROOT / args.path) if not Path(args.path).is_absolute() else Path(args.path)
    errors = check_transcript(path)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print(f"{display_path(path)}: conformance passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
