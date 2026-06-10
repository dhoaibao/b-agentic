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
    init_parser.add_argument("--source-of-truth")
    init_parser.add_argument("--runtime", help="Record runtime capability state for strict-mode readiness")
    init_parser.add_argument("--strict", action="store_true", help="Record capabilities as strict-mode requested")

    validate_parser = subparsers.add_parser("validate-action", help="Validate one runtime action from stdin JSON")
    validate_parser.add_argument("--root", default=".")
    validate_parser.add_argument("--runtime", required=True)
    validate_parser.add_argument("--strict", action="store_true")
    validate_parser.add_argument("--advisory", action="store_true", help="Disable strict enforcement for this validation")
    validate_parser.add_argument("--no-auto-derive", action="store_true", help="Require explicit [intent] blocks; do not auto-derive from payload")
    validate_parser.add_argument("--transcript")

    capability_parser = subparsers.add_parser("capabilities", help="Print runtime enforcement capabilities")
    capability_parser.add_argument("--runtime", required=True)
    capability_parser.add_argument("--strict", action="store_true")
    capability_parser.add_argument("--advisory", action="store_true", help="Report advisory-only capabilities")
    capability_parser.add_argument("--pre-action-payload", action="store_true")

    transition_parser = subparsers.add_parser("transition", help="Apply a state transition")
    transition_parser.add_argument("--root", default=".")
    transition_parser.add_argument("--active-skill")
    transition_parser.add_argument("--phase", required=True)
    transition_parser.add_argument("--reason", required=True)

    args = parser.parse_args(argv)
    root = Path(getattr(args, "root", ".")).resolve()

    if args.command == "init":
        capabilities = {}
        if args.runtime:
            capabilities = runtime_capabilities(
                args.runtime,
                strict=args.strict,
                pre_action_payload=args.strict,
            ).as_dict()
        state = init_state(
            root,
            active_skill=args.active_skill,
            phase=args.phase,
            source_of_truth=args.source_of_truth,
            capabilities=capabilities,
        )

        gitignore_path = root / ".gitignore"
        if gitignore_path.exists():
            gitignore_text = gitignore_path.read_text()
            if ".b-agentic/" not in gitignore_text:
                print("Warning: .b-agentic/ is not in .gitignore. Add it to prevent committing workflow state.", file=sys.stderr)
        else:
            print("Warning: .gitignore not found. Consider adding .b-agentic/ to prevent committing workflow state.", file=sys.stderr)

        print(json.dumps(state.to_dict(), indent=2, sort_keys=True))
        return 0

    if args.command == "validate-action":
        payload = _read_stdin_json()
        transcript = Path(args.transcript).read_text() if args.transcript else None
        strict_mode = not args.advisory  # strict is ON by default; --advisory opts out
        auto_derive = not args.no_auto_derive
        decision = validate_action(root, payload, runtime=args.runtime, strict=strict_mode, transcript=transcript, auto_derive=auto_derive)
        print(json.dumps(decision.__dict__, indent=2, sort_keys=True))
        return 0 if decision.allowed else 1

    if args.command == "capabilities":
        strict_mode = not args.advisory
        print(format_report(runtime_capabilities(args.runtime, strict=strict_mode, pre_action_payload=args.pre_action_payload)))
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
