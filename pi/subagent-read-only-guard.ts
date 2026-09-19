/**
 * Child-only pi-subagents guard. Loaded by managed profiles through
 * subagentOnlyExtensions, never as an ambient main-session extension.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

type ManagedMcpPolicy = {
  isTrustedManagedGatewayCall(input: unknown): boolean;
};

const READ_ONLY_ALLOWED_TOOLS = new Set(["read", "recall", "mcp"]);
const ALWAYS_BLOCKED_TOOLS = new Set([
  "bash",
  "powershell",
  "edit",
  "write",
  "mcpScript",
  "subagent",
  "intercom",
  "ask_user_question",
  "todo",
]);

function configuredAgentDirectory(): string {
  return (
    process.env.PI_CODING_AGENT_DIR?.trim() || join(homedir(), ".pi", "agent")
  );
}

async function loadManagedMcpPolicy(): Promise<ManagedMcpPolicy | undefined> {
  try {
    const path = join(
      configuredAgentDirectory(),
      "extensions",
      "b-agentic-support",
      "mcp.ts",
    );
    const module = (await import(
      pathToFileURL(path).href
    )) as Partial<ManagedMcpPolicy>;
    return typeof module.isTrustedManagedGatewayCall === "function"
      ? (module as ManagedMcpPolicy)
      : undefined;
  } catch {
    return undefined;
  }
}

export function childToolBlockReason(
  toolName: string,
  input: unknown,
  mcpPolicy: ManagedMcpPolicy | undefined,
): string | undefined {
  if (ALWAYS_BLOCKED_TOOLS.has(toolName)) {
    return `Blocked ${toolName}: managed subagents are read-only and cannot use mutation-capable or orchestration tools`;
  }
  if (toolName.startsWith("mcp__")) {
    return "Blocked direct MCP tool: managed subagents must use a classified read-only gateway operation";
  }
  if (!READ_ONLY_ALLOWED_TOOLS.has(toolName)) {
    return `Blocked ${toolName}: managed subagents expose only read, recall, and classified read-only MCP gateway operations`;
  }
  if (toolName === "mcp") {
    if (mcpPolicy?.isTrustedManagedGatewayCall(input)) return undefined;
    return "Blocked mcp: managed subagents may call only classified read-only or safe conditional-read gateway operations";
  }
  return undefined;
}

export default async function bAgenticSubagentReadOnlyGuard(
  pi: ExtensionAPI,
): Promise<void> {
  const mcpPolicy = await loadManagedMcpPolicy();
  pi.on("tool_call", (event) => {
    const reason = childToolBlockReason(event.toolName, event.input, mcpPolicy);
    return reason ? { block: true, reason } : undefined;
  });
}

export const __test__ = { childToolBlockReason };
