#!/usr/bin/env python3
"""Launcher of the run CLI, which is b_run_lib.py beside this file (ADR-040)."""

import importlib.util
import os
import sys
from importlib.machinery import SourceFileLoader

# The flags word of a checked-hash pyc (PEP 552), the only kind the installers and the suite build.
CHECKED_HASH = (3).to_bytes(4, "little")


class Loader(SourceFileLoader):
    """The default loader also takes a timestamp or unchecked pyc, which can run old code, and lets a damaged one
    raise. Here either counts as no pyc, so the source is compiled."""

    def get_data(self, path):
        data = super().get_data(path)
        if path.endswith(".pyc") and data[4:8] != CHECKED_HASH:
            raise OSError("not a checked-hash pyc")
        return data

    def set_data(self, path, data, **_kwargs):
        """Writes nothing, even without -B: only an installer or the suite builds the pyc."""

    def get_code(self, fullname):
        try:
            return super().get_code(fullname)
        except (EOFError, ImportError, TypeError, ValueError):
            path = self.get_filename(fullname)
            return self.source_to_code(self.get_data(path), path)


def launch() -> int:
    # Python reuses bytecode only for an imported file; a script run directly is compiled on every call. The path
    # is explicit because -I keeps the script folder off sys.path.
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "b_run_lib.py")
    spec = importlib.util.spec_from_file_location("b_run_lib", path, loader=Loader("b_run_lib", path))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except OSError as exc:
        print(f"{type(exc).__name__}: {exc.strerror or exc}", file=sys.stderr)
        return 2
    return module.main(sys.argv[1:])


if __name__ == "__main__":
    sys.exit(launch())
