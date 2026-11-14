// Run worktrees of the b-state CLI (ADR-016): the helpers and the worktree add, collect and
// remove command. Imports the core, git, store and gates modules.
import { createHash } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmdirSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve, sep } from "node:path";
import { isProtected } from "./b-candidate-snapshot.mjs";
import { invalid, refuse, Refused, SIZE_DRIFT } from "./b-state-core.mjs";
import {
  artifactsOk,
  captureStep,
  currentFingerprint,
  currentHead,
  HEAD_MOVED,
  namedPaths,
  parallelSteps,
  requireSpecUnchanged,
  sizeMatches,
  STATE_WRITTEN,
  stepDelta,
} from "./b-state-gates.mjs";
import { git, gitBytes, gitOr, worktreeTree } from "./b-state-git.mjs";

export const WORKTREE_CAP = 2;

const WORKTREE_PREFIX = "b-agentic-wt-";

const MARKER_ENV = {
  GIT_AUTHOR_NAME: "b-agentic",
  GIT_AUTHOR_EMAIL: "b-agentic@localhost",
  GIT_AUTHOR_DATE: "@0 +0000",
  GIT_COMMITTER_NAME: "b-agentic",
  GIT_COMMITTER_EMAIL: "b-agentic@localhost",
  GIT_COMMITTER_DATE: "@0 +0000",
};

const repoTag = (root) =>
  createHash("sha256").update(root).digest("hex").slice(0, 8);

const worktreePrefix = (root, state) =>
  `${WORKTREE_PREFIX}${repoTag(root)}-${state.run_id}-`;

const markerMessage = (state, id) => `b-agentic worktree ${state.run_id} ${id}`;

const lines = (bytes) => bytes.toString("utf8").split("\0").filter(Boolean);

// The registered worktrees of this run, found by name in git's own list so a
// different TMPDIR cannot hide one.
export async function runWorktrees(root, state, plan) {
  const listed = await gitOr(root, ["worktree", "list", "--porcelain"]);
  const prefix = worktreePrefix(root, state);
  const found = [];
  for (const entry of listed.split("\n\n")) {
    const line = entry.split("\n").find((l) => l.startsWith("worktree "));
    if (!line) continue;
    const path = line.slice("worktree ".length);
    const name = path.split("/").pop();
    if (!name.startsWith(prefix)) continue;
    const id = name.slice(prefix.length);
    if (/^S-[1-9][0-9]*$/.test(id)) found.push({ id, path, name });
  }
  const order = plan.step_ids;
  return found.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
}

// The marker commit a worktree must still be on: the step base tree under a
// fixed identity, so its subject, author, and parent say it was never moved.
async function markerIntact(entry, state, base) {
  const shown = await gitOr(entry.path, [
    "show",
    "-s",
    "--format=%an%n%ae%n%cn%n%ce%n%s%n%P",
    "HEAD",
  ]);
  const expected = [
    "b-agentic",
    "b-agentic@localhost",
    "b-agentic",
    "b-agentic@localhost",
    markerMessage(state, entry.id),
    base.head,
  ]
    .join("\n")
    .trim();
  const branch = await gitOr(entry.path, ["symbolic-ref", "-q", "HEAD"]);
  return shown === expected && branch === "";
}

// The folder every worker worktree goes into: made for this user alone, before
// any checkout, because the temporary folder is shared and a checkout takes
// its modes from the umask. An existing folder is trusted only when it is a
// real directory of this user that no one else can enter.
function ownerFolder(root) {
  const uid = typeof process.getuid === "function" ? process.getuid() : null;
  // A temporary folder inside the repository, or a link into it, would put the
  // worker's checkout in the main tree: resolved before anything is made.
  let base;
  try {
    base = realpathSync(tmpdir());
  } catch {
    throw refuse("the temporary folder cannot be resolved");
  }
  if (base === root || base.startsWith(root + sep))
    throw refuse(
      `the temporary folder ${base} is inside the repository; set TMPDIR to a folder outside it`,
    );
  const folder = join(base, `${WORKTREE_PREFIX}u${uid ?? "x"}`);
  try {
    mkdirSync(folder, { mode: 0o700 });
  } catch (error) {
    if (error.code !== "EEXIST")
      throw refuse(`cannot make the worktree folder ${folder}`);
  }
  const info = lstatSync(folder);
  if (
    !info.isDirectory() ||
    (uid !== null && info.uid !== uid) ||
    (info.mode & 0o077) !== 0
  )
    throw refuse(
      `${folder} is not an owner-only folder of this user; remove or fix it before a worker worktree is made`,
    );
  return folder;
}

// Whether a checkout could run a filter. Which paths a filter applies to comes
// from attributes files (the tree's, the repository's, the user's, the system's)
// that are not all reachable from here, so the test is on the configuration alone,
// as git sees it from each folder given (the repository root, and a worktree, whose
// own configuration may differ): any clean, smudge, or process filter, from the
// local, global, system, or worktree configuration, refuses (git LFS installed for
// the user is one). Building a tree runs clean filters and a checkout runs smudge
// and process filters, so this is asked before a worktree is made and again before
// each tree is built from one. The main session then applies those steps itself.
async function checkoutFilter(...folders) {
  for (const folder of folders) {
    const configured = await gitOr(folder, [
      "config",
      "--get-regexp",
      "^filter\\..+\\.(clean|smudge|process)$",
    ]);
    if (configured) return true;
  }
  return false;
}

const FILTER_REFUSAL =
  "a clean, smudge, or process filter is configured (git LFS, for one) and building or checking out a tree could run it: apply the step in the main session";

// Likely-secret names among the files the repository or global excludes ignore:
// worktreeTree leaves ignored files out, so a worker could write one unseen. Only
// names are read.
async function ignoredSecrets(path) {
  return lines(
    await gitBytes(
      path,
      ["ls-files", "-z", "--others", "--ignored", "--exclude-standard"],
      {
        ...process.env,
        GIT_CONFIG_COUNT: "1",
        GIT_CONFIG_KEY_0: "core.fsmonitor",
        GIT_CONFIG_VALUE_0: "false",
      },
    ),
  ).filter((name) => isProtected(name));
}

const ignoredSecretRefusal = (found) =>
  refuse(
    `${found.length} protected path(s) in the worktree, ignored files included`,
  );

// What changed between two trees, as git prints it: paths, modes, and blobs.
export const rawChange = async (root, from, to) =>
  (
    await gitBytes(root, ["diff-tree", "-r", "-z", "--no-renames", from, to])
  ).toString("latin1");

// What a worker changed in its worktree, in the same form.
export async function workerChange(root, state, entry, base) {
  if (!existsSync(entry.path))
    throw refuse(`the worktree folder is gone: ${entry.path}`);
  if (!(await markerIntact(entry, state, base)))
    throw refuse(`the worktree of ${entry.id} was moved off its base commit`);
  if (await checkoutFilter(root, entry.path)) throw refuse(FILTER_REFUSAL);
  const found = await ignoredSecrets(entry.path);
  if (found.length > 0) throw ignoredSecretRefusal(found);
  const from = (await git(entry.path, ["rev-parse", "HEAD^{tree}"])).trim();
  return rawChange(
    root,
    from,
    await worktreeTree(entry.path, [], { hardened: true }),
  );
}

async function removeWorktree(root, entry) {
  if (existsSync(entry.path)) {
    await git(root, ["worktree", "remove", "--force", entry.path]);
    return;
  }
  // The folder is gone (a reboot cleared the temporary folder): drop only this
  // worktree's registration. Never `git worktree prune`, which takes every one.
  const common = resolve(
    root,
    (await git(root, ["rev-parse", "--git-common-dir"])).trim(),
  );
  const admin = join(common, "worktrees");
  let removed = 0;
  for (const name of existsSync(admin) ? readdirSync(admin) : []) {
    let recorded = "";
    try {
      recorded = readFileSync(join(admin, name, "gitdir"), "utf8").trim();
    } catch {
      continue;
    }
    // With worktree.useRelativePaths git writes the link relative to its own folder.
    if (resolve(join(admin, name), recorded) === join(entry.path, ".git")) {
      rmSync(join(admin, name), { recursive: true, force: true });
      removed += 1;
    }
  }
  if (removed === 0) throw refuse(`no registration found for ${entry.path}`);
}

export async function cmdWorktree(
  root,
  dir,
  state,
  args,
  { capture = captureStep } = {},
) {
  const sub = args._[1];
  const id = args._[2];
  if (!["add", "collect", "remove"].includes(sub ?? ""))
    throw invalid("worktree needs add|collect|remove and a step id");
  if (!/^S-[1-9][0-9]*$/.test(id ?? "")) throw invalid("bad step id");
  requireSpecUnchanged(dir, state);
  const art = await artifactsOk(root, state);
  if (!sizeMatches(state, art)) throw refuse(SIZE_DRIFT);
  const plan = art.artifacts.plan;
  const step = plan.steps.find((s) => s.id === id);
  if (!step) throw invalid("unknown plan step");
  const existing = (await runWorktrees(root, state, plan)).find(
    (w) => w.id === id,
  );
  if (sub === "remove") {
    if (!existing) throw refuse(`no worktree of this run for ${id}`);
    await removeWorktree(root, existing);
    // The owner-only folder goes with its last worktree; rmdir takes only an empty one.
    try {
      if (basename(dirname(existing.path)).startsWith(`${WORKTREE_PREFIX}u`))
        rmdirSync(dirname(existing.path));
    } catch {
      // Other worktrees remain in it.
    }
    return { ok: true, step: id, removed: existing.path };
  }
  if (state.phase !== "implement")
    throw refuse("worktrees are made and collected in phase implement");
  if (!parallelSteps(art).includes(id))
    throw refuse(`${id} is not listed in the plan's parallel_steps`);
  if (state.steps[id])
    throw refuse(`${id} is already recorded; no worktree is made for it`);
  const base = state.step_base;
  if (!base)
    throw refuse(
      `${id} has no step base: apply it in the main session and record --by main`,
    );
  if (sub === "add") {
    const owed = step.depends_on.filter((dep) => !state.steps[dep]);
    if (owed.length > 0)
      throw refuse(
        `record the steps ${id} depends on first: ${owed.join(", ")}`,
      );
    if (existing)
      throw refuse(`${id} already has a worktree: ${existing.path}`);
    const open = await runWorktrees(root, state, plan);
    if (open.length >= WORKTREE_CAP)
      throw refuse(
        `a batch starts at most ${WORKTREE_CAP} workers; finish ${open.map((w) => w.id).join(", ")} first`,
      );
    if (state.rev !== base.rev) throw refuse(STATE_WRITTEN);
    if ((await currentHead(root)) !== base.head) throw refuse(HEAD_MOVED);
    if ((await currentFingerprint(state)) !== base.fingerprint)
      throw refuse(
        "the working tree is not the step base: record or restore the changes first",
      );
    if (existsSync(join(root, ".gitmodules")))
      throw refuse("a repository with submodules gets no worker worktrees");
    if (await checkoutFilter(root)) throw refuse(FILTER_REFUSAL);
    const path = join(ownerFolder(root), `${worktreePrefix(root, state)}${id}`);
    if (existsSync(path)) throw refuse(`${path} already exists`);
    const hooks = mkdtempSync(join(tmpdir(), "b-state-hooks-"));
    try {
      const commit = (
        await git(
          root,
          [
            "-c",
            "commit.gpgsign=false",
            "commit-tree",
            base.tree,
            ...(base.head ? ["-p", base.head] : []),
            "-m",
            markerMessage(state, id),
          ],
          { ...process.env, ...MARKER_ENV },
        )
      ).trim();
      await git(root, [
        "-c",
        `core.hooksPath=${hooks}`,
        "-c",
        "core.fsmonitor=false",
        "worktree",
        "add",
        "--detach",
        path,
        commit,
      ]);
    } catch (error) {
      if (error instanceof Refused) throw error;
      throw refuse(`git could not make the worktree for ${id}`);
    } finally {
      rmSync(hooks, { recursive: true, force: true });
    }
    return { ok: true, step: id, dir: path, base: base.tree };
  }
  // collect
  if (!existing) throw refuse(`no worktree of this run for ${id}`);
  if (!existsSync(existing.path))
    throw refuse(`the worktree folder is gone: ${existing.path}`);
  if (!(await markerIntact(existing, state, base)))
    throw refuse(`the worktree of ${id} was moved off its base commit`);
  if (await checkoutFilter(root, existing.path)) throw refuse(FILTER_REFUSAL);
  const captured = await capture(root, state);
  if (captured.head !== base.head || captured.tree !== base.tree) {
    const names = captured.tree
      ? lines(
          await gitBytes(root, [
            "diff-tree",
            "-r",
            "-z",
            "--name-only",
            "--no-renames",
            base.tree,
            captured.tree,
          ]),
        )
      : [];
    throw refuse(
      `the main working tree changed since the step base${names.length > 0 ? `: ${namedPaths(names)}` : ""}`,
    );
  }
  const found = await ignoredSecrets(existing.path);
  if (found.length > 0) throw ignoredSecretRefusal(found);
  const worktreeBase = (
    await git(existing.path, ["rev-parse", "HEAD^{tree}"])
  ).trim();
  const tree = await worktreeTree(existing.path, [], { hardened: true });
  const delta = await stepDelta(root, state, worktreeBase, tree, id);
  const changed = lines(
    await gitBytes(root, [
      "diff-tree",
      "-r",
      "-z",
      "--name-only",
      "--no-renames",
      worktreeBase,
      tree,
    ]),
  );
  if (delta.protected.length > 0)
    throw refuse(`${delta.protected.length} protected path(s) changed`);
  if (delta.outside_scope.length > 0)
    throw refuse(
      `outside the approved scope: ${namedPaths(delta.outside_scope)}`,
    );
  if (delta.outside_step > 0)
    throw refuse(
      `the worker changed paths outside ${id}'s own paths: ${namedPaths(changed)}`,
    );
  return {
    ok: true,
    step: id,
    dir: existing.path,
    base: worktreeBase,
    tree,
    changed: delta.changed,
    // Spelled out so the user's diff and apply configuration cannot change it: no
    // external driver or textconv program, no color, fixed prefixes, no whitespace rewrite.
    apply: `git diff --binary --full-index --no-renames --no-ext-diff --no-textconv --no-color --src-prefix=a/ --dst-prefix=b/ ${worktreeBase} ${tree} | git apply --whitespace=nowarn`,
  };
}
