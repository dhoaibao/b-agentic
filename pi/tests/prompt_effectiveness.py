#!/usr/bin/env python3

"""Run opt-in, human-scored prompt-effectiveness scenarios through Pi.

This makes external model calls and is intentionally excluded from default,
release, and structural validation. It does not mutate the repository.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURES = ROOT / "tests" / "behavior" / "principles.json"
ROUTING_FIXTURES = ROOT / "tests" / "behavior" / "routing.json"
DEFAULT_KERNEL = ROOT / "references" / "kernel.template.md"
DEFAULT_SKILL = ROOT / "skills" / "b-implement" / "SKILL.md"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run human-scored b-agentic behavior scenarios through Pi."
    )
    parser.add_argument(
        "--allow-model-calls",
        action="store_true",
        help="Acknowledge that this command makes potentially billable external model calls.",
    )
    parser.add_argument(
        "--validate-inputs",
        action="store_true",
        help="Validate default inputs and selected scenarios without making model calls.",
    )
    parser.add_argument("--fixtures", type=Path, default=DEFAULT_FIXTURES)
    parser.add_argument("--kernel", type=Path, default=DEFAULT_KERNEL)
    parser.add_argument("--skill", type=Path, default=DEFAULT_SKILL)
    parser.add_argument(
        "--routing",
        action="store_true",
        help="Evaluate native selection across every b-agentic skill instead of one explicit skill.",
    )
    parser.add_argument("--model", help="Pin a Pi model for reproducible comparisons.")
    parser.add_argument("--thinking", help="Pin the Pi thinking level.")
    parser.add_argument("--scenario", action="append", default=[], help="Run only this scenario ID; repeatable.")
    parser.add_argument("--timeout", type=int, default=180, help="Per-scenario timeout in seconds.")
    parser.add_argument("--label", default="unlabeled", help="Label included in the JSON report.")
    return parser.parse_args()


def load_scenarios(path: Path, selected: set[str]) -> tuple[dict, list[dict]]:
    fixture = json.loads(path.read_text())
    scenarios = fixture["scenarios"]
    known = {scenario["id"] for scenario in scenarios}
    missing = sorted(selected - known)
    if missing:
        raise ValueError(f"unknown scenario IDs: {', '.join(missing)}")
    if selected:
        scenarios = [scenario for scenario in scenarios if scenario["id"] in selected]
    return fixture, scenarios


def clean_output(value: str | bytes | None) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace").strip()
    return (value or "").strip()


def pi_command(args: argparse.Namespace, prompt: str) -> list[str]:
    command = [
        "pi",
        "--no-session",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files",
        "--append-system-prompt",
        str(args.kernel),
    ]
    if args.routing:
        command.extend(["--tools", "read"])
        for skill_path in sorted((ROOT / "skills").glob("*/SKILL.md")):
            command.extend(["--skill", str(skill_path)])
        prompt = (
            "Select exactly one available b-agentic skill for the request, load its SKILL.md, "
            "and follow it without editing files. Start the final response with 'SKILL: <name>'.\n\n"
            + prompt
        )
    else:
        command.extend(["--no-tools", "--skill", str(args.skill)])
    if args.model:
        command.extend(["--model", args.model])
    if args.thinking:
        command.extend(["--thinking", args.thinking])
    command.extend(["--print", prompt])
    return command


def main() -> int:
    args = parse_args()
    if args.routing and args.fixtures == DEFAULT_FIXTURES:
        args.fixtures = ROUTING_FIXTURES
    if not args.allow_model_calls and not args.validate_inputs:
        print(
            "Refusing external model calls without --allow-model-calls. "
            "Review costs and data exposure first.",
            file=sys.stderr,
        )
        return 2

    input_paths = [args.fixtures, args.kernel]
    if not args.routing:
        input_paths.append(args.skill)
    else:
        input_paths.extend(sorted((ROOT / "skills").glob("*/SKILL.md")))
    for path in input_paths:
        if not path.is_file():
            print(f"missing input: {path}", file=sys.stderr)
            return 2

    try:
        fixture, scenarios = load_scenarios(args.fixtures, set(args.scenario))
    except (KeyError, ValueError, json.JSONDecodeError) as exc:
        print(f"invalid fixtures: {exc}", file=sys.stderr)
        return 2

    if args.validate_inputs:
        print(f"Prompt-effectiveness inputs valid ({len(scenarios)} scenarios).")
        return 0

    environment = os.environ.copy()
    environment["PI_SKIP_VERSION_CHECK"] = "1"
    environment["PI_TELEMETRY"] = "0"
    results = []
    failed = False

    for scenario in scenarios:
        try:
            completed = subprocess.run(
                pi_command(args, scenario["prompt"]),
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=args.timeout,
            )
            result = {
                **scenario,
                "response": clean_output(completed.stdout),
                "exit_code": completed.returncode,
                "stderr": clean_output(completed.stderr),
            }
            failed |= completed.returncode != 0
        except subprocess.TimeoutExpired as exc:
            result = {
                **scenario,
                "response": clean_output(exc.stdout),
                "exit_code": None,
                "stderr": f"timed out after {args.timeout} seconds",
            }
            failed = True
        results.append(result)

    report = {
        "label": args.label,
        "runtime": "pi",
        "model": args.model or "runtime-default",
        "thinking": args.thinking or "runtime-default",
        "fixture_version": fixture["version"],
        "source": fixture["source"],
        "scoring": (
            "Human-review the reported SKILL against expected_skill and forbidden_skills; compare like-for-like model settings."
            if args.routing
            else "Human-review each response against its must and avoid lists; compare like-for-like model settings."
        ),
        "results": results,
    }
    print(json.dumps(report, indent=2))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
