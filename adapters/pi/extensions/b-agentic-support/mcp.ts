import { realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { isIP } from "node:net";
import { isAbsolute, relative } from "node:path";

import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { isProtectedPath, isProtectedLocalPath, SPECIALIZED_TOOLS } from "./shell.ts";
import { isAutoModeEnabled } from "./state.ts";

export const INTERCOM_ACTIONS = new Set(["list", "list-cwd", "send", "ask", "reply", "pending", "status", "cancel"]);
export const INTERCOM_FIELDS = new Set([
  "action",
  "to",
  "message",
  "attachments",
  "replyTo",
  "messageId",
  "supersedes",
  "retryOf",
  "cwd",
  "focus",
  "openProjectPaneIfMissing",
]);
export const INTERCOM_ATTACHMENT_TYPES = new Set(["file", "snippet", "context"]);
const INTERCOM_ATTACHMENT_FIELDS = new Set(["type", "name", "content", "language"]);

export function isValidIntercomAttachment(value: unknown): boolean {
  if (!isPlainObject(value) || typeof value.type !== "string" || !INTERCOM_ATTACHMENT_TYPES.has(value.type) || typeof value.name !== "string" || typeof value.content !== "string") return false;
  if (value.language !== undefined && typeof value.language !== "string") return false;
  return Object.keys(value).every((key) => INTERCOM_ATTACHMENT_FIELDS.has(key));
}

export function isAutoApprovedIntercomCall(toolName: string, input: unknown): boolean {
  if (toolName !== "intercom" || !isPlainObject(input) || typeof input.action !== "string" || !INTERCOM_ACTIONS.has(input.action)) return false;
  return Object.entries(input).every(([key, value]) => {
    if (!INTERCOM_FIELDS.has(key)) return false;
    if (key === "action") return typeof value === "string" && INTERCOM_ACTIONS.has(value);
    if (key === "attachments") return Array.isArray(value) && value.every(isValidIntercomAttachment);
    if (key === "focus") return typeof value === "boolean";
    if (key === "openProjectPaneIfMissing") return value === false;
    return typeof value === "string";
  });
}
export type McpToolApprovalDecision = "allow_once" | "allow_for_session" | "deny" | "abstain";
export type McpToolApprovalOrigin = "proxy" | "direct" | "script" | "resource" | "iframe";
export type McpToolApprovalRequest = {
  serverName: string;
  originalToolName: string;
  prefixedToolName: string;
  args: Record<string, unknown>;
  origin: McpToolApprovalOrigin;
  signal?: AbortSignal;
  claim: (handler: () => McpToolApprovalDecision | Promise<McpToolApprovalDecision>) => boolean;
};

export const MCP_TOOL_APPROVAL_REQUEST_EVENT = "pi-mcp-adapter:tool-approval-request";
// generated:mcp-runtime-policy:start
/** Generated from references/mcp_operations.yaml. */
export const MANAGED_MCP_SERVERS = new Set([
  "brave-search",
  "codegraph",
  "context7",
  "firecrawl",
  "playwright"
]);

/** Operations autonomous only for a validated safe argument shape. */
export const MCP_CONDITIONAL_TOOLS = new Set([
  "firecrawl:firecrawl_extract",
  "firecrawl:firecrawl_map",
  "firecrawl:firecrawl_scrape",
  "firecrawl:firecrawl_search",
  "playwright:browser_console_messages",
  "playwright:browser_network_request",
  "playwright:browser_network_requests",
  "playwright:browser_snapshot",
  "playwright:browser_tabs",
  "playwright:browser_verify_element_visible",
  "playwright:browser_verify_list_visible",
  "playwright:browser_verify_text_visible",
  "playwright:browser_verify_value"
]);

/** Known arguments for conditional operations, generated from the canonical policy. */
export const MCP_CONDITIONAL_ARGUMENTS: Record<string, readonly string[]> = {
  "firecrawl:firecrawl_extract": [
    "urls",
    "prompt",
    "schema",
    "allowExternalLinks",
    "enableWebSearch",
    "includeSubdomains"
  ],
  "firecrawl:firecrawl_map": [
    "url",
    "search",
    "sitemap",
    "includeSubdomains",
    "limit",
    "ignoreQueryParameters"
  ],
  "firecrawl:firecrawl_scrape": [
    "url",
    "formats",
    "jsonOptions",
    "queryOptions",
    "screenshotOptions",
    "parsers",
    "pdfOptions",
    "onlyMainContent",
    "redactPII",
    "includeTags",
    "excludeTags",
    "waitFor",
    "actions",
    "mobile",
    "skipTlsVerification",
    "removeBase64Images",
    "location",
    "storeInCache",
    "zeroDataRetention",
    "maxAge",
    "lockdown",
    "proxy",
    "profile"
  ],
  "firecrawl:firecrawl_search": [
    "query",
    "limit",
    "tbs",
    "filter",
    "location",
    "includeDomains",
    "excludeDomains",
    "sources",
    "categories",
    "scrapeOptions",
    "enterprise",
    "highlights"
  ],
  "playwright:browser_console_messages": [
    "level",
    "all",
    "filename"
  ],
  "playwright:browser_network_request": [
    "index",
    "part",
    "filename"
  ],
  "playwright:browser_network_requests": [
    "static",
    "filter",
    "filename"
  ],
  "playwright:browser_snapshot": [
    "target",
    "filename",
    "depth",
    "boxes"
  ],
  "playwright:browser_tabs": [
    "action",
    "index",
    "url"
  ],
  "playwright:browser_verify_element_visible": [
    "accessibleName",
    "role"
  ],
  "playwright:browser_verify_list_visible": [
    "element",
    "items",
    "target"
  ],
  "playwright:browser_verify_text_visible": [
    "text"
  ],
  "playwright:browser_verify_value": [
    "element",
    "target",
    "type",
    "value"
  ]
};

export const CODEGRAPH_TRUSTED_TOOLS = new Set([
  "codegraph_codegraph_explore"
]);

export const CONTEXT7_TRUSTED_TOOLS = new Set([
  "context7_query-docs",
  "context7_resolve-library-id"
]);

export const BRAVE_SEARCH_TRUSTED_TOOLS = new Set([
  "brave_search_brave_image_search",
  "brave_search_brave_llm_context",
  "brave_search_brave_local_search",
  "brave_search_brave_news_search",
  "brave_search_brave_place_search",
  "brave_search_brave_summarizer",
  "brave_search_brave_video_search",
  "brave_search_brave_web_search"
]);

export const FIRECRAWL_TRUSTED_TOOLS = new Set([
  "firecrawl_agent_status",
  "firecrawl_check_crawl_status",
  "firecrawl_developer_search",
  "firecrawl_extract",
  "firecrawl_map",
  "firecrawl_research_inspect_paper",
  "firecrawl_research_read_paper",
  "firecrawl_research_related_papers",
  "firecrawl_research_search_github",
  "firecrawl_research_search_papers",
  "firecrawl_scrape",
  "firecrawl_search"
]);

export const PLAYWRIGHT_TRUSTED_TOOLS = new Set([
  "browser_console_messages",
  "browser_find",
  "browser_generate_locator",
  "browser_network_request",
  "browser_network_requests",
  "browser_snapshot",
  "browser_tabs",
  "browser_verify_element_visible",
  "browser_verify_list_visible",
  "browser_verify_text_visible",
  "browser_verify_value",
  "browser_wait_for"
]);
// generated:mcp-runtime-policy:end
const MCP_CONDITIONAL_ARGUMENT_KEY_SETS: Record<string, ReadonlySet<string>> = Object.fromEntries(
  Object.entries(MCP_CONDITIONAL_ARGUMENTS).map(([tool, keys]) => [tool, new Set(keys)]),
);
const MCP_PROXY_EXECUTION_FIELDS = new Set(["server", "tool", "args"]);
const FIRECRAWL_SCRAPE_OPTION_KEYS = new Set([
  "formats", "jsonOptions", "queryOptions", "screenshotOptions", "parsers", "pdfOptions",
  "onlyMainContent", "redactPII", "includeTags", "excludeTags", "waitFor", "mobile",
  "skipTlsVerification", "removeBase64Images", "location", "storeInCache", "zeroDataRetention",
  "maxAge", "lockdown", "proxy",
]);
// `filename` writes a local artifact, so it stays approval-gated like screenshots.
const PLAYWRIGHT_SNAPSHOT_KEYS = new Set(["target", "depth", "boxes"]);
const PLAYWRIGHT_CONSOLE_MESSAGE_KEYS = new Set(["level", "all"]);
const PLAYWRIGHT_NETWORK_REQUESTS_KEYS = new Set(["static", "filter"]);
const PLAYWRIGHT_NETWORK_REQUEST_KEYS = new Set(["index", "part"]);
const PLAYWRIGHT_TABS_KEYS = new Set(["action"]);
const PLAYWRIGHT_VERIFY_ELEMENT_VISIBLE_KEYS = new Set(["accessibleName", "role"]);
const PLAYWRIGHT_VERIFY_LIST_VISIBLE_KEYS = new Set(["element", "items", "target"]);
const PLAYWRIGHT_VERIFY_TEXT_VISIBLE_KEYS = new Set(["text"]);
const PLAYWRIGHT_VERIFY_VALUE_KEYS = new Set(["element", "target", "type", "value"]);

export function normalizeServerId(value: string): string {
  return value.trim().toLowerCase().replace(/_/g, "-");
}

export function isManagedServer(server: string): boolean {
  return MANAGED_MCP_SERVERS.has(normalizeServerId(server));
}

type ManagedDirectMcpTool = { server: string; tool: string };

/** Parse Pi adapter names: mcp__<normalized_server>_<server_tool>. */
function managedDirectMcpTool(toolName: string): ManagedDirectMcpTool | undefined {
  if (!toolName.startsWith("mcp__")) return undefined;
  for (const server of [...MANAGED_MCP_SERVERS].sort((left, right) => right.length - left.length)) {
    const normalized = server.replace(/-/g, "_");
    for (const separator of ["__", "_"]) { // retain prior generated names for compatibility
      const prefix = `mcp__${normalized}${separator}`;
      if (toolName.startsWith(prefix) && toolName.slice(prefix.length)) {
        const tool = toolName.slice(prefix.length);
        return { server, tool };
      }
    }
  }
  return undefined;
}

/**
 * Strip adapter/namespace prefixes to get the server-local tool base name.
 * Examples:
 *   mcp__firecrawl__firecrawl_search -> firecrawl_search
 *   firecrawl_firecrawl_search -> firecrawl_search
 *   playwright_browser_click -> browser_click
 *   browser_click -> browser_click
 */
export function managedToolBaseName(toolName: string, server: string): string {
  let name = toolName;
  const direct = managedDirectMcpTool(name);
  if (direct) name = direct.tool;

  const serverUnderscore = server.replace(/-/g, "_");
  const repeated = `${serverUnderscore}_${serverUnderscore}_`;
  // Firecrawl's adapter prefix duplicates its public `firecrawl_` tool id.
  // Other managed tools retain their policy identifier unchanged.
  if (server === "firecrawl" && name.startsWith(repeated)) {
    return name.slice(serverUnderscore.length + 1);
  }
  const prefixed = `${serverUnderscore}_`;
  if (name.startsWith(prefixed)) {
    // firecrawl_search stays firecrawl_search; playwright_browser_click -> browser_click
    if (server === "playwright") {
      return name.slice(prefixed.length);
    }
    // firecrawl tools keep their firecrawl_ prefix as the public tool id
    if (server === "firecrawl" && name.startsWith("firecrawl_firecrawl_")) {
      return name.slice("firecrawl_".length);
    }
  }
  return name;
}

export function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

export function hasOnlyKeys(value: Record<string, unknown>, allowed: ReadonlySet<string>): boolean {
  return Object.keys(value).every((key) => allowed.has(key));
}

function isInteger(value: unknown): value is number {
  return Number.isInteger(value);
}

export function isPublicIpv4(host: string): boolean {
  const octets = host.split(".").map(Number);
  if (octets.length !== 4 || octets.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return false;
  const [a, b, c] = octets;
  return !(
    a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 0 && c === 0) ||
    (a === 192 && b === 0 && c === 2) ||
    (a === 192 && b === 168) ||
    (a === 198 && (b === 18 || b === 19)) ||
    (a === 198 && b === 51 && c === 100) ||
    (a === 203 && b === 0 && c === 113)
  );
}

export function ipv6Value(host: string): bigint | null {
  const normalized = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (isIP(normalized) !== 6) return null;
  const halves = normalized.split("::");
  if (halves.length > 2) return null;
  const parseHalf = (part: string): string[] => part ? part.split(":") : [];
  const left = parseHalf(halves[0]);
  const right = parseHalf(halves[1] || "");
  const expandIpv4 = (parts: string[]): string[] => {
    const last = parts.at(-1);
    if (!last || isIP(last) !== 4) return parts;
    const octets = last.split(".").map(Number);
    return [...parts.slice(0, -1), ((octets[0] << 8) | octets[1]).toString(16), ((octets[2] << 8) | octets[3]).toString(16)];
  };
  const expandedLeft = expandIpv4(left);
  const expandedRight = expandIpv4(right);
  const missing = 8 - expandedLeft.length - expandedRight.length;
  if ((halves.length === 1 && missing !== 0) || missing < 0) return null;
  const groups = [...expandedLeft, ...Array(missing).fill("0"), ...expandedRight];
  return groups.reduce((value, group) => (value << 16n) | BigInt(`0x${group || "0"}`), 0n);
}

export function isPublicIpv6(host: string): boolean {
  const value = ipv6Value(host);
  if (value === null || value === 0n || value === 1n) return false;
  if ((value >> 32n) === 0xffffn) return isPublicIpv4([
    Number((value >> 24n) & 255n), Number((value >> 16n) & 255n),
    Number((value >> 8n) & 255n), Number(value & 255n),
  ].join("."));
  return !(
    (value >> 121n) === 0x7en || // fc00::/7 unique-local
    (value >> 118n) === 0x3fan || // fe80::/10 link-local
    (value >> 120n) === 0xffn || // ff00::/8 multicast
    (value >> 96n) === 0x20010db8n || // documentation
    (value >> 32n) === 0n // IPv4-compatible and other special low addresses
  );
}

export function isSafeWebUrl(value: unknown): boolean {
  if (typeof value !== "string") return false;
  try {
    const parsed = new URL(value);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
    if (parsed.username || parsed.password) return false;
    const host = parsed.hostname.replace(/^\[|\]$/g, "").toLowerCase().replace(/\.$/, "");
    const ipVersion = isIP(host);
    if (ipVersion === 4) return isPublicIpv4(host);
    if (ipVersion === 6) return isPublicIpv6(host);
    if (!host.includes(".")) return false;
    return ![".localhost", ".local", ".internal", ".home", ".lan", ".test", ".invalid", ".example", ".onion"]
      .some((suffix) => host === suffix.slice(1) || host.endsWith(suffix));
  } catch {
    return false;
  }
}

export function isProjectConfinedPath(pathValue: unknown, requireFile = false): boolean {
  if (typeof pathValue !== "string" || !pathValue || isProtectedLocalPath(pathValue)) return false;
  try {
    const projectRoot = realpathSync(process.cwd());
    const target = realpathSync(pathValue);
    const projectRelative = relative(projectRoot, target);
    const confined = !isAbsolute(projectRelative) && projectRelative !== ".." &&
      !projectRelative.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`);
    return confined && (!requireFile || statSync(target).isFile());
  } catch {
    return false;
  }
}

export function isSafeFirecrawlScrapeOptions(input: Record<string, unknown>): boolean {
  return hasOnlyKeys(input, FIRECRAWL_SCRAPE_OPTION_KEYS) &&
    input.storeInCache !== true &&
    input.skipTlsVerification !== true;
}

export function isSafeFirecrawlSearch(input: Record<string, unknown>): boolean {
  return hasOnlyKeys(input, MCP_CONDITIONAL_ARGUMENT_KEY_SETS["firecrawl:firecrawl_search"]) &&
    typeof input.query === "string" && Boolean(input.query.trim()) &&
    isInteger(input.limit) && input.limit > 0 && input.limit <= 10 &&
    (input.scrapeOptions === undefined ||
      (isPlainObject(input.scrapeOptions) && isSafeFirecrawlScrapeOptions(input.scrapeOptions)));
}

export function isSafeFirecrawlMap(input: Record<string, unknown>): boolean {
  return hasOnlyKeys(input, MCP_CONDITIONAL_ARGUMENT_KEY_SETS["firecrawl:firecrawl_map"]) &&
    isSafeWebUrl(input.url) &&
    isInteger(input.limit) && input.limit > 0 && input.limit <= 100 &&
    input.includeSubdomains !== true;
}

export function isSafeFirecrawlExtract(input: Record<string, unknown>): boolean {
  return hasOnlyKeys(input, MCP_CONDITIONAL_ARGUMENT_KEY_SETS["firecrawl:firecrawl_extract"]) &&
    Array.isArray(input.urls) && input.urls.length > 0 && input.urls.length <= 10 &&
    input.urls.every(isSafeWebUrl) &&
    input.allowExternalLinks !== true && input.enableWebSearch !== true && input.includeSubdomains !== true;
}

export function isConditionallyTrustedTool(server: string, base: string, input: unknown): boolean {
  if (!isPlainObject(input)) return false;

  if (server === "firecrawl" && base === "firecrawl_search") {
    return isSafeFirecrawlSearch(input);
  }

  if (server === "firecrawl" && base === "firecrawl_scrape") {
    const { url, ...options } = input;
    return isSafeWebUrl(url) && isSafeFirecrawlScrapeOptions(options);
  }

  if (server === "firecrawl" && base === "firecrawl_map") {
    return isSafeFirecrawlMap(input);
  }

  if (server === "firecrawl" && base === "firecrawl_extract") {
    return isSafeFirecrawlExtract(input);
  }

  if (server === "playwright" && base === "browser_snapshot") {
    return hasOnlyKeys(input, PLAYWRIGHT_SNAPSHOT_KEYS);
  }

  if (server === "playwright" && base === "browser_console_messages") {
    return hasOnlyKeys(input, PLAYWRIGHT_CONSOLE_MESSAGE_KEYS);
  }

  if (server === "playwright" && base === "browser_network_requests") {
    return hasOnlyKeys(input, PLAYWRIGHT_NETWORK_REQUESTS_KEYS);
  }

  if (server === "playwright" && base === "browser_network_request") {
    return hasOnlyKeys(input, PLAYWRIGHT_NETWORK_REQUEST_KEYS);
  }

  if (server === "playwright" && base === "browser_tabs") {
    return hasOnlyKeys(input, PLAYWRIGHT_TABS_KEYS) && input.action === "list";
  }

  if (server === "playwright" && base === "browser_verify_element_visible") {
    return hasOnlyKeys(input, PLAYWRIGHT_VERIFY_ELEMENT_VISIBLE_KEYS);
  }

  if (server === "playwright" && base === "browser_verify_list_visible") {
    return hasOnlyKeys(input, PLAYWRIGHT_VERIFY_LIST_VISIBLE_KEYS);
  }

  if (server === "playwright" && base === "browser_verify_text_visible") {
    return hasOnlyKeys(input, PLAYWRIGHT_VERIFY_TEXT_VISIBLE_KEYS);
  }

  if (server === "playwright" && base === "browser_verify_value") {
    return hasOnlyKeys(input, PLAYWRIGHT_VERIFY_VALUE_KEYS);
  }

  return false;
}

/** Trust every classified policy-approved managed operation. */
export function isTrustedManagedTool(server: string, toolName: string, input?: unknown): boolean {
  if (!isManagedServer(server)) return false;
  const base = managedToolBaseName(toolName, server);
  if (MCP_CONDITIONAL_TOOLS.has(`${server}:${base}`)) {
    return isConditionallyTrustedTool(server, base, input);
  }
  if (server === "codegraph") return CODEGRAPH_TRUSTED_TOOLS.has(base);
  if (server === "context7") return CONTEXT7_TRUSTED_TOOLS.has(base);
  if (server === "brave-search") return BRAVE_SEARCH_TRUSTED_TOOLS.has(base);
  if (server === "firecrawl") return FIRECRAWL_TRUSTED_TOOLS.has(base);
  if (server === "playwright") return PLAYWRIGHT_TRUSTED_TOOLS.has(base);
  return false;
}

/** Parse an `mcp` gateway call without accepting selector mixtures or JSON primitives. */
export function gatewayArgs(value: unknown): Record<string, unknown> | undefined {
  if (value === undefined) return {};
  if (isPlainObject(value)) return value;
  if (typeof value !== "string") return undefined;
  try {
    const parsed: unknown = JSON.parse(value);
    return isPlainObject(parsed) ? parsed : undefined;
  } catch {
    return undefined;
  }
}

export function gatewayToolMatchesServer(server: string, toolName: string): boolean {
  const direct = managedDirectMcpTool(toolName);
  return !toolName.startsWith("mcp__") || direct?.server === server;
}

/** Return true only for an explicitly targeted adapter proxy execution. */
type McpProxyToolExecution = { server: string; tool: string; args?: unknown };

export function isMcpProxyToolExecution(input: unknown): input is McpProxyToolExecution {
  if (!isPlainObject(input)) return false;
  if (!Object.keys(input).every((key) => MCP_PROXY_EXECUTION_FIELDS.has(key))) return false;
  if (typeof input.server !== "string" || input.server.trim() === "") return false;
  if (typeof input.tool !== "string" || input.tool.trim() === "") return false;
  return gatewayArgs(input.args) !== undefined;
}

/**
 * A gateway name shares Pi's custom-tool namespace, so auto-allow only an
 * unambiguous call to an explicitly classified managed operation.
 */
export function isTrustedManagedGatewayCall(input: unknown): boolean {
  if (!isMcpProxyToolExecution(input)) return false;
  const server = normalizeServerId(input.server);
  const args = gatewayArgs(input.args);
  return args !== undefined && isManagedServer(server) &&
    gatewayToolMatchesServer(server, input.tool) &&
    isTrustedManagedTool(server, input.tool, args);
}

/** Return true only for a classified direct CodeGraph tool in its own namespace. */
function isDirectClassifiedManagedTool(toolName: string, input: unknown, server: "codegraph"): boolean {
  if (toolName.startsWith("mcp__")) {
    if (managedDirectMcpTool(toolName)?.server !== server) return false;
  } else {
    const namespace = `${server.replace(/-/g, "_")}_`;
    if (!toolName.startsWith(namespace)) return false;
  }
  const base = managedToolBaseName(toolName, server);
  return isTrustedManagedTool(server, base, input);
}

/** Return true only for the exact, local-only preview_markdown tool shape. */
export function isTrustedPreviewMarkdownCall(input: unknown): boolean {
  if (!isPlainObject(input)) return false;
  const keys = Object.keys(input);
  if (!keys.every((key) => key === "markdown" || key === "title")) return false;
  if (typeof input.markdown !== "string") return false;
  return input.title === undefined || typeof input.title === "string";
}

/** Returns true when the top-level tool call needs the custom/MCP approval prompt. */
export function isMcpOrCustomTool(toolName: string, input?: unknown): boolean {
  if (SPECIALIZED_TOOLS.has(toolName)) return false;
  if (toolName === "preview_markdown" && isTrustedPreviewMarkdownCall(input)) return false;
  // Only explicit adapter proxy executions reach the broker; metadata and
  // lifecycle selectors remain behind the generic custom-tool approval gate.
  if (toolName === "mcp") return !isMcpProxyToolExecution(input);
  if (isDirectClassifiedManagedTool(toolName, input, "codegraph")) return false;
  // Other direct tool names remain ambiguous with custom extensions.
  return true;
}

export function approvalPreview(value: unknown): string {
  let serialized: string;
  try {
    serialized = JSON.stringify(value ?? {}, null, 2);
  } catch {
    serialized = "[unserializable arguments]";
  }
  const sanitized = serialized.replace(/[\u0000-\u001F\u007F-\u009F]/g, " ");
  return sanitized.length > 700 ? `${sanitized.slice(0, 700)}...` : sanitized;
}

export function approvalLabel(value: string): string {
  return value.replace(/[\u0000-\u001F\u007F-\u009F]/g, " ");
}

export async function brokerApprovalDecision(
  request: McpToolApprovalRequest,
  context: Pick<ExtensionContext, "hasUI" | "ui"> | undefined,
): Promise<McpToolApprovalDecision> {
  const server = normalizeServerId(request.serverName);
  if (isTrustedManagedTool(server, request.originalToolName, request.args)) {
    return "allow_once";
  }
  if (isAutoModeEnabled()) {
    return "allow_once";
  }
  if (!context?.hasUI) {
    return "deny";
  }

  const choice = await context.ui.select(
    `b-agentic approval: ${approvalLabel(server)} wants to run ${approvalLabel(request.originalToolName)}` +
      ` (${approvalLabel(request.origin)})\n\nArguments:\n${approvalPreview(request.args)}`,
    ["Allow once", "Allow for session", "Deny"],
    request.signal === undefined ? undefined : { signal: request.signal },
  );
  if (choice === "Allow once") return "allow_once";
  if (choice === "Allow for session") return "allow_for_session";
  return "deny";
}

export function isMcpToolApprovalRequest(value: unknown): value is McpToolApprovalRequest {
  if (!isPlainObject(value)) return false;
  return (
    typeof value.serverName === "string" &&
    typeof value.originalToolName === "string" &&
    typeof value.prefixedToolName === "string" &&
    isPlainObject(value.args) &&
    typeof value.origin === "string" &&
    typeof value.claim === "function"
  );
}

export async function confirmOrBlock(
  ctx: { hasUI: boolean; ui: { confirm: (title: string, message: string) => Promise<boolean> } },
  title: string,
  message: string,
  reason: string,
): Promise<{ block: true; reason: string } | undefined> {
  if (!ctx.hasUI) {
    return { block: true, reason: `${reason} (no UI; fail-closed)` };
  }
  const ok = await ctx.ui.confirm(title, message);
  if (!ok) {
    return { block: true, reason: `${reason} (denied by user)` };
  }
  return undefined;
}
