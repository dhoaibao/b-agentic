# Shell Tools And RTK Preferences

Optional operational detail for local command selection. The always-loaded kernel only requires the lightest reliable local evidence; load this reference when shell-tool choice matters.

## RTK

When `rtk` is installed, use it for command families it supports when its filtered output preserves the evidence needed for the task. Do not mechanically prefix unsupported commands.

Run unsupported commands directly. Use `rtk proxy <cmd>` only when raw execution with RTK tracking is useful.

## Preferred local utilities

When these tools are installed, prefer them over the classic equivalents:

- `rg` replaces `grep` for text search.
- `fd` or `fdfind` replaces `find` for file and directory discovery.
- `bat` (or `batcat` on Debian/Ubuntu) replaces `cat` for viewing file contents.
- `eza` or `exa` replaces `ls` for listing directories.
- `sd` replaces `sed` and `awk` for find-and-replace text transformations.
- `jq` replaces `python -m json.tool` for JSON inspection, formatting, and filtering.

If a preferred shell tool is missing, use the closest available local fallback and mention the limitation only when it affects reliability. Do not block work to install shell utilities unless the user asks.
