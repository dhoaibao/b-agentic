#!/usr/bin/env python3
"""Validate the reviewer eval fixture (tests/behavior/review-eval.json) offline.

The fixture lists incident and control cases from this repository's history for
manually scoring a b-review round (docs/runbooks/review-eval.md). This check
makes no model calls: it validates the fixture's shape, freezes the test split
with a digest, trips when a test answer key is copied verbatim into the review
prompt or kernel (a tripwire, not proof of no leak), requires each blocker class
to appear in the b-review prompt (a substring check), and, when the checkout
has full history, confirms each case's commits and their parent relations.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "tests" / "behavior" / "review-eval.json"
# Text a leaked answer key could hide in: the review prompt, its rendered skill,
# and the kernel.
REVIEW_SOURCES = (
    ROOT / "skills" / "b-review" / "prompt.md",
    ROOT / "skills" / "b-review" / "SKILL.md",
    ROOT / "references" / "kernel.template.md",
)
# The blocker classes live in the b-review prompt; a case may name only one of
# them (checked against that prompt's text, so the two cannot drift).
CLASS_SOURCE = ROOT / "skills" / "b-review" / "prompt.md"

SPLITS = ("test", "tuning")
KINDS = ("incident", "control")
CONSTRUCTIONS = ("introducing-commit", "revert-of-fix", "merged-change")
INCIDENT_CONSTRUCTIONS = ("introducing-commit", "revert-of-fix")
VERDICTS = {"incident": "NEEDS FIXES", "control": "no blocker"}
INCIDENT_ONLY = ("fixed_by", "blocker_class", "answer_key")
COMMON = ("id", "split", "kind", "construction", "base", "head", "expected_verdict")
SHA = re.compile(r"^[0-9a-f]{40}$")
ID = re.compile(r"^[a-z0-9][a-z0-9-]*$")
KEY_LIMIT = 400

GitRunner = Callable[[list[str]], tuple[int, str]]


def digest(cases: list[dict]) -> str:
    """sha256 of the test-split cases in canonical JSON."""
    tests = [case for case in cases if case.get("split") == "test"]
    blob = json.dumps(tests, sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(blob.encode()).hexdigest()


def one_sentence(text: str) -> bool:
    return (
        isinstance(text, str)
        and 0 < len(text) <= KEY_LIMIT
        and "\n" not in text
        and text.strip() == text
        and text.endswith(".")
        and ". " not in text
    )


def normalize(text: str) -> str:
    return " ".join(text.lower().split())


def case_errors(case: dict, where: str) -> list[str]:
    errors: list[str] = []
    for field in COMMON:
        if not isinstance(case.get(field), str) or not case[field]:
            errors.append(f"{where}: {field} must be a non-empty string")
    if errors:
        return errors
    if not ID.match(case["id"]):
        errors.append(f"{where}: id must be lowercase words joined by hyphens")
    if case["split"] not in SPLITS:
        errors.append(f"{where}: split must be one of {', '.join(SPLITS)}")
    if case["kind"] not in KINDS:
        errors.append(f"{where}: kind must be one of {', '.join(KINDS)}")
        return errors
    if case["construction"] not in CONSTRUCTIONS:
        errors.append(f"{where}: unknown construction {case['construction']}")
    for field in ("base", "head"):
        if not SHA.match(case[field]):
            errors.append(f"{where}: {field} must be a full 40-character SHA")
    if case["base"] == case["head"]:
        errors.append(f"{where}: base and head must differ")
    if case["expected_verdict"] != VERDICTS[case["kind"]]:
        errors.append(f"{where}: a {case['kind']} expects {VERDICTS[case['kind']]!r}")
    if case["kind"] == "control":
        if case["construction"] != "merged-change":
            errors.append(f"{where}: a control must be a merged-change")
        for field in INCIDENT_ONLY:
            if field in case:
                errors.append(f"{where}: a control must not carry {field}")
        return errors
    if case["construction"] not in INCIDENT_CONSTRUCTIONS:
        errors.append(f"{where}: an incident must be built from a bug or its fix")
    fixed_by = case.get("fixed_by")
    if not (
        isinstance(fixed_by, list) and fixed_by and all(isinstance(sha, str) and SHA.match(sha) for sha in fixed_by)
    ):
        errors.append(f"{where}: fixed_by must list full SHAs")
    if not isinstance(case.get("blocker_class"), str):
        errors.append(f"{where}: an incident needs a blocker_class")
    if not one_sentence(case.get("answer_key")):
        errors.append(f"{where}: answer_key must be one sentence on one line (at most {KEY_LIMIT} characters)")
    return errors


def fixture_errors(doc: object, class_text: str, review_text: str) -> list[str]:
    if not isinstance(doc, dict) or not isinstance(doc.get("cases"), list):
        return ["fixture must be an object with a cases list"]
    errors: list[str] = []
    cases = doc["cases"]
    seen: set[str] = set()
    for index, case in enumerate(cases):
        where = f"cases[{index}]"
        if not isinstance(case, dict):
            errors.append(f"{where}: must be an object")
            continue
        where = f"{where} ({case.get('id')})"
        errors.extend(case_errors(case, where))
        cid = case.get("id")
        if isinstance(cid, str):
            if cid in seen:
                errors.append(f"{where}: duplicate id")
            seen.add(cid)
    good = [case for case in cases if isinstance(case, dict)]
    for split in SPLITS:
        for kind in KINDS:
            if not any(c.get("split") == split and c.get("kind") == kind for c in good):
                errors.append(f"split {split} needs at least one {kind}")
    normalized_class_text = normalize(class_text)
    normalized_review = normalize(review_text)
    for case in good:
        klass = case.get("blocker_class")
        if isinstance(klass, str) and normalize(klass) not in normalized_class_text:
            errors.append(f"{case.get('id')}: blocker_class {klass!r} is not a b-review blocker class")
        key = case.get("answer_key")
        if case.get("split") == "test" and isinstance(key, str) and normalize(key) in normalized_review:
            errors.append(f"{case.get('id')}: a test answer key leaked into b-review")
    expected = digest(good)
    if doc.get("test_set_digest") != expected:
        errors.append(
            "test_set_digest does not match the test-split cases: update it "
            f"to {expected} in the same change that edits a test case"
        )
    return errors


def history_errors(doc: dict, git: GitRunner) -> tuple[list[str], str]:
    """Check each case against git history; a shallow clone skips the check."""
    code, out = git(["rev-parse", "--is-shallow-repository"])
    if code != 0:
        return [], "history checks skipped: not a git checkout"
    if out.strip() == "true":
        return [], "history checks skipped: shallow clone"
    errors: list[str] = []

    def commit_exists(sha: str) -> bool:
        return git(["cat-file", "-e", f"{sha}^{{commit}}"])[0] == 0

    def is_ancestor(old: str, new: str) -> bool:
        return git(["merge-base", "--is-ancestor", old, new])[0] == 0

    for case in doc["cases"]:
        cid = case["id"]
        shas = [case["base"], case["head"], *case.get("fixed_by", [])]
        missing = [sha[:8] for sha in shas if not commit_exists(sha)]
        if missing:
            errors.append(f"{cid}: commits not in history: {', '.join(missing)}")
            continue
        if case["construction"] == "revert-of-fix":
            # Reviews the reverse of a fix: base is the fix, head its parent.
            if case.get("fixed_by") != [case["base"]]:
                errors.append(f"{cid}: a revert-of-fix has fixed_by equal to [base]")
            if git(["rev-parse", f"{case['base']}^"])[1].strip() != case["head"]:
                errors.append(f"{cid}: head must be the parent of the fix at base")
            continue
        if not is_ancestor(case["base"], case["head"]):
            errors.append(f"{cid}: base must be an ancestor of head")
        elif git(["rev-parse", f"{case['head']}^"])[1].strip() != case["base"]:
            errors.append(f"{cid}: base must be the parent of head")
        for fix in case.get("fixed_by", []):
            if not is_ancestor(case["head"], fix):
                errors.append(f"{cid}: fix {fix[:8]} must descend from head")
    return errors, "history checks ran"


def run_git(args: list[str]) -> tuple[int, str]:
    try:
        done = subprocess.run(
            ["git", "-C", str(ROOT), *args],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return 1, ""
    return done.returncode, done.stdout


def validate(doc: object, class_text: str, review_text: str, git: GitRunner):
    errors = fixture_errors(doc, class_text, review_text)
    if errors or not isinstance(doc, dict):
        return errors, "history checks skipped: fixture invalid"
    return history_errors(doc, git)


def sample() -> dict:
    def sha(n: int) -> str:
        return f"{n:040x}"

    def incident(cid: str, split: str, n: int) -> dict:
        return {
            "id": cid,
            "split": split,
            "kind": "incident",
            "construction": "introducing-commit",
            "base": sha(n),
            "head": sha(n + 1),
            "fixed_by": [sha(n + 2)],
            "blocker_class": "correctness regression",
            "answer_key": f"The change {cid} breaks an existing caller.",
            "expected_verdict": "NEEDS FIXES",
        }

    def control(cid: str, split: str, n: int) -> dict:
        return {
            "id": cid,
            "split": split,
            "kind": "control",
            "construction": "merged-change",
            "base": sha(n),
            "head": sha(n + 1),
            "expected_verdict": "no blocker",
        }

    cases = [
        incident("a-incident", "test", 0x10),
        control("a-control", "test", 0x20),
        incident("b-incident", "tuning", 0x30),
        control("b-control", "tuning", 0x40),
    ]
    return {"version": 1, "test_set_digest": digest(cases), "cases": cases}


def self_test() -> list[str]:
    problems: list[str] = []

    def sha_of(n: int) -> str:
        return f"{n:040x}"

    klass = "blockers: correctness regression, data-integrity loss"
    review = "Review prompt text with no answer keys."

    def expect(label: str, doc: object, fragment: str, text: str = review) -> None:
        errors = fixture_errors(doc, klass, text)
        if not any(fragment in error for error in errors):
            problems.append(f"{label}: expected an error containing {fragment!r}")

    good = sample()
    if fixture_errors(good, klass, review):
        problems.append("the sample fixture must validate")

    def mutate(label: str, fragment: str, change, resign: bool = True) -> None:
        doc = copy.deepcopy(good)
        change(doc["cases"])
        if resign:
            doc["test_set_digest"] = digest(doc["cases"])
        expect(label, doc, fragment)

    bad_digest = copy.deepcopy(good)
    bad_digest["test_set_digest"] = "sha256:" + "0" * 64
    expect("bad digest", bad_digest, "test_set_digest")
    stale = copy.deepcopy(good)
    stale["cases"][0]["answer_key"] = "The edited test case changes its key."
    expect("stale digest after editing a test case", stale, "test_set_digest")
    tuning_edit = copy.deepcopy(good)
    tuning_edit["cases"][2]["answer_key"] = "A tuning case may change freely."
    if fixture_errors(tuning_edit, klass, review):
        problems.append("a tuning-case edit must not need a new digest")

    mutate("missing answer key", "answer_key", lambda c: c[0].pop("answer_key"))
    mutate("missing fixed_by", "fixed_by", lambda c: c[0].pop("fixed_by"))
    mutate(
        "control with an answer key",
        "must not carry answer_key",
        lambda c: c[1].update(answer_key="A control has no key."),
    )
    mutate(
        "two-sentence key",
        "one sentence",
        lambda c: c[0].update(answer_key="First part. Second part."),
    )
    mutate(
        "multi-line key",
        "one sentence",
        lambda c: c[0].update(answer_key="First part\nsecond part."),
    )
    mutate(
        "unknown class",
        "not a b-review blocker class",
        lambda c: c[0].update(blocker_class="style nit"),
    )
    mutate("duplicate id", "duplicate id", lambda c: c[2].update(id=c[0]["id"]))
    mutate("short SHA", "40-character", lambda c: c[0].update(base="abc123"))
    mutate(
        "wrong verdict",
        "expects",
        lambda c: c[0].update(expected_verdict="no blocker"),
    )
    mutate(
        "control built from a fix",
        "merged-change",
        lambda c: c[1].update(construction="revert-of-fix"),
    )
    mutate(
        "split without a control",
        "needs at least one control",
        lambda c: c.pop(3),
    )
    expect(
        "leaked test key",
        good,
        "leaked",
        review + " " + good["cases"][0]["answer_key"],
    )

    # History checks: skipped in a shallow clone, enforced in a full one.
    def fake_git(shallow: str, known: set[str], parent: dict[str, str]) -> GitRunner:
        def git(args: list[str]) -> tuple[int, str]:
            if args[:2] == ["rev-parse", "--is-shallow-repository"]:
                return 0, shallow
            if args[0] == "cat-file":
                return (0 if args[2].split("^")[0] in known else 1), ""
            if args[0] == "rev-parse":
                return 0, parent.get(args[1].rstrip("^"), "")
            if args[0] == "merge-base":
                return (0 if args[2] <= args[3] else 1), ""
            return 1, ""

        return git

    every = {s for case in good["cases"] for s in (case["base"], case["head"])}
    every |= {s for case in good["cases"] for s in case.get("fixed_by", [])}
    errors, note = history_errors(good, fake_git("true\n", set(), {}))
    if errors or "shallow" not in note:
        problems.append("a shallow clone must skip the history checks, not fail")
    parents = {case["head"]: case["base"] for case in good["cases"]}
    errors, note = history_errors(good, fake_git("false\n", every, parents))
    if errors or note != "history checks ran":
        problems.append(f"a full clone with every commit must pass: {errors}")
    errors, _ = history_errors(good, fake_git("false\n", set(), parents))
    if not any("not in history" in error for error in errors):
        problems.append("a full clone must report commits missing from history")
    backwards = copy.deepcopy(good)
    backwards["cases"][0]["base"], backwards["cases"][0]["head"] = (
        backwards["cases"][0]["head"],
        backwards["cases"][0]["base"],
    )
    errors, _ = history_errors(backwards, fake_git("false\n", every, parents))
    if not any("ancestor" in error for error in errors):
        problems.append("base must be required to be an ancestor of head")
    skipped_parent = {**parents, good["cases"][0]["head"]: sha_of(0xAB)}
    errors, _ = history_errors(good, fake_git("false\n", every, skipped_parent))
    if not any("parent of head" in error for error in errors):
        problems.append("base must be required to be the parent of head")
    late_fix = copy.deepcopy(good)
    late_fix["cases"][0]["fixed_by"] = [sha_of(0x01)]
    errors, _ = history_errors(late_fix, fake_git("false\n", every | {sha_of(0x01)}, parents))
    if not any("descend from head" in error for error in errors):
        problems.append("a fix must be required to descend from head")

    # revert-of-fix: base is the fix, head is its parent.
    fix, parent = sha_of(0x70), sha_of(0x6F)
    revert = copy.deepcopy(good)
    revert["cases"][0].update(construction="revert-of-fix", base=fix, head=parent, fixed_by=[fix])
    known = every | {fix, parent}
    errors, _ = history_errors(revert, fake_git("false\n", known, {**parents, fix: parent}))
    if errors:
        problems.append(f"a well-formed revert-of-fix must pass: {errors}")
    errors, _ = history_errors(revert, fake_git("false\n", known, {**parents, fix: sha_of(0xCD)}))
    if not any("parent of the fix" in error for error in errors):
        problems.append("a revert-of-fix head must be required to be the fix's parent")
    revert["cases"][0]["fixed_by"] = [parent]
    errors, _ = history_errors(revert, fake_git("false\n", known, {**parents, fix: parent}))
    if not any("fixed_by equal to [base]" in error for error in errors):
        problems.append("a revert-of-fix must be required to name its fix as fixed_by")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        problems = self_test()
        for problem in problems:
            print(f"review-eval self-test failed: {problem}", file=sys.stderr)
        if problems:
            return 1
        print("review-eval self-test passed")
        return 0
    try:
        doc = json.loads(FIXTURE.read_text(encoding="utf-8"))
        class_text = CLASS_SOURCE.read_text(encoding="utf-8")
        review_text = "\n".join(path.read_text(encoding="utf-8") for path in REVIEW_SOURCES)
    except (OSError, ValueError) as error:
        print(f"review-eval failed: {error}", file=sys.stderr)
        return 1
    errors, note = validate(doc, class_text, review_text, run_git)
    for error in errors:
        print(f"review-eval failed: {error}", file=sys.stderr)
    if errors:
        return 1
    cases = doc["cases"]
    print(f"review-eval passed: {len(cases)} cases; {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
