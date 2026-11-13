// A credential-free scripted model for the Pi guard probe. PI_PROBE_STEPS is a
// JSON array of {name, arguments} tool calls or "text", or an object that maps a
// string found in the first user message to such an array (so a specialist
// child follows its own script). Each model call takes the next step (index =
// assistant messages already in the transcript), and every call's context is
// appended to PI_PROBE_LOG.
import { appendFileSync } from "node:fs";
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

const text = (content: unknown): string =>
  typeof content === "string"
    ? content
    : Array.isArray(content)
      ? content
          .map((part: any) =>
            part.type === "text"
              ? part.text
              : part.type === "toolCall"
                ? `[toolCall ${part.name}]`
                : `[${part.type}]`,
          )
          .join(" ")
      : String(content);

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
    const parsed = JSON.parse(process.env.PI_PROBE_STEPS ?? '["text"]');
    const firstUser = text(
      (context.messages.find((m: any) => m.role === "user") as any)?.content,
    );
    const steps: Step[] = Array.isArray(parsed)
      ? parsed
      : ((Object.entries(parsed).find(([key]) =>
          firstUser.includes(key),
        )?.[1] as Step[] | undefined) ?? ["text"]);
    const calls = context.messages.filter(
      (m: any) => m.role === "assistant",
    ).length;
    const summarizing = text((context.messages[0] as any)?.content).includes(
      "summarization",
    );
    const step: Step = summarizing
      ? "text"
      : steps[Math.min(calls, steps.length - 1)];
    if (process.env.PI_PROBE_LOG) {
      appendFileSync(
        process.env.PI_PROBE_LOG,
        `${JSON.stringify({
          type: "model_call",
          n: calls,
          step,
          contextKeys: Object.keys(context),
          tools: (context as any).tools?.map((t: any) => t.name),
          system: (context as any).systemPrompt ?? null,
          messages: context.messages.map((m: any) => ({
            role: m.role,
            customType: m.customType,
            text: text(m.content),
          })),
        })}\n`,
      );
    }
    stream.push({ type: "start", partial: message });
    if (step && step !== "text") {
      const toolCall = {
        type: "toolCall" as const,
        id: `probe-${calls + 1}`,
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
    } else {
      const reply = `probe-reply-${calls}`;
      message.content.push({ type: "text", text: reply });
      stream.push({ type: "text_start", contentIndex: 0, partial: message });
      stream.push({
        type: "text_end",
        contentIndex: 0,
        content: reply,
        partial: message,
      });
      message.stopReason = "stop";
      stream.push({ type: "done", reason: "stop", message });
    }
    stream.end();
  });
  return stream;
}

export default function (pi: ExtensionAPI) {
  pi.registerProvider("probe", {
    baseUrl: "http://127.0.0.1:9",
    apiKey: "probe",
    api: "probe-api",
    models: [
      {
        id: "probe-1",
        name: "Probe 1",
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
