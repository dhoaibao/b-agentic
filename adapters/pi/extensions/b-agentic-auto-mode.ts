/** Interactive opt-in for allowing approval prompts while preserving explicit denies. */
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import {
  AUTO_MODE_ENTRY_TYPE,
  autoModePath,
  latestAutoModeState,
  loadAutoModePreference,
  parseAutoMode,
  saveAutoModePreference,
} from "./b-agentic-support/auto.ts";
import {
  isAutoModeEnabled,
  setAutoModeEnabled,
} from "./b-agentic-support/state.ts";

function updateStatus(ctx: ExtensionContext): void {
  ctx.ui.setStatus(
    "b-auto-mode",
    isAutoModeEnabled() ? ctx.ui.theme.fg("error", "auto-mode") : undefined,
  );
}

export default function bAgenticAutoMode(pi: ExtensionAPI): void {
  const appendSessionState = (): void => {
    pi.appendEntry(AUTO_MODE_ENTRY_TYPE, { enabled: isAutoModeEnabled() });
  };
  const persist = (): void => {
    const enabled = isAutoModeEnabled();
    try {
      saveAutoModePreference(enabled);
    } catch {
      // A session entry still preserves the choice when the durable file is unavailable.
    }
    appendSessionState();
  };
  const disable = (ctx: ExtensionContext, shouldPersist = true): void => {
    setAutoModeEnabled(false);
    updateStatus(ctx);
    if (shouldPersist) persist();
  };
  const enable = async (
    ctx: ExtensionContext,
    shouldPersist = true,
  ): Promise<boolean> => {
    if (isAutoModeEnabled()) {
      updateStatus(ctx);
      return true;
    }
    if (!ctx.hasUI) {
      ctx.ui.notify(
        "Cannot enable b-auto-mode without an interactive UI; remaining fail-closed",
        "warning",
      );
      updateStatus(ctx);
      return false;
    }
    const confirmed = await ctx.ui.confirm(
      "Enable b-auto-mode?",
      "WARNING: b-auto-mode will automatically allow every approval request. Explicit deny decisions remain blocked. Enable it?",
    );
    if (!confirmed) {
      ctx.ui.notify("b-auto-mode remains off", "info");
      updateStatus(ctx);
      return false;
    }
    setAutoModeEnabled(true);
    updateStatus(ctx);
    if (shouldPersist) persist();
    ctx.ui.notify(
      "b-auto-mode enabled; approval asks will be auto-allowed and explicit denies remain blocked",
      "warning",
    );
    return true;
  };

  pi.registerFlag("b-auto-mode", {
    description:
      "Enable b-agentic automatic approval mode (requires confirmation)",
    type: "boolean",
  });
  pi.registerCommand("b-auto-mode", {
    description: "Enable or disable b-agentic automatic approval mode",
    getArgumentCompletions: (prefix) =>
      ["on", "off"]
        .filter((value) => value.startsWith(prefix.trim().toLowerCase()))
        .map((value) => ({ value, label: value })),
    handler: async (args, ctx) => {
      const requested = args.trim()
        ? parseAutoMode(args)
        : !isAutoModeEnabled();
      if (requested === undefined) {
        ctx.ui.notify("Usage: /b-auto-mode [on|off]", "error");
        return;
      }
      if (requested) await enable(ctx);
      else {
        disable(ctx);
        ctx.ui.notify(
          "b-auto-mode disabled; approval requests use the normal policy",
          "info",
        );
      }
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    const sessionState = latestAutoModeState(ctx.sessionManager.getBranch());
    const durableState = loadAutoModePreference();
    const flagValue = pi.getFlag("b-auto-mode");
    const requested =
      flagValue === undefined
        ? (durableState ?? sessionState)
        : parseAutoMode(flagValue);
    if (
      flagValue === undefined &&
      durableState === undefined &&
      sessionState !== undefined
    ) {
      // Migrate the legacy session entry only when no durable preference exists.
      try {
        saveAutoModePreference(sessionState);
      } catch {
        /* Keep session compatibility if persistence is unavailable. */
      }
    }
    if (requested === true) {
      // A persisted opt-in was already confirmed in an earlier session; restore
      // it without reopening an approval prompt. Explicit startup flags still
      // go through the confirmation above and remain one-session overrides.
      if (flagValue === undefined) {
        setAutoModeEnabled(true);
        updateStatus(ctx);
        return;
      }
      await enable(ctx, false);
      return;
    }
    disable(ctx, false);
  });
}

export const __test__ = {
  AUTO_MODE_ENTRY_TYPE,
  autoModePath,
  loadAutoModePreference,
  parseAutoMode,
  latestAutoModeState,
  saveAutoModePreference,
};
