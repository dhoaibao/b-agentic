#!/usr/bin/env python3
"""Validate the slim native Pi capability registry and rendered policy."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))


def main() -> int:
    from tooling.generate.registry_sync import (
        PI_CONFIGS_DIR,
        load_capabilities,
        load_policy,
        render_permissions,
        validate_capabilities,
    )

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    capabilities = load_capabilities()
    policy = load_policy()
    errors = validate_capabilities(capabilities, policy)
    import json

    template = PI_CONFIGS_DIR / "permission.user.template.json"
    expected = json.dumps(render_permissions(policy), indent=2) + "\n"
    if not template.exists():
        errors.append(f"{template}: missing generated Pi permission template")
    elif template.read_text() != expected:
        errors.append(f"{template}: generated Pi permission template is out of date")
    if args.self_test:
        ids = [item.get("id") for item in capabilities.get("capabilities", [])]
        if len(ids) != len(set(ids)):
            errors.append("capability registry contains duplicate IDs")
        if any(item.get("kind") not in {"mcp", "agent"} for item in capabilities.get("capabilities", [])):
            errors.append("capability registry contains a retired non-native kind")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Native Pi capability contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
