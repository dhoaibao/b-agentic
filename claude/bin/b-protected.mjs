// b-agentic protected-path rules: the likely-secret patterns shared by the path
// guard, the spec-context hook, the snapshot CLI, and b-state. This is a leaf
// module (no imports) so a hook that only needs the rules does not load the
// snapshot CLI. `b-candidate-snapshot.mjs` re-exports everything here.
//
// PROTECTED_RULES must stay aligned with the permission rules the generator
// renders (registry_sync.py checks it); edit them together.

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
  // Case-insensitive: `.ENV` opens `.env` on a case-insensitive filesystem, so a case variant is the same file.
  return new RegExp(`^${body}$`, "si");
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
