from __future__ import annotations

from typing import Any


SCHEMA_VERSION = 1

VALID_SKILLS = {
    "b-browser",
    "b-debug",
    "b-implement",
    "b-plan",
    "b-refactor",
    "b-research",
    "b-review",
    "b-ship",
    "b-test",
}

VALID_PHASES = {
    "idle",
    "planning",
    "implementing",
    "refactoring",
    "debugging",
    "testing",
    "browsing",
    "researching",
    "reviewing",
    "shipping",
    "blocked",
}

VALID_ENFORCEMENT = {"enforced", "advisory", "unsupported"}


def validate_state_data(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []

    if data.get("version") != SCHEMA_VERSION:
        errors.append(f"state.version must be {SCHEMA_VERSION}")

    active_skill = data.get("active_skill")
    if active_skill is not None and active_skill not in VALID_SKILLS:
        errors.append(f"state.active_skill is unknown: {active_skill!r}")

    phase = data.get("phase")
    if phase not in VALID_PHASES:
        errors.append(f"state.phase is unknown: {phase!r}")

    if not isinstance(data.get("session_id"), str) or not data.get("session_id"):
        errors.append("state.session_id must be a non-empty string")

    capabilities = data.get("capabilities", {})
    if not isinstance(capabilities, dict):
        errors.append("state.capabilities must be an object")
    else:
        for key, value in capabilities.items():
            if key == "runtime" and isinstance(value, str) and value:
                continue
            if value not in VALID_ENFORCEMENT:
                errors.append(f"state.capabilities.{key} must be enforced, advisory, or unsupported")

    approvals = data.get("approvals", [])
    if not isinstance(approvals, list):
        errors.append("state.approvals must be an array")

    pending_intent = data.get("pending_intent")
    if pending_intent is not None and not isinstance(pending_intent, dict):
        errors.append("state.pending_intent must be null or an object")

    return errors
