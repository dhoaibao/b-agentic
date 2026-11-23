#!/usr/bin/env python3
"""Install, sync, or remove b-agentic across every supported runtime (Claude Code and Pi)."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import claude_install
import pi_install
import vendor_tools
from claude_install import InstallError
from claude_install_ui import Ui

ROOT = claude_install.ROOT


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
        claude = claude_install.Installer(source, args.dry_run, args.force, ui, with_ids, without_ids, False)
        pi = pi_install.Installer(source, args.dry_run, args.force, with_ids, without_ids, ui=ui)
        try:
            if args.uninstall:
                claude_prepared = claude.prepare_uninstall()
                pi_prepared = pi.prepare_uninstall()
                claude.apply_uninstall(claude_prepared)
                pi.apply_uninstall(pi_prepared)
                claude.report("uninstall")
                pi.report("uninstall")
            else:
                claude_previous, claude_plan = claude.prepare_install(emit_notes=True, checklist_label="Claude Code")
                pi_previous, pi_plan, pi_warning = pi.prepare_install(emit_notes=False, checklist_label="Pi")
                if ui.fancy:
                    ui.box("Installation Summary (Claude Code)", claude.plan_summary(*claude_plan))
                    ui.box("Installation Summary (Pi)", pi.plan_summary(pi_plan))
                    if ui.interactive:
                        if not ui.confirm("Proceed with installation?", default=True):
                            raise InstallError(
                                f"installation cancelled; nothing under {claude.claude_dir}, {claude.mcp_path}, "
                                f"or {pi.agent_dir} was changed"
                            )
                        claude_previous, claude_plan = claude.replan_install()
                        pi_previous, pi_plan = pi.replan_install(pi_warning)
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
