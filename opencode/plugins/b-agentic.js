// b-agentic plugin for OpenCode (ADR-019). Installed to ~/.config/opencode/plugins/.
//
// - Path guard: `execute.before` throws for a file tool on a likely-secret path or a
//   .b-agentic write, and for a shell command the Codex guard refuses or asks about (a
//   self-approval or a direct companion call), which blocks the tool (also in subagent sessions; ADR-019 probe S1, S3).
//   The guard core fails closed: a missing hook module or any error blocks the call.
// - Verify gate: after a run settles (`session.execution.succeeded`) with an unchecked edit,
//   one follow-up turn carries the reminder (probe S5).
// - Context: spec and run context are added to the system prompt of a session's first model
//   call and after compaction. Both advisory parts fail open, as on Claude Code.
//
// If this file fails to load OpenCode starts without the guard; the generated native
// `permissions` rules for secret paths stay as the second layer.
import { Plugin } from "@opencode/plugin";
import { createGuard } from "../b-agentic/guard.mjs";

const hooksDir = new URL("../b-agentic/hooks/", import.meta.url);

export default Plugin.define({
  id: "b-agentic",
  async setup(ctx) {
    const guard = await createGuard({ hooksDir });
    const cwd = () => ctx.location?.directory ?? process.cwd();

    await ctx.tool.hook("execute.before", async (event) => {
      const verdict = await guard.toolBefore(event, cwd());
      if (verdict?.block) throw new Error(verdict.reason);
    });

    try {
      await ctx.session.hook("context", (event) => {
        const sessionID = event.sessionID;
        if (!sessionID) return;
        if (guard.firstCall(sessionID)) guard.queueContext(sessionID, cwd());
        const text = guard.takeContext(sessionID);
        if (text) event.system.push({ type: "text", text });
      });
    } catch {
      // Context injection is advisory.
    }

    void (async () => {
      try {
        for await (const event of ctx.event.subscribe()) {
          const sessionID = event.data?.sessionID;
          if (!sessionID) continue;
          if (event.type === "session.execution.started")
            guard.executionStarted(sessionID);
          else if (event.type === "session.execution.succeeded") {
            const text = guard.reminder(sessionID);
            if (text) await ctx.session.prompt({ sessionID, text });
          } else if (
            /^session\.compaction\..*(succeeded|completed|ended)$/.test(
              event.type,
            )
          ) {
            guard.queueContext(sessionID, cwd());
          }
        }
      } catch {
        // The verify reminder and compaction context are advisory.
      }
    })();
  },
});
