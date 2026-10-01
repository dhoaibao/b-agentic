#!/usr/bin/env python3
"""Validate and render version-1 b-diagram JSON sources without dependencies."""

from __future__ import annotations

import argparse
import html
import json
import math
import os
import re
import tempfile
from pathlib import Path
from typing import Any

ALLOWED_KINDS = {"architecture", "workflow", "sequence", "data-flow", "lifecycle"}
ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
TOP_LEVEL_KEYS = {"version", "kind", "title", "evidence", "nodes", "edges"}
NODE_KEYS = {"id", "label", "evidence"}
EDGE_KEYS = {"id", "source", "target", "label"}
EVIDENCE_KEYS = {"id", "label", "location"}


def issue(path: str, message: str) -> str:
    return f"{path}: {message}"


def is_id(value: object) -> bool:
    return isinstance(value, str) and bool(ID_PATTERN.fullmatch(value))


def nonempty_string(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def validate_document(document: object) -> list[str]:
    """Return deterministic source errors; no rendering or file writes occur."""
    if not isinstance(document, dict):
        return [issue("$", "must be an object")]

    errors: list[str] = []
    unknown = sorted(set(document) - TOP_LEVEL_KEYS)
    if unknown:
        errors.append(issue("$", f"unsupported properties: {', '.join(unknown)}"))
    version = document.get("version")
    if isinstance(version, bool) or version != 1:
        errors.append(issue("version", "must equal 1"))
    kind = document.get("kind")
    if not isinstance(kind, str) or kind not in ALLOWED_KINDS:
        errors.append(issue("kind", f"must be one of {', '.join(sorted(ALLOWED_KINDS))}"))
    if not nonempty_string(document.get("title")):
        errors.append(issue("title", "must be a non-empty string"))

    evidence_items = document.get("evidence", [])
    evidence_ids: set[str] = set()
    if not isinstance(evidence_items, list):
        errors.append(issue("evidence", "must be an array when supplied"))
        evidence_items = []
    for index, evidence in enumerate(evidence_items):
        path = f"evidence[{index}]"
        if not isinstance(evidence, dict):
            errors.append(issue(path, "must be an object"))
            continue
        unknown = sorted(set(evidence) - EVIDENCE_KEYS)
        if unknown:
            errors.append(issue(path, f"unsupported properties: {', '.join(unknown)}"))
        evidence_id = evidence.get("id")
        if not is_id(evidence_id):
            errors.append(issue(f"{path}.id", "must be a stable identifier"))
        elif evidence_id in evidence_ids:
            errors.append(issue(f"{path}.id", f"duplicates evidence id {evidence_id!r}"))
        else:
            evidence_ids.add(evidence_id)
        for field in ("label", "location"):
            if not nonempty_string(evidence.get(field)):
                errors.append(issue(f"{path}.{field}", "must be a non-empty string"))

    nodes = document.get("nodes")
    node_ids: set[str] = set()
    if not isinstance(nodes, list) or not nodes:
        errors.append(issue("nodes", "must be a non-empty array"))
        nodes = []
    for index, node in enumerate(nodes):
        path = f"nodes[{index}]"
        if not isinstance(node, dict):
            errors.append(issue(path, "must be an object"))
            continue
        unknown = sorted(set(node) - NODE_KEYS)
        if unknown:
            errors.append(issue(path, f"unsupported properties: {', '.join(unknown)}"))
        node_id = node.get("id")
        if not is_id(node_id):
            errors.append(issue(f"{path}.id", "must be a stable identifier"))
        elif node_id in node_ids:
            errors.append(issue(f"{path}.id", f"duplicates node id {node_id!r}"))
        else:
            node_ids.add(node_id)
        if not nonempty_string(node.get("label")):
            errors.append(issue(f"{path}.label", "must be a non-empty string"))
        references = node.get("evidence", [])
        if not isinstance(references, list) or not all(is_id(reference) for reference in references):
            errors.append(issue(f"{path}.evidence", "must be an array of stable identifiers"))
        elif len(references) != len(set(references)):
            errors.append(issue(f"{path}.evidence", "must not repeat an evidence identifier"))
        else:
            for reference in references:
                if reference not in evidence_ids:
                    errors.append(issue(f"{path}.evidence", f"references unknown evidence id {reference!r}"))

    edges = document.get("edges")
    edge_ids: set[str] = set()
    if not isinstance(edges, list):
        errors.append(issue("edges", "must be an array"))
        edges = []
    for index, edge in enumerate(edges):
        path = f"edges[{index}]"
        if not isinstance(edge, dict):
            errors.append(issue(path, "must be an object"))
            continue
        unknown = sorted(set(edge) - EDGE_KEYS)
        if unknown:
            errors.append(issue(path, f"unsupported properties: {', '.join(unknown)}"))
        edge_id = edge.get("id")
        if not is_id(edge_id):
            errors.append(issue(f"{path}.id", "must be a stable identifier"))
        elif edge_id in edge_ids:
            errors.append(issue(f"{path}.id", f"duplicates edge id {edge_id!r}"))
        else:
            edge_ids.add(edge_id)
        for field in ("source", "target"):
            value = edge.get(field)
            if not is_id(value):
                errors.append(issue(f"{path}.{field}", "must be a stable identifier"))
            elif value not in node_ids:
                errors.append(issue(f"{path}.{field}", f"references unknown node id {value!r}"))
        if "label" in edge and not nonempty_string(edge["label"]):
            errors.append(issue(f"{path}.label", "must be a non-empty string when supplied"))
    return errors


def load_document(path: Path) -> dict[str, Any]:
    try:
        loaded = json.loads(path.read_text())
    except OSError as exc:
        raise ValueError(f"cannot read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON in {path}: {exc.msg} at line {exc.lineno}, column {exc.colno}") from exc
    if not isinstance(loaded, dict):
        raise ValueError(f"{path}: top level must be an object")
    return loaded


def positions(nodes: list[dict[str, Any]]) -> dict[str, tuple[int, int]]:
    columns = max(1, math.ceil(math.sqrt(len(nodes))))
    return {
        node["id"]: (100 + (index % columns) * 260, 120 + (index // columns) * 170) for index, node in enumerate(nodes)
    }


def render(document: dict[str, Any]) -> str:
    nodes = document["nodes"]
    coordinates = positions(nodes)
    columns = max(1, math.ceil(math.sqrt(len(nodes))))
    rows = max(1, math.ceil(len(nodes) / columns))
    width = max(720, columns * 260 + 160)
    height = max(400, rows * 170 + 190)
    evidence = {item["id"]: item["label"] for item in document.get("evidence", [])}

    edge_svg: list[str] = []
    for edge in document["edges"]:
        source_x, source_y = coordinates[edge["source"]]
        target_x, target_y = coordinates[edge["target"]]
        start_x, start_y = source_x + 170, source_y + 44
        end_x, end_y = target_x, target_y + 44
        mid_x = (start_x + end_x) // 2
        edge_svg.append(
            f'<path class="edge" data-edge-id="{html.escape(edge["id"])}" '
            f'd="M {start_x} {start_y} H {mid_x} V {end_y} H {end_x}" marker-end="url(#arrow)"/>'
        )
        if "label" in edge:
            edge_svg.append(
                f'<text class="edge-label" x="{mid_x}" y="{min(start_y, end_y) - 8}">{html.escape(edge["label"])}</text>'
            )

    node_svg: list[str] = []
    for node in nodes:
        x, y = coordinates[node["id"]]
        references = ", ".join(evidence[reference] for reference in node.get("evidence", []))
        reference_text = (
            f'<text class="evidence" x="{x + 16}" y="{y + 70}">{html.escape(references)}</text>' if references else ""
        )
        node_svg.append(
            f'<g class="node" data-node-id="{html.escape(node["id"])}">'
            f'<rect x="{x}" y="{y}" width="170" height="88" rx="8"/>'
            f'<text class="node-label" x="{x + 16}" y="{y + 38}">{html.escape(node["label"])}</text>{reference_text}</g>'
        )

    title = html.escape(document["title"])
    kind = html.escape(document["kind"])
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
:root {{ color-scheme: light dark; font-family: system-ui, sans-serif; }}
body {{ margin: 0; background: Canvas; color: CanvasText; }}
main {{ max-width: {width}px; margin: 2rem auto; padding: 0 1rem; }}
h1 {{ font-size: 1.5rem; margin: 0; }}
p {{ color: GrayText; margin: .25rem 0 1rem; text-transform: capitalize; }}
svg {{ width: 100%; height: auto; border: 1px solid color-mix(in srgb, CanvasText 20%, transparent); border-radius: .5rem; }}
.edge {{ fill: none; stroke: color-mix(in srgb, CanvasText 65%, transparent); stroke-width: 2; }}
.edge-label {{ fill: GrayText; font-size: 12px; text-anchor: middle; }}
.node rect {{ fill: color-mix(in srgb, Canvas 92%, CanvasText 8%); stroke: color-mix(in srgb, CanvasText 55%, transparent); stroke-width: 1.5; }}
.node-label {{ fill: CanvasText; font-size: 15px; font-weight: 650; }}
.evidence {{ fill: GrayText; font-size: 11px; }}
</style>
</head>
<body>
<main>
<h1>{title}</h1>
<p>{kind} diagram · authored facts only</p>
<svg viewBox="0 0 {width} {height}" role="img" aria-label="{title}" data-diagram-kind="{kind}">
<defs><marker id="arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="currentColor"/></marker></defs>
{"".join(edge_svg)}
{"".join(node_svg)}
</svg>
</main>
</body>
</html>
"""


def deliver(source: Path, target: Path) -> None:
    document = load_document(source)
    errors = validate_document(document)
    if errors:
        raise ValueError("\n".join(errors))
    if target.suffix.lower() != ".html":
        raise ValueError("target must end with .html")
    if not target.parent.is_dir():
        raise ValueError(f"target parent does not exist: {target.parent}")
    content = render(document)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=target.parent, delete=False) as temporary:
        temporary.write(content)
        temporary_path = Path(temporary.name)
    try:
        os.replace(temporary_path, target)
    except OSError:
        temporary_path.unlink(missing_ok=True)
        raise


def self_test() -> int:
    valid = {
        "version": 1,
        "kind": "architecture",
        "title": "Checkout request",
        "evidence": [{"id": "src-router", "label": "router.py", "location": "app/router.py:12"}],
        "nodes": [
            {"id": "browser", "label": "Browser"},
            {"id": "router", "label": "Router", "evidence": ["src-router"]},
        ],
        "edges": [{"id": "browser-router", "source": "browser", "target": "router", "label": "request"}],
    }
    if validate_document(valid):
        print("diagram self-test failed: valid source rejected")
        return 1
    malformed = {
        **valid,
        "nodes": [{"id": "browser", "label": "Browser"}],
        "edges": [{"id": "bad", "source": "browser", "target": "missing"}],
    }
    if not any("unknown node id" in item for item in validate_document(malformed)):
        print("diagram self-test failed: dangling edge accepted")
        return 1
    for field, bad in (("version", True), ("kind", []), ("kind", {})):
        if not any(item.startswith(f"{field}:") for item in validate_document({**valid, field: bad})):
            print(f"diagram self-test failed: invalid {field} {bad!r} accepted")
            return 1
    with tempfile.TemporaryDirectory(prefix="b-diagram-") as directory:
        root = Path(directory)
        source = root / "source.json"
        target = root / "diagram.html"
        source.write_text(json.dumps(valid))
        deliver(source, target)
        delivered = target.read_text()
        if 'data-diagram-kind="architecture"' not in delivered or "Checkout request" not in delivered:
            print("diagram self-test failed: rendered artifact is incomplete")
            return 1
        target.write_text("last known good")
        source.write_text(json.dumps(malformed))
        try:
            deliver(source, target)
        except ValueError:
            pass
        else:
            print("diagram self-test failed: invalid source was delivered")
            return 1
        if target.read_text() != "last known good":
            print("diagram self-test failed: invalid delivery replaced target")
            return 1
    print("Diagram source and delivery self-test passed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate_parser = subparsers.add_parser("validate", help="validate source without writing")
    validate_parser.add_argument("source", type=Path)
    deliver_parser = subparsers.add_parser("deliver", help="validate and atomically write HTML")
    deliver_parser.add_argument("source", type=Path)
    deliver_parser.add_argument("target", type=Path)
    subparsers.add_parser("self-test", help="run local validation and delivery fixtures")
    args = parser.parse_args()

    if args.command == "self-test":
        return self_test()
    try:
        document = load_document(args.source)
        errors = validate_document(document)
        if errors:
            print("\n".join(errors))
            return 1
        if args.command == "validate":
            print(f"Diagram source valid: {args.source}")
            return 0
        deliver(args.source, args.target)
        print(f"Diagram delivered: {args.target}")
        return 0
    except ValueError as exc:
        print(exc)
        return 1
    except OSError as exc:
        print(f"delivery failed: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
