#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from tooling.state.capabilities import format_report, runtime_capabilities
from tooling.state.state import init_state, load_state, save_state
from tooling.state.validator import validate_action


def _read_stdin_json() -> dict:
    text = sys.stdin.read()
    if not text.strip():
        return {}
    data = json.loads(text)
    if not isinstance(data, dict):
        raise ValueError("stdin JSON top level must be an object")
    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Manage and validate b-agentic workflow state.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init", help="Initialize .b-agentic/state.json")
    init_parser.add_argument("--root", default=".")
    init_parser.add_argument("--active-skill")
    init_parser.add_argument("--phase", default="idle")

    validate_parser = subparsers.add_parser("validate-action", help="Validate one runtime action from stdin JSON")
    validate_parser.add_argument("--root", default=".")
    validate_parser.add_argument("--runtime", required=True)
    validate_parser.add_argument("--strict", action="store_true")
    validate_parser.add_argument("--transcript")

    capability_parser = subparsers.add_parser("capabilities", help="Print runtime enforcement capabilities")
    capability_parser.add_argument("--runtime", required=True)
    capability_parser.add_argument("--strict", action="store_true")
    capability_parser.add_argument("--pre-action-payload", action="store_true")

    transition_parser = subparsers.add_parser("transition", help="Apply a state transition")
    transition_parser.add_argument("--root", default=".")
    transition_parser.add_argument("--active-skill")
    transition_parser.add_argument("--phase", required=True)
    transition_parser.add_argument("--reason", required=True)

    args = parser.parse_args(argv)
    root = Path(getattr(args, "root", ".")).resolve()

    if args.command == "init":
        state = init_state(root, active_skill=args.active_skill, phase=args.phase)
        print(json.dumps(state.to_dict(), indent=2, sort_keys=True))
        return 0

    if args.command == "validate-action":
        payload = _read_stdin_json()
        transcript = Path(args.transcript).read_text() if args.transcript else None
        decision = validate_action(root, payload, runtime=args.runtime, strict=args.strict, transcript=transcript)
        print(json.dumps(decision.__dict__, indent=2, sort_keys=True))
        return 0 if decision.allowed else 1

    if args.command == "capabilities":
        print(format_report(runtime_capabilities(args.runtime, strict=args.strict, pre_action_payload=args.pre_action_payload)))
        return 0

    if args.command == "transition":
        state = load_state(root)
        if state is None:
            state = init_state(root)
        state.transition(active_skill=args.active_skill, phase=args.phase, reason=args.reason)
        save_state(root, state)
        print(json.dumps(state.to_dict(), indent=2, sort_keys=True))
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
