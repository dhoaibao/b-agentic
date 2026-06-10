from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from tooling.state.actions import (
    APPROVAL_REQUIRED,
    HIGH_RISK,
    PROJECT_WRITE,
    UNKNOWN,
    Action,
    classify_action,
    derive_intent_from_action,
)
from tooling.state.capabilities import ADVISORY, ENFORCED, UNSUPPORTED, runtime_capabilities
from tooling.state.intent import Intent, parse_approval_blocks, parse_intents
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
    if strict is None:
        return True  # strict is ON by default
    return strict


def _latest_intent(
    transcript: str | None,
    state: State | None,
    *,
    auto_derive: bool = True,
    action: Action | None = None,
    active_skill: str | None = None,
) -> tuple[Intent | None, list[str]]:
    # 1. Try explicit [intent] blocks in transcript
    if transcript:
        intents, errors = parse_intents(transcript)
        if intents:
            return intents[-1], errors
        if errors:
            return None, errors

    # 2. Try state.pending_intent
    if state and state.pending_intent:
        intent = Intent.from_fields(
            {key: str(value) for key, value in state.pending_intent.items()},
            raw="state.pending_intent",
        )
        return intent, []

    # 3. Auto-derive from action payload
    if auto_derive and action is not None:
        fields = derive_intent_from_action(action, active_skill=active_skill)
        return Intent.from_fields(fields, raw="auto-derived"), []

    return None, []


def _matches_target(action: Action, intent: Intent) -> bool:
    if action.command and intent.commands:
        return any(command in action.command or action.command in command for command in intent.commands)
    if action.files and intent.files:
        action_files = set(action.files)
        intent_files = set(intent.files)
        return action_files <= intent_files
    return False


def _capability_for_risk(action: Action, capability) -> str:
    if action.risk == "dependency-write":
        return capability.pre_action_dependency_write
    if action.risk == "destructive":
        return capability.pre_action_destructive
    return capability.pre_action_project_write


def _has_approval(
    action: Action,
    intent: Intent | None,
    state: State | None,
    transcript: str | None = None,
) -> bool:
    if action.risk not in APPROVAL_REQUIRED:
        return True
    if intent and intent.approval == "approved":
        return True
    # Check transcript for [approval] blocks with affirmative response
    if transcript:
        approvals = parse_approval_blocks(transcript)
        for approval in approvals:
            if action.command and action.command in approval.get("action", ""):
                return True
            if action.files:
                action_files = set(action.files)
                for f in action_files:
                    if f in approval.get("effect", ""):
                        return True
    if not state:
        return False
    return any(item.get("risk") == action.risk and item.get("status") == "approved" for item in state.approvals)


def _state_and_intent(
    root: Path,
    transcript: str | None,
    *,
    auto_derive: bool = True,
    action: Action | None = None,
    active_skill: str | None = None,
) -> tuple[State | None, Intent | None, list[str]]:
    try:
        state = load_state(root)
    except Exception as exc:
        return None, None, [f"invalid state: {exc}"]

    if state is None:
        return None, None, ["state file missing; strict enforcement not initialized"]

    intent, intent_errors = _latest_intent(
        transcript, state, auto_derive=auto_derive, action=action, active_skill=active_skill
    )
    if intent_errors:
        return state, None, intent_errors
    if intent is None:
        return state, None, ["high-risk action requires machine-readable intent"]
    return state, intent, []


def validate_action(
    root: Path,
    payload: dict[str, Any],
    *,
    runtime: str,
    strict: bool | None = None,
    transcript: str | None = None,
    auto_derive: bool = True,
) -> Decision:
    strict_mode = _strict_enabled(strict)
    action = classify_action(payload)
    has_action_payload = action.tool != "unknown" or action.command is not None
    capability = runtime_capabilities(runtime, pre_action_payload=has_action_payload, strict=strict_mode)
    risk_capability = _capability_for_risk(action, capability)

    # Resolve active skill from state for auto-derive
    active_skill: str | None = None
    try:
        state_for_skill = load_state(root)
        if state_for_skill:
            active_skill = state_for_skill.active_skill
    except Exception:
        pass

    if action.risk == UNKNOWN:
        if strict_mode:
            if risk_capability in {ADVISORY, UNSUPPORTED}:
                return Decision("block", f"pre-action capability is {risk_capability}", action.risk, risk_capability)
            if risk_capability != ENFORCED:
                return Decision("block", f"unknown pre-action capability {risk_capability!r}", action.risk, risk_capability)

            state, intent, errors = _state_and_intent(
                root, transcript, auto_derive=auto_derive, action=action, active_skill=active_skill
            )
            if errors:
                return Decision("block", "; ".join(errors), action.risk, risk_capability)
            assert state is not None and intent is not None
            if state.active_skill and intent.skill != state.active_skill:
                return Decision("block", "intent skill does not match active state skill", action.risk, risk_capability)
            if intent.approval != "approved":
                return Decision("block", "unknown action requires explicit approved intent", action.risk, risk_capability)
            if not _matches_target(action, intent):
                return Decision("block", "intent target does not match action target", action.risk, risk_capability)
            return Decision("allow", "approved unknown action intent validated", action.risk, risk_capability)
        return Decision("advisory", action.reason, action.risk, risk_capability)

    if action.risk not in HIGH_RISK:
        return Decision("allow", action.reason, action.risk, risk_capability)

    if not strict_mode:
        return Decision("advisory", "strict mode disabled", action.risk, risk_capability)

    if risk_capability in {ADVISORY, UNSUPPORTED}:
        return Decision("block", f"pre-action capability is {risk_capability}", action.risk, risk_capability)
    if risk_capability != ENFORCED:
        return Decision("block", f"unknown pre-action capability {risk_capability!r}", action.risk, risk_capability)

    state, intent, errors = _state_and_intent(
        root, transcript, auto_derive=auto_derive, action=action, active_skill=active_skill
    )
    if errors:
        return Decision("block", "; ".join(errors), action.risk, risk_capability)
    assert state is not None and intent is not None
    if state.active_skill and intent.skill != state.active_skill:
        return Decision("block", "intent skill does not match active state skill", action.risk, risk_capability)
    if intent.action != action.risk and not (action.risk == PROJECT_WRITE and intent.action == "project-write"):
        return Decision("block", "intent action does not match classified risk", action.risk, risk_capability)
    if not _matches_target(action, intent):
        return Decision("block", "intent target does not match action target", action.risk, risk_capability)
    if not _has_approval(action, intent, state, transcript=transcript):
        return Decision("block", "action requires explicit approval", action.risk, risk_capability)

    return Decision("allow", "intent and state validated", action.risk, risk_capability)
