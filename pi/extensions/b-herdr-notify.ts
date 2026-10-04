// Herdr blocked-prompt notifier: when Pi is waiting on you (an `ask_user_question`
// questionnaire or a permission ask), mark the Herdr pane blocked and show one Herdr
// toast with sound.
//
// Display-only and environment-gated:
// - It does nothing unless Herdr is in use (HERDR_ENV=1 plus HERDR_SOCKET_PATH and
//   HERDR_PANE_ID, the same gate as Herdr's own Pi integration). It subscribes to prompt
//   events only once a root interactive TUI session starts; elsewhere it stays inert.
// - It never throws or rejects: a missing `herdr` binary, a socket error, or a
//   malformed event payload is ignored silently.
// - It has no dependency on the extensions it listens to. Channels nobody emits are
//   harmless, so it works with either source absent.
// - It marks the pane through the `herdr:blocked` event that Herdr's managed
//   `herdr-agent-state.ts` already handles (that file is never edited). Every
//   `active: true` is followed by exactly one `active: false`, at the latest on
//   session shutdown, because Herdr counts them in pairs.
// - Toast text is privacy-safe: a fixed title plus, for a permission ask, only the
//   tool surface name (for example `bash`). Commands, paths, question text, agent
//   names, and other prompt values never leave Pi.
// - The toast is throttled so queued permission asks do not ping repeatedly; the
//   blocked state itself is always exact.
//
// Set PI_HERDR_NOTIFY=off to disable it without removing the file.
import { execFile } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const ASK_CHANNEL = "rpiv:ask-user:blocked";
const PROMPT_CHANNEL = "permissions:ui_prompt";
const DECISION_CHANNEL = "permissions:decision";
const BLOCKED_CHANNEL = "herdr:blocked";
const TOAST_COOLDOWN_MS = 5000;
const SURFACE = /^[a-z0-9_:-]{1,32}$/i;

export type EnvLike = Record<string, string | undefined>;

export interface NotifierDeps {
  /** Show one toast. May throw; the notifier contains it. */
  toast(title: string, body: string): void;
  /** Publish a `herdr:blocked` event. May throw; the notifier contains it. */
  emit(active: boolean, label?: string): void;
  now(): number;
}

/** Herdr is in use for this process, and the user has not opted out. */
export function isHerdrEnabled(env: EnvLike): boolean {
  return (
    env.HERDR_ENV === "1" &&
    !!env.HERDR_SOCKET_PATH &&
    !!env.HERDR_PANE_ID &&
    env.PI_HERDR_NOTIFY !== "off"
  );
}

/** A tool surface safe to show in a toast, or undefined. */
export function safeSurface(value: unknown): string | undefined {
  return typeof value === "string" && SURFACE.test(value) ? value : undefined;
}

function guard(fn: () => void): void {
  try {
    fn();
  } catch {
    // Notification is best-effort; it must never affect Pi.
  }
}

/**
 * Aggregates every open prompt into one blocked period: one balanced
 * `herdr:blocked` pair and at most one (throttled) toast per period.
 */
export function createHerdrNotifier(deps: NotifierDeps) {
  let root = false;
  let askDepth = 0;
  const permissionIds = new Set<string>();
  let active = false;
  let lastToast = Number.NEGATIVE_INFINITY;

  function update(title: string, body: string): void {
    const blocked = askDepth + permissionIds.size > 0;
    if (blocked === active) return;
    active = blocked;
    if (active) {
      guard(() => deps.emit(true, body));
      const now = deps.now();
      if (now - lastToast >= TOAST_COOLDOWN_MS) {
        lastToast = now;
        guard(() => deps.toast(title, body));
      }
    } else {
      guard(() => deps.emit(false));
    }
  }

  return {
    get active() {
      return active;
    },
    /** Called at session start with whether this is the root interactive TUI. */
    setRoot(value: boolean): void {
      root = value;
    },
    onAsk(data: unknown): void {
      if (!root) return;
      const flag = (data as { active?: unknown } | null | undefined)?.active;
      if (flag === true) askDepth += 1;
      else if (flag === false) askDepth = Math.max(0, askDepth - 1);
      else return;
      update("Pi needs input", "Question waiting for your answer");
    },
    onPrompt(data: unknown): void {
      if (!root) return;
      const event = data as { requestId?: unknown; surface?: unknown } | null;
      const id = event?.requestId;
      if (typeof id !== "string") return;
      permissionIds.add(id);
      const surface = safeSurface(event?.surface);
      update(
        "Pi needs input",
        surface ? `Permission needed: ${surface}` : "Permission needed",
      );
    },
    onDecision(data: unknown): void {
      if (!root) return;
      const id = (data as { requestId?: unknown } | null | undefined)
        ?.requestId;
      if (typeof id !== "string" || !permissionIds.delete(id)) return;
      update("", "");
    },
    /** Close any open blocked state so Herdr's counter stays balanced. */
    shutdown(): void {
      askDepth = 0;
      permissionIds.clear();
      root = false;
      if (active) {
        active = false;
        guard(() => deps.emit(false));
      }
    },
  };
}

/** Fire-and-forget `herdr notification show`; every failure is ignored. */
export function execHerdr(
  title: string,
  body: string,
  env: EnvLike = process.env,
): void {
  try {
    execFile(
      "herdr",
      ["notification", "show", title, `--body=${body}`, "--sound", "request"],
      {
        env: env as NodeJS.ProcessEnv,
        timeout: 3000,
        windowsHide: true,
        maxBuffer: 64 * 1024,
      },
      () => {},
    );
  } catch {
    // Missing binary or spawn failure: no visible effect.
  }
}

/** Wire the notifier to Pi. Registers nothing unless Herdr is enabled. */
export function register(
  pi: ExtensionAPI,
  env: EnvLike = process.env,
  toast: (title: string, body: string) => void = (title, body) =>
    execHerdr(title, body, env),
  now: () => number = Date.now,
): void {
  if (!isHerdrEnabled(env)) return;
  const notifier = createHerdrNotifier({
    toast,
    emit: (active, label) =>
      pi.events.emit(BLOCKED_CHANNEL, active ? { active, label } : { active }),
    now,
  });

  // The prompt listeners are attached only once a root TUI session starts, so print,
  // JSON, and RPC runs (and subagent children) never subscribe to anything.
  let subscribed = false;
  function subscribe(): void {
    if (subscribed) return;
    subscribed = true;
    pi.events.on(ASK_CHANNEL, (data) => guard(() => notifier.onAsk(data)));
    pi.events.on(PROMPT_CHANNEL, (data) =>
      guard(() => notifier.onPrompt(data)),
    );
    pi.events.on(DECISION_CHANNEL, (data) =>
      guard(() => notifier.onDecision(data)),
    );
  }

  pi.on("session_start", (_event, ctx) => {
    guard(() => {
      const tui = ctx?.mode === "tui" && !!ctx?.hasUI;
      if (tui) subscribe();
      notifier.setRoot(tui);
    });
  });
  pi.on("session_shutdown", () => {
    guard(() => notifier.shutdown());
  });
}

export default function (pi: ExtensionAPI) {
  register(pi);
}
