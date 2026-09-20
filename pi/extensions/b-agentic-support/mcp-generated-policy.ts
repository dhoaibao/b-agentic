/** Generated from references/mcp_operations.yaml. Do not edit; regenerate with tooling/generate/registry_sync.py. */
// prettier-ignore
export const MANAGED_MCP_SERVERS = new Set([
  "brave-search",
  "codegraph",
  "context7",
  "firecrawl",
  "mobbin",
  "playwright",
  "shadcn"
]);

/** Operations autonomous only for a validated safe argument shape. */
// prettier-ignore
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
// prettier-ignore
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

// prettier-ignore
export const CODEGRAPH_TRUSTED_TOOLS = new Set([
  "codegraph_codegraph_explore"
]);

// prettier-ignore
export const CONTEXT7_TRUSTED_TOOLS = new Set([
  "context7_query-docs",
  "context7_resolve-library-id"
]);

// prettier-ignore
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

// prettier-ignore
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

// prettier-ignore
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

// prettier-ignore
export const MOBBIN_TRUSTED_TOOLS = new Set([
  "mobbin_search_flows",
  "mobbin_search_screens",
  "mobbin_search_sections"
]);

// prettier-ignore
export const SHADCN_TRUSTED_TOOLS = new Set([
  "shadcn_get_add_command_for_items",
  "shadcn_get_audit_checklist",
  "shadcn_get_item_examples_from_registries",
  "shadcn_get_project_registries",
  "shadcn_list_items_in_registries",
  "shadcn_search_items_in_registries",
  "shadcn_view_items_in_registries"
]);
