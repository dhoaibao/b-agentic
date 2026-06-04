#!/usr/bin/env python3
"""Fail-open b-agentic runtime hook checks."""

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
    return 1 if errors and os.environ.get("B_AGENTIC_HOOK_STRICT") == "1" else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run fail-open b-agentic runtime hook checks.")
    parser.add_argument("--client", required=True, help="Runtime client name for diagnostics.")
    parser.add_argument("--event", required=True, choices=["stop"], help="Runtime hook event.")
    parser.add_argument("--source", default=os.environ.get("B_AGENTIC_SOURCE_DIR", "~/.b-agentic"), help="b-agentic source checkout.")
    args = parser.parse_args(argv)

    source_root = Path(args.source).expanduser()
    stdin_text = read_stdin()
    if args.event == "stop":
        return check_stop_event(source_root, stdin_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
