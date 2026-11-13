// b-agentic guard for Pi: wires the guard core to Pi's extension events.
// The core (guard.mjs) holds every decision and reuses the Claude hook modules
// installed under ~/.pi/agent/b-agentic/hooks.
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createGuard } from "./guard.mjs";

const agentDir = (): string =>
  process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");

export default async function (pi: ExtensionAPI) {
  const guard = await createGuard({
    hooksDir: new URL("../../b-agentic/hooks/", import.meta.url).href,
  });

  pi.on("tool_call", (event, ctx) => guard.toolCall(event, ctx.cwd));
  pi.on("tool_result", (event) => {
    guard.toolResult(event);
  });
  pi.on("agent_before_settle", (event) => guard.beforeSettle(event));
  pi.on("agent_settled", () => {
    guard.settled();
  });
  pi.on("session_compact", (_event, ctx) => {
    guard.compacted(ctx.cwd);
  });
  pi.on("before_agent_start", () => {
    const message = guard.takeContext();
    return message ? { message } : undefined;
  });

  // Specialist children run in the same process but load only the extensions
  // they list. Registering this guard and the permission system as required
  // child extensions applies both to every pi-subagents child, foreground or
  // background; a load failure then rejects the launch. When either entry is
  // missing or registration fails, children cannot be gated, so every subagent
  // launch is refused; without a subagent tool that refusal never applies.
  const subagents = join(
    agentDir(),
    "npm",
    "node_modules",
    "pi-subagents",
    "bundle",
    "required-child-extensions.js",
  );
  const permission = join(
    agentDir(),
    "npm",
    "node_modules",
    "@gotgenes",
    "pi-permission-system",
    "src",
    "index.ts",
  );
  let registration: { dispose(): void } | undefined;
  const release = () => {
    const held = registration;
    registration = undefined;
    held?.dispose();
  };
  pi.on("session_start", async (event, ctx) => {
    guard.sessionStart(event.reason, ctx.cwd);
    try {
      release();
      for (const [name, path] of [
        ["pi-subagents", subagents],
        ["pi-permission-system", permission],
      ]) {
        if (!existsSync(path)) {
          throw new Error(
            `the pinned ${name} package is not installed: ${path} is missing`,
          );
        }
      }
      const api = await import(pathToFileURL(subagents).href);
      if (typeof api.registerRequiredChildExtensions !== "function") {
        throw new Error(
          `${subagents} does not export registerRequiredChildExtensions; install the pinned pi-subagents package`,
        );
      }
      registration = api.registerRequiredChildExtensions({
        sessionId: ctx.sessionManager.getSessionId(),
        extensions: [
          { id: "b-agentic-guard", path: fileURLToPath(import.meta.url) },
          { id: "pi-permission-system", path: permission },
        ],
        requireForAllRunners: true,
      });
      guard.setChildGateError("");
    } catch (error) {
      guard.setChildGateError(
        error instanceof Error ? error.message : String(error),
      );
    }
  });
  pi.on("session_shutdown", release);
}
