# ADR-040: The run CLI ships with its bytecode

- Status: Accepted
- Date: 2026-11-27
- Supersedes: none; refines [ADR-010](ADR-010-run-artifact-cli.md) (the artifact writer) and [ADR-028](ADR-028-short-helper-wrappers.md) (`python3 -I -B` behind `b-run`)

## Context

Python caches bytecode only for an imported file. `b_run.py` held the whole CLI, about
3,500 lines, and was run as a script, so every call compiled it again: about 40 ms of a
74 ms `schema spec` on the measuring machine (Python 3.14). `b-state` calls the CLI for
most of its commands, and the default validation suite made over two thousand calls, at
about 159 s of wall time and 532 CPU-seconds.

## Decision

- **Launcher and module.** The source is `claude/bin/b_run_lib.py`. `b_run.py` is a short
  launcher that imports the module from beside its own resolved path and exits with
  `main`'s code. Wrappers, `b-state`, and printed commands keep calling `b_run.py`. A
  module that cannot be read gives one line and exit 2.
- **Installers build the bytecode.** Both write
  `b-agentic/bin/__pycache__/b_run_lib.<cache tag>.pyc`, built in memory from the exact
  module bytes they install and recorded by sha256 in the install manifest, so
  uninstall, a later version, and a change of Python remove it like any managed file. No repository
  bytecode is shipped, `--dry-run` writes nothing, and a Python without a cache tag gets
  none. The module, its bytecode, and the launcher are written in that order, before the
  skills.
- **Checked-hash only** ([PEP 552](https://peps.python.org/pep-0552/)). That is the one
  kind built, and the launcher loads no other: Python's own loader would also take a
  timestamp or unchecked-hash file, and either can run old code. A checked-hash file is
  used only while the module's source hash matches, whatever its size and modification
  time say.
- **`-I -B` stays.** `-I` keeps the script folder and `PYTHON*` variables out, so the
  launcher names the module by path, and `-B` keeps a run from writing bytecode. The
  launcher's loader also writes none, so a call without `-B` leaves the folder and the
  recorded file as they were.
- **A miss costs only time.** With no bytecode, a changed source, another Python
  version, another kind of file, or a payload that cannot be decoded into code, the
  source is compiled in memory. Python's own loader raises on such a payload, so the
  launcher catches that.
- **Existing ownership rules apply.** Claude Code keeps a modified bytecode file and
  warns; Pi refuses the install, as for every file its commands run.
- **The suite compiles once.** `tooling/validate/run.sh` and `bench.py` compile the
  module into the ignored `claude/bin/__pycache__`, with `-f` because `compileall`
  otherwise keeps a timestamp file that looks current. A failed compile, for example in
  a checkout where the file cannot be written, stops the suite before any check, so no
  check loads a file the run did not build. The file stays after the run. It is
  outside the candidate fingerprint and the kit's dirty check, and no installer ships it.

## Consequences

- A call that finds the bytecode starts in about half the time. A call that misses it
  gains nothing.
- Cases that call the CLI's functions load `b_run_lib.py`; the generator reads its
  constants there.
- **Tampering.** Someone who can write the install folder can craft bytecode that carries
  the real source hash and other code. The same access already edits the source or a
  wrapper, so no new access is needed, but reading the source no longer shows what runs.
  The next sync still compares the file with its recorded sha256. The path guard does not
  protect the install folder, for the source or the bytecode.
- Damage that still decodes into code is not detected: the hash covers the source, not
  the payload.
- A probe or helper run by hand from a checkout loads whatever file its ignored
  `__pycache__` holds, which the candidate fingerprint does not cover, as with every
  Python cache there. Only the suite and `bench.py` build it first.
- Importing the installed module without `-B` can leave other files in `__pycache__`;
  an uninstall removes only what the manifest records.
- Rejected: a timestamp `pyc` (it ran old code after an edit that kept the size and
  time); an unchecked-hash `pyc` (Python never compares it with the source); running a
  `pyc` directly (no staleness check, and an error on another Python version); dropping
  `-B` so Python caches by itself (unowned files appear in the install folder); a loader
  passed with `-c` by each caller (the same code in several pinned places); caching from
  inside the script (the whole file is compiled before any of it runs); a shim in the
  tests only (installed runs would keep compiling).

Evidence: [`claude/bin/b_run.py`](../../claude/bin/b_run.py),
[`claude/bin/b_run_lib.py`](../../claude/bin/b_run_lib.py),
[`tooling/install/claude_install.py`](../../tooling/install/claude_install.py),
[`tests/artifacts/artifact-probe.sh`](../../tests/artifacts/artifact-probe.sh).
