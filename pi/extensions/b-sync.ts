// b-agentic /b-sync: pull the installed b-agentic source and re-sync managed
// Pi assets by running the installer's `--sync --force` path inside Pi.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const TIMEOUT_MS = 10 * 60 * 1000;
const TAIL_LINES = 12;

function installerPath(): string {
  const source = process.env.B_AGENTIC_DIR || join(homedir(), ".b-agentic");
  return join(source, "install.sh");
}

function tail(text: string): string {
  return text.trim().split("\n").slice(-TAIL_LINES).join("\n");
}

// eslint-disable-next-line no-control-regex
const ANSI = /\u001b\[[0-9;]*[A-Za-z]/g;

const KILL_GRACE_MS = 5000;

export default function (pi: ExtensionAPI) {
  let running = false;
  let activeGroup: number | undefined;

  function killGroup(signal: NodeJS.Signals) {
    if (activeGroup === undefined) return;
    try {
      process.kill(-activeGroup, signal);
    } catch {
      // The group already exited.
    }
  }

  // Do not leave an installer running after Pi exits.
  pi.on("session_shutdown", () => killGroup("SIGKILL"));

  pi.registerCommand("b-sync", {
    description: "Pull the latest b-agentic source and sync managed Pi assets",
    handler: async (args, ctx) => {
      if (args.trim()) {
        ctx.ui.notify("/b-sync takes no arguments.", "warning");
        return;
      }
      if (running) {
        ctx.ui.notify("/b-sync is already running.", "warning");
        return;
      }
      const installer = installerPath();
      if (!existsSync(installer)) {
        ctx.ui.notify(
          `b-agentic source not found at ${installer}. Run the curl installer first (see README).`,
          "error",
        );
        return;
      }

      running = true;
      try {
        await ctx.waitForIdle();
        ctx.ui.setStatus("b-sync", "b-sync: starting");
        // stdin is closed, output is piped, and the child gets its own session
        // (detached) so it has no controlling terminal and cannot prompt on the
        // one Pi owns; git is told not to ask for credentials.
        const child = spawn("bash", [installer, "--sync", "--force"], {
          env: {
            ...process.env,
            NO_COLOR: "1",
            GIT_TERMINAL_PROMPT: "0",
          },
          stdio: ["ignore", "pipe", "pipe"],
          detached: true,
        });
        activeGroup = child.pid;
        let output = "";
        let pending = "";
        const onData = (chunk: Buffer) => {
          const text = chunk.toString("utf8").replace(ANSI, "");
          output += text;
          pending += text;
          const lines = pending.split("\n");
          pending = lines.pop() ?? "";
          for (const line of lines) {
            if (line.startsWith("==>")) {
              ctx.ui.setStatus("b-sync", `b-sync: ${line.slice(3).trim()}`);
            }
          }
        };
        child.stdout.on("data", onData);
        child.stderr.on("data", onData);

        const result = await new Promise<{
          code: number | null;
          error?: string;
        }>((resolve) => {
          let timedOut = false;
          let forceTimer: NodeJS.Timeout | undefined;
          const timer = setTimeout(() => {
            timedOut = true;
            killGroup("SIGTERM");
            forceTimer = setTimeout(() => killGroup("SIGKILL"), KILL_GRACE_MS);
          }, TIMEOUT_MS);
          const finish = (value: { code: number | null; error?: string }) => {
            clearTimeout(timer);
            clearTimeout(forceTimer);
            activeGroup = undefined;
            resolve(value);
          };
          child.on("error", (error) =>
            finish({ code: null, error: error.message }),
          );
          // Resolve only after the process has exited so a second /b-sync
          // cannot overlap a still-running installer.
          child.on("close", (code) =>
            finish(
              timedOut
                ? { code: null, error: "timed out after 10 minutes" }
                : { code },
            ),
          );
        });

        ctx.ui.setStatus("b-sync", undefined);
        if (result.code !== 0) {
          const reason = result.error ?? `exit code ${result.code}`;
          ctx.ui.notify(`b-sync failed (${reason}):\n${tail(output)}`, "error");
          return;
        }
        ctx.ui.notify(
          `b-sync complete; reloading Pi.\n${tail(output)}`,
          "info",
        );
      } catch (error) {
        ctx.ui.setStatus("b-sync", undefined);
        ctx.ui.notify(`b-sync failed: ${String(error)}`, "error");
        return;
      } finally {
        running = false;
      }
      // Reload replaces this runtime; do not touch ctx or state afterwards.
      await ctx.reload();
    },
  });
}
