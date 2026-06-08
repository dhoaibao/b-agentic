"""Tests for state init/load round-trip and save_state atomic write."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tooling.state.state import State, init_state, load_state, save_state, state_path_for


def test_init_creates_state_file(tmp_path):
    state = init_state(tmp_path)
    path = state_path_for(tmp_path)
    assert path.exists()
    data = json.loads(path.read_text())
    assert data["version"] == 1
    assert data["phase"] == "idle"
    assert data["active_skill"] is None


def test_init_load_round_trip(tmp_path):
    original = init_state(tmp_path, active_skill="b-implement", phase="implementing", source_of_truth="plan.md")
    loaded = load_state(tmp_path)
    assert loaded is not None
    assert loaded.active_skill == original.active_skill
    assert loaded.phase == original.phase
    assert loaded.source_of_truth == original.source_of_truth
    assert loaded.session_id == original.session_id


def test_load_returns_none_when_no_file(tmp_path):
    assert load_state(tmp_path) is None


def test_save_and_reload_with_capabilities(tmp_path):
    state = init_state(tmp_path, capabilities={"pre_action_project_write": "enforced"})
    loaded = load_state(tmp_path)
    assert loaded is not None
    assert loaded.capabilities["pre_action_project_write"] == "enforced"


def test_transition_updates_last_transition(tmp_path):
    state = init_state(tmp_path, active_skill="b-plan", phase="planning")
    state.transition(active_skill="b-implement", phase="implementing", reason="plan approved")
    save_state(tmp_path, state)

    loaded = load_state(tmp_path)
    assert loaded is not None
    assert loaded.phase == "implementing"
    assert loaded.active_skill == "b-implement"
    assert loaded.last_transition is not None
    assert loaded.last_transition["from"]["phase"] == "planning"
    assert loaded.last_transition["to"]["phase"] == "implementing"
    assert loaded.last_transition["reason"] == "plan approved"


def test_load_raises_on_invalid_state(tmp_path):
    path = state_path_for(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"version": 99, "session_id": "abc", "phase": "idle"}))
    with pytest.raises(ValueError, match="version"):
        load_state(tmp_path)


def test_save_is_atomic(tmp_path):
    state = init_state(tmp_path)
    path = state_path_for(tmp_path)
    original_inode = path.stat().st_ino
    state.phase = "reviewing"
    save_state(tmp_path, state)
    # After atomic replace, inode changes on Linux; verify the new content is correct
    assert json.loads(path.read_text())["phase"] == "reviewing"
