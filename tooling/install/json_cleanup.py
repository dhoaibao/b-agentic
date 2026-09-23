"""Inverse merge helpers for native OpenCode configuration uninstall."""

from __future__ import annotations

import json
from pathlib import Path

from jsonc import loads as load_jsonc

MISSING = object()


def cleanup(current_value, incoming_value, original_value, path=()):
    """Remove values introduced by an incoming managed config.

    Values present in the original user config retain their original ownership.
    Containers are recursively pruned only when all of their managed values can
    be removed without touching user additions.
    """
    if isinstance(current_value, dict) and isinstance(incoming_value, dict):
        original = original_value if isinstance(original_value, dict) else {}
        result = dict(current_value)
        for key, incoming_child in incoming_value.items():
            if key not in result:
                continue
            original_child = original.get(key, MISSING)
            if key == "permissions" and isinstance(result[key], list) and isinstance(incoming_child, list):
                # The installer places the whole managed OpenCode v2 rule block
                # first. Remove that positional prefix so a trailing user rule
                # identical to a managed rule retains its ownership and order.
                if result[key][: len(incoming_child)] == incoming_child:
                    cleaned = result[key][len(incoming_child) :]
                    if original_child is MISSING and not cleaned:
                        result.pop(key)
                    else:
                        result[key] = cleaned
                else:
                    result[key] = cleanup(result[key], incoming_child, original_child, path + (key,))
            elif original_child is MISSING:
                if result[key] == incoming_child:
                    result.pop(key)
                elif isinstance(result[key], type(incoming_child)) and isinstance(result[key], (dict, list)):
                    cleaned = cleanup(
                        result[key], incoming_child, {} if isinstance(result[key], dict) else [], path + (key,)
                    )
                    if cleaned in ({}, []):
                        result.pop(key)
                    else:
                        result[key] = cleaned
            else:
                result[key] = cleanup(result[key], incoming_child, original_child, path + (key,))
        return result
    if isinstance(current_value, list) and isinstance(incoming_value, list):
        original = original_value if isinstance(original_value, list) else []
        return [item for item in current_value if item in original or item not in incoming_value]
    # Only compaction.auto is overridden by install; other user-owned scalars
    # may have been changed to the managed value since installation.
    if path == ("compaction", "auto") and original_value is not MISSING and current_value == incoming_value:
        return original_value
    return current_value


def remove_managed_json_config(current_path: Path, template_path: Path, original_path: Path | None, _label: str):
    current = load_jsonc(current_path.read_text())
    incoming = json.loads(template_path.read_text())
    original = {} if original_path is None else load_jsonc(original_path.read_text())
    if not all(isinstance(value, dict) for value in (current, incoming, original)):
        raise ValueError("configuration cleanup requires JSON object inputs")
    return cleanup(current, incoming, original)
