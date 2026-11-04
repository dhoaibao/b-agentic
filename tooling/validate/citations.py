#!/usr/bin/env python3

"""Shared repository-citation tokenization and path resolution helpers."""

from __future__ import annotations

import re
import shlex
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
REPO_SOURCE_SUFFIXES = {".md", ".py", ".ts", ".mjs", ".js", ".json", ".yaml", ".yml", ".sh", ".toml"}
CODE_SPAN_RE = re.compile(r"`([^`]+)`")
PLAIN_PATH_RE = re.compile(r"(?<![@\w])(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.*@+-]+(?:\.[A-Za-z0-9_-]+)?")


def tracked_paths() -> set[str]:
    result = subprocess.run(["git", "ls-files"], cwd=ROOT, check=True, capture_output=True, text=True)
    return set(result.stdout.splitlines())


def candidate_path(token: str) -> str | None:
    token = token.rstrip(".,;:!?)]}>")
    token = token.lstrip("([{<")
    if not token or token.startswith(("@", "npm:", "http:", "https:")):
        return None
    if "*" in token:
        return token
    if "/" in token:
        if not re.fullmatch(r"(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.*@+-]+(?:\.[A-Za-z0-9_-]+)?", token):
            return None
        if Path(token).suffix.lower() not in REPO_SOURCE_SUFFIXES:
            return None
        return token
    if Path(token).suffix.lower() in REPO_SOURCE_SUFFIXES:
        return token
    return None


def resolve_path(citation: str, tracked: set[str]) -> bool:
    if "*" in citation:
        # Wildcard citations are intentionally skipped, following decision_design.py.
        return True
    normalized = citation.removeprefix("./")
    exact = ROOT / normalized
    if normalized in tracked:
        return exact.is_file()
    if exact.is_dir():
        return any(path.startswith(normalized.rstrip("/") + "/") for path in tracked)
    suffix_matches = [path for path in tracked if path.endswith("/" + normalized)]
    return len(suffix_matches) == 1 and (ROOT / suffix_matches[0]).is_file()


def path_citations(
    text: str,
    tracked: set[str] | None,
    *,
    include_plain: bool = True,
    include_prefix: bool = True,
) -> list[str]:
    citations: list[str] = []
    for raw in CODE_SPAN_RE.findall(text):
        try:
            tokens = shlex.split(raw)
        except ValueError:
            tokens = raw.split()
        for index, token in enumerate(tokens):
            if token == "--prefix" and index + 1 < len(tokens):
                if include_prefix:
                    citation = candidate_path(tokens[index + 1]) or tokens[index + 1]
                    if citation and citation not in citations:
                        citations.append(citation)
                continue
            citation = candidate_path(token)
            if (
                citation
                and ("/" in citation or tracked is None or resolve_path(citation, tracked))
                and citation not in citations
            ):
                citations.append(citation)
    if include_plain:
        for token in PLAIN_PATH_RE.findall(text):
            citation = candidate_path(token)
            if citation and citation not in citations:
                citations.append(citation)
    return citations
