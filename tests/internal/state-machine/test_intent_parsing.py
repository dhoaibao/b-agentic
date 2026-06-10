"""Tests for intent parsing and approval block detection."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tooling.state.intent import parse_approval_blocks, parse_intents


def test_parse_intent_block():
    text = (
        "```text\n"
        "[intent]\n"
        "skill: b-implement\n"
        "action: project-write\n"
        "files: foo.py\n"
        "commands: none\n"
        "source: plan\n"
        "approval: not-required\n"
        "reason: test\n"
        "```"
    )
    intents, errors = parse_intents(text)
    assert len(errors) == 0
    assert len(intents) == 1
    assert intents[0].skill == "b-implement"
    assert intents[0].action == "project-write"
    assert intents[0].files == ("foo.py",)
    assert intents[0].approval == "not-required"


def test_parse_approval_block_with_yes():
    text = (
        "Some conversation...\n"
        "```text\n"
        "[approval] rm -rf dist/\n"
        "Effect: deletes build artifacts\n"
        "Proceed? (y/n)\n"
        "```\n"
        "yes\n"
    )
    approvals = parse_approval_blocks(text)
    assert len(approvals) == 1
    assert approvals[0]["response"] == "approved"


def test_parse_approval_block_without_response():
    text = (
        "```text\n"
        "[approval] rm -rf dist/\n"
        "Effect: deletes build artifacts\n"
        "Proceed? (y/n)\n"
        "```\n"
    )
    approvals = parse_approval_blocks(text)
    assert len(approvals) == 0


def test_parse_approval_block_with_no():
    text = (
        "```text\n"
        "[approval] rm -rf dist/\n"
        "Effect: deletes build artifacts\n"
        "Proceed? (y/n)\n"
        "```\n"
        "no\n"
    )
    approvals = parse_approval_blocks(text)
    assert len(approvals) == 0


def test_parse_multiple_intents_returns_last():
    text = (
        "```text\n"
        "[intent]\n"
        "skill: b-plan\n"
        "action: project-write\n"
        "files: old.py\n"
        "commands: none\n"
        "source: plan\n"
        "approval: not-required\n"
        "reason: old\n"
        "```\n"
        "```text\n"
        "[intent]\n"
        "skill: b-implement\n"
        "action: project-write\n"
        "files: new.py\n"
        "commands: none\n"
        "source: plan\n"
        "approval: not-required\n"
        "reason: new\n"
        "```"
    )
    intents, errors = parse_intents(text)
    assert len(errors) == 0
    assert len(intents) == 2
    assert intents[-1].skill == "b-implement"
    assert intents[-1].files == ("new.py",)


def test_parse_approval_block_with_long_response_gap():
    """Approval response after a large gap (intervening model text) should still be detected."""
    text = (
        "```text\n"
        "[approval] rm -rf dist/\n"
        "Effect: deletes build artifacts\n"
        "Proceed? (y/n)\n"
        "```\n"
        + "Some long reasoning from the model about why this might be necessary. " * 50
        + "\nyes\n"
    )
    approvals = parse_approval_blocks(text)
    assert len(approvals) == 1
    assert approvals[0]["response"] == "approved"


def test_parse_approval_block_stops_at_next_block():
    """Response after the next structured block should not be associated with this approval."""
    text = (
        "```text\n"
        "[approval] rm -rf dist/\n"
        "Effect: deletes build artifacts\n"
        "Proceed? (y/n)\n"
        "```\n"
        "Some intervening text\n"
        "```text\n"
        "[intent]\n"
        "skill: b-implement\n"
        "action: destructive\n"
        "files: none\n"
        "commands: rm -rf dist/\n"
        "source: plan\n"
        "approval: pending\n"
        "reason: cleaning build\n"
        "```\n"
        "yes\n"
    )
    approvals = parse_approval_blocks(text)
    assert len(approvals) == 0
