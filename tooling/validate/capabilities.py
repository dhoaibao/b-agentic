#!/usr/bin/env python3
"""Validate the slim native OpenCode capability registry and rendered config."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))


def main() -> int:
    from tooling.generate.registry_sync import (
        OPENCODE_TEMPLATE_PATH,
        load_capabilities,
        load_policy,
        render_opencode_template,
        validate_capabilities,
    )

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    capabilities = load_capabilities()
    policy = load_policy()
    errors = validate_capabilities(capabilities, policy)
    expected = render_opencode_template(policy)
    if not OPENCODE_TEMPLATE_PATH.exists():
        errors.append(f"{OPENCODE_TEMPLATE_PATH}: missing generated OpenCode config template")
    elif OPENCODE_TEMPLATE_PATH.read_text() != expected:
        errors.append(f"{OPENCODE_TEMPLATE_PATH}: generated OpenCode config template is out of date")
    if args.self_test:
        ids = [item.get("id") for item in capabilities.get("capabilities", [])]
        if len(ids) != len(set(ids)):
            errors.append("capability registry contains duplicate IDs")
        if any(item.get("kind") not in {"mcp", "agent"} for item in capabilities.get("capabilities", [])):
            errors.append("capability registry contains a retired non-native kind")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Native OpenCode capability contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
