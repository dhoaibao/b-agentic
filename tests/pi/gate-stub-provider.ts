// A local, credential-free model that scripts edit/check sequences for the
// b-verify-gate probe. The scenario is the first user prompt; each model call
// takes the next step, and every scenario ends with a plain-text reply.
import {
  createAssistantMessageEventStream,
  type Api,
  type AssistantMessage,
  type AssistantMessageEventStream,
  type Model,
  type SimpleStreamOptions,
  type TranscriptContext,
} from "@earendil-works/pi-ai/compat";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type Step = { name: string; arguments: Record<string, unknown> } | "text";

const edit: Step = {
  name: "write",
  arguments: { path: "gate-scratch.ts", content: "export {};\n" },
};
const prose: Step = {
  name: "write",
  arguments: { path: "gate-notes.md", content: "notes\n" },
};
const check: Step = { name: "bash", arguments: { command: "echo checked" } };

const snapshot: Step = { name: "b_candidate_snapshot", arguments: {} };
const snapshotIgnored = (...paths: string[]): Step => ({
  name: "b_candidate_snapshot",
  arguments: { include_ignored: paths },
});

const SCENARIOS: Record<string, Step[]> = {
  // Used by tests/pi/snapshot-probe.sh.
  "snap-once": [snapshot, "text"],
  "snap-twice": [snapshot, snapshot, "text"],
  "snap-ignored": [snapshot, snapshotIgnored("dist"), "text"],
  "snap-ignored-glob": [snapshotIgnored("d*"), "text"],
  "snap-ignored-missing": [snapshotIgnored("nope"), "text"],
  "snap-ignored-outside": [snapshotIgnored("../escape"), "text"],
  // The probe exports the absolute path of an ignored file inside its fixture.
  "snap-ignored-absolute": [
    snapshotIgnored(process.env.SNAPSHOT_PROBE_ABSOLUTE ?? "/missing"),
    "text",
  ],
  "snap-ignored-surrogate": [snapshotIgnored("dist/\ud800.js"), "text"],
  "snap-ignored-secret": [snapshotIgnored(".env"), "text"],
  "gate-edit": [edit, "text"],
  "gate-edit-check": [edit, check, "text"],
  "gate-check-edit": [check, edit, "text"],
  "gate-prose": [prose, "text"],
  "gate-none": ["text"],
  // Edits again after the reminder; must not draw a second one.
  "gate-loop": [edit, "text", edit, "text"],
};

function streamStub(
  model: Model<Api>,
  context: TranscriptContext,
  _options?: SimpleStreamOptions,
): AssistantMessageEventStream {
  const stream = createAssistantMessageEventStream();
  const message: AssistantMessage = {
    role: "assistant",
    content: [],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: {
      input: 1,
      output: 1,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 2,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: "pending",
    timestamp: Date.now(),
  };

  queueMicrotask(() => {
    stream.push({ type: "start", partial: message });
    const prompt =
      context.messages
        .find((entry) => entry.role === "user")
        ?.content.filter((part) => part.type === "text")
        .map((part) => part.text)
        .join(" ") ?? "";
    const steps = SCENARIOS[prompt] ?? ["text"];
    // Tool results so far select the next scripted step; once the script is
    // exhausted the model answers in text, including after a gate reminder.
    const done = context.messages.filter(
      (entry) => entry.role === "toolResult",
    ).length;
    // The model's first text ends its first turn; a later scripted step runs
    // only after a reminder message has been added to the transcript.
    const reminded = context.messages.some((entry) =>
      JSON.stringify(entry.content ?? "").includes("b-agentic verify gate"),
    );
    const index = reminded ? done + 1 : done;
    const step = steps[Math.min(index, steps.length - 1)];
    if (step === "text") {
      const text = "gate-probe-done";
      message.content.push({ type: "text", text });
      stream.push({ type: "text_start", contentIndex: 0, partial: message });
      stream.push({
        type: "text_end",
        contentIndex: 0,
        content: text,
        partial: message,
      });
      message.stopReason = "stop";
      stream.push({ type: "done", reason: "stop", message });
    } else {
      const toolCall = {
        type: "toolCall" as const,
        id: `gate-${done + 1}`,
        name: step.name,
        arguments: step.arguments,
      };
      message.content.push(toolCall);
      stream.push({
        type: "toolcall_start",
        contentIndex: 0,
        partial: message,
      });
      stream.push({
        type: "toolcall_end",
        contentIndex: 0,
        toolCall,
        partial: message,
      });
      message.stopReason = "toolUse";
      stream.push({ type: "done", reason: "toolUse", message });
    }
    stream.end();
  });
  return stream;
}

export default function (pi: ExtensionAPI) {
  pi.registerProvider("gate-stub", {
    baseUrl: "http://127.0.0.1:9", // streamSimple never contacts this endpoint.
    apiKey: "stub",
    api: "gate-stub-api",
    models: [
      {
        id: "gate-1",
        name: "Gate 1",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 200000,
        maxTokens: 8192,
      },
    ],
    streamSimple: streamStub,
  });
}
