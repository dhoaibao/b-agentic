from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
import json
import os
import tempfile
import uuid
from typing import Any

from tooling.state.schema import SCHEMA_VERSION, validate_state_data


@dataclass
class State:
    version: int = SCHEMA_VERSION
    active_skill: str | None = None
    phase: str = "idle"
    source_of_truth: str | None = None
    approved_plan: str | None = None
    approved_head: str | None = None
    session_id: str = field(default_factory=lambda: uuid.uuid4().hex)
    pending_intent: dict[str, Any] | None = None
    approvals: list[dict[str, Any]] = field(default_factory=list)
    capabilities: dict[str, str] = field(default_factory=dict)
    last_transition: dict[str, Any] | None = None
    updated_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "State":
        errors = validate_state_data(data)
        if errors:
            raise ValueError("; ".join(errors))
        return cls(
            version=data["version"],
            active_skill=data.get("active_skill"),
            phase=data.get("phase", "idle"),
            source_of_truth=data.get("source_of_truth"),
            approved_plan=data.get("approved_plan"),
            approved_head=data.get("approved_head"),
            session_id=data["session_id"],
            pending_intent=data.get("pending_intent"),
            approvals=data.get("approvals", []),
            capabilities=data.get("capabilities", {}),
            last_transition=data.get("last_transition"),
            updated_at=data.get("updated_at", datetime.now(timezone.utc).isoformat()),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "active_skill": self.active_skill,
            "phase": self.phase,
            "source_of_truth": self.source_of_truth,
            "approved_plan": self.approved_plan,
            "approved_head": self.approved_head,
            "session_id": self.session_id,
            "pending_intent": self.pending_intent,
            "approvals": self.approvals,
            "capabilities": self.capabilities,
            "last_transition": self.last_transition,
            "updated_at": self.updated_at,
        }

    def transition(self, *, active_skill: str | None, phase: str, reason: str) -> None:
        previous = {"active_skill": self.active_skill, "phase": self.phase}
        self.active_skill = active_skill
        self.phase = phase
        self.last_transition = {
            "from": previous,
            "to": {"active_skill": active_skill, "phase": phase},
            "reason": reason,
            "at": datetime.now(timezone.utc).isoformat(),
        }
        self.updated_at = datetime.now(timezone.utc).isoformat()


def state_path_for(root: Path) -> Path:
    return root / ".b-agentic" / "state.json"


def load_state(root: Path) -> State | None:
    path = state_path_for(root)
    if not path.exists():
        return None
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError("state file top level must be an object")
    return State.from_dict(data)


def save_state(root: Path, state: State) -> None:
    path = state_path_for(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    state.updated_at = datetime.now(timezone.utc).isoformat()
    data = state.to_dict()
    errors = validate_state_data(data)
    if errors:
        raise ValueError("; ".join(errors))

    fd, temp_name = tempfile.mkstemp(prefix="state.", suffix=".json", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temp_name, path)
    finally:
        temp_path = Path(temp_name)
        if temp_path.exists():
            temp_path.unlink()


def init_state(
    root: Path,
    *,
    active_skill: str | None = None,
    phase: str = "idle",
    source_of_truth: str | None = None,
    capabilities: dict[str, str] | None = None,
) -> State:
    state = State(
        active_skill=active_skill,
        phase=phase,
        source_of_truth=source_of_truth,
        capabilities=capabilities or {},
    )
    save_state(root, state)
    return state
