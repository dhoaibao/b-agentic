"""Terminal presentation for the b-agentic installer: banner, timeline steps, boxes, and one confirm.

Standard library only. Rendering is enabled only when stdout is a terminal that is not `TERM=dumb`;
otherwise every method is a no-op and the installer keeps its plain, line-oriented output. Colors
follow `NO_COLOR`, and box-drawing characters fall back to ASCII when stdout is not UTF-8.
Questions are read from /dev/tty so they also work for `curl ... | bash`, where stdin is the pipe.
"""

from __future__ import annotations

import os
import re
import shutil
import sys
import textwrap
from typing import IO

ANSI = re.compile(r"\x1b\[[0-9;]*m")
BANNER_FONT = {
    "B": ("████ ", "█   █", "████ ", "█   █", "████ "),
    "A": (" ███ ", "█   █", "█████", "█   █", "█   █"),
    "-": ("     ", "     ", "█████", "     ", "     "),
    "G": (" ████", "█    ", "█  ██", "█   █", " ████"),
    "E": ("█████", "█    ", "████ ", "█    ", "█████"),
    "N": ("█   █", "██  █", "█ █ █", "█  ██", "█   █"),
    "T": ("█████", "  █  ", "  █  ", "  █  ", "  █  "),
    "I": ("█████", "  █  ", "  █  ", "  █  ", "█████"),
    "C": (" ████", "█    ", "█    ", "█    ", " ████"),
}
BANNER_SHADES = (252, 249, 246, 243, 240)
UNICODE_GLYPHS = {
    "step": "◇",
    "done": "●",
    "ok": "✓",
    "bar": "│",
    "top": "┌",
    "tr": "╮",
    "bl": "╰",
    "br": "╯",
    "h": "─",
    "v": "│",
}
ASCII_GLYPHS = {
    "step": "o",
    "done": "*",
    "ok": "+",
    "bar": "|",
    "top": "+",
    "tr": "+",
    "bl": "+",
    "br": "+",
    "h": "-",
    "v": "|",
}
COLORS = {"cyan": "36", "green": "32", "yellow": "33", "dim": "2", "bold": "1", "blue": "34"}


def visible_len(text: str) -> int:
    return len(ANSI.sub("", text))


class Ui:
    def __init__(self, stream: IO[str] | None = None, enabled: bool = True) -> None:
        self.out = stream or sys.stdout
        env = os.environ
        self.fancy = enabled and bool(self.out.isatty()) and env.get("TERM", "") != "dumb"
        self.color = self.fancy and "NO_COLOR" not in env
        encoding = (getattr(self.out, "encoding", None) or "").lower().replace("_", "-")
        self.glyph = UNICODE_GLYPHS if encoding in {"utf-8", "utf8"} else ASCII_GLYPHS
        self.tty_in: IO[str] | None = None
        self.tty_out: IO[str] | None = None
        if self.fancy:
            try:
                self.tty_in = open("/dev/tty")  # noqa: SIM115 - held for the lifetime of the run
                self.tty_out = open("/dev/tty", "w")  # noqa: SIM115
            except (OSError, ValueError):
                self.close()

    @property
    def interactive(self) -> bool:
        return self.tty_in is not None and self.tty_out is not None

    def close(self) -> None:
        for handle in (self.tty_in, self.tty_out):
            if handle is not None:
                handle.close()
        self.tty_in = self.tty_out = None

    # -- primitives -----------------------------------------------------------------
    def style(self, text: str, *names: str) -> str:
        if not self.color or not names:
            return text
        codes = ";".join(COLORS[name] for name in names)
        return f"\x1b[{codes}m{text}\x1b[0m"

    def width(self) -> int:
        return max(40, min(shutil.get_terminal_size((100, 24)).columns, 100))

    def emit(self, line: str = "") -> None:
        print(line, file=self.out)

    def bar(self) -> str:
        return self.style(self.glyph["bar"], "blue")

    # -- layout -----------------------------------------------------------------------
    def banner(self, text: str = "B-AGENTIC") -> None:
        if not self.fancy or not all(ch in BANNER_FONT for ch in text):
            return
        for row in range(5):
            line = " ".join(BANNER_FONT[ch][row] for ch in text).rstrip()
            if self.color and self.glyph is UNICODE_GLYPHS:
                line = f"\x1b[38;5;{BANNER_SHADES[row]}m{line}\x1b[0m"
            elif self.glyph is ASCII_GLYPHS:
                line = line.replace("█", "#")
            self.emit(line)
        self.emit()
        self.emit(f"{self.style(self.glyph['top'], 'blue')}  {self.style(' b-agentic ', 'cyan', 'bold')}")

    def step(self, title: str, detail: str | None = None, *, bold: bool = False, done: bool = False) -> None:
        if not self.fancy:
            return
        marker = self.style(self.glyph["done" if done else "step"], "green" if not done else "cyan")
        self.emit(self.bar())
        self.emit(f"{marker}  {self.style(title, 'bold') if bold else title}")
        if detail:
            self.emit(f"{self.bar()}  {self.style(detail, 'dim')}")

    def box(self, title: str, lines: list[str], *, tone: str | None = None) -> None:
        if not self.fancy:
            return
        inner = self.width() - 6
        body: list[str] = []
        for line in lines:
            if visible_len(line) <= inner:
                body.append(line)
                continue
            plain = ANSI.sub("", line)
            indent = " " * (len(plain) - len(plain.lstrip()))
            body.extend(textwrap.wrap(plain, inner, initial_indent="", subsequent_indent=indent + "  ") or [""])
        width = max([visible_len(title) + 2, *(visible_len(line) for line in body)])
        g = self.glyph
        head = self.style(title, tone, "bold") if tone else self.style(title, "bold")
        rule = self.style(g["h"] * (width + 1 - visible_len(title)) + g["tr"], "blue")
        edge = self.style(g["v"], "blue")
        self.emit(self.bar())
        self.emit(f"{self.style(g['step'], 'green')}  {head} {rule}")
        self.emit(f"{self.bar()}  {' ' * width}  {edge}")
        for line in body:
            self.emit(f"{self.bar()}  {line}{' ' * (width - visible_len(line))}  {edge}")
        self.emit(f"{self.bar()}  {' ' * width}  {edge}")
        self.emit(self.style(g["bl"] + g["h"] * (width + 4) + g["br"], "blue"))

    # -- input ------------------------------------------------------------------------
    def confirm(self, question: str, default: bool = True, *, say_answer: bool = True) -> bool:
        """Ask on /dev/tty; without a terminal the default is returned and nothing is printed."""
        if self.tty_in is None or self.tty_out is None:
            return default
        hint = "Y/n" if default else "y/N"
        answer = default
        for _ in range(3):
            self.emit(self.bar())
            self.tty_out.write(f"{self.style(self.glyph['step'], 'green')}  {self.style(question, 'bold')} [{hint}] ")
            self.tty_out.flush()
            reply = self.tty_in.readline()
            if reply == "":  # end of input keeps the default rather than looping
                break
            reply = reply.strip().lower()
            if reply == "":
                break
            if reply in {"y", "yes"}:
                answer = True
                break
            if reply in {"n", "no"}:
                answer = False
                break
        if say_answer:
            self.emit(f"{self.bar()}  {self.style('Yes' if answer else 'No', 'dim')}")
        return answer
