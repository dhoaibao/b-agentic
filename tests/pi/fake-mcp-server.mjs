// A stdio MCP fixture: no network, credentials, or filesystem mutations.
import readline from "node:readline";

for await (const line of readline.createInterface({ input: process.stdin })) {
  let request;
  try {
    request = JSON.parse(line);
  } catch {
    continue;
  }
  if (request.id === undefined) continue;

  let result;
  switch (request.method) {
    case "initialize":
      result = {
        protocolVersion: request.params.protocolVersion,
        capabilities: { tools: {} },
        serverInfo: { name: "b-agentic-permission-probe", version: "0" },
      };
      break;
    case "tools/list":
      result = {
        tools: ["lookup", "erase"].map((name) => ({
          name,
          description: `Probe ${name}`,
          inputSchema: {
            type: "object",
            properties: {},
            additionalProperties: false,
          },
        })),
      };
      break;
    case "tools/call":
      result = {
        content: [
          { type: "text", text: `server-called:${request.params.name}` },
        ],
      };
      break;
    case "ping":
      result = {};
      break;
    default:
      process.stdout.write(
        `${JSON.stringify({ jsonrpc: "2.0", id: request.id, error: { code: -32601, message: "Unknown method" } })}\n`,
      );
      continue;
  }
  process.stdout.write(
    `${JSON.stringify({ jsonrpc: "2.0", id: request.id, result })}\n`,
  );
}
