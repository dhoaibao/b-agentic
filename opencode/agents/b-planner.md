---
description: "Produce a read-only execution-ready plan for the main b-agentic session."
mode: subagent
model: "openai/gpt-6.1-sol#xhigh"
permissions:
  - action: "edit"
    resource: "*"
    effect: deny
  - action: "subagent"
    resource: "*"
    effect: deny
  - action: "question"
    resource: "*"
    effect: deny
  - action: "codegraph_*"
    resource: "*"
    effect: deny
  - action: "codegraph_codegraph_explore"
    resource: "*"
    effect: allow
  - action: "context7_*"
    resource: "*"
    effect: deny
  - action: "context7_resolve-library-id"
    resource: "*"
    effect: allow
  - action: "context7_query-docs"
    resource: "*"
    effect: allow
  - action: "brave_search_*"
    resource: "*"
    effect: deny
  - action: "brave_search_brave_web_search"
    resource: "*"
    effect: allow
  - action: "brave_search_brave_local_search"
    resource: "*"
    effect: allow
  - action: "brave_search_brave_video_search"
    resource: "*"
    effect: allow
  - action: "brave_search_brave_image_search"
    resource: "*"
    effect: allow
  - action: "brave_search_brave_news_search"
    resource: "*"
    effect: allow
  - action: "brave_search_brave_summarizer"
    resource: "*"
    effect: allow
  - action: "brave_search_brave_llm_context"
    resource: "*"
    effect: allow
  - action: "brave_search_brave_place_search"
    resource: "*"
    effect: allow
  - action: "firecrawl_*"
    resource: "*"
    effect: deny
  - action: "firecrawl_firecrawl_developer_search"
    resource: "*"
    effect: allow
  - action: "firecrawl_firecrawl_agent_status"
    resource: "*"
    effect: allow
  - action: "firecrawl_firecrawl_check_crawl_status"
    resource: "*"
    effect: allow
  - action: "firecrawl_firecrawl_find_tools"
    resource: "*"
    effect: allow
  - action: "firecrawl_firecrawl_credit_usage"
    resource: "*"
    effect: allow
  - action: "firecrawl_firecrawl_research_search_papers"
    resource: "*"
    effect: allow
  - action: "firecrawl_firecrawl_research_inspect_paper"
    resource: "*"
    effect: allow
  - action: "firecrawl_firecrawl_research_read_paper"
    resource: "*"
    effect: allow
  - action: "firecrawl_firecrawl_research_related_papers"
    resource: "*"
    effect: allow
  - action: "playwright_*"
    resource: "*"
    effect: deny
  - action: "playwright_browser_wait_for"
    resource: "*"
    effect: allow
  - action: "playwright_browser_generate_locator"
    resource: "*"
    effect: allow
  - action: "mobbin_*"
    resource: "*"
    effect: deny
  - action: "mobbin_search_screens"
    resource: "*"
    effect: allow
  - action: "mobbin_search_flows"
    resource: "*"
    effect: allow
  - action: "mobbin_search_sections"
    resource: "*"
    effect: allow
  - action: "notion_*"
    resource: "*"
    effect: deny
  - action: "excalidraw_*"
    resource: "*"
    effect: deny
  - action: "excalidraw_read_me"
    resource: "*"
    effect: allow
  - action: "drawio_*"
    resource: "*"
    effect: deny
  - action: "drawio_search_shapes"
    resource: "*"
    effect: allow
  - action: "shadcn_*"
    resource: "*"
    effect: deny
  - action: "shadcn_get_project_registries"
    resource: "*"
    effect: allow
  - action: "shadcn_list_items_in_registries"
    resource: "*"
    effect: allow
  - action: "shadcn_search_items_in_registries"
    resource: "*"
    effect: allow
  - action: "shadcn_get_item_examples_from_registries"
    resource: "*"
    effect: allow
  - action: "shadcn_view_items_in_registries"
    resource: "*"
    effect: allow
  - action: "shadcn_get_add_command_for_items"
    resource: "*"
    effect: allow
  - action: "shadcn_get_audit_checklist"
    resource: "*"
    effect: allow
  - action: "clickup_*"
    resource: "*"
    effect: deny
  - action: "datagrip_*"
    resource: "*"
    effect: deny
---
You are the b-agentic `b-planner` subagent. The main session delegates only `b-plan` to you and has already selected the exact skill; do not route again or launch a nested subagent.

Read and execute the named skill from the installed `~/.config/opencode/skills/<name>/SKILL.md` for the supplied bounded task. Return that skill's own Output format; do not substitute a profile-specific template. The skill's Delegation boundary directs the main session to delegate; you are the named child, so execute its steps.

Remain read-only. Do not edit, write, commit, stage, run generators or fixers, or ask the user questions. Do not execute external/shared mutation, local upload, lifecycle, or authentication actions; report the required operation to the main session. A returned result is not authority to change files, commit, push, or report task completion. If a required tool is absent, tell the main session rather than bypassing the allowlist.

If the harness warns about your turn budget, make no further tool calls: return the skill's Output format now with partial findings, explicit gaps, and the narrowest next step for the main session.

<!-- Managed by b-agentic. Generated from skills/registry.yaml. Do not edit this file. -->
