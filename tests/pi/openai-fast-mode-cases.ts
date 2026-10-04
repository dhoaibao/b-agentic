// Test-only extension for tests/pi/openai-fast-mode-probe.sh. At session start it
// exercises pi/extensions/b-openai-fast-mode.ts (config parsing, eligibility, payload
// injection, and the Pi wiring through a fake ExtensionAPI) and writes one JSON result
// per case to $PROBE_OUT.
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import fastMode, {
  DEFAULT_MODELS,
  footerStatus,
  isEligible,
  parseConfig,
  STATUS_KEY,
  statusReport,
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

    // Pure status helpers.
    const solModel = {
      provider: "openai",
      id: "gpt-6.1-sol",
      api: "openai-responses",
    };
    const miniModel = {
      provider: "openai",
      id: "gpt-5.4-mini",
      api: "openai-responses",
    };
    const claude = {
      provider: "anthropic",
      id: "claude-opus-5-5",
      api: "anthropic-messages",
    };
    const on = { ...cfg, active: true };
    check("footer off", footerStatus(solModel, cfg), "Fast: off");
    check("footer on", footerStatus(solModel, on), "⚡ Fast: on");
    check(
      "footer unsupported openai",
      footerStatus(miniModel, on),
      "Fast: n/a",
    );
    check("footer non-openai hidden", footerStatus(claude, on), undefined);
    check("footer no model hidden", footerStatus(undefined, on), undefined);
    check(
      "report on",
      /ON/.test(statusReport(solModel, on, 3)) &&
        /injected this session: 3/.test(statusReport(solModel, on, 3)),
      true,
    );
    check(
      "report eligible",
      /Eligible: yes/.test(statusReport(solModel, on, 0)),
      true,
    );
    check(
      "report not eligible",
      /Eligible: no/.test(statusReport(miniModel, on, 0)),
      true,
    );
    check(
      "report no model",
      /Model: none/.test(statusReport(undefined, cfg, 0)),
      true,
    );

    // Wiring through a fake Pi API, with the config file isolated by PI_CODING_AGENT_DIR.
    const notes: string[] = [];
    const statuses: Record<string, string | undefined> = {};
    const prompts: string[] = [];
    let choice: string | undefined;
    const makeCtx = (model: unknown, hasUI = true) => ({
      model,
      hasUI,
      ui: {
        theme: { fg: (color: string, text: string) => `<${color}>${text}` },
        notify: (message: string) => notes.push(message),
        setStatus: (key: string, text: string | undefined) => {
          statuses[key] = text;
        },
        select: async (title: string, options: string[]) => {
          prompts.push(`${title}|${options.join(",")}`);
          return choice;
        },
      },
    });
    const sol = {
      provider: "openai",
      id: "gpt-6.1-sol",
      api: "openai-responses",
    };
    const mini = {
      provider: "openai",
      id: "gpt-5.4-mini",
      api: "openai-responses",
    };
    const miniPayload = { model: "gpt-5.4-mini", input: [] };
    const { events, commands } = wire();
    check("wiring registers commands", Object.keys(commands).sort(), [
      "openai-fastmode",
      "openai-fastmode:status",
    ]);
    check("wiring hooks", Object.keys(events).sort(), [
      "before_provider_request",
      "model_select",
      "session_start",
    ]);

    const request = events.before_provider_request;
    events.session_start({}, makeCtx(sol));
    check("start footer off", statuses[STATUS_KEY], "Fast: off");
    check("off by default", request({ payload }, makeCtx(sol)), undefined);

    // Picker: cancel changes nothing; On persists and shows the footer.
    choice = undefined;
    await commands["openai-fastmode"].handler("", makeCtx(sol));
    check("cancel keeps off", request({ payload }, makeCtx(sol)), undefined);
    check(
      "picker title and options",
      prompts.at(-1),
      "OpenAI Fast mode (currently OFF, costs more)|On,Off",
    );
    choice = "On";
    await commands["openai-fastmode"].handler("ignored args", makeCtx(sol));
    check(
      "on persisted",
      JSON.parse(readFileSync(configFile, "utf8")).active,
      true,
    );
    check("on footer is red", statuses[STATUS_KEY], "<error>⚡ Fast: on");
    check("on notifies status", /ON/.test(notes.at(-1) ?? ""), true);
    check("on injects", request({ payload }, makeCtx(sol)), {
      ...payload,
      service_tier: TIER,
    });
    check("on skips mini", request({ payload }, makeCtx(mini)), undefined);
    check(
      "on skips redirected payload model",
      request({ payload: miniPayload }, makeCtx(sol)),
      undefined,
    );
    check(
      "on skips no model",
      request({ payload }, makeCtx(undefined)),
      undefined,
    );
    check(
      "on skips bad payload",
      request({ payload: null }, makeCtx(sol)),
      undefined,
    );

    // Model switches update the footer.
    events.model_select({ model: mini }, makeCtx(mini));
    check("footer n/a on mini", statuses[STATUS_KEY], "Fast: n/a");
    events.model_select(
      { model: { provider: "anthropic", id: "x", api: "anthropic-messages" } },
      makeCtx(sol),
    );
    check("footer cleared off OpenAI", statuses[STATUS_KEY], undefined);
    events.model_select({ model: sol }, makeCtx(sol));
    check("footer back on", statuses[STATUS_KEY], "<error>⚡ Fast: on");

    // /openai-fastmode:status is read-only and reports counts.
    await commands["openai-fastmode:status"].handler("", makeCtx(sol));
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

    // Status never reloads the file: an outside edit does not change the live state.
    writeFileSync(configFile, JSON.stringify({ active: false }));
    await commands["openai-fastmode:status"].handler("", makeCtx(sol));
    check("status keeps live state", /ON/.test(notes.at(-1) ?? ""), true);
    check("status keeps injecting", request({ payload }, makeCtx(sol)), {
      ...payload,
      service_tier: TIER,
    });
    check(
      "status leaves file alone",
      JSON.parse(readFileSync(configFile, "utf8")).active,
      false,
    );
    writeFileSync(configFile, JSON.stringify({ active: true }));
    // Without a UI, model switches do not touch the footer.
    statuses[STATUS_KEY] = "sentinel";
    events.model_select({ model: mini }, makeCtx(mini, false));
    check("model_select no UI untouched", statuses[STATUS_KEY], "sentinel");
    statuses[STATUS_KEY] = "⚡ Fast: on";

    // Picker Off persists; the picker reflects the current state.
    choice = "Off";
    await commands["openai-fastmode"].handler("", makeCtx(sol));
    check(
      "picker shows current ON",
      prompts.at(-1)?.includes("currently ON"),
      true,
    );
    check(
      "off persisted",
      JSON.parse(readFileSync(configFile, "utf8")).active,
      false,
    );
    check("off footer", statuses[STATUS_KEY], "Fast: off");
    check("off injects nothing", request({ payload }, makeCtx(sol)), undefined);

    // An unexpected picker value changes nothing.
    choice = "Maybe";
    await commands["openai-fastmode"].handler("", makeCtx(sol));
    check(
      "bogus choice keeps state",
      JSON.parse(readFileSync(configFile, "utf8")).active,
      false,
    );

    // Without a UI the picker is not shown and nothing changes.
    const promptCount = prompts.length;
    choice = "On";
    await commands["openai-fastmode"].handler("", makeCtx(sol, false));
    check("no UI no picker", prompts.length, promptCount);
    check(
      "no UI keeps state",
      JSON.parse(readFileSync(configFile, "utf8")).active,
      false,
    );
    check("no UI explains", /interactive/.test(notes.at(-1) ?? ""), true);
    events.session_start({}, makeCtx(sol, false));
    check("no UI footer untouched", statuses[STATUS_KEY], "Fast: off");

    // Persisted custom model list survives a toggle and a restart.
    writeFileSync(
      configFile,
      JSON.stringify({ active: true, models: ["gpt-5.4-mini"] }),
    );
    const second = wire();
    second.events.session_start({}, makeCtx(mini));
    check("custom list footer", statuses[STATUS_KEY], "<error>⚡ Fast: on");
    check(
      "custom list used",
      second.events.before_provider_request(
        { payload: miniPayload },
        makeCtx(mini),
      ),
      { ...miniPayload, service_tier: TIER },
    );
    check(
      "custom list rejects other payload model",
      second.events.before_provider_request({ payload }, makeCtx(mini)),
      undefined,
    );
    check(
      "custom list excludes default",
      second.events.before_provider_request({ payload }, makeCtx(sol)),
      undefined,
    );
    choice = "Off";
    await second.commands["openai-fastmode"].handler("", makeCtx(mini));
    check(
      "toggle keeps models",
      JSON.parse(readFileSync(configFile, "utf8")).models,
      ["gpt-5.4-mini"],
    );

    // A failed save leaves state unchanged and never enables injection.
    rmSync(configFile, { force: true });
    mkdirSync(configFile);
    const failing = wire();
    choice = "On";
    await failing.commands["openai-fastmode"].handler("", makeCtx(sol));
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
      failing.events.before_provider_request({ payload }, makeCtx(sol)),
      undefined,
    );
    rmSync(configFile, { recursive: true, force: true });

    // A corrupt file falls back to off and defaults.
    writeFileSync(configFile, "{not json");
    const third = wire();
    check(
      "corrupt file is off",
      third.events.before_provider_request({ payload }, makeCtx(sol)),
      undefined,
    );

    // The probe script requires a minimum count: an empty or partial run must not pass.
    results._count = Object.keys(results).length;
    writeFileSync(out, JSON.stringify(results, null, 1));
  });
}
