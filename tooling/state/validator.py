from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from tooling.state.actions import APPROVAL_REQUIRED, HIGH_RISK, PROJECT_WRITE, UNKNOWN, Action, classify_action
from tooling.state.capabilities import ADVISORY, ENFORCED, UNSUPPORTED, runtime_capabilities
from tooling.state.intent import Intent, parse_intents
from tooling.state.state import State, load_state


@dataclass(frozen=True)
class Decision:
    verdict: str
    reason: str
    risk: str
    capability: str

    @property
    def allowed(self) -> bool:
        return self.verdict in {"allow", "advisory"}


def _strict_enabled(strict: bool | None) -> bool:
    return bool(strict)


def _latest_intent(transcript: str | None, state: State | None) -> tuple[Intent | None, list[str]]:
    if transcript:
        intents, errors = parse_intents(transcript)
        if intents:
            return intents[-1], errors
        if errors:
            return None, errors
    if state and state.pending_intent:
        intent = Intent.from_fields(
            {key: str(value) for key, value in state.pending_intent.items()},
            raw="state.pending_intent",
        )
        return intent, []
    return None, []


def _matches_target(action: Action, intent: Intent) -> bool:
    if action.command and intent.commands:
        return any(command in action.command or action.command in command for command in intent.commands)
    if action.files and intent.files:
        action_files = set(action.files)
        intent_files = set(intent.files)
        return bool(action_files <= intent_files or intent_files <= action_files)
    return False


def _capability_for_risk(action: Action, capability) -> str:
    if action.risk == "dependency-write":
        return capability.pre_action_dependency_write
    if action.risk == "destructive":
        return capability.pre_action_destructive
    return capability.pre_action_project_write


def _has_approval(action: Action, intent: Intent | None, state: State | None) -> bool:
    if action.risk not in APPROVAL_REQUIRED:
        return True
    if intent and intent.approval == "approved":
        return True
    if not state:
        return False
    return any(item.get("risk") == action.risk and item.get("status") == "approved" for item in state.approvals)


def validate_action(
    root: Path,
    payload: dict[str, Any],
    *,
    runtime: str,
    strict: bool | None = None,
    transcript: str | None = None,
) -> Decision:
    strict_mode = _strict_enabled(strict)
    action = classify_action(payload)
    has_action_payload = action.tool != "unknown" or action.command is not None
    capability = runtime_capabilities(runtime, pre_action_payload=has_action_payload, strict=strict_mode)
    risk_capability = _capability_for_risk(action, capability)

    if action.risk == UNKNOWN:
        if strict_mode:
            return Decision("block", action.reason, action.risk, risk_capability)
        return Decision("advisory", action.reason, action.risk, risk_capability)

    if action.risk not in HIGH_RISK:
        return Decision("allow", action.reason, action.risk, risk_capability)

    if not strict_mode:
        return Decision("advisory", "strict mode disabled", action.risk, risk_capability)

    if risk_capability in {ADVISORY, UNSUPPORTED}:
        return Decision("block", f"pre-action capability is {risk_capability}", action.risk, risk_capability)
    if risk_capability != ENFORCED:
        return Decision("block", f"unknown pre-action capability {risk_capability!r}", action.risk, risk_capability)

    try:
        state = load_state(root)
    except Exception as exc:
        return Decision("block", f"invalid state: {exc}", action.risk, risk_capability)

    if state is None:
        return Decision("block", "state file missing; strict enforcement not initialized", action.risk, risk_capability)

    intent, intent_errors = _latest_intent(transcript, state)
    if intent_errors:
        return Decision("block", "; ".join(intent_errors), action.risk, risk_capability)

    if intent is None:
        return Decision("block", "high-risk action requires machine-readable intent", action.risk, risk_capability)
    if state.active_skill and intent.skill != state.active_skill:
        return Decision("block", "intent skill does not match active state skill", action.risk, risk_capability)
    if intent.action != action.risk and not (action.risk == PROJECT_WRITE and intent.action == "project-write"):
        return Decision("block", "intent action does not match classified risk", action.risk, risk_capability)
    if not _matches_target(action, intent):
        return Decision("block", "intent target does not match action target", action.risk, risk_capability)
    if not _has_approval(action, intent, state):
        return Decision("block", "action requires explicit approval", action.risk, risk_capability)

    return Decision("allow", "intent and state validated", action.risk, risk_capability)
