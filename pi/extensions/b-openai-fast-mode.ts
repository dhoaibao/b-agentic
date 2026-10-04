// b-agentic OpenAI Fast mode: opt-in `service_tier: "priority"` for OpenAI Responses
// requests, limited to models known to support it.
//
// - Commands: `/openai-fastmode` opens an On/Off picker (no typing arguments) and `/openai-fastmode:status`
//   shows the state. Under an OpenAI Responses model the footer shows the state too.
//   The state is read from the file at session start and after each picker choice; an
//   edit made outside Pi takes effect on the next session, not mid-session.
// - Off by default. The on/off choice persists in `<agentDir>/openai-fast-mode.json`
//   (user-owned, never overwritten by the installer):
//     { "active": false, "models": ["gpt-6.1-sol"] }
//   `models` replaces the built-in supported list when present and valid.
// - Touches only requests whose model API is `openai-responses` or
//   `openai-codex-responses` and whose model id is in the supported list. Every other
//   provider, model, and request is passed through unchanged.
// - Fast mode costs more (2x API price; 2.5x ChatGPT-plan limits on newer models).
//   Pi's pi-ai applies the cost multiplier from the response `service_tier`, so a
//   footer cost that does not rise suggests a gateway stripped the field.
// - It does not fire for context compaction requests in some Pi versions; those run
//   at standard speed.
//
// Set PI_OPENAI_FAST_MODE=off to disable it without removing the file.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

export const TIER = "priority";
export const FAST_APIS: ReadonlySet<string> = new Set([
  "openai-responses",
  "openai-codex-responses",
]);
export const DEFAULT_MODELS: readonly string[] = [
  "gpt-6.1-sol",
  "gpt-6-astra",
  "gpt-6-sol",
  "gpt-6-luna",
  "gpt-5.6-sol",
  "gpt-5.6-terra",
  "gpt-5.6-luna",
  "gpt-5.5",
];

export interface FastConfig {
  active: boolean;
  models: readonly string[];
}

/** Parse the persisted state; any malformed input falls back to defaults (off). */
export function parseConfig(raw: unknown): FastConfig {
  const value =
    raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const models = value.models;
  const valid =
    Array.isArray(models) &&
    models.length > 0 &&
    models.every((m) => typeof m === "string" && m.length > 0);
  return {
    active: value.active === true,
    models: valid ? (models as string[]) : DEFAULT_MODELS,
  };
}

/** True only for a supported model on an OpenAI Responses API. */
export function isEligible(
  model: { api: string; id: string } | undefined,
  config: FastConfig,
): boolean {
  return (
    !!model && FAST_APIS.has(model.api) && config.models.includes(model.id)
  );
}

/**
 * Return a copy of the outgoing payload with the tier set, or undefined to leave it
 * as is. The request's own `model` field is checked, not just the selected session
 * model, because an earlier hook may already have rewritten the payload.
 */
export function withTier(
  payload: unknown,
  config: FastConfig,
): Record<string, unknown> | undefined {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return undefined;
  }
  const body = payload as Record<string, unknown>;
  if (typeof body.model !== "string" || !config.models.includes(body.model)) {
    return undefined;
  }
  return { ...body, service_tier: TIER };
}

export const STATUS_KEY = "b-openai-fast-mode";

type ModelLike = { api: string; id: string; provider?: string } | undefined;

/**
 * Footer text, shown only while an OpenAI Responses model is selected: on/off for a
 * supported model, "n/a" for an OpenAI model outside the supported list.
 */
export function footerStatus(
  model: ModelLike,
  config: FastConfig,
): string | undefined {
  if (!model || !FAST_APIS.has(model.api)) return undefined;
  if (!isEligible(model, config)) return "Fast: n/a";
  return config.active ? "⚡ Fast: on" : "Fast: off";
}

export function statusReport(
  model: ModelLike,
  config: FastConfig,
  injected: number,
): string {
  return [
    `OpenAI Fast mode: ${config.active ? "ON" : "OFF"} (tier ${TIER})`,
    `Model: ${model ? `${model.provider ?? "?"}/${model.id} (${model.api})` : "none"}`,
    `Eligible: ${isEligible(model, config) ? "yes" : "no"}`,
    `Requests injected this session: ${injected}`,
    `Supported: ${config.models.join(", ")}`,
    "Note: the provider must honor service_tier; check the footer cost or the response tier.",
  ].join("\n");
}

function configPath(): string {
  return join(getAgentDir(), "openai-fast-mode.json");
}

function load(): FastConfig {
  try {
    const path = configPath();
    return existsSync(path)
      ? parseConfig(JSON.parse(readFileSync(path, "utf8")))
      : parseConfig(undefined);
  } catch {
    return parseConfig(undefined);
  }
}

function save(config: FastConfig): void {
  writeFileSync(configPath(), `${JSON.stringify(config, null, 2)}\n`, "utf8");
}

export default function (pi: ExtensionAPI) {
  if (process.env.PI_OPENAI_FAST_MODE === "off") return;

  let config = load();
  let injected = 0;

  const refresh = (ctx: ExtensionContext, model: ModelLike) => {
    if (!ctx.hasUI) return;
    const text = footerStatus(model, config);
    // Red while Fast mode is actually on (it costs more); other states keep the default style.
    const on = text !== undefined && config.active && isEligible(model, config);
    ctx.ui.setStatus(
      STATUS_KEY,
      text !== undefined && on ? ctx.ui.theme.fg("error", text) : text,
    );
  };

  pi.on("session_start", (_event, ctx) => {
    config = load();
    injected = 0;
    refresh(ctx, ctx.model);
  });

  pi.on("model_select", (event, ctx) => {
    refresh(ctx, event.model);
  });

  pi.on("before_provider_request", (event, ctx) => {
    if (!config.active || !isEligible(ctx.model, config)) return undefined;
    const next = withTier(event.payload, config);
    if (!next) return undefined;
    injected += 1;
    return next;
  });

  pi.registerCommand("openai-fastmode", {
    description: "Choose OpenAI Fast mode on or off",
    handler: async (_args, ctx) => {
      if (!ctx.hasUI) {
        ctx.ui.notify(
          "/openai-fastmode needs an interactive session; use /openai-fastmode:status.",
          "warning",
        );
        return;
      }
      const current = load().active;
      const choice = await ctx.ui.select(
        `OpenAI Fast mode (currently ${current ? "ON" : "OFF"}, costs more)`,
        ["On", "Off"],
      );
      if (choice !== "On" && choice !== "Off") return;
      // Publish the new state only after it is persisted, so a failed save never
      // leaves the in-memory state (and billing) differing from the file.
      const next: FastConfig = { ...load(), active: choice === "On" };
      try {
        save(next);
      } catch (error) {
        ctx.ui.notify(
          `Could not save ${configPath()}; Fast mode unchanged (${config.active ? "ON" : "OFF"}): ${String(error)}`,
          "error",
        );
        return;
      }
      config = next;
      refresh(ctx, ctx.model);
      ctx.ui.notify(statusReport(ctx.model, config, injected), "info");
    },
  });

  pi.registerCommand("openai-fastmode:status", {
    description: "Show OpenAI Fast mode status",
    handler: async (_args, ctx) => {
      // Read-only: reports the in-memory state; it never reloads the file.
      refresh(ctx, ctx.model);
      ctx.ui.notify(statusReport(ctx.model, config, injected), "info");
    },
  });
}
