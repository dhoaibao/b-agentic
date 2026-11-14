// Git helpers of the b-state CLI: command wrappers, the baseline and the worktree tree.
// Imports only the core module.
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import {
  closeSync,
  constants,
  copyFileSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readlinkSync,
  readSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { isProtected } from "./b-candidate-snapshot.mjs";
import {
  CONTROL,
  MAX_DIRTY,
  MAX_DIRTY_BYTES,
  MAX_TEXT,
  refuse,
  Refused,
  sha256,
} from "./b-state-core.mjs";

export function git(cwd, args, env = process.env) {
  return new Promise((done, fail) => {
    execFile(
      "git",
      args,
      { cwd, env, encoding: "utf8", maxBuffer: 1 << 24 },
      (error, stdout) => (error ? fail(error) : done(stdout)),
    );
  });
}

// The same, with stdout as bytes: for path lists handed back to git unchanged.
export function gitBytes(cwd, args, env = process.env) {
  return new Promise((done, fail) => {
    execFile(
      "git",
      args,
      { cwd, env, encoding: "buffer", maxBuffer: 1 << 26 },
      (error, stdout) => (error ? fail(error) : done(stdout)),
    );
  });
}

// The same, with bytes written to stdin: for paths git is to take literally.
function gitInput(cwd, args, input, env = process.env) {
  return new Promise((done, fail) => {
    const child = execFile(
      "git",
      args,
      { cwd, env, encoding: "utf8", maxBuffer: 1 << 24 },
      (error, stdout) => (error ? fail(error) : done(stdout)),
    );
    // git may exit before reading everything; the exit status reports that.
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
}

export async function gitOr(cwd, args, fallback = "", env = process.env) {
  try {
    return (await git(cwd, args, env)).trim();
  } catch {
    return fallback;
  }
}

export async function repoRoot(cwd) {
  try {
    return realpathSync(
      (await git(cwd, ["rev-parse", "--show-toplevel"])).trim(),
    );
  } catch {
    throw refuse("not inside a git worktree");
  }
}

export async function worktreeBaseline(root) {
  const status = await gitOr(root, [
    "status",
    "--porcelain=v1",
    "-z",
    "--untracked-files=all",
  ]);
  return {
    head: await gitOr(root, ["rev-parse", "HEAD"]),
    branch: await gitOr(root, ["rev-parse", "--abbrev-ref", "HEAD"]),
    status_digest: sha256(status),
    dirty: status.length > 0,
  };
}

// The identity of one path's content, without keeping the content: the same
// rule as path_digest in b_run.py, which compares against it.
//
// The read never leaves the tree: a link anywhere above the path makes it
// unidentifiable (""), and the path itself is opened without following a link.
// The digest carries the executable bit, which git tracks beside the content.
function pathDigest(root, rel) {
  const parts = rel.split("/");
  if (rel.startsWith("/") || parts.includes("..") || parts.includes(""))
    return "";
  let dir = root;
  for (const part of parts.slice(0, -1)) {
    dir = join(dir, part);
    let above;
    try {
      above = lstatSync(dir);
    } catch {
      return "absent";
    }
    if (above.isSymbolicLink()) return "";
    if (!above.isDirectory()) return "absent";
  }
  const full = join(root, rel);
  let stat;
  try {
    stat = lstatSync(full);
  } catch {
    return "absent";
  }
  if (stat.isSymbolicLink()) return `link:${sha256(readlinkSync(full))}`;
  if (!stat.isFile()) return "";
  let fd;
  try {
    fd = openSync(
      full,
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
  } catch {
    return "";
  }
  try {
    const opened = fstatSync(fd);
    if (!opened.isFile() || opened.size > MAX_DIRTY_BYTES) return "";
    const hash = createHash("sha256");
    const buffer = Buffer.alloc(1 << 20);
    for (;;) {
      const n = readSync(fd, buffer, 0, buffer.length, null);
      if (n === 0) break;
      hash.update(buffer.subarray(0, n));
    }
    return `${opened.mode & 0o100 ? "x:" : ""}${hash.digest("hex")}`;
  } finally {
    closeSync(fd);
  }
}

// The changes already in the tree when a run starts: they are the user's, not
// the run's, for as long as their content stays the same. A path whose content
// cannot be identified safely (a likely-secret file, a directory, a very large
// file, an odd name) is left out, so it counts as a change of the run and the
// scope check stops on it.
export async function dirtyBaseline(root) {
  // Untrimmed: the first status code may begin with a space.
  const status = await git(root, [
    "status",
    "--porcelain=v1",
    "-z",
    "--untracked-files=all",
  ]).catch(() => {
    throw refuse("git status failed; the tree's changes cannot be recorded");
  });
  const tokens = status.split("\0");
  const paths = [];
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (token.length < 4) continue;
    paths.push(token.slice(3));
    if ("RC".includes(token[0])) paths.push(tokens[++i] ?? "");
  }
  const unique = [...new Set(paths)].filter(Boolean);
  if (unique.length > MAX_DIRTY) {
    throw refuse(
      `the working tree has ${unique.length} changed paths, too many to tell apart from a run's own; commit or stash them first`,
    );
  }
  const dirty = {};
  for (const rel of unique) {
    if (rel.length > MAX_TEXT || CONTROL.test(rel) || isProtected(rel))
      continue;
    const digest = pathDigest(root, rel);
    if (digest) dirty[rel] = digest;
  }
  return dirty;
}

// The tree object of the whole working tree (tracked and untracked, not ignored),
// built in a throwaway index seeded from the real one so tracked files that an
// ignore rule covers, and sparse entries, are kept; the real index is never
// touched. A finished run must have committed exactly this tree.
//
// No likely-secret file's content may reach the object store through this
// tree, including one that appears while it is being built, so nothing is
// added by walking the working tree:
//   - the changed paths are listed by name, and a protected name refuses;
//   - exactly those index entries are updated (`update-index`, never `add`):
//     a listed path that has meanwhile become a directory is not descended
//     into, a symbolic link is stored as a link, and a path below a link is
//     refused by git;
//   - every entry that then differs from HEAD is checked by name once more,
//     which also covers a protected path that was already staged.
// `between` runs after each listing and before its entries are updated; the
// probes use it to change the tree at exactly that point.
export async function worktreeTree(
  root,
  includeIgnored = [],
  { between = async () => {}, hardened = false } = {},
) {
  const dir = mkdtempSync(join(tmpdir(), "b-state-"));
  const env = { ...process.env, GIT_INDEX_FILE: join(dir, "index") };
  // A worker's tree is built from files the worker may have written beside the
  // configuration it can reach: no file system monitor and no repository hook
  // (post-index-change runs on every index write) may run before the scope check.
  if (hardened) {
    mkdirSync(join(dir, "hooks"));
    Object.assign(env, {
      GIT_CONFIG_COUNT: "2",
      GIT_CONFIG_KEY_0: "core.fsmonitor",
      GIT_CONFIG_VALUE_0: "false",
      GIT_CONFIG_KEY_1: "core.hooksPath",
      GIT_CONFIG_VALUE_1: join(dir, "hooks"),
    });
  }
  const namesOf = (bytes) => bytes.toString("utf8").split("\0").filter(Boolean);
  const refuseProtected = (names) => {
    if (names.some((name) => isProtected(name))) {
      throw refuse(
        "a protected path is changed in the working tree; no tree is built",
      );
    }
  };
  try {
    const real = await gitOr(root, ["rev-parse", "--git-path", "index"]);
    if (real) {
      try {
        copyFileSync(resolve(root, real), join(dir, "index"));
      } catch {
        // No index yet: an empty one is the correct seed.
      }
    }
    // The list goes back to git as the bytes git printed, so a name that is
    // not valid UTF-8 survives; `update-index` takes paths, never patterns.
    const list = (selection) =>
      gitBytes(
        root,
        ["--literal-pathspecs", "ls-files", "-z", ...selection],
        env,
      );
    const entries = (bytes) => {
      const out = [];
      let start = 0;
      for (let i = 0; i < bytes.length; i++) {
        if (bytes[i] !== 0) continue;
        if (i > start) out.push(bytes.subarray(start, i));
        start = i + 1;
      }
      return out;
    };
    // Updates exactly the listed entries: the tracked ones that changed first,
    // then the untracked ones. A step may turn a file into a directory or a
    // directory into a file; the tracked entry is then no longer a file, and
    // git removes it when it comes first, so the new path no longer conflicts
    // with it (`--replace` covers what the order does not). Neither reads
    // anything from the tree beyond the listed paths.
    const update = async (tracked, untracked) => {
      refuseProtected([...namesOf(tracked), ...namesOf(untracked)]);
      await between();
      const first = entries(tracked);
      const seen = new Set(first.map((entry) => entry.toString("latin1")));
      const ordered = [
        ...first,
        ...entries(untracked).filter(
          (entry) => !seen.has(entry.toString("latin1")),
        ),
      ];
      if (ordered.length === 0) return;
      await gitInput(
        root,
        ["update-index", "--add", "--remove", "--replace", "-z", "--stdin"],
        Buffer.concat(ordered.flatMap((entry) => [entry, Buffer.alloc(1)])),
        env,
      );
    };
    await update(
      await list(["--modified", "--deleted"]),
      await list(["--others", "--exclude-standard"]),
    );
    // Artifacts the candidate names with --include-ignored are part of what was
    // reviewed and QA'd, so they belong to the approved tree too.
    if (includeIgnored.length > 0) {
      await update(
        Buffer.alloc(0),
        await list([
          "--others",
          "--ignored",
          "--exclude-standard",
          "--",
          ...includeIgnored,
        ]),
      );
      // A named artifact that matches nothing fails, as it always did: a typo
      // must not leave it out of the tree silently.
      await git(
        root,
        [
          "--literal-pathspecs",
          "ls-files",
          "--error-unmatch",
          "--",
          ...includeIgnored,
        ],
        env,
      );
    }
    const head = await gitOr(root, ["rev-parse", "--verify", "-q", "HEAD"]);
    refuseProtected(
      namesOf(
        await gitBytes(
          root,
          head
            ? [
                "diff-index",
                "--cached",
                "--name-only",
                "--no-renames",
                "-z",
                head,
              ]
            : ["ls-files", "-z"],
          env,
        ),
      ),
    );
    return (await git(root, ["write-tree"], env)).trim();
  } catch (error) {
    if (error instanceof Refused) throw error;
    throw refuse("cannot compute the working-tree identity");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

export const isAncestor = async (root, ancestor, descendant) => {
  try {
    await git(root, ["merge-base", "--is-ancestor", ancestor, descendant]);
    return true;
  } catch {
    return false;
  }
};
