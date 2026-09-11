/**
 * b-agentic shell/filesystem/local-tool policy for Pi.
 *
 * MCP/custom-tool approval and collaboration policy live in their
 * purpose-specific sibling extensions.
 * This entry point remains the compatibility module for policy helpers and
 * owns only local command/path gates.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  canonicalNativeToolPath,
  commandDecision,
  nativePathDecision,
} from "./b-agentic-support/shell.ts";
import * as shell from "./b-agentic-support/shell.ts";
import * as mcp from "./b-agentic-support/mcp.ts";
import { isAutoModeEnabled } from "./b-agentic-support/state.ts";

function hasExactOldTextError(content: readonly unknown[]): boolean {
  const text = content
    .filter(
      (item): item is { type: "text"; text: string } =>
        typeof item === "object" &&
        item !== null &&
        (item as { type?: unknown }).type === "text" &&
        typeof (item as { text?: unknown }).text === "string",
    )
    .map((item) => item.text)
    .join("\n");
  return /Could not find (?:edits\[\d+\]|the exact text) in .+\. The old(?:Text| text) must match exactly including all whitespace and newlines\./.test(
    text,
  );
}

export default function bAgenticPermissions(pi: ExtensionAPI): void {
  const editedPathsThisTurn = new Set<string>();

  pi.on("turn_start", () => {
    editedPathsThisTurn.clear();
  });
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "bash") {
      const command = String(
        (event.input as { command?: string }).command || "",
      );
      const decision = commandDecision(command);
      if (decision.decision === "deny")
        return { block: true, reason: decision.reason };
      if (decision.decision === "ask") {
        if (isAutoModeEnabled()) return undefined;
        if (!ctx.hasUI)
          return {
            block: true,
            reason: `${decision.reason} (no UI; fail-closed)`,
          };
        const allowed = await ctx.ui.confirm(
          "b-agentic approval",
          `${decision.reason}\n\nCommand:\n${command}\n\nAllow this tool call?`,
        );
        return allowed
          ? undefined
          : { block: true, reason: `${decision.reason} (denied by user)` };
      }
      return undefined;
    }

    if (
      event.toolName === "write" ||
      event.toolName === "edit" ||
      event.toolName === "read"
    ) {
      const pathValue = String((event.input as { path?: string }).path || "");
      const cwd = ctx.cwd || process.cwd();
      const decision = nativePathDecision(event.toolName, pathValue, cwd);
      if (decision.decision === "deny")
        return { block: true, reason: decision.reason };

      if (event.toolName === "edit" && pathValue) {
        let canonicalPath: string;
        try {
          canonicalPath = canonicalNativeToolPath(pathValue, cwd);
        } catch {
          canonicalPath = pathValue;
        }
        if (editedPathsThisTurn.has(canonicalPath)) {
          return {
            block: true,
            reason: `Blocked duplicate native edit for ${pathValue} in this turn: merge disjoint replacements into one edits[] call; otherwise reread and retry next turn.`,
          };
        }
        editedPathsThisTurn.add(canonicalPath);
        if (decision.decision === "ask" && isAutoModeEnabled())
          return undefined;
        if (decision.decision === "ask" && !ctx.hasUI) {
          editedPathsThisTurn.delete(canonicalPath);
          return {
            block: true,
            reason: `${decision.reason} (no UI; fail-closed)`,
          };
        }
        if (decision.decision === "ask") {
          const allowed = await ctx.ui.confirm(
            "b-agentic approval",
            `${decision.reason}\n\nAllow this tool call?`,
          );
          if (!allowed) editedPathsThisTurn.delete(canonicalPath);
          return allowed
            ? undefined
            : { block: true, reason: `${decision.reason} (denied by user)` };
        }
        return undefined;
      }

      if (decision.decision === "ask") {
        if (isAutoModeEnabled()) return undefined;
        if (!ctx.hasUI)
          return {
            block: true,
            reason: `${decision.reason} (no UI; fail-closed)`,
          };
        const allowed = await ctx.ui.confirm(
          "b-agentic approval",
          `${decision.reason}\n\nAllow this tool call?`,
        );
        return allowed
          ? undefined
          : { block: true, reason: `${decision.reason} (denied by user)` };
      }
      return undefined;
    }

    return undefined;
  });

  pi.on("tool_result", (event) => {
    if (
      event.toolName !== "edit" ||
      !event.isError ||
      !hasExactOldTextError(event.content) ||
      typeof event.input.path !== "string" ||
      !event.input.path
    )
      return;

    const pathValue = event.input.path;
    pi.sendMessage(
      {
        customType: "b-agentic-edit-recovery",
        content: `Native edit failed because its oldText no longer matches. Immediately read ${pathValue}, then make one exact retry for that path; do not issue another edit for it in this turn.`,
        display: false,
        details: { path: pathValue },
      },
      { deliverAs: "steer" },
    );
  });
}

// Compatibility test surface. Domain tests should import the corresponding
// sibling extension, while existing consumers can continue importing this one.
export const __test__ = {
  ...shell,
  ...mcp,
};
