# Shell Tools And RTK Preferences

Required operational tooling for local command selection. Install the listed shell tools and RTK before starting an agent session; this reference defines the required command conventions.

## RTK

Use `rtk` for every command family it supports when its filtered output preserves the evidence needed for the task. Run unsupported commands directly; use `rtk proxy <cmd>` when raw execution with RTK tracking is required.

## Preferred local utilities

Use these required tools instead of the classic equivalents:

- `rg` replaces `grep` for text search.
- `fd` or `fdfind` replaces `find` for file and directory discovery.
- `bat` (or `batcat` on Debian/Ubuntu) replaces `cat` for viewing file contents.
- `eza` or `exa` replaces `ls` for listing directories.
- `sd` replaces `sed` and `awk` for find-and-replace text transformations.
- `jq` replaces `python -m json.tool` for JSON inspection, formatting, and filtering.

These tools are required prerequisites, not optional enhancements. If one is missing, stop and report the missing prerequisite rather than silently falling back or continuing without it.
