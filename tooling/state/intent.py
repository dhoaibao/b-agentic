from __future__ import annotations

from dataclasses import dataclass
import re


INTENT_BLOCK_RE = re.compile(r"```text\s*\n(?P<body>\[intent\][\s\S]*?)\n```", re.MULTILINE)
APPROVAL_BLOCK_RE = re.compile(r"```text\s*\n(?P<body>\[approval\][\s\S]*?)\n```", re.MULTILINE)
FIELD_RE = re.compile(r"^(?P<key>[a-z-]+):\s(?P<value>.+)$")
APPROVED_RESPONSE_RE = re.compile(r"\b(y|yes|yeah|yep|sure|ok|okay|proceed|go ahead)\b", re.IGNORECASE)


@dataclass(frozen=True)
class Intent:
    skill: str
    action: str
    files: tuple[str, ...]
    commands: tuple[str, ...]
    source: str
    approval: str
    reason: str
    raw: str

    @classmethod
    def from_fields(cls, fields: dict[str, str], raw: str) -> "Intent":
        return cls(
            skill=fields.get("skill", ""),
            action=fields.get("action", ""),
            files=_split_csv(fields.get("files", "")),
            commands=_split_csv(fields.get("commands", "")),
            source=fields.get("source", ""),
            approval=fields.get("approval", ""),
            reason=fields.get("reason", ""),
            raw=raw,
        )


def _split_csv(value: str) -> tuple[str, ...]:
    if not value or value.strip().lower() == "none":
        return ()
    return tuple(part.strip() for part in value.split(",") if part.strip())


def parse_intents(text: str) -> tuple[list[Intent], list[str]]:
    intents: list[Intent] = []
    errors: list[str] = []

    for match in INTENT_BLOCK_RE.finditer(text):
        raw = match.group("body")
        lines = [line.rstrip() for line in raw.splitlines() if line.strip()]
        if not lines or lines[0] != "[intent]":
            errors.append("[intent]: malformed header")
            continue

        fields: dict[str, str] = {}
        for line in lines[1:]:
            field_match = FIELD_RE.match(line)
            if not field_match:
                errors.append(f"[intent]: malformed field line {line!r}")
                continue
            key = field_match.group("key")
            if key in fields:
                errors.append(f"[intent]: duplicate field {key!r}")
            fields[key] = field_match.group("value")

        for required in ["skill", "action", "source", "approval", "reason"]:
            if required not in fields:
                errors.append(f"[intent]: missing required field {required!r}")
        if "files" not in fields and "commands" not in fields:
            errors.append("[intent]: missing required field 'files' or 'commands'")

        intents.append(Intent.from_fields(fields, raw))

    return intents, errors


def parse_approval_blocks(text: str) -> list[dict[str, str]]:
    """Parse [approval] blocks from transcript.

    Returns a list of approval records with keys: action, effect, response.
    Only approvals with an affirmative response are considered valid.
    """
    approvals: list[dict[str, str]] = []
    for match in APPROVAL_BLOCK_RE.finditer(text):
        raw = match.group("body")
        lines = [line.rstrip() for line in raw.splitlines() if line.strip()]
        if not lines or not lines[0].startswith("[approval]"):
            continue

        fields: dict[str, str] = {}
        for line in lines[1:]:
            field_match = FIELD_RE.match(line)
            if field_match:
                fields[field_match.group("key")] = field_match.group("value")

        # Check for affirmative response after the block, up to the next structured block
        block_end = match.end()
        next_block_start = len(text)
        for next_match in re.finditer(r"```text\s*\n\[(?:intent|status|handoff|approval)", text[block_end:]):
            next_block_start = block_end + next_match.start()
            break
        following_text = text[block_end:next_block_start]
        is_approved = bool(APPROVED_RESPONSE_RE.search(following_text))

        if is_approved:
            approvals.append({
                "action": fields.get("action", ""),
                "effect": fields.get("effect", ""),
                "response": "approved",
            })

    return approvals
