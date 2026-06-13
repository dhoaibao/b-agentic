#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class Fixture:
    name: str
    prompt: str
    expected: str
    not_expected: tuple[str, ...] = ()


FIXTURES = [
    Fixture(
        name="explicit debug skill request",
        prompt="Please use b-debug to diagnose this stack trace.",
        expected="b-debug",
    ),
    Fixture(
        name="planning request",
        prompt="Plan how to add billing scope and decompose the work.",
        expected="b-plan",
    ),
    Fixture(
        name="external docs lookup",
        prompt="Look up the React Router API docs and compare the config options.",
        expected="b-research",
    ),
    Fixture(
        name="approved implementation",
        prompt="Implement the approved plan and finish the next build step.",
        expected="b-implement",
    ),
    Fixture(
        name="mechanical rename",
        prompt="Rename UserService to AccountService without changing behavior.",
        expected="b-refactor",
    ),
    Fixture(
        name="runtime bug",
        prompt="This regression is broken in production and throws this error stack trace.",
        expected="b-debug",
    ),
    Fixture(
        name="test mechanics",
        prompt="Fix the failing component test mock assertion and update coverage.",
        expected="b-test",
        not_expected=("b-debug",),
    ),
    Fixture(
        name="browser evidence",
        prompt="Run Playwright e2e, capture a screenshot, and check the live UI.",
        expected="b-browser",
        not_expected=("b-test",),
    ),
    Fixture(
        name="changed-code review",
        prompt="Review my working tree diff before PR.",
        expected="b-review",
    ),
    Fixture(
        name="shipping request",
        prompt="Commit these changes, push the branch, and open a PR.",
        expected="b-ship",
    ),
]


def load_registry() -> list[dict]:
    return json.loads((ROOT / "skills" / "registry.yaml").read_text())["skills"]


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.lower()).strip()


def words(text: str) -> set[str]:
    return set(re.findall(r"[a-z0-9][a-z0-9-]*", text.lower()))


def metadata_terms(skill: dict) -> tuple[list[str], set[str]]:
    phrases: list[str] = []
    word_set: set[str] = set()

    command = skill.get("command", {})
    prompt = skill.get("prompt", {})
    routing = skill.get("routing") or {}

    for value in [
        skill.get("name"),
        skill.get("phase"),
        skill.get("use"),
        command.get("alias"),
        command.get("description"),
        prompt.get("description"),
        routing.get("intent"),
    ]:
        if isinstance(value, str):
            phrases.append(value.strip('"'))
            word_set.update(words(value))

    triggers = routing.get("triggers", [])
    if isinstance(triggers, list):
        for trigger in triggers:
            if isinstance(trigger, str):
                phrases.append(trigger.strip('"'))
                word_set.update(words(trigger))

    return [normalize(phrase) for phrase in phrases if phrase], word_set


def score(prompt: str, skill: dict) -> int:
    normalized_prompt = normalize(prompt)
    prompt_words = words(prompt)
    phrases, word_set = metadata_terms(skill)
    name = skill.get("name", "")
    score_value = 0

    if name and re.search(rf"(^|\W){re.escape(name)}($|\W)", normalized_prompt):
        score_value += 100

    routing = skill.get("routing") or {}
    triggers = routing.get("triggers", [])
    if isinstance(triggers, list):
        for trigger in triggers:
            if isinstance(trigger, str) and normalize(trigger.strip('"')) in normalized_prompt:
                score_value += 12

    for phrase in phrases:
        if len(phrase) > 2 and phrase in normalized_prompt:
            score_value += 4

    score_value += len(prompt_words & word_set)
    return score_value


def classify(prompt: str, skills: list[dict]) -> tuple[str, dict[str, int]]:
    scores = {
        skill["name"]: score(prompt, skill)
        for skill in skills
        if isinstance(skill, dict) and isinstance(skill.get("name"), str)
    }
    best_score = max(scores.values())
    winners = sorted(name for name, value in scores.items() if value == best_score)
    if len(winners) != 1:
        return ",".join(winners), scores
    return winners[0], scores


def routing_table_text() -> str:
    return (ROOT / "references" / "contract" / "runtime.md").read_text()


def validate_runtime_contract(skills: list[dict], errors: list[str]) -> None:
    text = routing_table_text()
    for skill in skills:
        name = skill.get("name")
        if not isinstance(name, str):
            continue
        if skill.get("routing") is None:
            if name == "b-ship" and "Commit, push, or PR -> `b-ship`" not in text:
                errors.append("references/contract/runtime.md: missing b-ship precedence rule")
            continue
        if f"`{name}`" not in text:
            errors.append(f"references/contract/runtime.md: missing routing table entry for {name}")
        for trigger in skill.get("routing", {}).get("triggers", []):
            if isinstance(trigger, str) and trigger.strip('"') not in text:
                errors.append(
                    f"references/contract/runtime.md: missing trigger {trigger!r} for {name}"
                )


def main() -> int:
    skills = load_registry()
    skill_names = {skill.get("name") for skill in skills if isinstance(skill, dict)}
    errors: list[str] = []

    validate_runtime_contract(skills, errors)

    for fixture in FIXTURES:
        if fixture.expected not in skill_names:
            errors.append(f"{fixture.name}: expected unknown skill {fixture.expected!r}")
            continue

        actual, scores = classify(fixture.prompt, skills)
        if actual != fixture.expected:
            ordered = ", ".join(
                f"{name}={value}" for name, value in sorted(scores.items(), key=lambda item: (-item[1], item[0]))
            )
            errors.append(
                f"{fixture.name}: expected {fixture.expected}, classified as {actual}; scores: {ordered}"
            )
        for forbidden in fixture.not_expected:
            if actual == forbidden:
                errors.append(f"{fixture.name}: incorrectly routed to {forbidden}")

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print(f"Behavior routing validation passed ({len(FIXTURES)} fixtures).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
