#!/usr/bin/env python3
"""Validate the slim Claude Code capability registry and rendered settings."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))


def main() -> int:
    from tooling.generate.registry_sync import (
        SETTINGS_TEMPLATE_PATH,
        load_capabilities,
        load_policy,
        render_settings,
        validate_capabilities,
    )

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    capabilities = load_capabilities()
    policy = load_policy()
    errors = validate_capabilities(capabilities, policy)
    import json

    template = SETTINGS_TEMPLATE_PATH
    expected = json.dumps(render_settings(policy), indent=2) + "\n"
    if not template.exists():
        errors.append(f"{template}: missing generated settings template")
    elif template.read_text() != expected:
        errors.append(f"{template}: generated settings template is out of date")
    if args.self_test:
        ids = [item.get("id") for item in capabilities.get("capabilities", [])]
        if len(ids) != len(set(ids)):
            errors.append("capability registry contains duplicate IDs")
        if any(item.get("kind") not in {"mcp", "agent", "plugin"} for item in capabilities.get("capabilities", [])):
            errors.append("capability registry contains an unsupported kind")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Claude Code capability contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
