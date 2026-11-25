#!/usr/bin/env python3
"""Install, sync, or remove b-agentic across every supported runtime (Claude Code and Pi)."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

import claude_install
import pi_install
import vendor_tools
from claude_install import InstallError
from claude_install_ui import Ui

ROOT = claude_install.ROOT


def safe_destination_identity(path: Path) -> tuple[tuple[Any, ...] | None, Exception | None]:
    try:
        return claude_install.destination_identity(path), None
    except (OSError, ValueError, RecursionError) as exc:
        return None, exc


def check_cross_runtime_pairs(
    claude_dir: Path,
    mcp_path: Path,
    agent_dir: Path,
    claude_destinations: list[tuple[str, Path]],
    pi_destinations: list[tuple[str, Path]],
) -> None:
    """Refuse before any local guard or write if a Claude Code destination and a Pi destination are the same file."""
    lookup_error: Exception | None = None
    pi_by_key: dict[tuple[Any, ...], tuple[str, Path]] = {}
    for label, path in pi_destinations:
        key, error = safe_destination_identity(path)
        if error is not None:
            if lookup_error is None:
                lookup_error = error
            continue
        assert key is not None
        pi_by_key.setdefault(key, (label, path))
    for claude_label, claude_path in claude_destinations:
        key, error = safe_destination_identity(claude_path)
        if error is not None:
            if lookup_error is None:
                lookup_error = error
            continue
        if key in pi_by_key:
            pi_label, pi_path = pi_by_key[key]
            raise InstallError(
                f"Claude Code {claude_label} ({claude_path}) and Pi {pi_label} ({pi_path}) "
                "resolve to the same file; give each its own file before installing or uninstalling; "
                f"nothing under {claude_dir}, {mcp_path}, or {agent_dir} was changed"
            )
    if lookup_error is not None:
        raise InstallError(f"cannot inspect destination: {lookup_error}") from lookup_error


def precheck_cross_runtime_destinations(
    claude: claude_install.Installer,
    pi: pi_install.Installer,
    *,
    for_uninstall: bool,
    use_current_selection: bool = False,
    include_unforced_optional: bool = True,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Check cross-runtime destination identities before local preflights, manifest errors, or config parsing."""
    claude_destinations, claude_error, claude_manifest = claude.cross_runtime_destinations(
        for_uninstall=for_uninstall,
        use_current_selection=use_current_selection,
        include_unforced_optional=include_unforced_optional,
    )
    pi_destinations, pi_error, pi_manifest = pi.cross_runtime_destinations(
        for_uninstall=for_uninstall,
        use_current_selection=use_current_selection,
        include_unforced_optional=include_unforced_optional,
    )
    check_cross_runtime_pairs(claude.claude_dir, claude.mcp_path, pi.agent_dir, claude_destinations, pi_destinations)
    if claude.override_error is not None:
        raise claude.override_error
    if pi.override_error is not None:
        raise pi.override_error
    if claude_error is not None:
        raise claude_error
    if pi_error is not None:
        raise pi_error
    return claude_manifest, pi_manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uninstall", action="store_true", help="remove what the manifests recorded")
    parser.add_argument("--dry-run", action="store_true", help="print the plans and change nothing")
    parser.add_argument("--force", action="store_true", help="replace modified or unmanaged files after a backup")
    parser.add_argument("-y", "--yes", action="store_true", help="skip interactive questions and use defaults")
    parser.add_argument("--source", default=str(ROOT), help="b-agentic source checkout (default: this repository)")
    claude_install.add_optional_arguments(parser)
    args = parser.parse_args(argv)
    try:
        if args.uninstall and (args.with_ids or args.without_ids):
            raise InstallError("--with and --without cannot be combined with --uninstall")
        source = Path(args.source).resolve()
        if not (source / "skills" / "registry.yaml").is_file() or not (source / "claude" / "agents").is_dir():
            raise InstallError(f"{source} is not a b-agentic Claude Code source checkout")
        if not (source / "pi" / "extensions" / "b-agentic").is_dir():
            raise InstallError(f"{source} is not a b-agentic source checkout with the Pi runtime")
        with_ids, without_ids = claude_install.parse_optional_arguments(source, args)
        ui = Ui(enabled=not (args.yes or args.dry_run or args.uninstall))
        ui.header()
        claude = claude_install.Installer(
            source, args.dry_run, args.force, ui, with_ids, without_ids, False, defer_guards=True
        )
        pi = pi_install.Installer(source, args.dry_run, args.force, with_ids, without_ids, ui=ui, defer_guards=True)
        try:
            if args.uninstall:
                precheck_cross_runtime_destinations(claude, pi, for_uninstall=True)
                claude_prepared = claude.prepare_uninstall()
                pi_prepared = pi.prepare_uninstall()
                claude.apply_uninstall(claude_prepared)
                pi.apply_uninstall(pi_prepared)
                claude.report("uninstall")
                pi.report("uninstall")
            else:
                interactive_checklists = ui.interactive and not (with_ids or without_ids)
                claude_manifest, pi_manifest = precheck_cross_runtime_destinations(
                    claude,
                    pi,
                    for_uninstall=False,
                    include_unforced_optional=not interactive_checklists,
                )
                claude.prepare_component_selection(
                    emit_notes=True, checklist_label="Claude Code", defer_preflight=True, manifest=claude_manifest
                )
                pi_warning = pi.prepare_component_selection(
                    emit_notes=False, checklist_label="Pi", defer_preflight=True, manifest=pi_manifest
                )
                precheck_cross_runtime_destinations(claude, pi, for_uninstall=False, use_current_selection=True)
                claude_previous, claude_payload = claude.validate_destinations()
                claude.announce_install_counts(claude_payload, checklist_label="Claude Code")
                pi_previous, pi_payload = pi.validate_destinations()
                pi.announce_install_counts(pi_payload, checklist_label="Pi")
                claude_plan = claude.plan_all(claude_previous)
                pi_plan = pi.plan_install(pi_previous, pi_warning)
                if ui.fancy:
                    ui.box("Installation Summary (Claude Code)", claude.plan_summary(*claude_plan))
                    ui.box("Installation Summary (Pi)", pi.plan_summary(pi_plan))
                    if ui.interactive:
                        if not ui.confirm("Proceed with installation?", default=True):
                            raise InstallError(
                                f"installation cancelled; nothing under {claude.claude_dir}, {claude.mcp_path}, "
                                f"or {pi.agent_dir} was changed"
                            )
                        precheck_cross_runtime_destinations(claude, pi, for_uninstall=False, use_current_selection=True)
                        claude_previous, _ = claude.validate_destinations()
                        pi_previous, _ = pi.validate_destinations()
                        claude_plan = claude.plan_all(claude_previous)
                        pi_plan = pi.plan_install(pi_previous, pi_warning)
                claude.apply_install(claude_previous, claude_plan)
                pi.apply_install(pi_previous, pi_plan)
                if ui.interactive and not args.dry_run:
                    vendor_warnings, installed_vendor = vendor_tools.offer("all", ui)
                    pi.refresh_pi_warning(installed_vendor)
                    pi.warnings.extend(vendor_warnings)
                operation = f"install ({claude_install.source_revision(source) or 'unversioned source'})"
                claude.report(operation)
                pi.report(operation)
        finally:
            ui.close()
    except InstallError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(
            f"error: {exc}; the manifests record the interrupted run, so fix the cause and rerun the same command "
            "(or --uninstall)",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
