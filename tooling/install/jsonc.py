#!/usr/bin/env python3
"""Dependency-free JSONC loading without modifying string contents."""

from __future__ import annotations

import json
from typing import Any


def _copy_string(text: str, start: int, output: list[str]) -> int:
    index = start
    while index < len(text):
        char = text[index]
        output.append(char)
        index += 1
        if char == "\\" and index < len(text):
            output.append(text[index])
            index += 1
            continue
        if char == '"' and index > start + 1:
            return index
    raise ValueError("unterminated JSONC string")


def strip_jsonc(text: str) -> str:
    without_comments: list[str] = []
    index = 0
    while index < len(text):
        char = text[index]
        if char == '"':
            index = _copy_string(text, index, without_comments)
            continue
        if text.startswith("//", index):
            without_comments.append(" ")
            index += 2
            while index < len(text) and text[index] not in "\r\n":
                index += 1
            continue
        if text.startswith("/*", index):
            without_comments.append(" ")
            index += 2
            while index < len(text) and not text.startswith("*/", index):
                if text[index] in "\r\n":
                    without_comments.append(text[index])
                index += 1
            if index >= len(text):
                raise ValueError("unterminated JSONC block comment")
            index += 2
            continue
        without_comments.append(char)
        index += 1

    cleaned = "".join(without_comments)
    without_trailing_commas: list[str] = []
    index = 0
    while index < len(cleaned):
        char = cleaned[index]
        if char == '"':
            index = _copy_string(cleaned, index, without_trailing_commas)
            continue
        if char == ",":
            lookahead = index + 1
            while lookahead < len(cleaned) and cleaned[lookahead].isspace():
                lookahead += 1
            if lookahead < len(cleaned) and cleaned[lookahead] in "}]":
                index += 1
                continue
        without_trailing_commas.append(char)
        index += 1
    return "".join(without_trailing_commas)


def loads(text: str) -> Any:
    stripped = strip_jsonc(text).strip()
    return json.loads(stripped) if stripped else {}
