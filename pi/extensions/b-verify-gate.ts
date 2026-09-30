// b-agentic verify gate: an advisory, one-shot reminder at the end of a turn.
//
// When the main session edited files after its last shell command and is about
// to finish, append one short message restating the kernel's verify/review
// rule and request a single extra model turn. It never blocks a tool call and
// never repeats within one run.
//
// Read-only specialist children load this extension too, but their tool lists
// omit `edit` and `write`, so nothing is ever tracked and the gate stays idle.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const CUSTOM_TYPE = "b-verify-gate";

// Prose-only edits carry no behavior to verify.
const PROSE_PATH = /\.(md|mdx|txt|rst)$/i;

const REMINDER = [
  "b-agentic verify gate: files were edited after the last shell command in this run.",
  "Before finishing, run the applicable checks and inspect the changed paths and diff.",
  "If the change touches a kernel review trigger (security, permissions, contracts,",
  "dependencies, installer or config merge, workflow policy), freeze the checked candidate",
  "and request independent b-reviewer review; otherwise state the low-risk exception.",
  "If the work is already verified, or there is nothing to verify, say so in one line and finish.",
].join(" ");

export default function (pi: ExtensionAPI) {
  // An edit exists that no later shell command has followed.
  let dirty = false;
  // The single reminder for the current run has been used.
  let reminded = false;

  // Accounting spans one run until Pi settles, so input queued mid-run (which
  // Pi announces when it is queued, not when it is consumed) cannot discard a
  // pending edit, and the gate's own continuation cannot re-arm it.
  pi.on("agent_settled", () => {
    dirty = false;
    reminded = false;
  });

  pi.on("tool_result", (event) => {
    if (event.toolName === "bash") {
      // Any shell command counts as a check attempt, pass or fail.
      dirty = false;
      return;
    }
    if (event.toolName !== "edit" && event.toolName !== "write") return;
    if (event.isError) return;
    const path = event.input?.path;
    if (typeof path === "string" && PROSE_PATH.test(path)) return;
    dirty = true;
  });

  pi.on("agent_before_settle", (event) => {
    if (reminded || !dirty) return;
    // `event.context.canContinue` describes the transcript before this
    // handler's drafts (it ends on an assistant message), so it is not checked:
    // the appended user-role message below is what makes a continuation valid.
    if (event.outcome !== "completed") return;
    reminded = true;
    return {
      entries: [
        ...event.entries,
        {
          type: "custom_message",
          customType: CUSTOM_TYPE,
          content: REMINDER,
          display: true,
        },
      ],
      continue: true,
    };
  });
}
