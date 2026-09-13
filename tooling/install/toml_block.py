#!/usr/bin/env python3

"""Insert, replace, or remove a marked managed block in a TOML file.

Codex writes MCP servers and approval settings into ``~/.codex/config.toml``,
and its documentation requires config writes to preserve existing comments and
formatting (docs/hosts.md). A generic TOML round-trip cannot do that without a
formatting-preserving writer, which this dependency-light installer does not
have.

So the managed content lives in one delimited block instead. Everything
outside the markers is copied through byte for byte, which preserves comments,
key order, and whitespace by construction. The block is validated with
``tomllib`` before and after the edit, and any table the user already defines
outside the block is skipped rather than duplicated, because a duplicate table
header makes the whole file unparseable for Codex.

Usage:
    toml_block.py apply <config.toml> <managed-block.toml>
    toml_block.py remove <config.toml>

``apply`` prints ``write``, ``merge``, or ``skip`` on the first line, then the
backup path or ``none`` on the second.
"""

from __future__ import annotations

import re
import shutil
import sys
import tomllib
from datetime import datetime, timezone
from pathlib import Path

# The managed content is delivered as two regions, not one.
#
# TOML binds a bare key to whichever table header precedes it, so a block that
# mixes root keys and tables cannot simply be appended: the root keys would
# silently become members of the user's last table. Root keys therefore go
# above the first table header in the file, and the managed tables go at the
# end, where they cannot capture user keys that follow.
BEGIN = "# >>> b-agentic managed settings (generated; edits are replaced) >>>"
END = "# <<< b-agentic managed settings <<<"
BEGIN_TABLES = "# >>> b-agentic managed tables (generated; edits are replaced) >>>"
END_TABLES = "# <<< b-agentic managed tables <<<"


def _region(begin: str, end: str) -> re.Pattern[str]:
    return re.compile(rf"(?:\n*){re.escape(begin)}.*?{re.escape(end)}\n?", re.DOTALL)


BLOCK_RE = _region(BEGIN, END)
TABLES_RE = _region(BEGIN_TABLES, END_TABLES)

# Top-level keys the managed block may set. Anything else in the block is a
# table header and is checked by name.
MANAGED_SCALAR_KEYS = {"approval_policy", "sandbox_mode"}


def fail(message: str) -> "None":
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def strip_block(text: str) -> str:
    """Return the file without either managed region."""
    return TABLES_RE.sub("\n", BLOCK_RE.sub("\n", text, count=1), count=1)


def has_block(text: str) -> bool:
    return BLOCK_RE.search(text) is not None or TABLES_RE.search(text) is not None


def split_block(block: str) -> tuple[str, str]:
    """Split the managed template into its root-key part and its table part."""
    lines = block.splitlines()
    for index, line in enumerate(lines):
        if line.lstrip().startswith("["):
            return "\n".join(lines[:index]).rstrip("\n"), "\n".join(lines[index:]).rstrip("\n")
    return block.rstrip("\n"), ""


def parse(text: str, label: str) -> dict:
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        fail(f"{label} is not valid TOML: {exc}")
        raise  # unreachable; keeps type checkers happy


def block_table_names(block: str) -> list[str]:
    """Top-level table paths declared by the managed block, e.g. mcp_servers.foo."""
    names: list[str] = []
    for line in block.splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and not stripped.startswith("[["):
            names.append(stripped[1:].split("]", 1)[0].strip())
    return names


def conflicting_names(existing: dict, block: str) -> list[str]:
    """Managed names the user already defines outside the block.

    Emitting them again would create a duplicate key or table header and make
    the file unparseable, so the caller refuses the whole merge instead.
    """
    conflicts: list[str] = []
    block_keys = {
        line.split("=", 1)[0].strip()
        for line in block.splitlines()
        if "=" in line and not line.lstrip().startswith("#")
    }
    for key in sorted(MANAGED_SCALAR_KEYS & block_keys):
        if key in existing:
            conflicts.append(key)
    for name in block_table_names(block):
        node: object = existing
        for part in name.split("."):
            if not isinstance(node, dict) or part not in node:
                node = None
                break
            node = node[part]
        if node is not None:
            conflicts.append(name)
    return conflicts


def backup(path: Path) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    destination = path.with_name(f"{path.name}.b-agentic.{stamp}.bak")
    shutil.copy2(path, destination)
    return str(destination)


def compose(existing: str, root_part: str, tables_part: str) -> str:
    """Place the root region first and the table region last."""
    sections = []
    if root_part:
        sections.append(f"{BEGIN}\n{root_part}\n{END}")
    body = existing.strip("\n")
    if body:
        sections.append(body)
    if tables_part:
        sections.append(f"{BEGIN_TABLES}\n{tables_part}\n{END_TABLES}")
    return "\n\n".join(sections) + "\n"


def apply(config: Path, block_source: Path) -> int:
    block = block_source.read_text().rstrip("\n")
    parse(block, str(block_source))
    root_part, tables_part = split_block(block)

    if not config.exists():
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(compose("", root_part, tables_part))
        print("write")
        print("none")
        return 0

    original = config.read_text()
    without = strip_block(original)
    existing = parse(without, str(config))

    conflicts = conflicting_names(existing, block)
    if conflicts:
        print(
            f"warning: preserving user-owned Codex settings; not managing {', '.join(sorted(set(conflicts)))}",
            file=sys.stderr,
        )
        print("skip")
        print("none")
        return 0

    # Back up only the first time, so a re-run never overwrites the snapshot of
    # the user's pre-install file with an already-managed copy.
    saved = "none" if has_block(original) else backup(config)
    updated = compose(without, root_part, tables_part)
    parse(updated, str(config))
    config.write_text(updated)
    print("merge")
    print(saved)
    return 0


def remove(config: Path) -> int:
    if not config.exists():
        return 0
    original = config.read_text()
    if not has_block(original):
        print(f"warning: no b-agentic managed block in {config}; leaving it untouched", file=sys.stderr)
        return 0
    # strip_block leaves a newline where each region was; a region at the top
    # of the file would otherwise leave the file starting with blank lines.
    updated = strip_block(original).strip("\n")
    parse(updated, str(config))
    if updated:
        config.write_text(updated + "\n")
    else:
        config.unlink()
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        fail("usage: toml_block.py apply <config.toml> <block.toml> | remove <config.toml>")
    action = argv[0]
    config = Path(argv[1]).expanduser()
    if action == "apply":
        if len(argv) != 3:
            fail("apply requires a config path and a managed block path")
        return apply(config, Path(argv[2]).expanduser())
    if action == "remove":
        return remove(config)
    fail(f"unknown action: {action}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
