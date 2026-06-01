from __future__ import annotations

from pathlib import Path
import json
import re


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "tooling" / "policy" / "schema.json"
POLICY_PATH = ROOT / "tooling" / "policy" / "output-policy.json"


def _load_json(path: Path, errors: list[str]) -> dict:
    rel_path = path.relative_to(ROOT).as_posix()
    if not path.exists():
        errors.append(f"{rel_path}: missing")
        return {}

    try:
        data = json.loads(path.read_text())
    except Exception as exc:  # pragma: no cover - exercised by validation command
        errors.append(f"{rel_path}: invalid JSON: {exc}")
        return {}

    if not isinstance(data, dict):
        errors.append(f"{rel_path}: top level must be an object")
        return {}
    return data


def _require_keys(data: dict, keys: list[str], label: str, errors: list[str]) -> None:
    for key in keys:
        if key not in data:
            errors.append(f"{label}: missing required key {key!r}")


def _require_string_list(value: object, label: str, errors: list[str]) -> list[str]:
    if not isinstance(value, list) or not value:
        errors.append(f"{label}: expected non-empty array")
        return []

    cleaned: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item:
            errors.append(f"{label}[{index}]: expected non-empty string")
            continue
        cleaned.append(item)

    if len(cleaned) != len(set(cleaned)):
        errors.append(f"{label}: duplicate values are not allowed")
    return cleaned


def load_output_policy(errors: list[str]) -> tuple[dict, dict]:
    schema = _load_json(SCHEMA_PATH, errors)
    policy = _load_json(POLICY_PATH, errors)
    if not schema or not policy:
        return schema, policy

    schema_required = schema.get("top_level_required")
    if not isinstance(schema_required, list):
        errors.append("tooling/policy/schema.json: top_level_required must be an array")
        return schema, policy
    _require_keys(policy, schema_required, "tooling/policy/output-policy.json", errors)

    if policy.get("policy_version") != schema.get("version"):
        errors.append(
            "tooling/policy/output-policy.json: policy_version must match tooling/policy/schema.json version"
        )

    status_block = policy.get("status_block")
    if not isinstance(status_block, dict):
        errors.append("tooling/policy/output-policy.json: status_block must be an object")
    else:
        _require_keys(
            status_block,
            schema.get("status_block_required", []),
            "tooling/policy/output-policy.json status_block",
            errors,
        )
        states = _require_string_list(
            status_block.get("state_values"),
            "tooling/policy/output-policy.json status_block.state_values",
            errors,
        )
        if states and states != schema.get("allowed_status_states", []):
            errors.append(
                "tooling/policy/output-policy.json: status_block.state_values must match schema allowed_status_states"
            )
        confidence = _require_string_list(
            status_block.get("confidence_values"),
            "tooling/policy/output-policy.json status_block.confidence_values",
            errors,
        )
        if confidence and confidence != schema.get("allowed_confidence_values", []):
            errors.append(
                "tooling/policy/output-policy.json: status_block.confidence_values must match schema allowed_confidence_values"
            )
        _require_string_list(
            status_block.get("required_fields"),
            "tooling/policy/output-policy.json status_block.required_fields",
            errors,
        )
        _require_string_list(
            status_block.get("optional_fields"),
            "tooling/policy/output-policy.json status_block.optional_fields",
            errors,
        )
        run_id_format = status_block.get("run_id_format")
        if not isinstance(run_id_format, str) or not run_id_format:
            errors.append(
                "tooling/policy/output-policy.json status_block.run_id_format: expected non-empty string"
            )
        elif "run-id:" in run_id_format:
            errors.append(
                "tooling/policy/output-policy.json status_block.run_id_format: store the format token only, not the full field label"
            )
        conditions = status_block.get("run_id_conditions")
        if not isinstance(conditions, list) or not conditions:
            errors.append(
                "tooling/policy/output-policy.json status_block.run_id_conditions: expected non-empty array"
            )
        else:
            seen_conditions = set()
            for index, item in enumerate(conditions):
                if not isinstance(item, dict):
                    errors.append(
                        f"tooling/policy/output-policy.json status_block.run_id_conditions[{index}]: expected object"
                    )
                    continue
                condition = item.get("condition")
                include = item.get("include")
                if not isinstance(condition, str) or not condition:
                    errors.append(
                        f"tooling/policy/output-policy.json status_block.run_id_conditions[{index}].condition: expected non-empty string"
                    )
                elif condition in seen_conditions:
                    errors.append(
                        "tooling/policy/output-policy.json status_block.run_id_conditions: duplicate condition names are not allowed"
                    )
                else:
                    seen_conditions.add(condition)
                if not isinstance(include, bool):
                    errors.append(
                        f"tooling/policy/output-policy.json status_block.run_id_conditions[{index}].include: expected boolean"
                    )

    handoff_block = policy.get("handoff_block")
    if not isinstance(handoff_block, dict):
        errors.append("tooling/policy/output-policy.json: handoff_block must be an object")
    else:
        _require_keys(
            handoff_block,
            schema.get("handoff_block_required", []),
            "tooling/policy/output-policy.json handoff_block",
            errors,
        )
        _require_string_list(
            handoff_block.get("required_fields"),
            "tooling/policy/output-policy.json handoff_block.required_fields",
            errors,
        )
        _require_string_list(
            handoff_block.get("optional_fields"),
            "tooling/policy/output-policy.json handoff_block.optional_fields",
            errors,
        )

    cause_classes = _require_string_list(
        policy.get("cause_classes"),
        "tooling/policy/output-policy.json cause_classes",
        errors,
    )
    cause_pattern = schema.get("cause_class_pattern")
    if isinstance(cause_pattern, str):
        matcher = re.compile(cause_pattern)
        for cause in cause_classes:
            if not matcher.match(cause):
                errors.append(
                    f"tooling/policy/output-policy.json cause_classes: invalid cause class {cause!r}"
                )

    verdicts = policy.get("skill_verdicts")
    if not isinstance(verdicts, dict):
        errors.append("tooling/policy/output-policy.json: skill_verdicts must be an object")
    else:
        for owner in schema.get("required_verdict_owners", []):
            owner_verdicts = _require_string_list(
                verdicts.get(owner),
                f"tooling/policy/output-policy.json skill_verdicts.{owner}",
                errors,
            )
            if not owner_verdicts:
                errors.append(
                    f"tooling/policy/output-policy.json: missing verdict definitions for {owner}"
                )

    readiness = policy.get("readiness")
    if not isinstance(readiness, dict):
        errors.append("tooling/policy/output-policy.json: readiness must be an object")
    else:
        _require_keys(
            readiness,
            schema.get("readiness_required", []),
            "tooling/policy/output-policy.json readiness",
            errors,
        )
        _require_string_list(
            readiness.get("review_ready_for_pr_requires"),
            "tooling/policy/output-policy.json readiness.review_ready_for_pr_requires",
            errors,
        )
        browser_evidence = readiness.get("browser_evidence_prerequisites")
        if not isinstance(browser_evidence, dict):
            errors.append(
                "tooling/policy/output-policy.json readiness.browser_evidence_prerequisites: expected object"
            )
        else:
            for key in ["applies_to", "required_for"]:
                value = browser_evidence.get(key)
                if not isinstance(value, str) or not value:
                    errors.append(
                        f"tooling/policy/output-policy.json readiness.browser_evidence_prerequisites.{key}: expected non-empty string"
                    )
            _require_string_list(
                browser_evidence.get("accepted_sources"),
                "tooling/policy/output-policy.json readiness.browser_evidence_prerequisites.accepted_sources",
                errors,
            )

    modes = policy.get("modes")
    if not isinstance(modes, dict):
        errors.append("tooling/policy/output-policy.json: modes must be an object")
    else:
        _require_keys(
            modes,
            schema.get("modes_required", []),
            "tooling/policy/output-policy.json modes",
            errors,
        )
        default_mode = modes.get("default")
        allowed_modes = _require_string_list(
            modes.get("allowed"),
            "tooling/policy/output-policy.json modes.allowed",
            errors,
        )
        if allowed_modes and allowed_modes != schema.get("allowed_modes", []):
            errors.append(
                "tooling/policy/output-policy.json: modes.allowed must match schema allowed_modes"
            )
        if not isinstance(default_mode, str) or not default_mode:
            errors.append("tooling/policy/output-policy.json modes.default: expected non-empty string")
        elif allowed_modes and default_mode not in allowed_modes:
            errors.append("tooling/policy/output-policy.json modes.default: must be one of modes.allowed")
        _require_string_list(
            modes.get("lite_when"),
            "tooling/policy/output-policy.json modes.lite_when",
            errors,
        )
        _require_string_list(
            modes.get("strict_when"),
            "tooling/policy/output-policy.json modes.strict_when",
            errors,
        )
        _require_string_list(
            modes.get("override_rules"),
            "tooling/policy/output-policy.json modes.override_rules",
            errors,
        )

    return schema, policy


def validate_output_policy_contract(policy: dict, contract_text: str, errors: list[str]) -> None:
    if not policy or not contract_text:
        return

    status_block = policy["status_block"]
    handoff_block = policy["handoff_block"]

    for field in status_block["required_fields"] + status_block["optional_fields"]:
        if f"{field}:" not in contract_text:
            errors.append(
                f"references/contract/09-output.md: missing status-block field marker {field!r} required by tooling/policy/output-policy.json"
            )

    for field in handoff_block["required_fields"] + handoff_block["optional_fields"]:
        if f"{field}:" not in contract_text:
            errors.append(
                f"references/contract/09-output.md: missing handoff field marker {field!r} required by tooling/policy/output-policy.json"
            )

    for state in status_block["state_values"]:
        if f"- `{state}`" not in contract_text:
            errors.append(
                f"references/contract/09-output.md: missing state value {state!r} from tooling/policy/output-policy.json"
            )

    expected_run_id_line = f"run-id: {status_block['run_id_format']}"
    if contract_text.count(expected_run_id_line) < 2:
        errors.append(
            "references/contract/09-output.md: missing run-id format line "
            f"{expected_run_id_line!r} in both status and handoff blocks"
        )

    for condition in status_block["run_id_conditions"]:
        expected_include = "Yes" if condition["include"] else "Omit"
        table_row = f"| {condition['condition']} | {expected_include} |"
        if table_row not in contract_text:
            errors.append(
                "references/contract/09-output.md: missing run-id condition row "
                f"{table_row!r} from tooling/policy/output-policy.json"
            )

    for cause in policy["cause_classes"]:
        if f"| `{cause}` |" not in contract_text:
            errors.append(
                f"references/contract/09-output.md: missing cause class {cause!r} from tooling/policy/output-policy.json"
            )

    for owner, owner_verdicts in policy["skill_verdicts"].items():
        for verdict in owner_verdicts:
            if f"| `{verdict}` |" not in contract_text:
                errors.append(
                    f"references/contract/09-output.md: missing verdict {verdict!r} for {owner} from tooling/policy/output-policy.json"
                )

    readiness = policy["readiness"]
    for requirement in readiness.get("workflow_ready_for_pr_requires", []):
        if requirement not in contract_text:
            errors.append(
                "references/contract/09-output.md: missing workflow readiness requirement "
                f"{requirement!r} from tooling/policy/output-policy.json"
            )
    for requirement in readiness["review_ready_for_pr_requires"]:
        if requirement not in contract_text:
            errors.append(
                "references/contract/09-output.md: missing review readiness requirement "
                f"{requirement!r} from tooling/policy/output-policy.json"
            )

    browser_evidence = readiness["browser_evidence_prerequisites"]
    for required_text in [browser_evidence["required_for"], browser_evidence["applies_to"]]:
        if required_text not in contract_text:
            errors.append(
                "references/contract/09-output.md: missing browser-evidence readiness text "
                f"{required_text!r} from tooling/policy/output-policy.json"
            )
    for source in browser_evidence["accepted_sources"]:
        if source not in contract_text:
            errors.append(
                "references/contract/09-output.md: missing browser-evidence source "
                f"{source!r} from tooling/policy/output-policy.json"
            )


def validate_mode_policy_contract(
    policy: dict,
    definitions_text: str,
    kernel_text: str,
    readme_text: str,
    errors: list[str],
) -> None:
    if not policy:
        return

    modes = policy.get("modes")
    if not isinstance(modes, dict):
        return

    for mode in modes["allowed"]:
        for label, text in [
            ("references/contract/03-definitions.md", definitions_text),
            ("references/contract/kernel.template.md", kernel_text),
            ("README.md", readme_text),
        ]:
            if mode not in text:
                errors.append(
                    f"{label}: missing mode {mode!r} from tooling/policy/output-policy.json"
                )

    for trigger in modes["strict_when"]:
        if trigger not in definitions_text:
            errors.append(
                "references/contract/03-definitions.md: missing strict trigger "
                f"{trigger!r} from tooling/policy/output-policy.json"
            )

    for rule in modes["override_rules"]:
        if rule not in definitions_text:
            errors.append(
                "references/contract/03-definitions.md: missing mode override rule "
                f"{rule!r} from tooling/policy/output-policy.json"
            )
