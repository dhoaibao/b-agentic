# @dhoaibao/preview-markdown

A standalone Pi package for inline Markdown previews with Tokyo Night Moon/Day
cards, global theme switching, active-branch preview history, and exact source
copying.

## Install

Install with Pi:

```bash
pi install npm:@dhoaibao/preview-markdown
```

The package registers the `preview_markdown` tool and these commands:

- `/preview-markdown:render <prompt>` requests a one-response preview.
- `/preview-markdown:theme` selects the globally persisted Moon or Day theme.
- `/preview-markdown:list` lists the 20 most recent successful active-branch
  previews for exact Markdown source copying.
- `Ctrl+Shift+M` copies the latest preview source.

## Terminal Markdown support

The preview uses Pi's terminal Markdown renderer, so it supports terminal-native
headings, emphasis, strikethrough, links and autolinks, inline and fenced code,
task and nested lists, blockquotes, rules, tables, and supported LaTeX math.
Raw HTML is shown literally, images fall back to their alt text, Mermaid fences
remain code, and footnote syntax remains literal because browser-only embeds and
plugin-based token renderers are not part of the terminal contract. Tables that
cannot fit a very narrow terminal keep their raw Markdown instead of forcing an
unstable layout.

## Raw GitHub alternative

The npm package and the raw installer use the same canonical extension source:
`extensions/b-agentic-preview-markdown.ts` within this package.

For a version-pinned GitHub install without the npm package, use the standalone
raw installer after the corresponding public release tag exists:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/v0.1.2/adapters/pi/scripts/install-preview-markdown.sh | bash -s -- v0.1.2
```

The raw installer preserves unrelated Pi files and installs no other b-agentic
extension or dependency. Run `/reload` in Pi after either installation route.

## Scope

This package contains only the Markdown preview extension and package-facing
documentation. Pi itself and its core extension packages are peer dependencies;
they are not bundled in this package.
