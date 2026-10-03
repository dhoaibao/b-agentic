// b-agentic candidate snapshot: a read-only tool that computes the kernel's
// frozen-review-candidate identity so the model does not hash it by hand.
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
// SNAPSHOT_DIFF_FLAGS and PROTECTED_RULES are mirrored by a consistency check
// in tooling/generate/registry_sync.py (canonical fallback command and the
// generated permission policy's path rules). Edit them together.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { lstat, readlink } from "node:fs/promises";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

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
export const PROTECTED_RULES: Array<[string, "deny" | "allow"]> = [
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

type Entry = {
  raw: Buffer;
  // UTF-8 display label; lossy when the name is not valid UTF-8 (see `hex`).
  label: string;
  // Lowercase hex of the raw name when it is not valid UTF-8, else null.
  hex: string | null;
  // One char per byte, used only for protected-path matching.
  match: string;
};
type Untracked = {
  path: string;
  path_hex: string | null;
  type: "file" | "symlink" | "directory" | "other";
  mode: string | null;
  size: number | null;
  sha256: string | null;
  reason?: string;
};
type Protected = {
  path: string;
  path_hex: string | null;
  where: string[];
  status: "unhashed/protected";
};
type Submodule = {
  path: string;
  path_hex: string | null;
  index_oid: string;
  status: "unhashed/submodule";
};

function globToRegExp(pattern: string): RegExp {
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

const COMPILED_RULES = PROTECTED_RULES.map(
  ([pattern, action]) => [globToRegExp(pattern), action] as const,
);

export function isProtected(path: string): boolean {
  let verdict: "deny" | "allow" = "allow";
  for (const [matcher, action] of COMPILED_RULES) {
    if (matcher.test(path)) verdict = action;
  }
  return verdict === "deny";
}

function entry(raw: Buffer): Entry {
  const text = raw.toString("utf8");
  const valid = Buffer.from(text, "utf8").equals(raw);
  return {
    raw,
    label: text,
    hex: valid ? null : raw.toString("hex"),
    match: raw.toString("latin1"),
  };
}

function sortedEntries(raws: Buffer[]): Entry[] {
  const unique = new Map(raws.map((raw) => [raw.toString("hex"), raw]));
  return [...unique.values()].sort(Buffer.compare).map(entry);
}

function splitZ(output: Buffer): Buffer[] {
  const items: Buffer[] = [];
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

type GitResult = { code: number; stdout: Buffer; stderr: string };

function git(
  cwd: string,
  args: string[],
  signal: AbortSignal | undefined,
  options: { sink?: ReturnType<typeof createHash>; input?: Buffer } = {},
): Promise<GitResult> {
  return new Promise((resolve, reject) => {
    // Pin everything that could run a program or change the diff format:
    // fsmonitor hooks, submodule rendering, and external diff/textconv drivers
    // (also refused by flag). Repository clean/process filters are checked
    // separately because no `-c` override can neutralize them safely.
    const env: Record<string, string> = {};
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
    const chunks: Buffer[] = [];
    let stderr = "";
    child.stdout?.on("data", (chunk: Buffer) => {
      if (options.sink) options.sink.update(chunk);
      else chunks.push(chunk);
    });
    child.stderr?.on("data", (chunk: Buffer) => {
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

async function gitOk(
  cwd: string,
  args: string[],
  signal: AbortSignal | undefined,
  input?: Buffer,
): Promise<Buffer> {
  const result = await git(cwd, args, signal, { input });
  if (result.code !== 0) {
    throw new Error(
      `git ${args[0]} failed: ${result.stderr.trim() || result.code}`,
    );
  }
  return result.stdout;
}

function excludeSpecs(excluded: Entry[]): string[] {
  if (excluded.length > MAX_EXCLUDED_PATHS) {
    throw new Error(
      `snapshot refused: ${excluded.length} protected or submodule paths exceed the ${MAX_EXCLUDED_PATHS}-path limit; use the manual procedure`,
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

function diffArgs(
  cached: boolean,
  mode: string[],
  excluded: Entry[],
): string[] {
  return [
    "diff",
    ...mode,
    ...(cached ? ["--cached"] : []),
    "--",
    ".",
    ...excludeSpecs(excluded),
  ];
}

async function diffNames(
  cwd: string,
  cached: boolean,
  excluded: Entry[],
  signal: AbortSignal | undefined,
): Promise<Buffer[]> {
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

async function diffDigest(
  cwd: string,
  cached: boolean,
  excluded: Entry[],
  signal: AbortSignal | undefined,
): Promise<string> {
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
async function assertNotPartialClone(
  cwd: string,
  signal: AbortSignal | undefined,
): Promise<void> {
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
async function assertNoExecutableFilters(
  cwd: string,
  paths: Entry[],
  signal: AbortSignal | undefined,
): Promise<void> {
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
  const drivers = new Set<string>();
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
  const fields: Buffer[] = [];
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
        `snapshot refused: repository filter '${value}' has a clean/process command that git diff would run; the manual procedure would run it too, so block the review`,
      );
    }
  }
}

function fileDigest(
  path: Buffer,
  signal: AbortSignal | undefined,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    const stream = createReadStream(path, { signal });
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("error", reject);
    stream.on("end", () => resolve(hash.digest("hex")));
  });
}

async function describeUntracked(
  top: string,
  item: Entry,
  signal: AbortSignal | undefined,
): Promise<Untracked> {
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

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
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
async function listIgnored(
  top: string,
  specs: string[],
  signal: AbortSignal | undefined,
): Promise<Buffer[]> {
  if (specs.length > MAX_IGNORED_SPECS) {
    throw new Error(
      `snapshot refused: ${specs.length} include_ignored paths exceed the ${MAX_IGNORED_SPECS}-path limit`,
    );
  }
  const raws: Buffer[] = [];
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

export async function computeSnapshot(
  cwd: string,
  signal?: AbortSignal,
  includeIgnored: string[] = [],
) {
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
  const trackedRaws: Buffer[] = [];
  const gitlinks = new Map<string, { raw: Buffer; oid: string }>();
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

  const protectedByPath = new Map<string, { item: Entry; where: string[] }>();
  const markProtected = (items: Entry[], where: string) => {
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
  const protectedPaths: Protected[] = [...protectedByPath.values()].map(
    ({ item, where }) => ({
      path: item.label,
      path_hex: item.hex,
      where,
      status: "unhashed/protected" as const,
    }),
  );
  const submodules: Submodule[] = [...gitlinks.values()]
    .sort((a, b) => Buffer.compare(a.raw, b.raw))
    .map(({ raw, oid }) => {
      const item = entry(raw);
      return {
        path: item.label,
        path_hex: item.hex,
        index_oid: oid,
        status: "unhashed/submodule" as const,
      };
    });

  // Never hashed, diffed, or returned: protected tracked paths and submodules.
  const excluded = sortedEntries([
    ...tracked
      .filter((item) => protectedByPath.has(item.raw.toString("hex")))
      .map((item) => item.raw),
    ...[...gitlinks.values()].map((link) => link.raw),
  ]);
  const hashable = (items: Entry[]) =>
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

  const untracked: Untracked[] = [];
  for (const item of hashable(untrackedNames)) {
    untracked.push(await describeUntracked(top, item, signal));
  }

  const ignored: Untracked[] = [];
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
        .filter((hex): hex is string => hex !== null),
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

type Snapshot = Awaited<ReturnType<typeof computeSnapshot>>;

function summarize(snapshot: Snapshot): string {
  const lines = [
    `fingerprint: ${snapshot.fingerprint}`,
    `schema: ${snapshot.schema}; scope: ${snapshot.scope}; complete: ${snapshot.complete}; ignored_included: ${snapshot.ignored_included}${snapshot.ignored_included ? " (only the named ignored paths)" : " (git-ignored files are NOT covered)"}`,
    `head: ${snapshot.head ?? "(no commits)"}`,
    `staged_diff_sha256: ${snapshot.staged_diff_sha256}`,
    `unstaged_diff_sha256: ${snapshot.unstaged_diff_sha256}`,
    `changed tracked paths (${snapshot.changed_paths.length}): ${snapshot.changed_paths.join(", ") || "none"}`,
    `untracked (${snapshot.untracked.length}):`,
    ...snapshot.untracked
      .slice(0, TEXT_UNTRACKED_LIMIT)
      .map(
        (item) =>
          `  ${item.type} ${item.path} ${item.sha256 ?? `UNHASHED (${item.reason})`}`,
      ),
  ];
  if (snapshot.untracked.length > TEXT_UNTRACKED_LIMIT) {
    lines.push(
      `  ... ${snapshot.untracked.length - TEXT_UNTRACKED_LIMIT} more; all entries are in structuredContent`,
    );
  }
  if (snapshot.ignored_included) {
    lines.push(
      `ignored (${snapshot.ignored.length}):`,
      ...snapshot.ignored
        .slice(0, TEXT_UNTRACKED_LIMIT)
        .map(
          (item) =>
            `  ${item.type} ${item.path} ${item.sha256 ?? `UNHASHED (${item.reason})`}`,
        ),
    );
    if (snapshot.ignored.length > TEXT_UNTRACKED_LIMIT) {
      lines.push(
        `  ... ${snapshot.ignored.length - TEXT_UNTRACKED_LIMIT} more; all entries are in structuredContent`,
      );
    }
  }
  if (snapshot.protected.length > 0) {
    lines.push(
      `protected paths (never hashed or diffed, excluded from the diff digests): ${snapshot.protected
        .map((item) => `${item.path} [${item.where.join("+")}]`)
        .join(", ")}`,
    );
  }
  if (snapshot.submodules.length > 0) {
    lines.push(
      `submodules (not inspected, excluded from the diff digests): ${snapshot.submodules
        .map((item) => `${item.path}@${item.index_oid}`)
        .join(", ")}`,
    );
  }
  if (snapshot.nonutf8_paths_hex.length > 0) {
    lines.push(
      `non-UTF-8 paths (raw names as hex; labels above are lossy): ${snapshot.nonutf8_paths_hex.join(", ")}`,
    );
  }
  if (!snapshot.complete) {
    lines.push(
      "INCOMPLETE: the fingerprint does not cover protected, submodule, or unhashable content; the kernel requires blocking rather than claiming an unchanged candidate.",
    );
  }
  lines.push(
    "Compare `fingerprint` at each checkpoint; never compare it with a hand-computed identity.",
  );
  return lines.join("\n");
}

const PATH_PROPERTIES = { path: Type.String() };
const FILE_ENTRY = Type.Object({
  ...PATH_PROPERTIES,
  path_hex: Type.Union([Type.String(), Type.Null()]),
  type: Type.String(),
  mode: Type.Union([Type.String(), Type.Null()]),
  size: Type.Union([Type.Number(), Type.Null()]),
  sha256: Type.Union([Type.String(), Type.Null()]),
  reason: Type.Optional(Type.String()),
});

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "b_candidate_snapshot",
    label: "Candidate snapshot",
    description:
      "Compute the frozen review-candidate identity for the current git repository: HEAD, SHA-256 of the staged and unstaged binary diffs, sorted untracked paths with type and content digest, and one `fingerprint`. Read-only. Always covers the whole repository. Protected (likely-secret) paths and submodules are listed but never hashed, diffed, or returned, and make the snapshot incomplete. Git-ignored files are NOT covered unless named in `include_ignored` (repository-relative ignored files or directories, hashed like untracked files); a relevant ignored or derived artifact that is not named leaves the fingerprint unable to prove an unchanged candidate. Refuses, with an error, when a repository clean/process filter would run.",
    promptSnippet:
      "Compute the review-candidate fingerprint (read-only git identity) for freeze/recheck",
    promptGuidelines: [
      "Use b_candidate_snapshot to freeze and recheck a review candidate instead of hashing diffs by hand, and compare only its `fingerprint` values. If complete is false, block rather than claim an unchanged candidate. Name every relevant git-ignored or derived artifact in include_ignored at every checkpoint, or block the fingerprint-based review handoff and report the uncovered paths.",
    ],
    parameters: Type.Object({
      include_ignored: Type.Optional(
        Type.Array(Type.String(), {
          maxItems: MAX_IGNORED_SPECS,
          description:
            "Repository-relative git-ignored files or directories (for example a relevant build output) to hash into the candidate identity. Each must match at least one ignored file.",
        }),
      ),
    }),
    outputSchema: Type.Object({
      schema: Type.String(),
      scope: Type.String(),
      head: Type.Union([Type.String(), Type.Null()]),
      staged_diff_sha256: Type.String(),
      unstaged_diff_sha256: Type.String(),
      changed_paths: Type.Array(Type.String()),
      untracked: Type.Array(FILE_ENTRY),
      ignored: Type.Array(FILE_ENTRY),
      protected: Type.Array(
        Type.Object({
          ...PATH_PROPERTIES,
          path_hex: Type.Union([Type.String(), Type.Null()]),
          where: Type.Array(Type.String()),
          status: Type.String(),
        }),
      ),
      submodules: Type.Array(
        Type.Object({
          ...PATH_PROPERTIES,
          path_hex: Type.Union([Type.String(), Type.Null()]),
          index_oid: Type.String(),
          status: Type.String(),
        }),
      ),
      nonutf8_paths_hex: Type.Array(Type.String()),
      ignored_included: Type.Boolean(),
      complete: Type.Boolean(),
      fingerprint: Type.String(),
    }),
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false,
    },
    executionMode: "sequential",
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const snapshot = await computeSnapshot(
        ctx.cwd,
        signal,
        params.include_ignored ?? [],
      );
      return {
        content: [{ type: "text", text: summarize(snapshot) }],
        structuredContent: snapshot,
        details: {
          fingerprint: snapshot.fingerprint,
          complete: snapshot.complete,
        },
      };
    },
  });
}
