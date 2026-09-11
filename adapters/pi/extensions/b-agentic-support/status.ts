/** Read-only local capability status helpers. This module never starts MCP servers or persists session data. */
import { accessSync, constants, existsSync } from "node:fs";
import { join } from "node:path";
import type { CapabilityDefinition, CapabilityKind } from "./capabilities.ts";

export type CapabilityState =
  | "local-ready"
  | "installed"
  | "configured"
  | "degraded"
  | "blocked"
  | "missing"
  | "unknown";

export type CapabilityStatus = {
  id: string;
  kind: CapabilityKind;
  state: CapabilityState;
  detail: string;
};

export type CapabilityObservation = {
  packageListing?: string;
  extensionRoot?: string;
  mcpConfigPresent?: boolean;
  commandAvailable?: (command: string) => boolean;
};

export function commandOnPath(
  command: string,
  pathValue = process.env.PATH ?? "",
): boolean {
  if (!command) return false;
  if (command.includes("/")) {
    try {
      accessSync(command, constants.X_OK);
      return true;
    } catch {
      return false;
    }
  }
  return pathValue.split(":").some((directory) => {
    if (!directory) return false;
    try {
      accessSync(join(directory, command), constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

function packageIsListed(listing: string, packageName: string): boolean {
  return listing.split(/\r?\n/).some((line) => {
    const token = line.trim().replace(/^[-*]\s+/, "");
    return (
      token === packageName ||
      token === `npm:${packageName}` ||
      token.startsWith(`npm:${packageName}@`) ||
      token.startsWith(`${packageName}@`)
    );
  });
}

function capabilityLabel(capability: CapabilityDefinition): string {
  return capability.id.replace(/^(package|mcp|extension)\./, "");
}

function packageStatus(
  capability: CapabilityDefinition,
  observation: CapabilityObservation,
): CapabilityStatus {
  const packageName = capability.package?.name ?? capability.probe.name;
  if (!packageName) {
    return {
      id: capability.id,
      kind: capability.kind,
      state: "unknown",
      detail: "unknown: package metadata is incomplete",
    };
  }
  if (observation.packageListing === undefined) {
    return {
      id: capability.id,
      kind: capability.kind,
      state: "unknown",
      detail:
        "unknown: local Pi package listing is unavailable; authentication, external health, and session usage are not observed",
    };
  }
  if (!packageIsListed(observation.packageListing, packageName)) {
    return {
      id: capability.id,
      kind: capability.kind,
      state: "missing",
      detail:
        "missing: package is not present in the local Pi package listing; no authentication, external health, or session usage is claimed",
    };
  }
  return {
    id: capability.id,
    kind: capability.kind,
    state: "installed",
    detail:
      "installed locally; authentication, external health, and use in this session are not verified",
  };
}

function extensionStatus(
  capability: CapabilityDefinition,
  observation: CapabilityObservation,
): CapabilityStatus {
  const name = capability.extension?.name ?? capability.probe.name;
  const root = observation.extensionRoot;
  if (!name || !root) {
    return {
      id: capability.id,
      kind: capability.kind,
      state: "unknown",
      detail: "unknown: local extension root is unavailable",
    };
  }
  if (!existsSync(join(root, name))) {
    return {
      id: capability.id,
      kind: capability.kind,
      state: "missing",
      detail: "missing: managed extension entrypoint is not installed locally",
    };
  }
  return {
    id: capability.id,
    kind: capability.kind,
    state: "installed",
    detail:
      "installed locally; runtime loading and session use are not independently verified",
  };
}

function mcpStatus(
  capability: CapabilityDefinition,
  observation: CapabilityObservation,
): CapabilityStatus {
  const probe = capability.mcp ?? capability.probe;
  if (observation.mcpConfigPresent === false) {
    return {
      id: capability.id,
      kind: capability.kind,
      state: "blocked",
      detail:
        "blocked: the local MCP configuration file is absent; entry shape, credentials, server health, and session usage are not inspected",
    };
  }

  const command = probe.launcher;
  if (command && !(observation.commandAvailable ?? commandOnPath)(command)) {
    return {
      id: capability.id,
      kind: capability.kind,
      state: "blocked",
      detail: `blocked: the managed launcher ${command} is unavailable; MCP configuration contents, credentials, server health, and session usage are not inspected`,
    };
  }

  return {
    id: capability.id,
    kind: capability.kind,
    state: "unknown",
    detail:
      "unknown: MCP configuration contents and credential/key readiness are intentionally unverified; no authentication, server health, browser activity, or session usage is inspected",
  };
}

export function statusForCapability(
  capability: CapabilityDefinition,
  observation: CapabilityObservation,
): CapabilityStatus {
  if (capability.kind === "package")
    return packageStatus(capability, observation);
  if (capability.kind === "extension")
    return extensionStatus(capability, observation);
  return mcpStatus(capability, observation);
}

export function collectCapabilityStatuses(
  capabilities: readonly CapabilityDefinition[],
  observation: CapabilityObservation,
): CapabilityStatus[] {
  return capabilities.map((capability) =>
    statusForCapability(capability, observation),
  );
}

export function formatCapabilitySnapshot(
  statuses: readonly CapabilityStatus[],
): string {
  const blocked = statuses.filter(
    (status) => status.state === "blocked",
  ).length;
  const degraded = statuses.filter(
    (status) => status.state === "degraded",
  ).length;
  const unknown = statuses.filter(
    (status) => status.state === "unknown",
  ).length;
  const missing = statuses.filter(
    (status) => status.state === "missing",
  ).length;
  const overall =
    blocked || degraded || missing || unknown ? "degraded" : "locally ready";
  const lines = [
    "b-agentic capability snapshot (local, read-only; no MCP/auth/browser probes)",
    `Overall: ${overall}; authentication, external verification, and use-this-session are not claimed`,
  ];
  for (const status of statuses) {
    lines.push(
      `- ${capabilityLabel({ id: status.id } as CapabilityDefinition)}: ${status.state} — ${status.detail}`,
    );
  }
  return lines.join("\n");
}

export function defaultCapabilityObservation(
  agentDir: string,
  mcpConfigPath: string,
): CapabilityObservation {
  return {
    extensionRoot: join(agentDir, "extensions"),
    mcpConfigPresent: existsSync(mcpConfigPath),
    commandAvailable: (command) => commandOnPath(command),
  };
}

export const __test__ = {
  commandOnPath,
  statusForCapability,
};
