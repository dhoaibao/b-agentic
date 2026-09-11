/** Show a read-only local capability snapshot without starting managed services. */
// The snapshot is local and read-only: no MCP/auth/browser probes are performed.
import {
  getAgentDir,
  type ExtensionAPI,
  type ExtensionCommandContext,
} from "@earendil-works/pi-coding-agent";
import { join } from "node:path";
import {
  CAPABILITIES,
  CAPABILITY_CONTRACT_VERSION,
} from "./b-agentic-support/capabilities.ts";
import {
  collectCapabilityStatuses,
  defaultCapabilityObservation,
  formatCapabilitySnapshot,
  type CapabilityObservation,
} from "./b-agentic-support/status.ts";

async function localPackageListing(
  pi: ExtensionAPI,
): Promise<string | undefined> {
  try {
    const result = await pi.exec("pi", ["list"], { timeout: 10_000 });
    return result.code === 0 ? result.stdout : undefined;
  } catch {
    return undefined;
  }
}

export async function buildCapabilitySnapshot(
  pi: ExtensionAPI,
  observation: CapabilityObservation = defaultCapabilityObservation(
    getAgentDir(),
    process.env.B_AGENTIC_PI_MCP_JSON?.trim() ||
      join(getAgentDir(), "mcp.json"),
  ),
): Promise<string> {
  const packageListing =
    observation.packageListing ?? (await localPackageListing(pi));
  const statuses = collectCapabilityStatuses(CAPABILITIES, {
    ...observation,
    packageListing,
  });
  return `Capability contract v${CAPABILITY_CONTRACT_VERSION}\n${formatCapabilitySnapshot(statuses)}`;
}

export default function bAgenticStatus(pi: ExtensionAPI): void {
  // registerCommand("b-status") is the public command contract.
  pi.registerCommand("b-status", {
    description: "Show a read-only local b-agentic capability snapshot",
    handler: async (args, ctx: ExtensionCommandContext) => {
      if (args.trim()) {
        ctx.ui.notify("Usage: /b-status", "error");
        return;
      }
      ctx.ui.notify(await buildCapabilitySnapshot(pi), "info");
    },
  });
}

export const __test__ = {
  buildCapabilitySnapshot,
  collectCapabilityStatuses,
  defaultCapabilityObservation,
  formatCapabilitySnapshot,
  localPackageListing,
};
