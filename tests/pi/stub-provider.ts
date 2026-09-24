// A local, credential-free model for exercising real Pi tool decisions.
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
    const results = context.messages.filter(
      (entry) => entry.role === "toolResult",
    );
    const result = results.at(-1);
    if (
      !result ||
      (context.messages.some(
        (entry) =>
          entry.role === "user" &&
          entry.content.some(
            (part) => part.type === "text" && part.text === "direct",
          ),
      ) &&
        results.length === 1)
    ) {
      const request = context.messages.find((entry) => entry.role === "user");
      const prompt =
        request?.content
          .filter((part) => part.type === "text")
          .map((part) => part.text)
          .join(" ") ?? "";
      const toolCall =
        prompt === "direct-allow"
          ? {
              type: "toolCall" as const,
              id: "probe-1",
              name: "fake_lookup",
              arguments: {},
            }
          : prompt === "direct"
            ? {
                type: "toolCall" as const,
                id: `probe-${results.length + 1}`,
                name: results.length ? "fake_erase" : "mcp",
                arguments: results.length ? {} : { connect: "fake" },
              }
            : prompt.startsWith("child-")
              ? {
                  type: "toolCall" as const,
                  id: "probe-1",
                  name: "subagent",
                  arguments: {
                    subagent_type: "probe-reader",
                    prompt: prompt.slice(6),
                    description: "Probe child policy",
                  },
                }
              : prompt === "write" ||
                  prompt === "nested" ||
                  prompt === "question"
                ? {
                    type: "toolCall" as const,
                    id: "probe-1",
                    name:
                      prompt === "nested"
                        ? "subagent"
                        : prompt === "question"
                          ? "ask_user_question"
                          : "write",
                    arguments:
                      prompt === "write"
                        ? {
                            path: "scratch.txt",
                            content: "should not be written",
                          }
                        : prompt === "nested"
                          ? {
                              subagent_type: "probe-reader",
                              prompt: "shell",
                              description: "Nested child",
                            }
                          : {
                              questions: [
                                {
                                  question: "Continue?",
                                  header: "Probe",
                                  options: [
                                    { label: "Yes", description: "Continue" },
                                  ],
                                },
                              ],
                            },
                  }
                : prompt === "mcp" || prompt === "mcp-lookup"
                  ? {
                      type: "toolCall" as const,
                      id: "probe-1",
                      name: "mcp",
                      arguments:
                        prompt === "mcp-lookup"
                          ? { tool: "fake_lookup", server: "fake", args: {} }
                          : {
                              tool: "fake_delete",
                              server: "fake",
                              args: { path: "scratch.txt" },
                            },
                    }
                  : prompt === "path"
                    ? {
                        type: "toolCall" as const,
                        id: "probe-1",
                        name: "read",
                        arguments: { path: ".env" },
                      }
                    : {
                        type: "toolCall" as const,
                        id: "probe-1",
                        name: "bash",
                        arguments: { command: "echo permission-probe" },
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
      const text = `done: ${result.isError} ${result.content
        .filter((part) => part.type === "text")
        .map((part) => part.text)
        .join(" ")}`;
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
    }
    stream.end();
  });
  return stream;
}

export default function (pi: ExtensionAPI) {
  pi.registerProvider("stub", {
    baseUrl: "http://127.0.0.1:9", // streamSimple never contacts this endpoint.
    apiKey: "stub",
    api: "stub-api",
    models: [
      {
        id: "stub-1",
        name: "Stub 1",
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
