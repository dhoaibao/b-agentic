"""Tests for action classification edge cases and regex boundaries."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tooling.state.actions import DESTRUCTIVE, DEPENDENCY_WRITE, ENVIRONMENT_WRITE, EXTERNAL_WRITE, READ_ONLY, UNKNOWN, classify_action


def test_make_lint_is_unknown():
    action = classify_action({"tool": "bash", "command": "make lint"})
    assert action.risk == UNKNOWN


def test_terraform_plan_is_unknown():
    action = classify_action({"tool": "bash", "command": "terraform plan"})
    assert action.risk == UNKNOWN


def test_docker_ps_is_unknown():
    action = classify_action({"tool": "bash", "command": "docker ps"})
    assert action.risk == UNKNOWN


def test_npm_test_is_unknown():
    action = classify_action({"tool": "bash", "command": "npm test"})
    assert action.risk == UNKNOWN


def test_make_dev_is_environment_write():
    action = classify_action({"tool": "bash", "command": "make dev"})
    assert action.risk == ENVIRONMENT_WRITE


def test_docker_compose_up_is_environment_write():
    action = classify_action({"tool": "bash", "command": "docker-compose up"})
    assert action.risk == ENVIRONMENT_WRITE


def test_npm_install_is_dependency_write():
    action = classify_action({"tool": "bash", "command": "npm install"})
    assert action.risk == DEPENDENCY_WRITE


def test_rm_rf_is_destructive():
    action = classify_action({"tool": "bash", "command": "rm -rf dist/"})
    assert action.risk == DESTRUCTIVE


def test_rm_dash_f_is_destructive():
    action = classify_action({"tool": "bash", "command": "rm -f file.txt"})
    assert action.risk == DESTRUCTIVE


def test_git_status_is_read_only():
    action = classify_action({"tool": "bash", "command": "git status"})
    assert action.risk == READ_ONLY


def test_git_reset_hard_is_destructive():
    action = classify_action({"tool": "bash", "command": "git reset --hard"})
    assert action.risk == DESTRUCTIVE


def test_gh_pr_create_is_external_write():
    action = classify_action({"tool": "bash", "command": "gh pr create"})
    assert action.risk == EXTERNAL_WRITE


def test_arbitrary_python_script_is_unknown():
    action = classify_action({"tool": "bash", "command": "python3 script.py"})
    assert action.risk == UNKNOWN


def test_project_write_tool_classification():
    action = classify_action({"tool": "write", "files": ["foo.py"]})
    assert action.risk == "project-write"


def test_read_only_tool_classification():
    action = classify_action({"tool": "read", "files": ["foo.py"]})
    assert action.risk == READ_ONLY
