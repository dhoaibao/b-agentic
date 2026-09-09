/** Explicit role selection, compatible peer discovery, and role model preferences. */
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import {
  ROLE_ENTRY_TYPE,
  ROLE_PROTOCOL_VERSION,
  isCompatibleRolePayload,
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

type RoleSession = {
  id: string;
  cwd: string;
  name?: string;
  pid: number;
  startedAt: number;
};
type RoleChannel = {
  publish(
    payload: unknown,
    options?: { audience?: "owner" | "capable"; ownerOnly?: boolean },
  ): void;
  listSessions(): Promise<RoleSession[]>;
};
type RoleChannelEvent =
  | { type: "connection"; connected: boolean; supported: boolean }
  | { type: "session_joined" }
  | { type: "session_left"; sessionId: string }
  | { type: "message"; fromSessionId: string; payload: unknown };
function sameCwdPeers(
  sessions: RoleSession[],
  cwd: string,
  pid: number,
): RoleSession[] {
  return sessions.filter(
    (session) => session.cwd === cwd && session.pid !== pid,
  );
}
function hasActiveSameCwdPeerExecutor(
  sessions: RoleSession[],
  cwd: string,
  pid: number,
  peerRoles: ReadonlyMap<string, BAgenticRole>,
): boolean {
  return sameCwdPeers(sessions, cwd, pid).some(
    (peer) => peerRoles.get(peer.id) === "executor",
  );
}
function canClaimExecutor(
  sessions: RoleSession[],
  cwd: string,
  pid: number,
  peerRoles: ReadonlyMap<string, BAgenticRole> = new Map(),
): boolean {
  const peers = sameCwdPeers(sessions, cwd, pid);
  return (
    peers.length === 0 ||
    (peers.length === 1 && peerRoles.get(peers[0].id) === "architect")
  );
}
function preferredExecutorId(
  sessions: RoleSession[],
  cwd: string,
  pid: number,
  peerRoles: ReadonlyMap<string, BAgenticRole>,
): string | undefined {
  return sessions
    .filter(
      (session) =>
        session.cwd === cwd &&
        (session.pid === pid || peerRoles.get(session.id) === "executor"),
    )
    .map((session) => session.id)
    .sort((left, right) => left.localeCompare(right))[0];
}
export default function bAgenticRole(pi: ExtensionAPI): void {
  let channel: RoleChannel | undefined;
  let applyingSavedModel = false;
  let pendingExecutorClaim = false;
  let pendingExecutorModel = false;
  let peerStateGeneration = 0;
  const peerRoles = new Map<string, BAgenticRole>();

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
  const publishRole = (): void => {
    try {
      channel?.publish(
        {
          type: "b-agentic-role",
          version: ROLE_PROTOCOL_VERSION,
          role: getRole(),
        },
        { audience: "capable" },
      );
    } catch {
      /* Retry on a connection event. */
    }
  };
  const requestPeerRoles = (): void => {
    try {
      channel?.publish(
        { type: "b-agentic-role-request", version: ROLE_PROTOCOL_VERSION },
        { audience: "capable" },
      );
    } catch {
      /* Retry on a connection event. */
    }
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
    publishRole();
    updateStatus(ctx);
    if (shouldPersist) persist();
  };
  const resolvePendingExecutorClaim = async (
    ctx: ExtensionContext,
  ): Promise<void> => {
    if (!pendingExecutorClaim || !channel) return;
    const generation = peerStateGeneration;
    try {
      const sessions = await channel.listSessions();
      if (generation !== peerStateGeneration || !pendingExecutorClaim) return;
      if (!canClaimExecutor(sessions, ctx.cwd, process.pid, peerRoles)) return;
      pendingExecutorClaim = false;
      const shouldApplySavedModel = pendingExecutorModel;
      pendingExecutorModel = false;
      if (
        hasActiveSameCwdPeerExecutor(sessions, ctx.cwd, process.pid, peerRoles)
      ) {
        ctx.ui.notify(
          "A same-CWD b-agentic executor is already active",
          "warning",
        );
        return;
      }
      applyRole("executor", ctx);
      if (shouldApplySavedModel) await applySavedModel("executor", ctx);
    } catch {
      /* Remain Off until compatible discovery completes. */
    }
  };
  const resolveExecutorCollision = async (
    ctx: ExtensionContext,
  ): Promise<void> => {
    if (getRole() !== "executor" || !channel) return;
    const generation = peerStateGeneration;
    try {
      const sessions = await channel.listSessions();
      if (generation !== peerStateGeneration || getRole() !== "executor")
        return;
      const self = sessions.find(
        (session) => session.cwd === ctx.cwd && session.pid === process.pid,
      );
      const peers = sameCwdPeers(sessions, ctx.cwd, process.pid);
      if (!self || peers.length > 1) {
        applyRole("off", ctx);
        ctx.ui.notify(
          "Could not resolve a same-CWD executor claim; remaining Off",
          "warning",
        );
        return;
      }
      if (
        hasActiveSameCwdPeerExecutor(sessions, ctx.cwd, process.pid, peerRoles)
      ) {
        if (
          preferredExecutorId(sessions, ctx.cwd, process.pid, peerRoles) !==
          self.id
        ) {
          applyRole("off", ctx);
          ctx.ui.notify(
            "A same-CWD executor claim won; remaining Off",
            "warning",
          );
        }
        return;
      }
      if (!canClaimExecutor(sessions, ctx.cwd, process.pid, peerRoles)) {
        applyRole("off", ctx);
        ctx.ui.notify(
          "A same-CWD peer is not a confirmed Architect; remaining Off",
          "warning",
        );
      }
    } catch {
      applyRole("off", ctx);
      ctx.ui.notify(
        "Could not resolve a same-CWD executor claim; remaining Off",
        "warning",
      );
    }
  };
  const handleChannelEvent = async (
    event: RoleChannelEvent,
    ctx: ExtensionContext,
  ): Promise<void> => {
    if (event.type === "session_left") {
      peerStateGeneration += 1;
      peerRoles.delete(event.sessionId);
      await resolvePendingExecutorClaim(ctx);
      await resolveExecutorCollision(ctx);
      return;
    }
    if (event.type === "connection") {
      peerStateGeneration += 1;
      peerRoles.clear();
      if (!event.connected || !event.supported) {
        if (getRole() === "executor") {
          pendingExecutorClaim = true;
          pendingExecutorModel = false;
          applyRole("off", ctx);
          ctx.ui.notify(
            "The role channel is unavailable; remaining Off until peer discovery completes",
            "warning",
          );
        }
        return;
      }
      publishRole();
      requestPeerRoles();
      await resolvePendingExecutorClaim(ctx);
      await resolveExecutorCollision(ctx);
      return;
    }
    if (event.type === "session_joined") {
      peerStateGeneration += 1;
      publishRole();
      await resolvePendingExecutorClaim(ctx);
      await resolveExecutorCollision(ctx);
      return;
    }
    if (
      event.type !== "message" ||
      !event.payload ||
      typeof event.payload !== "object"
    )
      return;
    const payload = event.payload as Record<string, unknown>;
    if (
      payload.type === "b-agentic-role-request" &&
      payload.version === ROLE_PROTOCOL_VERSION
    ) {
      publishRole();
      return;
    }
    if (payload.type === "b-agentic-role") {
      peerStateGeneration += 1;
      if (isCompatibleRolePayload(payload))
        peerRoles.set(event.fromSessionId, payload.role);
      else peerRoles.delete(event.fromSessionId);
      await resolvePendingExecutorClaim(ctx);
      await resolveExecutorCollision(ctx);
    }
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
      pendingExecutorClaim = next === "executor";
      pendingExecutorModel = next === "executor";
      // Record the explicit request itself, so a claim that loses same-CWD
      // arbitration still retries in this pane's next session.
      persistPaneSelection(next, ctx);
      applyRole(next === "executor" ? "off" : next, ctx);
      if (next === "architect") await applySavedModel("architect", ctx);
      if (pendingExecutorClaim) {
        requestPeerRoles();
        await resolvePendingExecutorClaim(ctx);
      }
      ctx.ui.notify(
        pendingExecutorClaim
          ? "b-agentic executor request is waiting for compatible peer discovery"
          : `b-agentic role set to ${getRole()}`,
        pendingExecutorClaim ? "warning" : "info",
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
    pendingExecutorClaim = requestedRole === "executor";
    pendingExecutorModel = pendingExecutorClaim;
    const selectedRole = pendingExecutorClaim
      ? "off"
      : (requestedRole ?? "off");
    applyRole(selectedRole, ctx, false);
    const startupModelRole =
      flagRole && flagRole !== "off"
        ? flagRole
        : !pendingExecutorClaim && selectedRole !== "off"
          ? selectedRole
          : undefined;
    if (startupModelRole) await applySavedModel(startupModelRole, ctx);
    // Record a continued role in this session too, so its own successors keep
    // inheriting it; a pending executor claim records only once it wins.
    const recordsSelection =
      flagRole !== undefined ||
      (continuesLineage && requestedRole !== undefined);
    if (recordsSelection && !pendingExecutorClaim) persist();
    pi.events.emit("intercom:extension-register", {
      namespace: "b-agentic/roles/v3",
      ownerEligible: false,
      onReady: (nextChannel: RoleChannel) => {
        channel = nextChannel;
        publishRole();
        requestPeerRoles();
        void resolvePendingExecutorClaim(ctx);
      },
      onEvent: (event: RoleChannelEvent) => handleChannelEvent(event, ctx),
    });
  });
}

export const __test__ = {
  ROLE_ENTRY_TYPE,
  ROLE_PROTOCOL_VERSION,
  parseRole,
  latestRoleState,
  isCompatibleRolePayload,
  loadRoleModelPreferences,
  saveRoleModelPreference,
  hasActiveSameCwdPeerExecutor,
  canClaimExecutor,
  preferredExecutorId,
  loadPaneRole,
  savePaneRole,
  paneRolePath,
  terminalPaneId,
  roleFromSessionFile,
};
