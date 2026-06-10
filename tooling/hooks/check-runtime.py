#!/usr/bin/env python3
"""b-agentic runtime hook checks.

Stop hooks validate transcript conformance after a run. Pre-action hooks validate
observable tool/action payloads before execution when runtimes provide them.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any


def warn(message: str) -> None:
    print(f"[b-agentic hook] {message}", file=sys.stderr)


def strict_enabled() -> bool:
    """Strict enforcement is ON by default. Use B_AGENTIC_ADVISORY=1 to opt out."""
    if os.environ.get("B_AGENTIC_ADVISORY") == "1":
        return False
    return os.environ.get("B_AGENTIC_STRICT") != "0" and os.environ.get("B_AGENTIC_HOOK_STRICT") != "0"


def find_key(value: Any, keys: set[str]) -> str | None:
    if isinstance(value, dict):
        for key, item in value.items():
            if key in keys and isinstance(item, str) and item:
                return item
            found = find_key(item, keys)
            if found:
                return found
    if isinstance(value, list):
        for item in value:
            found = find_key(item, keys)
            if found:
                return found
    return None


def read_stdin() -> str:
    try:
        return sys.stdin.read()
    except OSError:
        return ""


def transcript_path_from_stdin(stdin_text: str) -> str | None:
    if not stdin_text.strip():
        return None
    try:
        payload = json.loads(stdin_text)
    except json.JSONDecodeError:
        return None
    return find_key(payload, {"transcript_path", "transcriptPath", "transcript_file", "transcriptFile"})


def load_payload(stdin_text: str) -> dict[str, Any]:
    if not stdin_text.strip():
        return {}
    try:
        payload = json.loads(stdin_text)
    except json.JSONDecodeError:
        return {}
    return payload if isinstance(payload, dict) else {}


def workspace_root_from_payload(payload: dict[str, Any]) -> Path:
    value = find_key(payload, {"cwd", "current_dir", "currentDir", "workspace", "workspaceRoot", "project_dir", "projectDir"})
    if value:
        path = Path(value).expanduser()
        if path.exists():
            return path
    return Path.cwd()


def checker_path(source_root: Path) -> Path:
    return source_root / "tooling" / "conformance" / "checker.py"


def run_checker(checker: Path, transcript: Path) -> list[str]:
    repo_root = checker.parents[2]
    env = os.environ.copy()
    existing_pythonpath = env.get("PYTHONPATH")
    env["PYTHONPATH"] = str(repo_root) if not existing_pythonpath else f"{repo_root}{os.pathsep}{existing_pythonpath}"
    result = subprocess.run(
        [sys.executable, str(checker), str(transcript)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=repo_root,
        env=env,
        check=False,
    )
    if result.returncode == 0:
        return []
    output = "\n".join(part for part in [result.stderr.strip(), result.stdout.strip()] if part)
    return [line for line in output.splitlines() if line.strip()] or ["transcript conformance failed"]


def check_stop_event(source_root: Path, stdin_text: str) -> int:
    checker = checker_path(source_root)
    if not checker.exists():
        if os.environ.get("B_AGENTIC_HOOK_VERBOSE") == "1":
            warn(f"conformance checker unavailable: {checker}")
        return 0

    transcript_value = transcript_path_from_stdin(stdin_text)
    temp_path: Path | None = None
    if transcript_value:
        transcript = Path(transcript_value).expanduser()
    elif "```text\n[status]" in stdin_text or "```text\n[handoff]" in stdin_text:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, prefix="b-agentic-hook-", suffix=".md") as handle:
            handle.write(stdin_text)
            temp_path = Path(handle.name)
        transcript = temp_path
    else:
        return 0

    try:
        errors = run_checker(checker, transcript)
    finally:
        if temp_path is not None:
            try:
                temp_path.unlink()
            except OSError:
                pass

    for error in errors:
        warn(f"conformance warning: {error}")
    return 1 if errors and strict_enabled() else 0


def check_pre_action(source_root: Path, client: str, stdin_text: str) -> int:
    sys.path.insert(0, str(source_root))
    try:
        from tooling.state.validator import validate_action
    except Exception as exc:
        warn(f"state validator unavailable: {exc}")
        return 1 if strict_enabled() else 0

    payload = load_payload(stdin_text)
    workspace_root = workspace_root_from_payload(payload)

    if strict_enabled():
        try:
            from tooling.state.state import load_state, init_state
            from tooling.state.capabilities import runtime_capabilities
            if load_state(workspace_root) is None:
                caps = runtime_capabilities(client, strict=True, pre_action_payload=bool(payload)).as_dict()
                init_state(workspace_root, source_of_truth="auto-initialized by hook", capabilities=caps)
        except Exception:
            pass

    transcript_path = transcript_path_from_stdin(stdin_text)
    transcript = None
    if transcript_path:
        try:
            transcript = Path(transcript_path).expanduser().read_text()
        except OSError as exc:
            warn(f"could not read transcript for pre-action validation: {exc}")

    decision = validate_action(
        workspace_root,
        payload,
        runtime=client,
        strict=strict_enabled(),
        transcript=transcript,
    )
    if decision.verdict == "allow":
        return 0
    warn(f"pre-action {decision.verdict}: risk={decision.risk}; capability={decision.capability}; reason={decision.reason}")
    return 1 if decision.verdict == "block" else 0


def report_capabilities(source_root: Path, client: str, stdin_text: str) -> int:
    payload = load_payload(stdin_text)
    sys.path.insert(0, str(source_root))
    try:
        from tooling.state.capabilities import format_report, runtime_capabilities
    except Exception as exc:
        warn(f"capability reporter unavailable: {exc}")
        return 1
    print(format_report(runtime_capabilities(client, strict=strict_enabled(), pre_action_payload=bool(payload))))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run b-agentic runtime hook checks.")
    parser.add_argument("--client", required=True, help="Runtime client name for diagnostics.")
    parser.add_argument("--event", required=True, choices=["stop", "pre-action", "capabilities"], help="Runtime hook event.")
    parser.add_argument("--source", default=os.environ.get("B_AGENTIC_SOURCE_DIR", "~/.b-agentic"), help="b-agentic source checkout.")
    args = parser.parse_args(argv)

    source_root = Path(args.source).expanduser()
    stdin_text = read_stdin()
    if args.event == "stop":
        return check_stop_event(source_root, stdin_text)
    if args.event == "pre-action":
        return check_pre_action(source_root, args.client, stdin_text)
    if args.event == "capabilities":
        return report_capabilities(source_root, args.client, stdin_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
