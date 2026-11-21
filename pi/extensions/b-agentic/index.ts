// b-agentic guard for Pi: the entry Pi loads. Every decision lives in guard.mjs
// (plain Node, tested without Pi); this file only supplies what needs the Pi
// package: the extension type, the running Pi version, and this file's own path
// and hook folder (installed beside the extension under the agent directory).
import { fileURLToPath } from "node:url";
import { VERSION, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { register } from "./guard.mjs";

export default async function (pi: ExtensionAPI) {
  await register(pi, {
    version: VERSION,
    entryPath: fileURLToPath(import.meta.url),
    hooksDir: new URL("../../b-agentic/hooks/", import.meta.url).href,
  });
}
