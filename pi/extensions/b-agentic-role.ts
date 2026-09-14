/** Explicit role selection and role model preferences. */
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import {
  ROLE_ENTRY_TYPE,
  ROLE_PROTOCOL_VERSION,
  SKILL_OWNERS,
  latestRoleState,
  parseRole,
  type BAgenticRole,
} from "./b-agentic-support/role.ts";
import {
  loadRoleModelPreferences,
  saveRoleModelPreference,
} from "./b-agentic-support/role-models.ts";
import {
  loadPaneRole,
  paneRolePath,
  roleFromSessionFile,
  savePaneRole,
  terminalPaneId,
} from "./b-agentic-support/role-store.ts";
import { getRole, setRole } from "./b-agentic-support/state.ts";

/** Canonical one-line ownership display, derived only from the generated registry map. */
export function ownershipLine(role: BAgenticRole): string | undefined {
  if (role === "off") return undefined;
  const label = role === "executor" ? "Executor" : "Architect";
  const skills = Object.entries(SKILL_OWNERS)
    .filter(([, owner]) => owner === role)
    .map(([skill]) => skill)
    .join(", ");
  return `${label}-owned skills: ${skills}`;
}
function withOwnership(message: string, ownership: string | undefined): string {
  return ownership === undefined ? message : `${message}. ${ownership}`;
}
export default function bAgenticRole(pi: ExtensionAPI): void {
  let applyingSavedModel = false;

  const updateStatus = (ctx: ExtensionContext): void => {
    const role = getRole();
    const status =
      role === "executor"
        ? ctx.ui.theme.getColorMode() === "truecolor"
          ? "\x1b[38;2;0;215;255mb-agentic: executor\x1b[39m"
          : "\x1b[38;5;45mb-agentic: executor\x1b[39m"
        : role === "architect"
          ? ctx.ui.theme.fg("success", "b-agentic: architect")
          : undefined;
    ctx.ui.setStatus("b-agentic-role", status);
  };
  const persist = (): void =>
    pi.appendEntry(ROLE_ENTRY_TYPE, {
      role: getRole(),
      version: ROLE_PROTOCOL_VERSION,
    });
  /** Explicit selections survive into later sessions of the same terminal pane. */
  const persistPaneSelection = (
    role: BAgenticRole,
    ctx: ExtensionContext,
  ): void => {
    try {
      savePaneRole(ctx.cwd, role);
    } catch {
      // A session entry still preserves the choice when the durable file is unavailable.
    }
  };
  const saveModel = (
    role: Exclude<BAgenticRole, "off">,
    model: { provider: string; id: string },
  ): void =>
    saveRoleModelPreference(role, {
      provider: model.provider,
      model: model.id,
      thinkingLevel: pi.getThinkingLevel(),
    });
  const applySavedModel = async (
    role: Exclude<BAgenticRole, "off">,
    ctx: ExtensionContext,
  ): Promise<boolean> => {
    const preference = loadRoleModelPreferences()[role];
    if (!preference) return false;
    const model = ctx.modelRegistry.find(preference.provider, preference.model);
    if (!model) {
      ctx.ui.notify(
        `b-agentic ${role} model is unavailable: ${preference.provider}/${preference.model}`,
        "warning",
      );
      return false;
    }
    applyingSavedModel = true;
    try {
      if (!(await pi.setModel(model))) {
        ctx.ui.notify(
          `b-agentic ${role} model has no configured authentication: ${preference.provider}/${preference.model}`,
          "warning",
        );
        return false;
      }
      if (preference.thinkingLevel)
        pi.setThinkingLevel(preference.thinkingLevel);
      return true;
    } finally {
      applyingSavedModel = false;
    }
  };
  const applyRole = (
    role: BAgenticRole,
    ctx: ExtensionContext,
    shouldPersist = true,
  ): void => {
    setRole(role);
    updateStatus(ctx);
    if (shouldPersist) persist();
  };

  pi.registerFlag("b-role", {
    description: "Set b-agentic role: off, executor, or architect",
    type: "string",
  });
  pi.registerCommand("b-role", {
    description: "Set b-agentic role: executor, architect, or off",
    getArgumentCompletions: (prefix) =>
      ["executor", "architect", "off"]
        .filter((role) => role.startsWith(prefix.trim().toLowerCase()))
        .map((role) => ({ value: role, label: role })),
    handler: async (args, ctx) => {
      let next = parseRole(args);
      if (!next && !args.trim() && ctx.hasUI)
        next = parseRole(
          await ctx.ui.select("Select b-agentic role", [
            "executor",
            "architect",
            "off",
          ]),
        );
      if (!next) {
        ctx.ui.notify(
          args.trim()
            ? "Usage: /b-role executor|architect|off"
            : `b-agentic role: ${getRole()}`,
          args.trim() ? "error" : "info",
        );
        return;
      }
      persistPaneSelection(next, ctx);
      applyRole(next, ctx);
      if (next !== "off") await applySavedModel(next, ctx);
      ctx.ui.notify(
        withOwnership(`b-agentic role set to ${next}`, ownershipLine(next)),
        "info",
      );
    },
  });
  pi.on("model_select", (event) => {
    const role = getRole();
    if (!applyingSavedModel && role !== "off") {
      try {
        saveModel(role, event.model);
      } catch {
        /* Preference persistence cannot block selection. */
      }
    }
  });
  pi.on("thinking_level_select", (event) => {
    const role = getRole();
    if (applyingSavedModel || role === "off") return;
    try {
      const preference = loadRoleModelPreferences()[role];
      if (preference)
        saveRoleModelPreference(role, {
          ...preference,
          thinkingLevel: event.level,
        });
    } catch {
      /* Preference persistence cannot block selection. */
    }
  });
  pi.on("session_start", async (event, ctx) => {
    const persistedRole = latestRoleState(ctx.sessionManager.getBranch())?.role;
    // A startup flag stays a one-session override. Otherwise a session keeps its
    // own recorded role, then continues its predecessor's role, then this
    // terminal pane's last explicit selection; an unrelated pane stays Off.
    const inheritedRole = event.previousSessionFile
      ? roleFromSessionFile(event.previousSessionFile)
      : undefined;
    const flagRole = parseRole(pi.getFlag("b-role"));
    const requestedRole =
      flagRole ?? persistedRole ?? inheritedRole ?? loadPaneRole(ctx.cwd);
    const continuesLineage = !flagRole && persistedRole === undefined;
    const selectedRole = requestedRole ?? "off";
    applyRole(selectedRole, ctx, false);
    const ownership = ownershipLine(selectedRole);
    if (event.reason !== "reload" && ownership)
      ctx.ui.notify(
        withOwnership(`b-agentic role: ${selectedRole}`, ownership),
        "info",
      );
    if (selectedRole !== "off") await applySavedModel(selectedRole, ctx);
    // Record a continued role in this session too, so its own successors keep
    // inheriting it.
    const recordsSelection =
      flagRole !== undefined ||
      (continuesLineage && requestedRole !== undefined);
    if (recordsSelection) persist();
  });
}

export const __test__ = {
  ROLE_ENTRY_TYPE,
  ROLE_PROTOCOL_VERSION,
  parseRole,
  latestRoleState,
  ownershipLine,
  loadRoleModelPreferences,
  saveRoleModelPreference,
  loadPaneRole,
  savePaneRole,
  paneRolePath,
  terminalPaneId,
  roleFromSessionFile,
};
