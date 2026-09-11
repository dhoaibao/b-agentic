/** Refresh b-agentic assets or installed runtime tooling from an active Pi session. */
import type {
  ExtensionAPI,
  ExtensionCommandContext,
} from "@earendil-works/pi-coding-agent";
import { homedir } from "node:os";
import { join } from "node:path";
import { isAutoModeEnabled } from "./b-agentic-support/state.ts";

const installerPath = (): string =>
  join(
    process.env.B_AGENTIC_DIR || join(homedir(), ".b-agentic"),
    "install.sh",
  );

async function runRefresh(
  pi: ExtensionAPI,
  mode: "--sync" | "--update",
  args: string,
  ctx: ExtensionCommandContext,
): Promise<void> {
  if (args.trim()) {
    ctx.ui.notify(
      `Usage: /b-${mode === "--sync" ? "sync" : "update"}`,
      "error",
    );
    return;
  }
  if (!ctx.hasUI) {
    ctx.ui.notify(
      "b-agentic refresh requires an interactive Pi session",
      "error",
    );
    return;
  }

  const label =
    mode === "--sync" ? "Sync b-agentic" : "Update b-agentic tooling";
  if (
    mode === "--sync" &&
    !isAutoModeEnabled() &&
    !(await ctx.ui.confirm(
      label,
      "This downloads and runs updates on your machine. Continue?",
    ))
  )
    return;

  ctx.ui.notify(`${label} started`, "info");
  const result = await pi.exec("bash", [installerPath(), mode], {
    timeout: 300_000,
  });
  if (result.code !== 0) {
    ctx.ui.notify(`${label} failed (exit ${result.code})`, "error");
    return;
  }

  ctx.ui.notify(`${label} completed; reloading Pi`, "info");
  await ctx.reload();
}

export default function bAgenticSync(pi: ExtensionAPI): void {
  pi.registerCommand("b-sync", {
    description: "Pull and sync managed Pi assets, then reload Pi",
    handler: (args, ctx) => runRefresh(pi, "--sync", args, ctx),
  });
  pi.registerCommand("b-update", {
    description:
      "Update installed b-agentic tooling without pulling or installing b-agentic, then reload Pi",
    handler: (args, ctx) => runRefresh(pi, "--update", args, ctx),
  });
}
