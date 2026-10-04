// Test-only extension for tests/pi/openai-fast-mode-probe.sh. At session start it
// exercises pi/extensions/b-openai-fast-mode.ts (config parsing, eligibility, payload
// injection, and the Pi wiring through a fake ExtensionAPI) and writes one JSON result
// per case to $PROBE_OUT.
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import fastMode, {
  DEFAULT_MODELS,
  isEligible,
  parseConfig,
  TIER,
  withTier,
} from "../../pi/extensions/b-openai-fast-mode.ts";

const results: Record<string, unknown> = {};
const check = (name: string, got: unknown, want: unknown) => {
  results[name] =
    JSON.stringify(got) === JSON.stringify(want) ? "ok" : { got, want };
};

type Handler = (event: any, ctx: any) => any;

function wire() {
  const events: Record<string, Handler> = {};
  const commands: Record<string, { handler: Handler }> = {};
  const fake = {
    on: (name: string, handler: Handler) => {
      events[name] = handler;
    },
    registerCommand: (name: string, options: { handler: Handler }) => {
      commands[name] = options;
    },
  } as unknown as ExtensionAPI;
  fastMode(fake);
  return { events, commands };
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    const out = process.env.PROBE_OUT;
    const work = process.env.PROBE_WORK;
    if (!out || !work) return;
    mkdirSync(path.dirname(out), { recursive: true });
    const configFile = path.join(
      process.env.PI_CODING_AGENT_DIR ?? "",
      "openai-fast-mode.json",
    );
    void work;

    // parseConfig: defaults, malformed input, custom list.
    check("parse undefined", parseConfig(undefined), {
      active: false,
      models: DEFAULT_MODELS,
    });
    check("parse junk", parseConfig("x"), {
      active: false,
      models: DEFAULT_MODELS,
    });
    check("parse active string", parseConfig({ active: "true" }).active, false);
    check("parse custom", parseConfig({ active: true, models: ["m1"] }), {
      active: true,
      models: ["m1"],
    });
    check(
      "parse empty list",
      parseConfig({ models: [] }).models,
      DEFAULT_MODELS,
    );
    check(
      "parse bad list",
      parseConfig({ models: [1] }).models,
      DEFAULT_MODELS,
    );
    check("default has target", DEFAULT_MODELS.includes("gpt-6.1-sol"), true);

    // isEligible: API and id both required.
    const cfg = parseConfig(undefined);
    const resp = (id: string, api = "openai-responses") => ({ api, id });
    check("eligible responses", isEligible(resp("gpt-6.1-sol"), cfg), true);
    check(
      "eligible codex",
      isEligible(resp("gpt-5.5", "openai-codex-responses"), cfg),
      true,
    );
    check("not eligible mini", isEligible(resp("gpt-5.4-mini"), cfg), false);
    check(
      "not eligible api",
      isEligible(resp("gpt-6.1-sol", "openai-completions"), cfg),
      false,
    );
    check(
      "not eligible anthropic",
      isEligible(resp("gpt-6.1-sol", "anthropic-messages"), cfg),
      false,
    );
    check("not eligible none", isEligible(undefined, cfg), false);

    // withTier: copies objects, gates on the request's own model, ignores non-objects.
    const payload = { model: "gpt-6.1-sol", input: [] };
    check("tier added", withTier(payload, cfg), {
      ...payload,
      service_tier: TIER,
    });
    check("tier input untouched", payload, {
      model: "gpt-6.1-sol",
      input: [],
    });
    check(
      "tier unsupported payload model",
      withTier({ model: "gpt-5.4-mini", input: [] }, cfg),
      undefined,
    );
    check(
      "tier missing payload model",
      withTier({ input: [] }, cfg),
      undefined,
    );
    check("tier non-string model", withTier({ model: 1 }, cfg), undefined);
    check("tier null", withTier(null, cfg), undefined);
    check("tier array", withTier([], cfg), undefined);
    check("tier string", withTier("x", cfg), undefined);
    check("tier value", TIER, "priority");

    // Wiring through a fake Pi API, with the config file isolated by PI_CODING_AGENT_DIR.
    const notes: string[] = [];
    const cmdCtx = (model: unknown) => ({
      model,
      ui: { notify: (message: string) => notes.push(message) },
    });
    const sol = {
      provider: "openai",
      id: "gpt-6.1-sol",
      api: "openai-responses",
    };
    const miniPayload = { model: "gpt-5.4-mini", input: [] };
    const mini = {
      provider: "openai",
      id: "gpt-5.4-mini",
      api: "openai-responses",
    };
    const { events, commands } = wire();
    check("wiring registers /fast", Object.keys(commands), ["fast"]);
    check("wiring hooks", Object.keys(events).sort(), [
      "before_provider_request",
      "session_start",
    ]);

    const request = events.before_provider_request;
    check("off by default", request({ payload }, { model: sol }), undefined);

    await commands.fast.handler("on", cmdCtx(sol));
    check(
      "on persisted",
      JSON.parse(readFileSync(configFile, "utf8")).active,
      true,
    );
    check("on injects", request({ payload }, { model: sol }), {
      ...payload,
      service_tier: TIER,
    });
    check("on skips mini", request({ payload }, { model: mini }), undefined);
    check(
      "on skips redirected payload model",
      request({ payload: miniPayload }, { model: sol }),
      undefined,
    );
    check(
      "on skips no model",
      request({ payload }, { model: undefined }),
      undefined,
    );
    check(
      "on skips bad payload",
      request({ payload: null }, { model: sol }),
      undefined,
    );
    await commands.fast.handler("status", cmdCtx(sol));
    const status = notes.at(-1) ?? "";
    check(
      "status reports",
      /ON/.test(status) && /Eligible: yes/.test(status),
      true,
    );
    check("status counts", /injected this session: 1/.test(status), true);
    check(
      "status is read-only",
      JSON.parse(readFileSync(configFile, "utf8")).active,
      true,
    );

    await commands.fast.handler("", cmdCtx(sol));
    check(
      "toggle off",
      JSON.parse(readFileSync(configFile, "utf8")).active,
      false,
    );
    check(
      "off injects nothing",
      request({ payload }, { model: sol }),
      undefined,
    );

    await commands.fast.handler("bogus", cmdCtx(sol));
    check("usage message", /Usage/.test(notes.at(-1) ?? ""), true);
    check(
      "bogus keeps state",
      JSON.parse(readFileSync(configFile, "utf8")).active,
      false,
    );

    // Persisted custom model list survives a toggle and a restart.
    writeFileSync(
      configFile,
      JSON.stringify({ active: true, models: ["gpt-5.4-mini"] }),
    );
    const second = wire();
    second.events.session_start({}, {});
    check(
      "custom list used",
      second.events.before_provider_request(
        { payload: miniPayload },
        { model: mini },
      ),
      { ...miniPayload, service_tier: TIER },
    );
    check(
      "custom list rejects other payload model",
      second.events.before_provider_request({ payload }, { model: mini }),
      undefined,
    );
    check(
      "custom list excludes default",
      second.events.before_provider_request({ payload }, { model: sol }),
      undefined,
    );
    await second.commands.fast.handler("off", cmdCtx(mini));
    check(
      "toggle keeps models",
      JSON.parse(readFileSync(configFile, "utf8")).models,
      ["gpt-5.4-mini"],
    );

    // A failed save leaves state unchanged and never enables injection.
    rmSync(configFile, { force: true });
    mkdirSync(configFile);
    const failing = wire();
    await failing.commands.fast.handler("on", cmdCtx(sol));
    check(
      "save failure notified",
      /Could not save/.test(notes.at(-1) ?? ""),
      true,
    );
    check(
      "save failure says unchanged",
      /unchanged \(OFF\)/.test(notes.at(-1) ?? ""),
      true,
    );
    check(
      "save failure does not inject",
      failing.events.before_provider_request({ payload }, { model: sol }),
      undefined,
    );
    rmSync(configFile, { recursive: true, force: true });

    // A corrupt file falls back to off and defaults.
    writeFileSync(configFile, "{not json");
    const third = wire();
    check(
      "corrupt file is off",
      third.events.before_provider_request({ payload }, { model: sol }),
      undefined,
    );

    // The probe script requires a minimum count: an empty or partial run must not pass.
    results._count = Object.keys(results).length;
    writeFileSync(out, JSON.stringify(results, null, 1));
  });
}
