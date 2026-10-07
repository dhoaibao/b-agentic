#!/usr/bin/env node
// b-agentic candidate snapshot: a read-only CLI that computes the kernel's
// frozen-review-candidate identity so the model does not hash it by hand.
// Usage: b-candidate-snapshot.mjs [--include-ignored <path>]... [--fingerprint]
//        b-candidate-snapshot.mjs --check-protected
// Exit: 0 complete, 3 incomplete (protected/submodule/unhashable content) or
// blocking protected paths, 2 refused or failed. Output is JSON on stdout.
//
// Identity = HEAD, SHA-256 of the staged and unstaged binary diffs, and the
// sorted relevant untracked paths with type and content digest. Git-ignored
// files are excluded unless the caller names them in `include_ignored`; they
// are then hashed like untracked files. Paths that
// match the likely-secret patterns are listed by path only and never hashed or diffed; any
// such path, or any entry that cannot be hashed, makes the snapshot incomplete
// so the kernel's "block if its identity cannot safely be checked" applies.
//
// Git always runs as an argv (no shell). GIT_OPTIONAL_LOCKS=0 keeps it from
// refreshing the index, and the tool refuses when a repository clean/process
// filter would run a program, so it never writes inside the repository.
// Protected tracked paths and submodules are excluded by pathspec from every
// diff (names included) so git never compares their working-tree content; the
// tool never hashes, diffs, or returns protected content. Git's own ignore-file
// and attribute processing still reads what git would read for `git status`;
// that is not exposure, and it is documented as a residual boundary.
//
// SNAPSHOT_DIFF_FLAGS and PROTECTED_RULES must stay aligned with the
// permission rules the generator renders. Edit them together.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream, realpathSync } from "node:fs";
import { lstat, readlink } from "node:fs/promises";
import { pathToFileURL } from "node:url";
export const SNAPSHOT_SCHEMA = "b-candidate-snapshot/3";
export const SNAPSHOT_DIFF_FLAGS = [
  "--no-ext-diff",
  "--no-textconv",
  "--no-color",
  "--no-renames",
  "--ignore-submodules=none",
  "--submodule=short",
  "--binary",
];
// Same order and semantics as the permission policy's `path` rules: `*` spans
// `/`, `?` is one character, the whole path must match, and the last match wins.
// Paths are matched repository-relative, as raw bytes (latin1), so neither a
// subdirectory cwd nor a non-UTF-8 name can hide a protected path.
export const PROTECTED_RULES = [
  ["*.env", "deny"],
  ["*.env.*", "deny"],
  ["*.env.example", "allow"],
  ["*.pem", "deny"],
  ["*credentials.*", "deny"],
  ["*secrets.*", "deny"],
];
const TIMEOUT_MS = 120_000;
const KEPT_GIT_ENV = new Set([
  "GIT_CEILING_DIRECTORIES",
  "GIT_CONFIG_GLOBAL",
  "GIT_CONFIG_SYSTEM",
  "GIT_CONFIG_NOSYSTEM",
  "GIT_EXEC_PATH",
]);
const TEXT_UNTRACKED_LIMIT = 40;
// Every excluded path becomes one git argument; refuse rather than hit ARG_MAX.
const MAX_EXCLUDED_PATHS = 400;
// Explicitly included ignored files are hashed one by one; refuse a runaway tree.
const MAX_IGNORED_FILES = 2000;
const MAX_IGNORED_SPECS = 50;
function globToRegExp(pattern) {
  const body = [...pattern]
    .map((char) =>
      char === "*"
        ? ".*"
        : char === "?"
          ? "."
          : char.replace(/[.+^${}()|[\]\\]/g, "\\$&"),
    )
    .join("");
  return new RegExp(`^${body}$`, "s");
}
const COMPILED_RULES = PROTECTED_RULES.map(([pattern, action]) => [
  globToRegExp(pattern),
  action,
]);
export function isProtected(path) {
  let verdict = "allow";
  for (const [matcher, action] of COMPILED_RULES) {
    if (matcher.test(path)) verdict = action;
  }
  return verdict === "deny";
}
function entry(raw) {
  const text = raw.toString("utf8");
  const valid = Buffer.from(text, "utf8").equals(raw);
  return {
    raw,
    label: text,
    hex: valid ? null : raw.toString("hex"),
    match: raw.toString("latin1"),
  };
}
function sortedEntries(raws) {
  const unique = new Map(raws.map((raw) => [raw.toString("hex"), raw]));
  return [...unique.values()].sort(Buffer.compare).map(entry);
}
function splitZ(output) {
  const items = [];
  let start = 0;
  for (let index = 0; index < output.length; index++) {
    if (output[index] === 0) {
      if (index > start) items.push(output.subarray(start, index));
      start = index + 1;
    }
  }
  if (start < output.length) items.push(output.subarray(start));
  return items;
}
function git(cwd, args, signal, options = {}) {
  return new Promise((resolve, reject) => {
    // Pin everything that could run a program or change the diff format:
    // fsmonitor hooks, submodule rendering, and external diff/textconv drivers
    // (also refused by flag). Repository clean/process filters are checked
    // separately because no `-c` override can neutralize them safely.
    const env = {};
    for (const [key, value] of Object.entries(process.env)) {
      // Drop every inherited GIT_* control (pathspec mode, external diff,
      // attribute source, lazy fetch, ...) except a few location/config ones;
      // pathspec variables in particular would disable the exclusions below.
      if (value === undefined) continue;
      if (key.startsWith("GIT_") && !KEPT_GIT_ENV.has(key)) continue;
      env[key] = value;
    }
    env.GIT_OPTIONAL_LOCKS = "0";
    env.GIT_TERMINAL_PROMPT = "0";
    env.GIT_NO_LAZY_FETCH = "1";
    env.LC_ALL = "C";
    const child = spawn(
      "git",
      [
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.quotePath=false",
        "-c",
        "diff.submodule=short",
        "-c",
        "diff.ignoreSubmodules=none",
        ...args,
      ],
      {
        cwd,
        shell: false,
        signal,
        timeout: TIMEOUT_MS,
        env,
        stdio: [options.input ? "pipe" : "ignore", "pipe", "pipe"],
      },
    );
    const chunks = [];
    let stderr = "";
    child.stdout?.on("data", (chunk) => {
      if (options.sink) options.sink.update(chunk);
      else chunks.push(chunk);
    });
    child.stderr?.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    if (options.input && child.stdin) {
      child.stdin.on("error", () => undefined);
      child.stdin.end(options.input);
    }
    child.on("error", reject);
    child.on("close", (code) =>
      resolve({ code: code ?? -1, stdout: Buffer.concat(chunks), stderr }),
    );
  });
}
async function gitOk(cwd, args, signal, input) {
  const result = await git(cwd, args, signal, { input });
  if (result.code !== 0) {
    throw new Error(
      `git ${args[0]} failed: ${result.stderr.trim() || result.code}`,
    );
  }
  return result.stdout;
}
function excludeSpecs(excluded) {
  if (excluded.length > MAX_EXCLUDED_PATHS) {
    throw new Error(
      `snapshot refused: ${excluded.length} protected or submodule paths exceed the ${MAX_EXCLUDED_PATHS}-path limit; block the review and report the gap`,
    );
  }
  return excluded.map((item) => {
    if (item.hex !== null) {
      throw new Error(
        `snapshot refused: a protected or submodule path is not valid UTF-8 (hex ${item.hex}) and cannot be excluded from git diff without reading it`,
      );
    }
    return `:(exclude,literal)${item.label}`;
  });
}
function diffArgs(cached, mode, excluded) {
  return [
    "diff",
    ...mode,
    ...(cached ? ["--cached"] : []),
    "--",
    ".",
    ...excludeSpecs(excluded),
  ];
}
async function diffNames(cwd, cached, excluded, signal) {
  return splitZ(
    await gitOk(
      cwd,
      diffArgs(
        cached,
        [
          "--name-only",
          "-z",
          "--no-renames",
          "--ignore-submodules=none",
          "--submodule=short",
        ],
        excluded,
      ),
      signal,
    ),
  );
}
async function diffDigest(cwd, cached, excluded, signal) {
  const hash = createHash("sha256");
  const result = await git(
    cwd,
    diffArgs(cached, SNAPSHOT_DIFF_FLAGS, excluded),
    signal,
    {
      sink: hash,
    },
  );
  if (result.code !== 0) {
    throw new Error(`git diff failed: ${result.stderr.trim() || result.code}`);
  }
  return hash.digest("hex");
}
// A promisor (partial-clone) repository can fetch missing objects from its
// remote in the middle of a diff, which is a network operation and a write.
async function assertNotPartialClone(cwd, signal) {
  const config = await git(
    cwd,
    [
      "config",
      "--get-regexp",
      "^(extensions\\.partialclone|remote\\..*\\.promisor)$",
    ],
    signal,
  );
  if (config.code === 1) return;
  if (config.code !== 0) {
    throw new Error(
      `git config failed: ${config.stderr.trim() || config.code}`,
    );
  }
  throw new Error(
    "snapshot refused: partial-clone (promisor) repository; git could fetch missing objects during diff",
  );
}
// Repository clean/process filters are programs the diff would run, and they
// can write anywhere or read protected files. Refuse when a path uses one.
async function assertNoExecutableFilters(cwd, paths, signal) {
  const config = await git(
    cwd,
    ["config", "--get-regexp", "-z", "^filter\\..*\\.(clean|process)$"],
    signal,
  );
  if (config.code === 1) return;
  if (config.code !== 0) {
    throw new Error(
      `git config failed: ${config.stderr.trim() || config.code}`,
    );
  }
  const drivers = new Set();
  for (const record of splitZ(config.stdout)) {
    const key = record.toString("utf8").split("\n", 1)[0];
    drivers.add(key.slice("filter.".length, key.lastIndexOf(".")));
  }
  if (paths.length === 0) return;
  const input = Buffer.concat(
    paths.flatMap((item) => [item.raw, Buffer.alloc(1)]),
  );
  const output = await gitOk(
    cwd,
    ["check-attr", "-z", "--stdin", "filter"],
    signal,
    input,
  );
  // Fixed `path NUL attribute NUL value NUL` triples; a value may be empty, so
  // empty fields must be kept or every later triple shifts.
  const fields = [];
  let start = 0;
  for (let index = 0; index < output.length; index++) {
    if (output[index] === 0) {
      fields.push(output.subarray(start, index));
      start = index + 1;
    }
  }
  if (start !== output.length || fields.length !== paths.length * 3) {
    throw new Error("snapshot refused: unexpected git check-attr output");
  }
  for (let index = 0; index < fields.length; index += 3) {
    const value = fields[index + 2].toString("utf8");
    if (drivers.has(value)) {
      throw new Error(
        `snapshot refused: repository filter '${value}' has a clean/process command that git diff would run; block the review`,
      );
    }
  }
}
function fileDigest(path, signal) {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    const stream = createReadStream(path, { signal });
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("error", reject);
    stream.on("end", () => resolve(hash.digest("hex")));
  });
}
async function describeUntracked(top, item, signal) {
  const base = { path: item.label, path_hex: item.hex };
  const full = Buffer.concat([Buffer.from(`${top}/`), item.raw]);
  try {
    const info = await lstat(full);
    const mode = (info.mode & 0o777).toString(8).padStart(3, "0");
    if (info.isSymbolicLink()) {
      const target = Buffer.from(await readlink(full, { encoding: "buffer" }));
      return {
        ...base,
        type: "symlink",
        mode,
        size: target.length,
        sha256: createHash("sha256").update(target).digest("hex"),
      };
    }
    if (info.isFile()) {
      return {
        ...base,
        type: "file",
        mode,
        size: info.size,
        sha256: await fileDigest(full, signal),
      };
    }
    return {
      ...base,
      type: info.isDirectory() ? "directory" : "other",
      mode,
      size: null,
      sha256: null,
      reason: info.isDirectory()
        ? "nested-repository"
        : "unsupported-file-type",
    };
  } catch (error) {
    if (signal?.aborted) throw error;
    return {
      ...base,
      type: "other",
      mode: null,
      size: null,
      sha256: null,
      reason: "unreadable",
    };
  }
}
function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    const record = value;
    return `{${Object.keys(record)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}
// Expand each caller-named repository-relative path to the git-ignored files
// beneath it. A literal pathspec keeps globs inert, git itself rejects paths
// outside the repository, and a path that names no ignored file is refused so a
// typo cannot silently leave a relevant artifact uncovered.
async function listIgnored(top, specs, signal) {
  if (specs.length > MAX_IGNORED_SPECS) {
    throw new Error(
      `snapshot refused: ${specs.length} include_ignored paths exceed the ${MAX_IGNORED_SPECS}-path limit`,
    );
  }
  const raws = [];
  for (const spec of specs) {
    // A lone surrogate is sent to git as U+FFFD, which could name a different
    // file; require an exact UTF-8 round trip. Absolute paths are refused so the
    // repository-relative contract does not depend on git's normalization.
    if (
      spec === "" ||
      spec.includes("\0") ||
      spec.includes("\uFFFD") ||
      spec.startsWith("/") ||
      Buffer.from(spec, "utf8").toString("utf8") !== spec
    ) {
      throw new Error(
        "snapshot refused: include_ignored paths must be non-empty, repository-relative, valid UTF-8 strings",
      );
    }
    const listed = splitZ(
      await gitOk(
        top,
        [
          "ls-files",
          "--others",
          "--ignored",
          "--exclude-standard",
          "-z",
          "--full-name",
          "--",
          `:(literal)${spec}`,
        ],
        signal,
      ),
    );
    if (listed.length === 0) {
      throw new Error(
        `snapshot refused: include_ignored path '${spec}' matches no git-ignored file; name a repository-relative ignored file or directory`,
      );
    }
    raws.push(...listed);
    if (raws.length > MAX_IGNORED_FILES) {
      throw new Error(
        `snapshot refused: include_ignored covers more than ${MAX_IGNORED_FILES} files; name a narrower path`,
      );
    }
  }
  return raws;
}
export async function computeSnapshot(cwd, signal, includeIgnored = []) {
  // Always the whole repository, from its top, so a subdirectory cwd can
  // neither narrow the candidate nor hide a protected parent directory.
  // Node decodes a non-UTF-8 working directory lossily to U+FFFD, which can
  // name a different directory; refuse instead of snapshotting a lookalike.
  if (cwd.includes("\uFFFD")) {
    throw new Error(
      "snapshot refused: working directory path is not valid UTF-8 (contains U+FFFD)",
    );
  }
  const rootRaw = await gitOk(cwd, ["rev-parse", "--show-toplevel"], signal);
  // Remove exactly git's line terminator (a directory name may end in
  // whitespace) and require the root to survive a UTF-8 round trip: a lossy
  // decode would point every later git call at a different directory.
  const rootBytes =
    rootRaw[rootRaw.length - 1] === 0x0a ? rootRaw.subarray(0, -1) : rootRaw;
  const top = rootBytes.toString("utf8");
  if (!Buffer.from(top, "utf8").equals(rootBytes)) {
    throw new Error(
      `snapshot refused: repository root is not valid UTF-8 (hex ${rootBytes.toString("hex")})`,
    );
  }
  const headRun = await git(
    top,
    ["rev-parse", "--verify", "-q", "HEAD^{commit}"],
    signal,
  );
  const head =
    headRun.code === 0 ? headRun.stdout.toString("utf8").trim() : null;
  // Metadata-only discovery first (index and untracked listing read no file
  // content); everything protected or unsupported is decided before any
  // command that compares working-tree content.
  const indexRecords = splitZ(
    await gitOk(top, ["ls-files", "-s", "-z", "--full-name"], signal),
  );
  const trackedRaws = [];
  const gitlinks = new Map();
  for (const record of indexRecords) {
    const tab = record.indexOf(0x09);
    const meta = record.subarray(0, tab).toString("utf8").split(" ");
    const raw = record.subarray(tab + 1);
    trackedRaws.push(raw);
    if (meta[0] === "160000")
      gitlinks.set(raw.toString("hex"), { raw, oid: meta[1] });
  }
  const stagedRaws = splitZ(
    await gitOk(
      top,
      [
        "diff",
        "--cached",
        "--name-only",
        "-z",
        "--no-renames",
        "--ignore-submodules=none",
        "--submodule=short",
      ],
      signal,
    ),
  );
  const untrackedRaws = splitZ(
    await gitOk(
      top,
      ["ls-files", "--others", "--exclude-standard", "-z", "--full-name"],
      signal,
    ),
  );
  const ignoredRaws = await listIgnored(top, includeIgnored, signal);
  const tracked = sortedEntries([...trackedRaws, ...stagedRaws]);
  const untrackedNames = sortedEntries(untrackedRaws);
  const ignoredNames = sortedEntries(ignoredRaws);
  const protectedByPath = new Map();
  const markProtected = (items, where) => {
    for (const item of items) {
      if (!isProtected(item.match)) continue;
      const key = item.raw.toString("hex");
      const record = protectedByPath.get(key) ?? { item, where: [] };
      record.where.push(where);
      protectedByPath.set(key, record);
    }
  };
  markProtected(tracked, "tracked");
  markProtected(untrackedNames, "untracked");
  markProtected(ignoredNames, "ignored");
  const protectedPaths = [...protectedByPath.values()].map(
    ({ item, where }) => ({
      path: item.label,
      path_hex: item.hex,
      where,
      status: "unhashed/protected",
    }),
  );
  const submodules = [...gitlinks.values()]
    .sort((a, b) => Buffer.compare(a.raw, b.raw))
    .map(({ raw, oid }) => {
      const item = entry(raw);
      return {
        path: item.label,
        path_hex: item.hex,
        index_oid: oid,
        status: "unhashed/submodule",
      };
    });
  // Never hashed, diffed, or returned: protected tracked paths and submodules.
  const excluded = sortedEntries([
    ...tracked
      .filter((item) => protectedByPath.has(item.raw.toString("hex")))
      .map((item) => item.raw),
    ...[...gitlinks.values()].map((link) => link.raw),
  ]);
  const hashable = (items) =>
    items.filter((item) => !protectedByPath.has(item.raw.toString("hex")));
  await assertNotPartialClone(top, signal);
  const checked = [
    ...hashable(tracked).filter(
      (item) => !gitlinks.has(item.raw.toString("hex")),
    ),
    ...hashable(untrackedNames),
    ...hashable(ignoredNames),
  ];
  await assertNoExecutableFilters(top, checked, signal);
  const stagedDigest = await diffDigest(top, true, excluded, signal);
  const unstagedDigest = await diffDigest(top, false, excluded, signal);
  const changed = sortedEntries([
    ...(await diffNames(top, true, excluded, signal)),
    ...(await diffNames(top, false, excluded, signal)),
  ]);
  const untracked = [];
  for (const item of hashable(untrackedNames)) {
    untracked.push(await describeUntracked(top, item, signal));
  }
  const ignored = [];
  for (const item of hashable(ignoredNames)) {
    ignored.push(await describeUntracked(top, item, signal));
  }
  const unhashed = [...untracked, ...ignored].filter(
    (item) => item.sha256 === null,
  );
  const nonUtf8 = [
    ...new Set(
      [...changed, ...tracked, ...untrackedNames, ...ignoredNames]
        .map((item) => item.hex)
        .filter((hex) => hex !== null),
    ),
  ].sort();
  const body = {
    schema: SNAPSHOT_SCHEMA,
    scope: "repo",
    head,
    staged_diff_sha256: stagedDigest,
    unstaged_diff_sha256: unstagedDigest,
    changed_paths: changed.map((item) => item.label),
    untracked,
    ignored,
    protected: protectedPaths,
    submodules,
    nonutf8_paths_hex: nonUtf8,
    // True when the caller named ignored paths; only those are covered.
    ignored_included: includeIgnored.length > 0,
    complete:
      protectedPaths.length === 0 &&
      submodules.length === 0 &&
      unhashed.length === 0,
  };
  const fingerprint = createHash("sha256")
    .update(canonicalJson(body))
    .digest("hex");
  return { ...body, fingerprint };
}

// Metadata-only protected-path scan for the Codex secret guard. It lists
// protected paths by name and never reads, hashes, or diffs file content.
// Tracked and untracked-not-ignored protected paths are blocking; ignored ones
// are reported as warnings because the caller accepts that residual risk.
export async function checkProtected(cwd, signal) {
  // Same pre-spawn refusal as computeSnapshot: a lossily decoded working
  // directory can name a different, UTF-8 lookalike repository.
  if (cwd.includes("\uFFFD")) {
    throw new Error(
      "snapshot refused: working directory path is not valid UTF-8 (contains U+FFFD)",
    );
  }
  const rootRaw = await gitOk(cwd, ["rev-parse", "--show-toplevel"], signal);
  const rootBytes =
    rootRaw[rootRaw.length - 1] === 0x0a ? rootRaw.subarray(0, -1) : rootRaw;
  const top = rootBytes.toString("utf8");
  if (!Buffer.from(top, "utf8").equals(rootBytes)) {
    throw new Error("snapshot refused: repository root is not valid UTF-8");
  }
  const indexRecords = splitZ(
    await gitOk(top, ["ls-files", "-s", "-z", "--full-name"], signal),
  );
  const trackedRaws = [];
  const opaque = [];
  for (const record of indexRecords) {
    const tab = record.indexOf(0x09);
    const mode = record.subarray(0, tab).toString("utf8").split(" ")[0];
    const raw = record.subarray(tab + 1);
    trackedRaws.push(raw);
    // A submodule's own files are not enumerated by the parent repository, so
    // protected paths inside it cannot be ruled out by name.
    if (mode === "160000") {
      const item = entry(raw);
      opaque.push({ path: item.label, path_hex: item.hex, kind: "submodule" });
    }
  }
  const untrackedRaws = splitZ(
    await gitOk(
      top,
      ["ls-files", "--others", "--exclude-standard", "-z", "--full-name"],
      signal,
    ),
  );
  const untrackedNames = [];
  for (const raw of untrackedRaws) {
    // Git lists an untracked embedded repository as one `dir/` entry without
    // its descendants; it is an opaque boundary, and its name still has to be
    // matched without the slash.
    if (raw[raw.length - 1] === 0x2f) {
      const item = entry(raw.subarray(0, -1));
      opaque.push({
        path: item.label,
        path_hex: item.hex,
        kind: "embedded-repository",
      });
      untrackedNames.push(raw.subarray(0, -1));
    } else {
      untrackedNames.push(raw);
    }
  }
  const lists = {
    tracked: [
      ...trackedRaws,
      ...splitZ(
        await gitOk(
          top,
          [
            "diff",
            "--cached",
            "--name-only",
            "-z",
            "--no-renames",
            "--ignore-submodules=none",
          ],
          signal,
        ),
      ),
    ],
    untracked: untrackedNames,
    ignored: splitZ(
      await gitOk(
        top,
        [
          "ls-files",
          "--others",
          "--ignored",
          "--exclude-standard",
          "-z",
          "--full-name",
        ],
        signal,
      ),
    ),
  };
  const found = new Map();
  for (const [where, raws] of Object.entries(lists)) {
    for (const item of sortedEntries(raws)) {
      if (!isProtected(item.match)) continue;
      const key = item.raw.toString("hex");
      const record = found.get(key) ?? {
        path: item.label,
        path_hex: item.hex,
        where: [],
      };
      record.where.push(where);
      found.set(key, record);
    }
  }
  const protectedPaths = [...found.values()];
  const blocking = protectedPaths.filter(
    (item) =>
      item.where.includes("tracked") || item.where.includes("untracked"),
  );
  return {
    schema: "b-protected-check/1",
    protected: protectedPaths,
    blocking: blocking.map((item) => item.path),
    // Submodules and embedded repositories hide their descendants from a
    // name-based scan, so they fail the guard closed.
    opaque,
    ok: blocking.length === 0 && opaque.length === 0,
  };
}

async function main(argv) {
  const includeIgnored = [];
  let mode = "snapshot";
  let fingerprintOnly = false;
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (arg === "--include-ignored") {
      const value = argv[++index];
      if (value === undefined)
        throw new Error("--include-ignored needs a path");
      includeIgnored.push(value);
    } else if (arg === "--check-protected") mode = "check";
    else if (arg === "--fingerprint") fingerprintOnly = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (mode === "check") {
    const result = await checkProtected(process.cwd());
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return result.ok ? 0 : 3;
  }
  const snapshot = await computeSnapshot(
    process.cwd(),
    undefined,
    includeIgnored,
  );
  process.stdout.write(
    fingerprintOnly
      ? `${snapshot.fingerprint}\n`
      : `${JSON.stringify(snapshot, null, 2)}\n`,
  );
  return snapshot.complete ? 0 : 3;
}

// Resolve symlinked launchers so a link to this file still runs main().
function isEntryPoint() {
  if (!process.argv[1]) return false;
  try {
    return (
      import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href
    );
  } catch {
    return false;
  }
}

if (isEntryPoint()) {
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code;
    },
    (error) => {
      process.stderr.write(
        `${error instanceof Error ? error.message : String(error)}\n`,
      );
      process.exitCode = 2;
    },
  );
}
