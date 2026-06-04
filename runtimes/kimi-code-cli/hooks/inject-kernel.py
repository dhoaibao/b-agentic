#!/usr/bin/env python3
"""Inject the managed b-agentic kernel into a Kimi session once."""

from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path


def state_key(payload: dict) -> str:
    raw = payload.get("session_id") or payload.get("cwd") or "unknown-session"
    return hashlib.sha256(str(raw).encode("utf-8")).hexdigest()[:32]


def main() -> int:
    if len(sys.argv) != 2:
        return 0

    kernel_path = Path(sys.argv[1]).expanduser()
    if not kernel_path.exists():
        print(f"[b-agentic hook] kernel injection failed open: missing {kernel_path}", file=sys.stderr)
        return 0

    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        payload = {}
        print("[b-agentic hook] kernel injection failed open: invalid hook payload", file=sys.stderr)

    state_root_env = os.environ.get("B_AGENTIC_KIMI_HOOK_STATE", "")
    if state_root_env:
        state_root = Path(state_root_env).expanduser()
    else:
        state_root = kernel_path.parent / "b-agentic" / "hook-state"
    state_root.mkdir(parents=True, exist_ok=True)

    marker = state_root / f"{state_key(payload)}.seen"
    if marker.exists():
        return 0

    marker.write_text("seen\n", encoding="utf-8")
    kernel = kernel_path.read_text(encoding="utf-8")
    sys.stdout.write("\n[b-agentic runtime kernel]\n")
    sys.stdout.write(kernel)
    if not kernel.endswith("\n"):
        sys.stdout.write("\n")
    sys.stdout.write("[/b-agentic runtime kernel]\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
