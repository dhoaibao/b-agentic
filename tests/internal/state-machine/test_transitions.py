"""Tests for validate_action: allow/block/advisory paths and transition guards."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tooling.state.state import init_state
from tooling.state.validator import validate_action


def test_read_only_action_is_allowed(tmp_path):
    decision = validate_action(tmp_path, {"tool": "read"}, runtime="claude-code")
    assert decision.verdict == "allow"
    assert decision.risk == "read-only"


def test_advisory_verdict_when_strict_off(tmp_path):
    # project-write without state in non-strict mode → advisory
    decision = validate_action(tmp_path, {"tool": "write", "files": ["foo.py"]}, runtime="claude-code", strict=False)
    assert decision.verdict == "advisory"
    assert decision.allowed is True


def test_missing_state_blocks_in_strict_mode(tmp_path):
    # No state file + strict mode → block
    decision = validate_action(
        tmp_path,
        {"tool": "write", "files": ["foo.py"]},
        runtime="claude-code",
        strict=True,
    )
    assert decision.verdict == "block"
    assert decision.allowed is False


def test_valid_approved_project_write_allowed_in_strict_mode(tmp_path):
    init_state(tmp_path, active_skill="b-implement", phase="implementing", capabilities={
        "pre_action_project_write": "enforced",
    })
    # parse_intents requires the intent block wrapped in ```text ... ```
    transcript = (
        "```text\n"
        "[intent]\n"
        "skill: b-implement\n"
        "action: project-write\n"
        "files: foo.py\n"
        "commands: none\n"
        "source: plan\n"
        "approval: not-required\n"
        "reason: adding feature\n"
        "```"
    )
    decision = validate_action(
        tmp_path,
        {"tool": "write", "files": ["foo.py"]},
        runtime="claude-code",
        strict=True,
        transcript=transcript,
    )
    assert decision.verdict == "allow"
    assert decision.allowed is True


def test_intent_skill_mismatch_blocks_in_strict_mode(tmp_path):
    init_state(tmp_path, active_skill="b-plan", phase="planning", capabilities={
        "pre_action_project_write": "enforced",
    })
    transcript = (
        "```text\n"
        "[intent]\n"
        "skill: b-implement\n"
        "action: project-write\n"
        "files: foo.py\n"
        "commands: none\n"
        "source: plan\n"
        "approval: not-required\n"
        "reason: wrong skill\n"
        "```"
    )
    decision = validate_action(
        tmp_path,
        {"tool": "write", "files": ["foo.py"]},
        runtime="claude-code",
        strict=True,
        transcript=transcript,
    )
    assert decision.verdict == "block"
    assert "skill" in decision.reason


def test_destructive_action_requires_approval(tmp_path):
    init_state(tmp_path, active_skill="b-implement", phase="implementing", capabilities={
        "pre_action_destructive": "enforced",
    })
    transcript = (
        "```text\n"
        "[intent]\n"
        "skill: b-implement\n"
        "action: destructive\n"
        "files: none\n"
        "commands: rm -rf dist/\n"
        "source: plan\n"
        "approval: pending\n"
        "reason: cleaning build\n"
        "```"
    )
    decision = validate_action(
        tmp_path,
        {"tool": "bash", "command": "rm -rf dist/"},
        runtime="claude-code",
        strict=True,
        transcript=transcript,
    )
    assert decision.verdict == "block"
    assert decision.allowed is False


def test_unknown_tool_advisory_when_not_strict(tmp_path):
    decision = validate_action(tmp_path, {"tool": "some_custom_tool"}, runtime="claude-code", strict=False)
    assert decision.verdict == "advisory"
    assert decision.risk == "unknown"


def test_action_exceeding_intent_scope_is_blocked(tmp_path):
    init_state(tmp_path, active_skill="b-implement", phase="implementing", capabilities={
        "pre_action_project_write": "enforced",
    })
    transcript = (
        "```text\n"
        "[intent]\n"
        "skill: b-implement\n"
        "action: project-write\n"
        "files: foo.py\n"
        "commands: none\n"
        "source: plan\n"
        "approval: not-required\n"
        "reason: editing foo\n"
        "```"
    )
    decision = validate_action(
        tmp_path,
        {"tool": "write", "files": ["foo.py", "bar.py"]},
        runtime="claude-code",
        strict=True,
        transcript=transcript,
    )
    assert decision.verdict == "block"
    assert "target" in decision.reason


def test_action_within_intent_scope_is_allowed(tmp_path):
    init_state(tmp_path, active_skill="b-implement", phase="implementing", capabilities={
        "pre_action_project_write": "enforced",
    })
    transcript = (
        "```text\n"
        "[intent]\n"
        "skill: b-implement\n"
        "action: project-write\n"
        "files: src/utils.py,src/helpers.py\n"
        "commands: none\n"
        "source: plan\n"
        "approval: not-required\n"
        "reason: editing helpers\n"
        "```"
    )
    decision = validate_action(
        tmp_path,
        {"tool": "write", "files": ["src/helpers.py"]},
        runtime="claude-code",
        strict=True,
        transcript=transcript,
    )
    assert decision.verdict == "allow"


def test_codex_cli_native_hooks_supported_by_registry(tmp_path):
    from tooling.state.capabilities import PRE_ACTION_ENFORCED_RUNTIMES, SUPPORTED_RUNTIMES
    assert "codex-cli" in PRE_ACTION_ENFORCED_RUNTIMES
    assert "claude-code" in PRE_ACTION_ENFORCED_RUNTIMES
    assert "kilo-code" not in PRE_ACTION_ENFORCED_RUNTIMES
    assert "kilo-code" not in SUPPORTED_RUNTIMES
