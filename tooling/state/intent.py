from __future__ import annotations

from dataclasses import dataclass
import re


INTENT_BLOCK_RE = re.compile(r"```text\s*\n(?P<body>\[intent\][\s\S]*?)\n```", re.MULTILINE)
FIELD_RE = re.compile(r"^(?P<key>[a-z-]+):\s(?P<value>.+)$")


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
