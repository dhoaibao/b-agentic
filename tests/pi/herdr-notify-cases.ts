// Test-only extension for tests/pi/herdr-notify-probe.sh. At session start it exercises
// pi/extensions/b-herdr-notify.ts (the Herdr gate, the balanced blocked aggregate, toast
// throttle and privacy, the Pi wiring, and a missing or fake `herdr` binary) and writes one
// JSON result per case to $PROBE_OUT.
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  createHerdrNotifier,
  execHerdr,
  isHerdrEnabled,
  register,
  safeSurface,
} from "../../pi/extensions/b-herdr-notify.ts";

const results: Record<string, unknown> = {};
const check = (name: string, got: unknown, want: unknown) => {
  results[name] =
    JSON.stringify(got) === JSON.stringify(want) ? "ok" : { got, want };
};

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const HERDR_ENV = {
  HERDR_ENV: "1",
  HERDR_SOCKET_PATH: "/tmp/herdr-probe.sock",
  HERDR_PANE_ID: "p_probe",
};

function harness(root = true, throwing = false) {
  const log: string[] = [];
  let clock = 1_000_000;
  const notifier = createHerdrNotifier({
    toast: (title, body) => {
      log.push(`toast:${title}|${body}`);
      if (throwing) throw new Error("toast failed");
    },
    emit: (active, label) => {
      log.push(`emit:${active}${label ? `|${label}` : ""}`);
      if (throwing) throw new Error("emit failed");
    },
    now: () => clock,
  });
  notifier.setRoot(root);
  return {
    notifier,
    log,
    advance: (ms: number) => {
      clock += ms;
    },
    emits: () =>
      log.filter((l) => l.startsWith("emit:")).map((l) => l.slice(5)),
    toasts: () => log.filter((l) => l.startsWith("toast:")).length,
  };
}

// A minimal stand-in for Pi's extension API that records handlers and emitted events.
function fakePi() {
  const handlers: Record<string, ((...a: unknown[]) => unknown)[]> = {};
  const bus: Record<string, ((d: unknown) => unknown)[]> = {};
  const emitted: unknown[] = [];
  const pi = {
    on: (name: string, h: (...a: unknown[]) => unknown) => {
      (handlers[name] ??= []).push(h);
    },
    events: {
      on: (name: string, h: (d: unknown) => unknown) => {
        (bus[name] ??= []).push(h);
      },
      emit: (name: string, data: unknown) => {
        if (name === "herdr:blocked") emitted.push(data);
        for (const h of bus[name] ?? []) h(data);
      },
    },
  };
  return { pi: pi as unknown as ExtensionAPI, pi_: pi, handlers, bus, emitted };
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    const out = process.env.PROBE_OUT;
    if (!out) return;
    const work = process.env.PROBE_WORK ?? "/tmp";

    // The Herdr gate: all three variables are needed, and PI_HERDR_NOTIFY=off wins.
    check("enabled with herdr env", isHerdrEnabled(HERDR_ENV), true);
    check("disabled without HERDR_ENV", isHerdrEnabled({}), false);
    check(
      "disabled when HERDR_ENV is not 1",
      isHerdrEnabled({ ...HERDR_ENV, HERDR_ENV: "0" }),
      false,
    );
    check(
      "disabled without socket",
      isHerdrEnabled({ ...HERDR_ENV, HERDR_SOCKET_PATH: "" }),
      false,
    );
    check(
      "disabled without pane",
      isHerdrEnabled({ ...HERDR_ENV, HERDR_PANE_ID: undefined }),
      false,
    );
    check(
      "disabled by opt-out",
      isHerdrEnabled({ ...HERDR_ENV, PI_HERDR_NOTIFY: "off" }),
      false,
    );

    // Surfaces are shown only when they look like a tool name.
    check("surface plain", safeSurface("bash"), "bash");
    check(
      "surface mcp tool",
      safeSurface("playwright_browser_click"),
      "playwright_browser_click",
    );
    check("surface with path dropped", safeSurface("/etc/passwd"), undefined);
    check("surface with space dropped", safeSurface("git push"), undefined);
    check("surface too long dropped", safeSurface("a".repeat(33)), undefined);
    check("surface non-string dropped", safeSurface({ x: 1 }), undefined);

    // One ask: one balanced pair and one toast.
    {
      const h = harness();
      h.notifier.onAsk({ active: true });
      check("ask active state", h.notifier.active, true);
      h.notifier.onAsk({ active: false });
      check("ask pair", h.emits(), [
        "true|Question waiting for your answer",
        "false",
      ]);
      check("ask one toast", h.toasts(), 1);
      check("ask cleared state", h.notifier.active, false);
    }
    // Overlapping asks stay one pair and one toast.
    {
      const h = harness();
      h.notifier.onAsk({ active: true });
      h.notifier.onAsk({ active: true });
      h.notifier.onAsk({ active: false });
      check("overlap still active", h.notifier.active, true);
      h.notifier.onAsk({ active: false });
      check("overlap one pair", h.emits().length, 2);
      check("overlap one toast", h.toasts(), 1);
    }
    // A stray `false` never goes negative or emits.
    {
      const h = harness();
      h.notifier.onAsk({ active: false });
      h.notifier.onAsk({ active: true });
      check("stray false ignored", h.emits(), [
        "true|Question waiting for your answer",
      ]);
    }
    // Permission prompt and decision join by requestId.
    {
      const h = harness();
      h.notifier.onPrompt({
        requestId: "r1",
        surface: "bash",
        value: "SECRET-CMD",
      });
      check("permission blocks", h.notifier.active, true);
      h.notifier.onDecision({ requestId: "r1" });
      check("permission pair", h.emits(), [
        "true|Permission needed: bash",
        "false",
      ]);
    }
    // A decision for an unknown id clears nothing and emits nothing.
    {
      const h = harness();
      h.notifier.onDecision({ requestId: "ghost" });
      check("unknown decision silent", h.log, []);
      h.notifier.onPrompt({ requestId: "r1", surface: "read" });
      h.notifier.onDecision({ requestId: "ghost" });
      check("unknown decision keeps blocked", h.notifier.active, true);
    }
    // A duplicate prompt id is not counted twice.
    {
      const h = harness();
      h.notifier.onPrompt({ requestId: "r1", surface: "bash" });
      h.notifier.onPrompt({ requestId: "r1", surface: "bash" });
      h.notifier.onDecision({ requestId: "r1" });
      check("duplicate prompt id", h.emits().length, 2);
    }
    // Concurrent permission prompts stay one pair until the last decision.
    {
      const h = harness();
      h.notifier.onPrompt({ requestId: "a", surface: "bash" });
      h.notifier.onPrompt({ requestId: "b", surface: "mcp" });
      h.notifier.onDecision({ requestId: "a" });
      check("two prompts still blocked", h.notifier.active, true);
      h.notifier.onDecision({ requestId: "b" });
      check("two prompts one pair", h.emits().length, 2);
      check("two prompts one toast", h.toasts(), 1);
    }
    // An ask plus a permission prompt overlap into one pair.
    {
      const h = harness();
      h.notifier.onAsk({ active: true });
      h.notifier.onPrompt({ requestId: "r1", surface: "bash" });
      h.notifier.onAsk({ active: false });
      check("mixed still blocked", h.notifier.active, true);
      h.notifier.onDecision({ requestId: "r1" });
      check("mixed one pair", h.emits().length, 2);
    }
    // Toast throttle: queued asks keep exact state but ping once within the cooldown.
    {
      const h = harness();
      h.notifier.onPrompt({ requestId: "a", surface: "bash" });
      h.notifier.onDecision({ requestId: "a" });
      h.advance(1000);
      h.notifier.onPrompt({ requestId: "b", surface: "bash" });
      h.notifier.onDecision({ requestId: "b" });
      check("throttle exact pairs", h.emits().length, 4);
      check("throttle one toast", h.toasts(), 1);
      h.advance(5000);
      h.notifier.onPrompt({ requestId: "c", surface: "bash" });
      check("toast after cooldown", h.toasts(), 2);
    }
    // Privacy: prompt values, request facts, and unsafe surfaces never reach the toast.
    {
      const h = harness();
      h.notifier.onPrompt({
        requestId: "r1",
        surface: "bash",
        value: "rm -rf SECRET-VALUE",
        agentName: "SECRET-AGENT",
        request: { matchedPattern: "SECRET-PATTERN" },
      });
      check("privacy label", h.log.join("\n").includes("SECRET"), false);
      const h2 = harness();
      h2.notifier.onPrompt({
        requestId: "r2",
        surface: "/home/me/SECRET-PATH",
      });
      check(
        "unsafe surface omitted",
        h2.log.join("\n").includes("SECRET"),
        false,
      );
      check("unsafe surface generic", h2.emits()[0], "true|Permission needed");
    }
    // Malformed payloads never throw or emit.
    {
      const h = harness();
      for (const bad of [
        null,
        undefined,
        1,
        "x",
        {},
        { active: "yes" },
        { requestId: 5 },
      ]) {
        h.notifier.onAsk(bad);
        h.notifier.onPrompt(bad);
        h.notifier.onDecision(bad);
      }
      check("malformed payloads silent", h.log, []);
    }
    // Non-root sessions are inert.
    {
      const h = harness(false);
      h.notifier.onAsk({ active: true });
      h.notifier.onPrompt({ requestId: "r1", surface: "bash" });
      check("non-root silent", h.log, []);
    }
    // Shutdown while blocked closes the pair; shutdown while idle emits nothing.
    {
      const h = harness();
      h.notifier.onAsk({ active: true });
      h.notifier.shutdown();
      check("shutdown balances", h.emits(), [
        "true|Question waiting for your answer",
        "false",
      ]);
      h.notifier.onAsk({ active: true });
      check("inert after shutdown", h.emits().length, 2);
      const idle = harness();
      idle.notifier.shutdown();
      check("idle shutdown silent", idle.log, []);
    }
    // A throwing toast or emit is contained.
    {
      const h = harness(true, true);
      let threw = false;
      try {
        h.notifier.onAsk({ active: true });
        h.notifier.onAsk({ active: false });
        h.notifier.shutdown();
      } catch {
        threw = true;
      }
      check("throwing deps contained", threw, false);
    }

    // Wiring: nothing is registered outside Herdr, with the opt-out, or without its env.
    {
      const off = fakePi();
      register(off.pi, {});
      check(
        "no registration without herdr",
        [Object.keys(off.handlers), Object.keys(off.bus)],
        [[], []],
      );
      const optOut = fakePi();
      register(optOut.pi, { ...HERDR_ENV, PI_HERDR_NOTIFY: "off" });
      check(
        "no registration when opted out",
        [Object.keys(optOut.handlers), Object.keys(optOut.bus)],
        [[], []],
      );
    }
    // Wiring in a root TUI session: asks, permission prompts, and shutdown reach herdr:blocked.
    {
      const toasts: string[] = [];
      const w = fakePi();
      register(
        w.pi,
        HERDR_ENV,
        (t, b) => toasts.push(`${t}|${b}`),
        () => 1_000_000,
      );
      check(
        "wiring subscribes",
        [Object.keys(w.handlers).sort(), Object.keys(w.bus).sort()],
        [["session_shutdown", "session_start"], []],
      );
      // Before a root TUI session starts nothing is subscribed, so nothing is emitted.
      w.pi_.events.emit("rpiv:ask-user:blocked", { active: true });
      check("silent before session start", w.emitted, []);
      w.pi_.events.emit("rpiv:ask-user:blocked", { active: false });
      w.handlers.session_start[0]({}, { mode: "tui", hasUI: true });
      check("subscribes on root tui start", Object.keys(w.bus).sort(), [
        "permissions:decision",
        "permissions:ui_prompt",
        "rpiv:ask-user:blocked",
      ]);
      // A second session start (reload, new session) does not subscribe twice.
      w.handlers.session_start[0]({}, { mode: "tui", hasUI: true });
      check(
        "no double subscription",
        Object.values(w.bus).map((l) => l.length),
        [1, 1, 1],
      );
      w.pi_.events.emit("rpiv:ask-user:blocked", { active: true });
      w.pi_.events.emit("rpiv:ask-user:blocked", { active: false });
      w.pi_.events.emit("permissions:ui_prompt", {
        requestId: "r1",
        surface: "bash",
        value: "SECRET",
      });
      w.handlers.session_shutdown[0]({});
      check("wiring emits balanced pairs", w.emitted, [
        { active: true, label: "Question waiting for your answer" },
        { active: false },
        { active: true, label: "Permission needed: bash" },
        { active: false },
      ]);
      check("wiring toasts", toasts, [
        "Pi needs input|Question waiting for your answer",
      ]);
    }
    // A non-TUI session (print, JSON, RPC) never becomes root.
    {
      const w = fakePi();
      register(
        w.pi,
        HERDR_ENV,
        () => {},
        () => 1,
      );
      w.handlers.session_start[0]({}, { mode: "json", hasUI: false });
      w.pi_.events.emit("rpiv:ask-user:blocked", { active: true });
      check("non-tui session silent", w.emitted, []);
      check("non-tui session never subscribes", Object.keys(w.bus), []);
    }
    // Full wiring with the real process call and no `herdr` binary on PATH: a blocked
    // period still runs to completion without a throw, a rejection, or a stray event.
    {
      const emptyBin = path.join(work, "empty-bin-wiring");
      mkdirSync(emptyBin, { recursive: true });
      const w = fakePi();
      const seen: unknown[] = [];
      const onError = (e: unknown) => seen.push(e);
      process.on("unhandledRejection", onError);
      process.on("uncaughtException", onError);
      let threw = false;
      try {
        register(w.pi, { ...HERDR_ENV, PATH: emptyBin });
        w.handlers.session_start[0]({}, { mode: "tui", hasUI: true });
        w.pi_.events.emit("permissions:ui_prompt", {
          requestId: "r1",
          surface: "bash",
        });
        w.pi_.events.emit("permissions:decision", { requestId: "r1" });
        w.handlers.session_shutdown[0]({});
      } catch {
        threw = true;
      }
      await sleep(300);
      process.off("unhandledRejection", onError);
      process.off("uncaughtException", onError);
      check("wiring without herdr binary does not throw", threw, false);
      check(
        "wiring without herdr binary raises no error events",
        seen.length,
        0,
      );
      check("wiring without herdr binary keeps pair balanced", w.emitted, [
        { active: true, label: "Permission needed: bash" },
        { active: false },
      ]);
    }

    // The real process call: a missing `herdr` is silent (no throw, no rejection).
    const noBin = path.join(work, "empty-bin");
    mkdirSync(noBin, { recursive: true });
    const seen: unknown[] = [];
    const onError = (e: unknown) => seen.push(e);
    process.on("unhandledRejection", onError);
    process.on("uncaughtException", onError);
    let threw = false;
    try {
      execHerdr("title", "body", { PATH: noBin });
    } catch {
      threw = true;
    }
    await sleep(300);
    process.off("unhandledRejection", onError);
    process.off("uncaughtException", onError);
    check("missing herdr does not throw", threw, false);
    check("missing herdr raises no error events", seen.length, 0);

    // A fake `herdr` records its exact argv; a leading dash in the body stays one argument.
    const bin = path.join(work, "fake-bin");
    const record = path.join(work, "argv.txt");
    mkdirSync(bin, { recursive: true });
    const fake = path.join(bin, "herdr");
    writeFileSync(fake, `#!/bin/sh\nprintf '%s\\n' "$@" > "${record}"\n`);
    chmodSync(fake, 0o755);
    execHerdr("Pi needs input", "-x Permission needed: bash", {
      PATH: `${bin}:/usr/bin:/bin`,
    });
    for (let i = 0; i < 40 && !existsSync(record); i += 1) await sleep(50);
    await sleep(100);
    check(
      "herdr argv",
      existsSync(record)
        ? readFileSync(record, "utf8").split("\n").slice(0, -1)
        : null,
      [
        "notification",
        "show",
        "Pi needs input",
        "--body=-x Permission needed: bash",
        "--sound",
        "request",
      ],
    );

    // The probe script requires a minimum count: an empty or partial run must not pass.
    results._count = Object.keys(results).length;
    writeFileSync(out, JSON.stringify(results, null, 1));
  });
}
